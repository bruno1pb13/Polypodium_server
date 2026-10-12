import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../../core/config.dart';
import '../../core/http_utils.dart';
import '../gardens/i_garden_repository.dart';
import 'i_mcp_token_repository.dart';

const _maxNameLength = 100;
const _maxTokensPerMember = 20;

/// `/gardens/<id>/mcp-tokens`: the tokens an MCP client connects to one
/// garden with. Any member creates and revokes their own; the owner sees
/// and revokes everyone's. A garden the caller doesn't belong to answers
/// 404, like the rest of `/gardens`.
class McpTokenHandler {
  const McpTokenHandler(this._tokens, this._gardens);
  final IMcpTokenRepository _tokens;
  final IGardenRepository _gardens;

  Future<Response> list(Request request, String gardenId) async {
    final userId = request.context['userId'] as String;
    final role = await _gardens.memberRole(gardenId, userId);
    if (role == null) return _gardenNotFound();
    final tokens = await _tokens.list(gardenId,
        userId: role == 'owner' ? null : userId);
    return _json(200, {'tokens': tokens});
  }

  /// Body: `{"name": String, "canWrite": bool?}`. The secret is only in this
  /// response.
  Future<Response> create(Request request, String gardenId) async {
    final userId = request.context['userId'] as String;
    if (await _gardens.memberRole(gardenId, userId) == null) {
      return _gardenNotFound();
    }
    final body = await readJsonMap(request, maxBytes: Config.maxJsonBodyBytes);
    final name = body['name'];
    final trimmed = name is String ? name.trim() : '';
    if (trimmed.isEmpty || trimmed.length > _maxNameLength) {
      return _error(400, 'name must be 1-$_maxNameLength characters');
    }
    final canWrite = body['canWrite'];
    if (canWrite != null && canWrite is! bool) {
      return _error(400, 'canWrite must be a boolean');
    }
    if (await _tokens.countFor(gardenId, userId) >= _maxTokensPerMember) {
      return _error(409, 'token limit reached ($_maxTokensPerMember)');
    }
    return _json(
      201,
      await _tokens.create(gardenId, userId,
          name: trimmed, canWrite: canWrite == true),
    );
  }

  Future<Response> revoke(
      Request request, String gardenId, String tokenId) async {
    final userId = request.context['userId'] as String;
    final role = await _gardens.memberRole(gardenId, userId);
    if (role == null) return _gardenNotFound();
    final owner = await _tokens.ownerOf(gardenId, tokenId);
    // Someone else's token is as invisible to a member as a missing one.
    if (owner == null || (owner != userId && role != 'owner')) {
      return _error(404, 'token not found');
    }
    await _tokens.delete(gardenId, tokenId);
    return _json(200, {'ok': true});
  }
}

Response _gardenNotFound() => _error(404, 'garden not found');

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

Response _error(int status, String message) =>
    _json(status, {'error': message});
