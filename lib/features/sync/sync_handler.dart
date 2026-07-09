import 'dart:convert';
import 'dart:math' as math;

import 'package:shelf/shelf.dart';

import 'i_sync_repository.dart';
import 'mat_change_model.dart';

class SyncHandler {
  const SyncHandler(this._repo);
  final ISyncRepository _repo;

  /// `GET /sync/changes?since=&limit=` — a real pull: returns this user's
  /// rows with `rev > since`, across every entity type.
  Future<Response> changes(Request request) async {
    final userId = request.context['userId'] as String;

    final params = request.url.queryParameters;
    final since = math.max(0, int.tryParse(params['since'] ?? '0') ?? 0);
    final limit =
        (int.tryParse(params['limit'] ?? '100') ?? 100).clamp(1, 1000);

    final result = await _repo.serveChanges(userId, since: since, limit: limit);
    final nextCursor =
        result.changes.isNotEmpty ? result.changes.last.rev : since;

    return _json(200, {
      'changes': result.changes.map((c) => c.toJson()).toList(),
      'nextCursor': nextCursor,
      'hasMore': result.hasMore,
    });
  }

  /// `POST /sync/receive` — the client-server equivalent of a peer pushing
  /// its own local changes to us; internally applied via the same
  /// last-write-wins logic `receiveChanges` would use for any peer.
  Future<Response> receive(Request request) async {
    final userId = request.context['userId'] as String;
    final jwtDeviceId = request.context['deviceId'] as String;

    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
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

    final changes = changesRaw
        .map((c) => MatChange.fromJson(c as Map<String, dynamic>))
        .toList();

    final appliedCount = await _repo.receiveChanges(userId, deviceId, changes);

    return _json(200, {'appliedCount': appliedCount});
  }

  Future<Response> ack(Request request) async {
    final jwtDeviceId = request.context['deviceId'] as String;

    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final deviceId = body['deviceId'] as String?;
    final cursor = body['cursor'];

    if (deviceId == null || cursor == null) {
      return _error(400, 'deviceId and cursor required');
    }
    if (deviceId != jwtDeviceId) {
      return _error(403, 'deviceId does not match token');
    }

    final cursorInt = (cursor as num).toInt();
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

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

Response _error(int status, String message) =>
    _json(status, {'error': message});
