import 'dart:convert';

import 'package:mocktail/mocktail.dart';
import 'package:polypodium_core/polypodium_core.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

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

  group('changes', () {
    test('returns changes and correct cursor', () async {
      final changes = [
        SyncChange(
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
          .thenAnswer((_) async => (changes: <SyncChange>[], hasMore: false));

      final req = _withContext(
          Request('GET', Uri.parse('http://localhost/changes?since=42')));
      final res = await handler.changes(req);
      final body =
          jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['nextCursor'], 42);
    });
  });

  group('changes entry types header', () {
    Future<Set<String>?> declaredFor(Map<String, String> headers) async {
      when(() => repo.serveChanges(any(),
              since: any(named: 'since'),
              limit: any(named: 'limit'),
              entryTypes: any(named: 'entryTypes')))
          .thenAnswer((_) async => (changes: <SyncChange>[], hasMore: false));

      await handler.changes(_withContext(Request(
          'GET', Uri.parse('http://localhost/changes?since=0'),
          headers: headers)));
      return verify(() => repo.serveChanges(any(),
              since: any(named: 'since'),
              limit: any(named: 'limit'),
              entryTypes: captureAny(named: 'entryTypes')))
          .captured
          .single as Set<String>?;
    }

    test('absent header leaves the legacy default to the repository',
        () async {
      expect(await declaredFor({}), isNull);
    });

    test('blank header counts as absent', () async {
      expect(await declaredFor({'X-Polypodium-Entry-Types': ' , '}), isNull);
    });

    test('declared types are trimmed into a set', () async {
      expect(
        await declaredFor(
            {'X-Polypodium-Entry-Types': 'irrigation, repotting,irrigation'}),
        {'irrigation', 'repotting'},
      );
    });
  });

  group('changes entities param', () {
    Future<({Set<String>? restricted, Map<String, dynamic> body})> pull(
        String query) async {
      when(() => repo.serveChanges(any(),
              since: any(named: 'since'),
              limit: any(named: 'limit'),
              entryTypes: any(named: 'entryTypes'),
              entityTypes: any(named: 'entityTypes')))
          .thenAnswer((_) async => (changes: <SyncChange>[], hasMore: false));

      final res = await handler.changes(_withContext(
          Request('GET', Uri.parse('http://localhost/changes?$query'))));
      final restricted = verify(() => repo.serveChanges(any(),
              since: any(named: 'since'),
              limit: any(named: 'limit'),
              entryTypes: any(named: 'entryTypes'),
              entityTypes: captureAny(named: 'entityTypes')))
          .captured
          .single as Set<String>?;
      return (
        restricted: restricted,
        body: jsonDecode(await res.readAsString()) as Map<String, dynamic>,
      );
    }

    test('absent param serves every entity and echoes nothing', () async {
      final (:restricted, :body) = await pull('since=0');
      expect(restricted, isNull);
      expect(body.containsKey('entities'), isFalse);
    });

    test('blank param counts as absent', () async {
      final (:restricted, :body) = await pull('since=0&entities=%20,');
      expect(restricted, isNull);
      expect(body.containsKey('entities'), isFalse);
    });

    test('restriction is passed on and echoed back', () async {
      final (:restricted, :body) =
          await pull('since=0&entities=plant,%20entry');
      expect(restricted, {'entry', 'plant'});
      expect(body['entities'], ['entry', 'plant']);
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
