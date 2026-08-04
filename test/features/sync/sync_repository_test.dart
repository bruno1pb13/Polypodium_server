// Integration test against a real Postgres instance (unlike
// sync_handler_test.dart, which mocks ISyncRepository). Needs the same
// DATABASE_URL/APP_ENV/DB_SSL env vars as `dart run bin/server.dart` --
// point it at the docker-compose `db` service, e.g.:
//   docker-compose up -d db
//   DATABASE_URL=postgresql://polypodium:<pw>@localhost/polypodium dart test test/features/sync/sync_repository_test.dart
// Skips (rather than fails) if no Postgres is reachable, so `dart test`
// still runs clean in environments without one configured.
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'package:polypodium_server/database/db.dart';
import 'package:polypodium_server/features/sync/mat_change_model.dart';
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
        MatChange(
          entityType: 'plant',
          entityId: 'p1',
          payload: {'name': 'v2-newer'},
          updatedAt: newer,
          deviceId: deviceId,
          rev: 0,
        ),
      ]);
      final appliedOlder = await repo.receiveChanges(userId, deviceId, [
        MatChange(
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
        MatChange(
          entityType: 'plant',
          entityId: sharedEntityId,
          payload: {'name': 'user-a-plant'},
          updatedAt: DateTime.utc(2025),
          deviceId: deviceA,
          rev: 0,
        ),
      ]);
      await repo.receiveChanges(userB, deviceB, [
        MatChange(
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
        MatChange(
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
  });
}
