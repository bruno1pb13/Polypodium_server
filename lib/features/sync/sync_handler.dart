import 'dart:convert';
import 'dart:math' as math;

import 'package:polypodium_core/polypodium_core.dart';
import 'package:shelf/shelf.dart';

import '../../core/config.dart';
import '../../core/http_utils.dart';
import 'i_sync_repository.dart';

class SyncHandler {
  const SyncHandler(this._repo);
  final ISyncRepository _repo;

  /// `GET /sync/changes?since=&limit=&entities=` — a real pull: returns
  /// this user's rows with `rev > since`, across every entity type unless
  /// `entities` restricts them.
  Future<Response> changes(Request request) async {
    final userId = request.context['userId'] as String;

    final params = request.url.queryParameters;
    final since = math.max(0, int.tryParse(params['since'] ?? '0') ?? 0);
    final limit =
        (int.tryParse(params['limit'] ?? '100') ?? 100).clamp(1, 1000);

    final entities = _csvSet(params['entities']);

    final result = await _repo.serveChanges(userId,
        since: since,
        limit: limit,
        entryTypes: _declaredEntryTypes(request),
        entityTypes: entities);
    final nextCursor =
        result.changes.isNotEmpty ? result.changes.last.rev : since;

    return _json(200, {
      'changes': result.changes.map((c) => c.toJson()).toList(),
      'nextCursor': nextCursor,
      'hasMore': result.hasMore,
      // Echoed so a client can tell the restriction was honored: a server
      // predating it would have sent every entity type. Only the types this
      // server stores, so a client also learns which ones it doesn't yet.
      if (entities != null)
        'entities': entities.intersection(syncEntityTypes).toList()..sort(),
      // Lets a client find out when an upgrade starts storing a type it
      // pushed before, so it can send those rows again.
      'supportedEntities': syncEntityTypes.toList()..sort(),
    });
  }

  /// `POST /sync/receive` — the client-server equivalent of a peer pushing
  /// its own local changes to us; internally applied via the same
  /// last-write-wins logic `receiveChanges` would use for any peer.
  Future<Response> receive(Request request) async {
    final userId = request.context['userId'] as String;
    final jwtDeviceId = request.context['deviceId'] as String;

    final body = await readJsonMap(request, maxBytes: Config.maxJsonBodyBytes);
    final deviceId = body['deviceId'] as String?;

    if (deviceId == null) {
      return _error(400, 'deviceId required');
    }
    if (deviceId != jwtDeviceId) {
      return _error(403, 'deviceId does not match token');
    }

    final changesRaw = body['changes'] as List<dynamic>? ?? [];
    if (changesRaw.length > 500) {
      return _error(400, 'too many changes (max 500)');
    }

    final List<SyncChange> changes;
    try {
      changes = changesRaw
          .map((c) => SyncChange.fromJson(c as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return _error(400, 'malformed change in batch');
    }

    final appliedCount = await _repo.receiveChanges(userId, deviceId, changes);
    final ignored = {
      for (final c in changes)
        if (!syncEntityTypes.contains(c.entityType)) c.entityType,
    };

    return _json(200, {
      'appliedCount': appliedCount,
      // Dropped, not stored: the client must not treat them as delivered.
      'ignoredEntityTypes': ignored.toList()..sort(),
    });
  }

  Future<Response> ack(Request request) async {
    final jwtDeviceId = request.context['deviceId'] as String;

    final body = await readJsonMap(request, maxBytes: Config.maxJsonBodyBytes);
    final deviceId = body['deviceId'] as String?;
    final cursor = body['cursor'];

    if (deviceId == null || cursor == null) {
      return _error(400, 'deviceId and cursor required');
    }
    if (deviceId != jwtDeviceId) {
      return _error(403, 'deviceId does not match token');
    }
    if (cursor is! num) {
      return _error(400, 'cursor must be a number');
    }

    final cursorInt = cursor.toInt();
    await _repo.ackCursor(deviceId, cursorInt);

    return _json(200, {'ok': true});
  }

  Future<Response> status(Request request) async {
    final userId = request.context['userId'] as String;
    final deviceId = request.context['deviceId'] as String;

    final data = await _repo.getStatus(userId, deviceId);
    return _json(200, data);
  }
}

/// Entry types the client declared it can parse, or null when it sent no
/// (or a blank) `X-Polypodium-Entry-Types` header, i.e. a legacy client.
Set<String>? _declaredEntryTypes(Request request) =>
    _csvSet(request.headers['x-polypodium-entry-types']);

/// Trimmed, non-empty items of a comma-separated list, or null when there
/// are none.
Set<String>? _csvSet(String? csv) {
  final items = (csv ?? '')
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toSet();
  return items.isEmpty ? null : items;
}

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

Response _error(int status, String message) =>
    _json(status, {'error': message});
