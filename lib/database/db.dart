import 'package:postgres/postgres.dart';
import '../core/config.dart';

Future<Pool> initDatabase() async {
  final pool = Pool.withEndpoints(
    [databaseEndpoint()],
    settings: PoolSettings(
      maxConnectionCount: 10,
      sslMode: Config.dbSsl ? SslMode.require : SslMode.disable,
    ),
  );

  await runMigrations(pool);
  return pool;
}

Endpoint databaseEndpoint() {
  final uri = Uri.parse(Config.databaseUrl);
  final userInfo = uri.userInfo.split(':');
  return Endpoint(
    host: uri.host,
    port: uri.port == 0 ? 5432 : uri.port,
    database: uri.path.substring(1),
    username: userInfo.isNotEmpty ? userInfo[0] : 'postgres',
    password: userInfo.length > 1 ? userInfo[1] : '',
  );
}

/// Brings the schema up to date. Runs on every boot, so each step must be
/// idempotent; the whole run is one transaction (a failed upgrade leaves the
/// previous schema intact) serialized by an advisory lock, so two server
/// instances -- or test files -- booting together never interleave DDL.
Future<void> runMigrations(SessionExecutor db) =>
    db.runTx((tx) async {
      await tx.execute(Sql('SELECT pg_advisory_xact_lock(918273646)'));
      await _runMigrations(tx);
    });

Future<void> _runMigrations(Session pool) async {
  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS users (
      id           TEXT PRIMARY KEY,
      email        TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  '''));

  // role: server-wide admin vs. regular member (distinct from any future
  // per-workspace concept). disabled: soft-removal — blocks login while
  // preserving the account's data.
  await pool.execute(
      Sql("ALTER TABLE users ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'member'"));
  await pool.execute(Sql(
      'ALTER TABLE users ADD COLUMN IF NOT EXISTS disabled BOOLEAN NOT NULL DEFAULT FALSE'));

  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS devices (
      id           TEXT PRIMARY KEY,
      user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      name         TEXT,
      last_seen_at TIMESTAMPTZ,
      created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  '''));

  // sync_events (append-only event log) is gone: sync moved from a
  // push/pull event log to pull+ack over versioned mat_* rows. Drops any
  // pre-existing table from before the rewrite (no production data to
  // preserve).
  await pool.execute(Sql('DROP TABLE IF EXISTS sync_events'));

  // Gardens (jardins) are the unit synced data belongs to. Every account
  // owns a personal garden whose id is the account's own id, which is what
  // lets pre-garden data (scoped by user_id) and photo directories (named
  // after the user id) move in place. `personal` marks the garden a request
  // without a garden selector uses; other gardens are created explicitly
  // and shared through garden_members.
  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS gardens (
      id            TEXT PRIMARY KEY,
      name          TEXT NOT NULL DEFAULT '',
      owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      personal      BOOLEAN NOT NULL DEFAULT FALSE,
      created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  '''));
  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS garden_members (
      garden_id TEXT NOT NULL REFERENCES gardens(id) ON DELETE CASCADE,
      user_id   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      role      TEXT NOT NULL CHECK (role IN ('owner', 'member')),
      added_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (garden_id, user_id)
    )
  '''));
  await pool.execute(Sql(
      'CREATE INDEX IF NOT EXISTS idx_garden_members_user ON garden_members(user_id)'));
  // Backfills a personal garden for every account (all of them on the first
  // upgrade; afterwards only accounts created some other way than
  // AuthRepository). Owner membership is derived from gardens itself, so a
  // garden id colliding with a user id can never grant that user anything.
  await pool.execute(Sql('''
    INSERT INTO gardens (id, owner_user_id, personal)
    SELECT id, id, TRUE FROM users
    ON CONFLICT (id) DO NOTHING
  '''));
  await pool.execute(Sql('''
    INSERT INTO garden_members (garden_id, user_id, role)
    SELECT id, owner_user_id, 'owner' FROM gardens WHERE personal
    ON CONFLICT DO NOTHING
  '''));

  // A device pulls each garden it syncs with its own cursor.
  if (await _tableExists(pool, 'device_cursors') &&
      !await _columnExists(pool, 'device_cursors', 'garden_id')) {
    // Pre-garden cursors belonged to the device's account, i.e. its
    // personal garden.
    await pool.execute(Sql(
        'ALTER TABLE device_cursors ADD COLUMN garden_id TEXT REFERENCES gardens(id) ON DELETE CASCADE'));
    await pool.execute(Sql('''
      UPDATE device_cursors c SET garden_id = d.user_id
      FROM devices d WHERE d.id = c.device_id
    '''));
    await pool.execute(
        Sql('DELETE FROM device_cursors WHERE garden_id IS NULL'));
    await pool.execute(
        Sql('ALTER TABLE device_cursors ALTER COLUMN garden_id SET NOT NULL'));
    await _replacePrimaryKey(pool, 'device_cursors', 'device_id, garden_id');
  }
  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS device_cursors (
      device_id          TEXT NOT NULL REFERENCES devices(id),
      garden_id          TEXT NOT NULL REFERENCES gardens(id) ON DELETE CASCADE,
      last_pulled_cursor BIGINT NOT NULL DEFAULT 0,
      PRIMARY KEY (device_id, garden_id)
    )
  '''));

  // Server-wide key/value configuration set by admins (e.g. whether member
  // accounts may export/import their data from the client). Values are
  // stored as strings; absent keys fall back to per-key defaults in
  // SettingsRepository.
  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS server_settings (
      key        TEXT PRIMARY KEY,
      value      TEXT NOT NULL,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  '''));

  // Weather forecasts. Nearby locations share a region (one fetch for all
  // of them); data thins out with age: hourly for the last few days, daily
  // for about a year, monthly summaries after that. Hours and dates are the
  // region's local wall-clock values (`timezone`), as the provider returns
  // them.
  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS weather_regions (
      id              TEXT PRIMARY KEY,
      latitude        DOUBLE PRECISION NOT NULL,
      longitude       DOUBLE PRECISION NOT NULL,
      timezone        TEXT,
      elevation       DOUBLE PRECISION,
      created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_used_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      last_fetched_at TIMESTAMPTZ,
      last_attempt_at TIMESTAMPTZ,
      last_error      TEXT
    )
  '''));
  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS weather_hourly (
      region_id                 TEXT NOT NULL REFERENCES weather_regions(id) ON DELETE CASCADE,
      time                      TIMESTAMP NOT NULL,
      temperature               DOUBLE PRECISION,
      humidity                  DOUBLE PRECISION,
      precipitation             DOUBLE PRECISION,
      precipitation_probability DOUBLE PRECISION,
      weather_code              INTEGER,
      wind_speed                DOUBLE PRECISION,
      PRIMARY KEY (region_id, time)
    )
  '''));
  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS weather_daily (
      region_id                     TEXT NOT NULL REFERENCES weather_regions(id) ON DELETE CASCADE,
      date                          DATE NOT NULL,
      weather_code                  INTEGER,
      temperature_max               DOUBLE PRECISION,
      temperature_min               DOUBLE PRECISION,
      precipitation_sum             DOUBLE PRECISION,
      precipitation_probability_max DOUBLE PRECISION,
      wind_speed_max                DOUBLE PRECISION,
      et0                           DOUBLE PRECISION,
      PRIMARY KEY (region_id, date)
    )
  '''));
  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS weather_monthly (
      region_id           TEXT NOT NULL REFERENCES weather_regions(id) ON DELETE CASCADE,
      month               DATE NOT NULL,
      days                INTEGER NOT NULL,
      temperature_max_avg DOUBLE PRECISION,
      temperature_min_avg DOUBLE PRECISION,
      temperature_max     DOUBLE PRECISION,
      temperature_min     DOUBLE PRECISION,
      precipitation_sum   DOUBLE PRECISION,
      rainy_days          INTEGER NOT NULL,
      et0_sum             DOUBLE PRECISION,
      PRIMARY KEY (region_id, month)
    )
  '''));

  // Single sequence shared by every mat_* table so `rev` stays one
  // monotonic stream across entity types (mirrors the ordering guarantee
  // the old global sync_events.id sequence gave for free), which keeps
  // FK-dependency order (species -> soils -> locations -> plants -> entries)
  // intact when a peer replays changes.
  await pool.execute(Sql('CREATE SEQUENCE IF NOT EXISTS mat_rev_seq'));

  for (final table in [
    'mat_species',
    'mat_plants',
    'mat_entries',
    'mat_entry_photos',
    'mat_locations',
    'mat_soils',
    'mat_beds',
    'mat_defensivos',
    'mat_reminders',
  ]) {
    // Pre-rewrite mat_* tables (entity_id-only PK, no rev/updated_at) can't
    // be migrated in place -- the PK itself changed shape (see comment
    // below) -- so they're dropped and recreated. The drop MUST stay gated
    // on the old shape: an unconditional drop here would wipe every user's
    // synced data on every server restart, since migrations run on boot.
    final legacyShape = await pool.execute(Sql('''
      SELECT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = current_schema() AND table_name = '$table'
      ) AND NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = '$table' AND column_name = 'rev'
      )
    '''));
    if (legacyShape.first[0] as bool) {
      await pool.execute(Sql('DROP TABLE $table'));
    }

    // Pre-garden tables were keyed (user_id, entity_id): every row moves to
    // its account's personal garden (whose id is the user id) in place, so
    // revs, timestamps and tombstones stay untouched. user_id survives as
    // the account that last wrote the row, without the FK that would let
    // deleting a member's account cascade into a shared garden.
    if (await _tableExists(pool, table) &&
        !await _columnExists(pool, table, 'garden_id')) {
      await pool.execute(Sql(
          'ALTER TABLE $table ADD COLUMN garden_id TEXT REFERENCES gardens(id) ON DELETE CASCADE'));
      await pool.execute(Sql('UPDATE $table SET garden_id = user_id'));
      await pool.execute(
          Sql('ALTER TABLE $table ALTER COLUMN garden_id SET NOT NULL'));
      await _replacePrimaryKey(pool, table, 'garden_id, entity_id');
      final userFks = await pool.execute(Sql('''
        SELECT conname FROM pg_constraint
        WHERE conrelid = '$table'::regclass AND contype = 'f'
          AND confrelid = 'users'::regclass
      '''));
      for (final row in userFks) {
        await pool.execute(
            Sql('ALTER TABLE $table DROP CONSTRAINT "${row[0]}"'));
      }
      await pool.execute(Sql('DROP INDEX IF EXISTS idx_${table}_rev'));
    }

    await pool.execute(Sql('''
      CREATE TABLE IF NOT EXISTS $table (
        entity_id  TEXT NOT NULL,
        garden_id  TEXT NOT NULL REFERENCES gardens(id) ON DELETE CASCADE,
        -- Account that last wrote the row (informational).
        user_id    TEXT NOT NULL,
        payload    JSONB NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL,
        deleted_at TIMESTAMPTZ NULL,
        device_id  TEXT NOT NULL,
        rev        BIGINT NOT NULL DEFAULT nextval('mat_rev_seq'),
        -- Composite PK (not just entity_id): a client-generated UUID
        -- colliding across two gardens must never let a write to one
        -- overwrite the other's row.
        PRIMARY KEY (garden_id, entity_id)
      )
    '''));
    await pool.execute(Sql(
        'CREATE INDEX IF NOT EXISTS idx_${table}_garden_rev ON $table(garden_id, rev)'));
  }
}

Future<bool> _tableExists(Session db, String table) async {
  final result = await db.execute(Sql('''
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = current_schema() AND table_name = '$table'
    )
  '''));
  return result.first[0] as bool;
}

Future<bool> _columnExists(Session db, String table, String column) async {
  final result = await db.execute(Sql('''
    SELECT EXISTS (
      SELECT FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = '$table' AND column_name = '$column'
    )
  '''));
  return result.first[0] as bool;
}

/// Swaps [table]'s primary key for one on [columns], looking the old
/// constraint up by kind rather than assuming its generated name.
Future<void> _replacePrimaryKey(
    Session db, String table, String columns) async {
  final pk = await db.execute(Sql(
      "SELECT conname FROM pg_constraint WHERE conrelid = '$table'::regclass AND contype = 'p'"));
  for (final row in pk) {
    await db.execute(Sql('ALTER TABLE $table DROP CONSTRAINT "${row[0]}"'));
  }
  await db.execute(Sql('ALTER TABLE $table ADD PRIMARY KEY ($columns)'));
}
