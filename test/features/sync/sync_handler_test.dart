import 'dart:convert';

import 'package:mocktail/mocktail.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:polypodium_server/features/sync/i_sync_repository.dart';
import 'package:polypodium_server/features/sync/mat_change_model.dart';
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

  group('changes', () {
    test('returns changes and correct cursor', () async {
      final changes = [
        MatChange(
          entityType: 'plant',
          entityId: 'p1',
          payload: {'name': 'Fern'},
          updatedAt: DateTime.utc(2025),
          deviceId: 'other-device',
          rev: 5,
        ),
      ];
      when(() => repo.serveChanges(any(),
              since: any(named: 'since'), limit: any(named: 'limit')))
          .thenAnswer((_) async => (changes: changes, hasMore: false));

      final req = _withContext(
          Request('GET', Uri.parse('http://localhost/changes?since=0')));
      final res = await handler.changes(req);

      expect(res.statusCode, 200);
      final body =
          jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect((body['changes'] as List).length, 1);
      expect(body['nextCursor'], 5);
      expect(body['hasMore'], false);
    });

    test('nextCursor equals since when no changes', () async {
      when(() => repo.serveChanges(any(),
              since: any(named: 'since'), limit: any(named: 'limit')))
          .thenAnswer((_) async => (changes: <MatChange>[], hasMore: false));

      final req = _withContext(
          Request('GET', Uri.parse('http://localhost/changes?since=42')));
      final res = await handler.changes(req);
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

  group('receive', () {
    test('403 when deviceId mismatches JWT', () async {
      final req = _withContext(
        Request('POST', Uri.parse('http://localhost/receive'),
            body: jsonEncode({'deviceId': 'wrong', 'changes': []})),
      );
      final res = await handler.receive(req);
      expect(res.statusCode, 403);
    });

    test('400 when more than 500 changes', () async {
      final changes = List.generate(
        501,
        (i) => {
          'entityType': 'plant',
          'entityId': 'p$i',
          'payload': <String, dynamic>{},
          'updatedAt': DateTime.now().toIso8601String(),
          'deletedAt': null,
          'deviceId': 'device1',
          'rev': i,
        },
      );
      final req = _withContext(
        Request('POST', Uri.parse('http://localhost/receive'),
            body: jsonEncode({'deviceId': 'device1', 'changes': changes})),
      );
      final res = await handler.receive(req);
      expect(res.statusCode, 400);
    });

    test('200 with appliedCount on success', () async {
      when(() => repo.receiveChanges(any(), any(), any()))
          .thenAnswer((_) async => 2);

      final changes = [
        {
          'entityType': 'plant',
          'entityId': 'p1',
          'payload': <String, dynamic>{'name': 'Fern'},
          'updatedAt': DateTime.now().toIso8601String(),
          'deletedAt': null,
          'deviceId': 'device1',
          'rev': 1,
        },
        {
          'entityType': 'plant',
          'entityId': 'p2',
          'payload': <String, dynamic>{'name': 'Moss'},
          'updatedAt': DateTime.now().toIso8601String(),
          'deletedAt': null,
          'deviceId': 'device1',
          'rev': 2,
        },
      ];
      final req = _withContext(
        Request('POST', Uri.parse('http://localhost/receive'),
            body: jsonEncode({'deviceId': 'device1', 'changes': changes})),
      );
      final res = await handler.receive(req);

      expect(res.statusCode, 200);
      final body =
          jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['appliedCount'], 2);
    });
  });
}
