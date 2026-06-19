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

  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS devices (
      id           TEXT PRIMARY KEY,
      user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      name         TEXT,
      last_seen_at TIMESTAMPTZ,
      created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  '''));

  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS sync_events (
      id               BIGSERIAL PRIMARY KEY,
      device_id        TEXT NOT NULL REFERENCES devices(id),
      user_id          TEXT NOT NULL REFERENCES users(id),
      entity_type      TEXT NOT NULL,
      entity_id        TEXT NOT NULL,
      operation        TEXT NOT NULL,
      payload          JSONB NOT NULL,
      client_timestamp TIMESTAMPTZ NOT NULL,
      server_timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  '''));

  await pool.execute(
      Sql('CREATE INDEX IF NOT EXISTS idx_sync_events_user_id ON sync_events(user_id)'));
  await pool.execute(
      Sql('CREATE INDEX IF NOT EXISTS idx_sync_events_cursor ON sync_events(id)'));
  await pool.execute(Sql('''
    CREATE INDEX IF NOT EXISTS idx_sync_events_entity
      ON sync_events(user_id, entity_id, id DESC)
  '''));

  await pool.execute(Sql('''
    CREATE TABLE IF NOT EXISTS device_cursors (
      device_id          TEXT PRIMARY KEY REFERENCES devices(id),
      last_pulled_cursor BIGINT NOT NULL DEFAULT 0
    )
  '''));

  for (final table in [
    'mat_species',
    'mat_plants',
    'mat_entries',
    'mat_locations',
    'mat_soils',
  ]) {
    await pool.execute(Sql('''
      CREATE TABLE IF NOT EXISTS $table (
        entity_id        TEXT PRIMARY KEY,
        user_id          TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        payload          JSONB NOT NULL,
        server_timestamp TIMESTAMPTZ NOT NULL
      )
    '''));
  }
}
