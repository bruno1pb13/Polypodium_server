// Integration test against a real Postgres instance (unlike
// sync_handler_test.dart, which mocks ISyncRepository). Needs the same
// DATABASE_URL/APP_ENV/DB_SSL env vars as `dart run bin/server.dart` --
// point it at the docker-compose `db` service, e.g.:
//   docker-compose up -d db
//   DATABASE_URL=postgresql://polypodium:<pw>@localhost/polypodium dart test test/features/sync/sync_repository_test.dart
// Skips (rather than fails) if no Postgres is reachable, so `dart test`
// still runs clean in environments without one configured.
import 'package:polypodium_core/lww_vectors.dart';
import 'package:polypodium_core/polypodium_core.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'package:polypodium_server/database/db.dart';
import 'package:polypodium_server/features/sync/sync_repository.dart';

void main() {
  Pool? pool;

  setUpAll(() async {
    try {
      pool = await initDatabase();
    } catch (_) {
      pool = null;
    }
  });

  tearDownAll(() async {
    await pool?.close();
  });

  Future<String> _makeUser(Pool db) async {
    final userId = 'test-user-${DateTime.now().microsecondsSinceEpoch}';
    await db.execute(
      Sql.named('''
        INSERT INTO users (id, email, password_hash)
        VALUES (@id, @email, 'x')
      '''),
      parameters: {'id': userId, 'email': '$userId@test.local'},
    );
    return userId;
  }

  Future<void> _makeDevice(Pool db, String userId, String deviceId) async {
    await db.execute(
      Sql.named(
          'INSERT INTO devices (id, user_id) VALUES (@id, @userId)'),
      parameters: {'id': deviceId, 'userId': userId},
    );
  }

  group('SyncRepository against real Postgres', () {
    test('receiveChanges resolves LWW by updatedAt, not arrival order',
        () async {
      final db = pool;
      if (db == null) {
        markTestSkipped('no reachable Postgres (set DATABASE_URL)');
        return;
      }

      final repo = SyncRepository(db);
      final userId = await _makeUser(db);
      addTearDown(() => db
          .execute(Sql.named('DELETE FROM users WHERE id = @id'),
              parameters: {'id': userId})); // cascades devices + mat_*
      final deviceId = 'device-a-${DateTime.now().microsecondsSinceEpoch}';
      await _makeDevice(db, userId, deviceId);

      final older = DateTime.utc(2025, 1, 1);
      final newer = DateTime.utc(2025, 6, 1);

      // Newer edit applied first, older edit arrives second (out-of-order
      // delivery) -- the older one must lose despite arriving later.
      final appliedNewer = await repo.receiveChanges(userId, deviceId, [
        SyncChange(
          entityType: 'plant',
          entityId: 'p1',
          payload: {'name': 'v2-newer'},
          updatedAt: newer,
          deviceId: deviceId,
          rev: 0,
        ),
      ]);
      final appliedOlder = await repo.receiveChanges(userId, deviceId, [
        SyncChange(
          entityType: 'plant',
          entityId: 'p1',
          payload: {'name': 'v1-older'},
          updatedAt: older,
          deviceId: deviceId,
          rev: 0,
        ),
      ]);

      expect(appliedNewer, 1);
      expect(appliedOlder, 0, reason: 'older updatedAt must no-op, not win');

      final result = await repo.serveChanges(userId, since: 0, limit: 10);
      final plant = result.changes.firstWhere((c) => c.entityId == 'p1');
      expect(plant.payload['name'], 'v2-newer');
    });

    test('composite (user_id, entity_id) PK keeps two users with the same '
        'entity id apart', () async {
      final db = pool;
      if (db == null) {
        markTestSkipped('no reachable Postgres (set DATABASE_URL)');
        return;
      }

      final repo = SyncRepository(db);
      final userA = await _makeUser(db);
      addTearDown(() => db
          .execute(Sql.named('DELETE FROM users WHERE id = @id'),
              parameters: {'id': userA}));
      final userB = await _makeUser(db);
      final deviceA = 'device-a-${DateTime.now().microsecondsSinceEpoch}';
      final deviceB = 'device-b-${DateTime.now().microsecondsSinceEpoch}';
      await _makeDevice(db, userA, deviceA);
      await _makeDevice(db, userB, deviceB);
      addTearDown(() => db
          .execute(Sql.named('DELETE FROM users WHERE id = @id'),
              parameters: {'id': userB}));

      const sharedEntityId = 'colliding-uuid';
      await repo.receiveChanges(userA, deviceA, [
        SyncChange(
          entityType: 'plant',
          entityId: sharedEntityId,
          payload: {'name': 'user-a-plant'},
          updatedAt: DateTime.utc(2025),
          deviceId: deviceA,
          rev: 0,
        ),
      ]);
      await repo.receiveChanges(userB, deviceB, [
        SyncChange(
          entityType: 'plant',
          entityId: sharedEntityId,
          payload: {'name': 'user-b-plant'},
          updatedAt: DateTime.utc(2025),
          deviceId: deviceB,
          rev: 0,
        ),
      ]);

      final aResult = await repo.serveChanges(userA, since: 0, limit: 10);
      final bResult = await repo.serveChanges(userB, since: 0, limit: 10);

      expect(aResult.changes.single.payload['name'], 'user-a-plant');
      expect(bResult.changes.single.payload['name'], 'user-b-plant');
    });

    test('defensivo entity type round-trips through receive/serveChanges',
        () async {
      final db = pool;
      if (db == null) {
        markTestSkipped('no reachable Postgres (set DATABASE_URL)');
        return;
      }

      final repo = SyncRepository(db);
      final userId = await _makeUser(db);
      addTearDown(() => db
          .execute(Sql.named('DELETE FROM users WHERE id = @id'),
              parameters: {'id': userId}));
      final deviceId = 'device-a-${DateTime.now().microsecondsSinceEpoch}';
      await _makeDevice(db, userId, deviceId);

      final applied = await repo.receiveChanges(userId, deviceId, [
        SyncChange(
          entityType: 'defensivo',
          entityId: 'd1',
          payload: {'name': 'Calda bordalesa', 'category': 'fungicide'},
          updatedAt: DateTime.utc(2025, 1, 1),
          deviceId: deviceId,
          rev: 0,
        ),
      ]);
      expect(applied, 1);

      final result = await repo.serveChanges(userId, since: 0, limit: 10);
      final defensivo = result.changes.firstWhere((c) => c.entityId == 'd1');
      expect(defensivo.entityType, 'defensivo');
      expect(defensivo.payload['name'], 'Calda bordalesa');
    });

    test('plant status fields pass through untouched, and are simply absent '
        'for older clients', () async {
      final db = pool;
      if (db == null) {
        markTestSkipped('no reachable Postgres (set DATABASE_URL)');
        return;
      }

      final repo = SyncRepository(db);
      final userId = await _makeUser(db);
      addTearDown(() => db
          .execute(Sql.named('DELETE FROM users WHERE id = @id'),
              parameters: {'id': userId}));
      final deviceId = 'device-a-${DateTime.now().microsecondsSinceEpoch}';
      await _makeDevice(db, userId, deviceId);

      await repo.receiveChanges(userId, deviceId, [
        SyncChange(
          entityType: 'plant',
          entityId: 'p-new',
          payload: {
            'nickname': 'Doada',
            'status': 'donated',
            'statusChangedAt': '2025-03-01T10:00:00.000',
          },
          updatedAt: DateTime.utc(2025, 3, 1),
          deviceId: deviceId,
          rev: 0,
        ),
        SyncChange(
          entityType: 'plant',
          entityId: 'p-old',
          payload: {'nickname': 'Cliente antigo'},
          updatedAt: DateTime.utc(2025, 3, 1),
          deviceId: deviceId,
          rev: 0,
        ),
      ]);

      final result = await repo.serveChanges(userId, since: 0, limit: 10);
      final newer = result.changes.firstWhere((c) => c.entityId == 'p-new');
      final older = result.changes.firstWhere((c) => c.entityId == 'p-old');
      expect(newer.payload['status'], 'donated');
      expect(newer.payload['statusChangedAt'], '2025-03-01T10:00:00.000');
      // The client treats a missing status as 'active'.
      expect(older.payload.containsKey('status'), isFalse);
    });

    test('reminder entity type round-trips through receive/serveChanges',
        () async {
      final db = pool;
      if (db == null) {
        markTestSkipped('no reachable Postgres (set DATABASE_URL)');
        return;
      }

      final repo = SyncRepository(db);
      final userId = await _makeUser(db);
      addTearDown(() => db
          .execute(Sql.named('DELETE FROM users WHERE id = @id'),
              parameters: {'id': userId}));
      final deviceId = 'device-a-${DateTime.now().microsecondsSinceEpoch}';
      await _makeDevice(db, userId, deviceId);

      final applied = await repo.receiveChanges(userId, deviceId, [
        SyncChange(
          entityType: 'reminder',
          entityId: 'r1',
          payload: {
            'id': 'r1',
            'plantId': 'p1',
            'entryType': 'fertilizer',
            'intervalDays': 30,
            'enabled': true,
            'createdAt': '2025-01-01T00:00:00.000',
          },
          updatedAt: DateTime.utc(2025, 1, 1),
          deviceId: deviceId,
          rev: 0,
        ),
      ]);
      expect(applied, 1);

      final result = await repo.serveChanges(userId, since: 0, limit: 10);
      final reminder = result.changes.firstWhere((c) => c.entityId == 'r1');
      expect(reminder.entityType, 'reminder');
      expect(reminder.payload['entryType'], 'fertilizer');
      expect(reminder.payload['intervalDays'], 30);
    });

    group('entry type filtering', () {
      const allTypes = {...legacyEntryTypes, 'repotting'};

      SyncChange entry(String id, String type, String deviceId,
              {DateTime? deletedAt}) =>
          SyncChange(
            entityType: 'entry',
            entityId: id,
            payload: {'id': id, 'type': type},
            updatedAt: DateTime.utc(2025, 1, 1),
            deletedAt: deletedAt,
            deviceId: deviceId,
            rev: 0,
          );

      // Replays the pull loop every released client runs: the next `since`
      // is the rev of the last change applied, and an empty page ends it.
      Future<({List<String> ids, int cursor})> pullLikeClient(
        SyncRepository repo,
        String userId, {
        required int since,
        required int limit,
        Set<String>? entryTypes,
      }) async {
        final ids = <String>[];
        for (var page = 0; page < 50; page++) {
          final result = await repo.serveChanges(userId,
              since: since, limit: limit, entryTypes: entryTypes);
          ids.addAll(result.changes.map((c) => c.entityId));
          if (result.changes.isNotEmpty) since = result.changes.last.rev;
          if (result.changes.isEmpty || !result.hasMore) {
            return (ids: ids, cursor: since);
          }
        }
        fail('pull did not terminate');
      }

      Future<({SyncRepository repo, String userId, String deviceId})?>
          setUpUser() async {
        final db = pool;
        if (db == null) {
          markTestSkipped('no reachable Postgres (set DATABASE_URL)');
          return null;
        }
        final userId = await _makeUser(db);
        addTearDown(() => db
            .execute(Sql.named('DELETE FROM users WHERE id = @id'),
                parameters: {'id': userId}));
        final deviceId = 'device-a-${DateTime.now().microsecondsSinceEpoch}';
        await _makeDevice(db, userId, deviceId);
        return (repo: SyncRepository(db), userId: userId, deviceId: deviceId);
      }

      test('a client without the header gets only legacy types, tombstones '
          'included; a declaring client gets what it declared', () async {
        final ctx = await setUpUser();
        if (ctx == null) return;
        final (:repo, :userId, :deviceId) = ctx;

        await repo.receiveChanges(userId, deviceId, [
          entry('e-irrigation', 'irrigation', deviceId),
          entry('e-repotting', 'repotting', deviceId),
          entry('e-repotting-deleted', 'repotting', deviceId,
              deletedAt: DateTime.utc(2025, 1, 2)),
          entry('e-pesticide-deleted', 'pesticide', deviceId,
              deletedAt: DateTime.utc(2025, 1, 2)),
        ]);

        Future<Set<String>> ids(Set<String>? entryTypes) async =>
            (await repo.serveChanges(userId,
                    since: 0, limit: 10, entryTypes: entryTypes))
                .changes
                .map((c) => c.entityId)
                .toSet();

        expect(await ids(null), {'e-irrigation', 'e-pesticide-deleted'});
        expect(await ids(allTypes), {
          'e-irrigation',
          'e-repotting',
          'e-repotting-deleted',
          'e-pesticide-deleted',
        });
        expect(await ids({'repotting'}),
            {'e-repotting', 'e-repotting-deleted'});
      });

      test('hidden rows never stall or loop the pull: a window made only of '
          'hidden rows, and hidden rows at the tail', () async {
        final ctx = await setUpUser();
        if (ctx == null) return;
        final (:repo, :userId, :deviceId) = ctx;

        // irrigation, 5 hidden, plant, 3 hidden, irrigation, 4 hidden (tail).
        await repo.receiveChanges(userId, deviceId, [
          entry('e1', 'irrigation', deviceId),
          for (var i = 0; i < 5; i++) entry('r-a$i', 'repotting', deviceId),
          SyncChange(
            entityType: 'plant',
            entityId: 'p1',
            payload: {'nickname': 'Samambaia'},
            updatedAt: DateTime.utc(2025, 1, 1),
            deviceId: deviceId,
            rev: 0,
          ),
          for (var i = 0; i < 3; i++) entry('r-b$i', 'repotting', deviceId),
          entry('e2', 'irrigation', deviceId),
          for (var i = 0; i < 4; i++) entry('r-c$i', 'repotting', deviceId),
        ]);

        final all = (await repo.serveChanges(userId,
                since: 0, limit: 100, entryTypes: allTypes))
            .changes;
        int revOf(String id) => all.firstWhere((c) => c.entityId == id).rev;

        // The next rows after e1 (by rev) are all hidden; the page still
        // reaches past them instead of coming back empty with hasMore.
        final afterE1 = await repo.serveChanges(userId,
            since: revOf('e1'), limit: 3);
        expect(afterE1.changes.map((c) => c.entityId), ['p1', 'e2']);
        expect(afterE1.hasMore, isFalse);

        // Only hidden rows remain past e2: empty page, no hasMore.
        final tail =
            await repo.serveChanges(userId, since: revOf('e2'), limit: 3);
        expect(tail.changes, isEmpty);
        expect(tail.hasMore, isFalse);

        for (final limit in [1, 2, 3, 100]) {
          final legacy =
              await pullLikeClient(repo, userId, since: 0, limit: limit);
          expect(legacy.ids, ['e1', 'p1', 'e2'], reason: 'limit $limit');
          expect(legacy.cursor, revOf('e2'));

          // A later sync from that cursor finds nothing new and ends.
          final again = await pullLikeClient(repo, userId,
              since: legacy.cursor, limit: limit);
          expect(again.ids, isEmpty);

          final declared = await pullLikeClient(repo, userId,
              since: 0, limit: limit, entryTypes: allTypes);
          expect(declared.ids, hasLength(15));
          expect(declared.cursor, all.last.rev);
        }
      });
    });

    // The ON CONFLICT clause can't call incomingWins() directly, so the
    // package's shared vectors pin the SQL to it instead.
    group('ON CONFLICT clause agrees with incomingWins on lwwVectors', () {
      for (final (i, v) in lwwVectors.indexed) {
        test(v.description, () async {
          final db = pool;
          if (db == null) {
            markTestSkipped('no reachable Postgres (set DATABASE_URL)');
            return;
          }

          final repo = SyncRepository(db);
          final userId = await _makeUser(db);
          addTearDown(() => db
              .execute(Sql.named('DELETE FROM users WHERE id = @id'),
                  parameters: {'id': userId}));
          final entityId = 'lww-vector-$i';
          // device_id is NOT NULL here; the package's rule compares a null
          // deviceId as '', which Postgres also sorts before any other id.
          final currentDeviceId = v.currentDeviceId ?? '';
          final incomingDeviceId = v.incomingDeviceId ?? '';

          await repo.receiveChanges(userId, currentDeviceId, [
            SyncChange(
              entityType: 'plant',
              entityId: entityId,
              payload: {'name': 'current'},
              updatedAt: v.currentUpdatedAt,
              deviceId: currentDeviceId,
              rev: 0,
            ),
          ]);
          final applied =
              await repo.receiveChanges(userId, incomingDeviceId, [
            SyncChange(
              entityType: 'plant',
              entityId: entityId,
              payload: {'name': 'incoming'},
              updatedAt: v.incomingUpdatedAt,
              deviceId: incomingDeviceId,
              rev: 0,
            ),
          ]);

          final expected = incomingWins(
            incomingUpdatedAt: v.incomingUpdatedAt,
            incomingDeviceId: v.incomingDeviceId,
            currentUpdatedAt: v.currentUpdatedAt,
            currentDeviceId: v.currentDeviceId,
          );
          expect(expected, v.incomingWins);
          expect(applied, expected ? 1 : 0);

          final result = await repo.serveChanges(userId, since: 0, limit: 10);
          expect(result.changes.single.payload['name'],
              expected ? 'incoming' : 'current');
        });
      }
    });
  });
}

