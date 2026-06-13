import 'dart:convert';

import 'package:mocktail/mocktail.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:polypodium_server/features/sync/event_model.dart';
import 'package:polypodium_server/features/sync/i_sync_repository.dart';
import 'package:polypodium_server/features/sync/sync_handler.dart';

class _MockSyncRepo extends Mock implements ISyncRepository {}

void main() {
  late _MockSyncRepo repo;
  late SyncHandler handler;

  setUp(() {
    repo = _MockSyncRepo();
    handler = SyncHandler(repo);
  });

  Request _withContext(Request req) =>
      req.change(context: {'userId': 'user1', 'deviceId': 'device1'});

  group('pull', () {
    test('returns events and correct cursor', () async {
      final events = [
        SyncEvent(
          id: 5,
          deviceId: 'other-device',
          entityType: 'plant',
          entityId: 'p1',
          operation: 'create',
          payload: {'name': 'Fern'},
          serverTimestamp: DateTime.utc(2025),
        ),
      ];
      when(() => repo.pullEvents(any(), any(), any(), any()))
          .thenAnswer((_) async => events);

      final req = _withContext(
          Request('GET', Uri.parse('http://localhost/pull?since=0')));
      final res = await handler.pull(req);

      expect(res.statusCode, 200);
      final body =
          jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect((body['events'] as List).length, 1);
      expect(body['nextCursor'], 5);
      expect(body['hasMore'], false);
    });

    test('nextCursor equals since when no events', () async {
      when(() => repo.pullEvents(any(), any(), any(), any()))
          .thenAnswer((_) async => []);

      final req = _withContext(
          Request('GET', Uri.parse('http://localhost/pull?since=42')));
      final res = await handler.pull(req);
      final body =
          jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['nextCursor'], 42);
    });
  });

  group('ack', () {
    test('403 when deviceId mismatches JWT', () async {
      final req = _withContext(
        Request('POST', Uri.parse('http://localhost/ack'),
            body: jsonEncode({'deviceId': 'wrong-device', 'cursor': 10})),
      );
      final res = await handler.ack(req);
      expect(res.statusCode, 403);
    });

    test('200 on success', () async {
      when(() => repo.ackCursor(any(), any())).thenAnswer((_) async {});

      final req = _withContext(
        Request('POST', Uri.parse('http://localhost/ack'),
            body: jsonEncode({'deviceId': 'device1', 'cursor': 10})),
      );
      final res = await handler.ack(req);
      expect(res.statusCode, 200);
      verify(() => repo.ackCursor('device1', 10)).called(1);
    });

    test('400 when cursor is missing', () async {
      final req = _withContext(
        Request('POST', Uri.parse('http://localhost/ack'),
            body: jsonEncode({'deviceId': 'device1'})),
      );
      final res = await handler.ack(req);
      expect(res.statusCode, 400);
    });
  });

  group('push', () {
    test('403 when deviceId mismatches JWT', () async {
      final req = _withContext(
        Request('POST', Uri.parse('http://localhost/push'),
            body: jsonEncode({'deviceId': 'wrong', 'events': []})),
      );
      final res = await handler.push(req);
      expect(res.statusCode, 403);
    });

    test('400 when more than 500 events', () async {
      final events = List.generate(
        501,
        (i) => {
          'localQueueId': i,
          'entityType': 'plant',
          'entityId': 'p$i',
          'operation': 'create',
          'payload': <String, dynamic>{},
          'clientTimestamp': DateTime.now().toIso8601String(),
        },
      );
      final req = _withContext(
        Request('POST', Uri.parse('http://localhost/push'),
            body: jsonEncode({'deviceId': 'device1', 'events': events})),
      );
      final res = await handler.push(req);
      expect(res.statusCode, 400);
    });

    test('200 with accepted list on success', () async {
      when(() => repo.pushEvents(any(), any(), any())).thenAnswer(
          (_) async => (accepted: [0, 1], conflicts: <ConflictResult>[]));

      final events = [
        {
          'localQueueId': 0,
          'entityType': 'plant',
          'entityId': 'p1',
          'operation': 'create',
          'payload': <String, dynamic>{'name': 'Fern'},
          'clientTimestamp': DateTime.now().toIso8601String(),
        },
        {
          'localQueueId': 1,
          'entityType': 'plant',
          'entityId': 'p2',
          'operation': 'create',
          'payload': <String, dynamic>{'name': 'Moss'},
          'clientTimestamp': DateTime.now().toIso8601String(),
        },
      ];
      final req = _withContext(
        Request('POST', Uri.parse('http://localhost/push'),
            body: jsonEncode({'deviceId': 'device1', 'events': events})),
      );
      final res = await handler.push(req);

      expect(res.statusCode, 200);
      final body =
          jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['accepted'], [0, 1]);
      expect(body['conflicts'], isEmpty);
    });
  });
}
