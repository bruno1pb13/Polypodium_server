import 'dart:convert';
import 'dart:math' as math;

import 'package:shelf/shelf.dart';

import 'event_model.dart';
import 'sync_repository.dart';

class SyncHandler {
  final _repo = SyncRepository();

  Future<Response> push(Request request) async {
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

    final eventsRaw = body['events'] as List<dynamic>? ?? [];
    if (eventsRaw.length > 500) {
      return _error(400, 'too many events (max 500)');
    }

    final events = eventsRaw
        .map((e) => PushEvent.fromJson(e as Map<String, dynamic>))
        .toList();

    final result = await _repo.pushEvents(userId, deviceId, events);

    return _json(200, {
      'accepted': result.accepted,
      'conflicts': result.conflicts.map((c) => c.toJson()).toList(),
    });
  }

  Future<Response> pull(Request request) async {
    final userId = request.context['userId'] as String;
    final deviceId = request.context['deviceId'] as String;

    final params = request.url.queryParameters;
    final since = math.max(0, int.tryParse(params['since'] ?? '0') ?? 0);
    final limit = (int.tryParse(params['limit'] ?? '100') ?? 100).clamp(1, 1000);

    final events = await _repo.pullEvents(userId, deviceId, since, limit);
    final nextCursor = events.isNotEmpty ? events.last.id : since;

    return _json(200, {
      'events': events.map((e) => e.toJson()).toList(),
      'nextCursor': nextCursor,
      'hasMore': events.length == limit,
    });
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
