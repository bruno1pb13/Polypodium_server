import 'package:postgres/postgres.dart';
import '../core/config.dart';

Future<Pool> initDatabase() async {
  final uri = Uri.parse(Config.databaseUrl);
  final userInfo = uri.userInfo.split(':');

  final pool = Pool.withEndpoints(
    [
      Endpoint(
        host: uri.host,
        port: uri.port == 0 ? 5432 : uri.port,
        database: uri.path.substring(1),
        username: userInfo.isNotEmpty ? userInfo[0] : 'postgres',
        password: userInfo.length > 1 ? userInfo[1] : '',
      ),
    ],
    settings: PoolSettings(
      maxConnectionCount: 10,
      sslMode: Config.dbSsl ? SslMode.require : SslMode.disable,
    ),
  );

  await _runMigrations(pool);
  return pool;
}

Future<void> _runMigrations(Pool pool) async {
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

  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS device_cursors (
      device_id          TEXT PRIMARY KEY REFERENCES devices(id),
      last_pulled_cursor BIGINT NOT NULL DEFAULT 0
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
    'mat_locations',
    'mat_soils',
    'mat_beds',
  ]) {
    // Pre-rewrite mat_* tables (entity_id-only PK, no rev/updated_at) are
    // dropped and recreated: no production data to preserve, and the PK
    // itself is changing shape (see comment below).
    await pool.execute(Sql('DROP TABLE IF EXISTS $table'));
    await pool.execute(Sql('''
      CREATE TABLE $table (
        entity_id  TEXT NOT NULL,
        user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        payload    JSONB NOT NULL,
        updated_at TIMESTAMPTZ NOT NULL,
        deleted_at TIMESTAMPTZ NULL,
        device_id  TEXT NOT NULL,
        rev        BIGINT NOT NULL DEFAULT nextval('mat_rev_seq'),
        -- Composite PK (not just entity_id): a client-generated UUID
        -- colliding across two different users would otherwise let one
        -- user's write silently overwrite another's, since entity_id alone
        -- was both the old PK and the old ON CONFLICT target.
        PRIMARY KEY (user_id, entity_id)
      )
    '''));
    await pool.execute(
        Sql('CREATE INDEX IF NOT EXISTS idx_${table}_rev ON $table(user_id, rev)'));
  }
}
