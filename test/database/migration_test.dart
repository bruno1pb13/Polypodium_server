// Runs the boot migrations against a database shaped like the last
// pre-garden release, inside a throwaway schema of the DATABASE_URL
// database. Skips when no Postgres is reachable.
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'package:polypodium_server/core/config.dart';
import 'package:polypodium_server/database/db.dart';

const _matTables = [
  'mat_species',
  'mat_plants',
  'mat_entries',
  'mat_entry_photos',
  'mat_locations',
  'mat_soils',
  'mat_beds',
  'mat_defensivos',
  'mat_reminders',
];

/// The schema as the pre-garden server left it (data keyed by user_id).
Future<void> _createPreGardenSchema(Connection db) async {
  await db.execute('''
    CREATE TABLE users (
      id            TEXT PRIMARY KEY,
      email         TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      role          TEXT NOT NULL DEFAULT 'member',
      disabled      BOOLEAN NOT NULL DEFAULT FALSE
    )
  ''');
  await db.execute('''
    CREATE TABLE devices (
      id           TEXT PRIMARY KEY,
      user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      name         TEXT,
      last_seen_at TIMESTAMPTZ,
      created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  ''');
  await db.execute('''
    CREATE TABLE device_cursors (
      device_id          TEXT PRIMARY KEY REFERENCES devices(id),
      last_pulled_cursor BIGINT NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('CREATE SEQUENCE mat_rev_seq');
  for (final table in _matTables) {
    await db.execute('''
      CREATE TABLE $table (
        entity_id  TEXT NOT NULL,
        user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        payload    JSONB NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL,
        deleted_at TIMESTAMPTZ NULL,
        device_id  TEXT NOT NULL,
        rev        BIGINT NOT NULL DEFAULT nextval('mat_rev_seq'),
        PRIMARY KEY (user_id, entity_id)
      )
    ''');
    await db.execute('CREATE INDEX idx_${table}_rev ON $table(user_id, rev)');
  }
}

Future<void> _seed(Connection db) async {
  await db.execute('''
    INSERT INTO users (id, email, password_hash, role) VALUES
      ('u1', 'u1@test.local', 'x', 'admin'),
      ('u2', 'u2@test.local', 'x', 'member')
  ''');
  await db.execute(
      "INSERT INTO devices (id, user_id) VALUES ('d1', 'u1'), ('d2', 'u2')");
  await db.execute("INSERT INTO device_cursors VALUES ('d1', 102), ('d2', 0)");
  // The same client-generated id under two accounts, plus a tombstone.
  await db.execute('''
    INSERT INTO mat_plants
      (entity_id, user_id, payload, updated_at, deleted_at, device_id, rev)
    VALUES
      ('p1', 'u1', '{"name":"Samambaia"}', '2025-01-01T00:00:00Z', NULL, 'd1', 101),
      ('p1', 'u2', '{"name":"Avenca"}', '2025-02-01T00:00:00Z', NULL, 'd2', 102)
  ''');
  await db.execute('''
    INSERT INTO mat_entries
      (entity_id, user_id, payload, updated_at, deleted_at, device_id, rev)
    VALUES
      ('e1', 'u1', '{"type":"irrigation"}', '2025-03-01T00:00:00Z',
       '2025-03-02T00:00:00Z', 'd1', 103)
  ''');
  await db.execute("SELECT setval('mat_rev_seq', 103)");
}

void main() {
  Connection? db;
  final schema = 'mig_test_${DateTime.now().microsecondsSinceEpoch}';

  setUpAll(() async {
    try {
      db = await Connection.open(
        databaseEndpoint(),
        settings: ConnectionSettings(
          sslMode: Config.dbSsl ? SslMode.require : SslMode.disable,
        ),
      );
    } catch (_) {
      db = null;
    }
  });

  tearDownAll(() async => db?.close());

  setUp(() async {
    final conn = db;
    if (conn == null) return;
    await conn.execute('CREATE SCHEMA $schema');
    await conn.execute('SET search_path TO $schema');
  });

  tearDown(() async {
    final conn = db;
    if (conn == null) return;
    await conn.execute('SET search_path TO DEFAULT');
    await conn.execute('DROP SCHEMA $schema CASCADE');
  });

  Future<List<List<Object?>>> rows(Connection conn, String sql) async =>
      [for (final row in await conn.execute(sql)) row.toList()];

  test('moves pre-garden data into personal gardens, keeping revs', () async {
    final conn = db;
    if (conn == null) {
      markTestSkipped('no reachable Postgres (set DATABASE_URL)');
      return;
    }
    await _createPreGardenSchema(conn);
    await _seed(conn);

    await runMigrations(conn);

    expect(
      await rows(
          conn, 'SELECT id, owner_user_id, personal FROM gardens ORDER BY id'),
      [
        ['u1', 'u1', true],
        ['u2', 'u2', true],
      ],
    );
    expect(
      await rows(conn,
          'SELECT garden_id, user_id, role FROM garden_members ORDER BY garden_id'),
      [
        ['u1', 'u1', 'owner'],
        ['u2', 'u2', 'owner'],
      ],
    );
    expect(
      await rows(conn, '''
        SELECT garden_id, user_id, entity_id, payload->>'name', rev, device_id
        FROM mat_plants ORDER BY rev
      '''),
      [
        ['u1', 'u1', 'p1', 'Samambaia', 101, 'd1'],
        ['u2', 'u2', 'p1', 'Avenca', 102, 'd2'],
      ],
    );
    final tombstone =
        await rows(conn, 'SELECT garden_id, rev, deleted_at FROM mat_entries');
    expect(tombstone.single[0], 'u1');
    expect(tombstone.single[1], 103);
    expect(tombstone.single[2], DateTime.utc(2025, 3, 2));
    expect(
      await rows(conn,
          'SELECT device_id, garden_id, last_pulled_cursor FROM device_cursors ORDER BY device_id'),
      [
        ['d1', 'u1', 102],
        ['d2', 'u2', 0],
      ],
    );

    // Keys and constraints now follow the garden.
    for (final table in [..._matTables, 'device_cursors']) {
      final pk = await rows(conn, '''
        SELECT a.attname FROM pg_index i
        JOIN pg_attribute a
          ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = '$table'::regclass AND i.indisprimary
        ORDER BY a.attname
      ''');
      expect(
          pk.map((r) => r[0]),
          table == 'device_cursors'
              ? ['device_id', 'garden_id']
              : ['entity_id', 'garden_id'],
          reason: table);
    }
    final userFks = await rows(conn, '''
      SELECT conrelid::regclass::text FROM pg_constraint
      WHERE contype = 'f' AND confrelid = 'users'::regclass
        AND conrelid::regclass::text LIKE 'mat_%'
    ''');
    expect(userFks, isEmpty,
        reason: "deleting an account mustn't cascade into shared gardens");

    // The rev sequence carries on past the migrated rows.
    final next = await rows(conn, "SELECT nextval('mat_rev_seq')");
    expect(next.single[0] as int, greaterThan(103));
  });

  test('is idempotent: a second boot changes nothing', () async {
    final conn = db;
    if (conn == null) {
      markTestSkipped('no reachable Postgres (set DATABASE_URL)');
      return;
    }
    await _createPreGardenSchema(conn);
    await _seed(conn);

    await runMigrations(conn);
    Future<List<List<Object?>>> snapshot() async => [
          ...await rows(conn, 'SELECT * FROM gardens ORDER BY id'),
          ...await rows(
              conn, 'SELECT * FROM garden_members ORDER BY garden_id, user_id'),
          ...await rows(conn,
              'SELECT garden_id, entity_id, rev FROM mat_plants ORDER BY rev'),
          ...await rows(conn,
              'SELECT garden_id, entity_id, rev FROM mat_entries ORDER BY rev'),
          ...await rows(conn, 'SELECT * FROM device_cursors ORDER BY 1'),
        ];
    final before = await snapshot();

    await runMigrations(conn);

    expect(await snapshot(), before);
  });

  test('creates the garden schema on an empty database', () async {
    final conn = db;
    if (conn == null) {
      markTestSkipped('no reachable Postgres (set DATABASE_URL)');
      return;
    }
    await runMigrations(conn);
    await runMigrations(conn);

    for (final table in ['gardens', 'garden_members', ..._matTables]) {
      final exists = await rows(conn, "SELECT to_regclass('$table')");
      expect(exists.single[0], isNotNull, reason: table);
    }
  });

  test('a failed upgrade leaves the previous schema untouched', () async {
    final conn = db;
    if (conn == null) {
      markTestSkipped('no reachable Postgres (set DATABASE_URL)');
      return;
    }
    await _createPreGardenSchema(conn);
    await _seed(conn);
    // A row whose account is gone can't move to a personal garden; the FK
    // on garden_id makes the whole upgrade fail.
    await conn
        .execute('ALTER TABLE mat_beds DROP CONSTRAINT mat_beds_user_id_fkey');
    await conn.execute('''
      INSERT INTO mat_beds (entity_id, user_id, payload, updated_at, device_id)
      VALUES ('b1', 'ghost', '{}', NOW(), 'd1')
    ''');

    await expectLater(runMigrations(conn), throwsA(anything));

    expect(await rows(conn, "SELECT to_regclass('gardens')"), [
      [null]
    ]);
    final cols = await rows(conn, '''
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = current_schema() AND table_name = 'mat_plants'
        AND column_name = 'garden_id'
    ''');
    expect(cols, isEmpty);
  });
}
