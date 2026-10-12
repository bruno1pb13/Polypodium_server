import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import 'i_mcp_token_repository.dart';

/// Prefix of every MCP secret, so a leaked one is recognisable (and
/// greppable by secret scanners).
const mcpTokenPrefix = 'pmcp_';

String hashMcpToken(String secret) =>
    sha256.convert(utf8.encode(secret)).toString();

/// A fresh secret: the prefix plus 256 random bits, base64url.
String generateMcpToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return mcpTokenPrefix + base64Url.encode(bytes).replaceAll('=', '');
}

class McpTokenRepository implements IMcpTokenRepository {
  const McpTokenRepository(this._db);
  final Pool _db;

  @override
  Future<Map<String, dynamic>> create(
    String gardenId,
    String userId, {
    required String name,
    required bool canWrite,
  }) async {
    final id = const Uuid().v4();
    final secret = generateMcpToken();
    final prefix = secret.substring(0, mcpTokenPrefix.length + 6);
    final result = await _db.execute(
      Sql.named('''
        INSERT INTO mcp_tokens
          (id, garden_id, user_id, name, token_hash, token_prefix, can_write)
        VALUES (@id, @gardenId, @userId, @name, @hash, @prefix, @canWrite)
        RETURNING created_at
      '''),
      parameters: {
        'id': id,
        'gardenId': gardenId,
        'userId': userId,
        'name': name,
        'hash': hashMcpToken(secret),
        'prefix': prefix,
        'canWrite': canWrite,
      },
    );
    return {
      'id': id,
      'name': name,
      'tokenPrefix': prefix,
      'canWrite': canWrite,
      'createdAt': (result.first[0] as DateTime).toUtc().toIso8601String(),
      'token': secret,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> list(String gardenId,
      {String? userId}) async {
    final result = await _db.execute(
      Sql.named('''
        SELECT t.id, t.name, t.token_prefix, t.can_write, t.created_at,
               t.last_used_at, t.user_id, u.email
        FROM mcp_tokens t
        JOIN users u ON u.id = t.user_id
        WHERE t.garden_id = @gardenId
          AND (@userId::text IS NULL OR t.user_id = @userId::text)
        ORDER BY t.created_at, t.id
      '''),
      parameters: {'gardenId': gardenId, 'userId': userId},
    );
    return [
      for (final row in result)
        {
          'id': row[0] as String,
          'name': row[1] as String,
          'tokenPrefix': row[2] as String,
          'canWrite': row[3] as bool,
          'createdAt': (row[4] as DateTime).toUtc().toIso8601String(),
          'lastUsedAt': (row[5] as DateTime?)?.toUtc().toIso8601String(),
          'userId': row[6] as String,
          'email': row[7] as String,
        }
    ];
  }

  @override
  Future<int> countFor(String gardenId, String userId) async {
    final result = await _db.execute(
      Sql.named('''
        SELECT COUNT(*) FROM mcp_tokens
        WHERE garden_id = @gardenId AND user_id = @userId
      '''),
      parameters: {'gardenId': gardenId, 'userId': userId},
    );
    return (result.first[0] as num).toInt();
  }

  @override
  Future<String?> ownerOf(String gardenId, String tokenId) async {
    final result = await _db.execute(
      Sql.named('''
        SELECT user_id FROM mcp_tokens
        WHERE garden_id = @gardenId AND id = @id
      '''),
      parameters: {'gardenId': gardenId, 'id': tokenId},
    );
    return result.isEmpty ? null : result.first[0] as String;
  }

  @override
  Future<bool> delete(String gardenId, String tokenId) async {
    final result = await _db.execute(
      Sql.named('DELETE FROM mcp_tokens WHERE garden_id = @gardenId AND id = @id'),
      parameters: {'gardenId': gardenId, 'id': tokenId},
    );
    return result.affectedRows > 0;
  }

  @override
  Future<McpGrant?> resolve(String secret) async {
    if (!secret.startsWith(mcpTokenPrefix)) return null;
    final result = await _db.execute(
      Sql.named('''
        SELECT t.id, t.garden_id, g.name, t.user_id, t.can_write,
               (t.last_used_at IS NULL
                OR t.last_used_at < NOW() - INTERVAL '1 minute')
        FROM mcp_tokens t
        JOIN users u ON u.id = t.user_id AND NOT u.disabled
        JOIN gardens g ON g.id = t.garden_id
        JOIN garden_members m
          ON m.garden_id = t.garden_id AND m.user_id = t.user_id
        WHERE t.token_hash = @hash
      '''),
      parameters: {'hash': hashMcpToken(secret)},
    );
    if (result.isEmpty) return null;
    final row = result.first;
    final grant = McpGrant(
      tokenId: row[0] as String,
      gardenId: row[1] as String,
      gardenName: row[2] as String,
      userId: row[3] as String,
      canWrite: row[4] as bool,
    );
    // Coarse: one write a minute at most, not one per tool call.
    if (row[5] as bool) {
      await _db.execute(
        Sql.named('UPDATE mcp_tokens SET last_used_at = NOW() WHERE id = @id'),
        parameters: {'id': grant.tokenId},
      );
    }
    return grant;
  }
}
