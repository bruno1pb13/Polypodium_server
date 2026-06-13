# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run (development — reads vars from .env)
source .env && dart run bin/server.dart

# Analyze (no test suite yet)
dart analyze

# Compile to native binary
dart compile exe bin/server.dart -o server

# Update dependencies
dart pub get
dart pub upgrade
```

## Environment

Copy `.env.example` to `.env` and fill in the values. Required vars:

| Var | Purpose |
|-----|---------|
| `DATABASE_URL` | PostgreSQL connection string |
| `JWT_SECRET` | Minimum 32 chars; used for all token signing |
| `APP_ENV` | `development` disables SSL on the DB pool; any other value requires SSL |
| `SSL_CERT_PATH` / `SSL_KEY_PATH` | Only needed when `APP_ENV != development` |

## Architecture

The server is an **event-log sync backend** for the Polypodium Flutter app. It never reassigns client IDs — all UUIDs are generated on the device.

### Request flow

```
shelf Pipeline
  errorMiddleware → corsMiddleware → logRequests
    Router /api/v1/auth/*   → AuthHandler   (no auth required)
    Router /api/v1/sync/*   → authMiddleware → SyncHandler
    GET /health
```

`authMiddleware` verifies the JWT Bearer token and injects `userId` and `deviceId` into `request.context`. Every sync handler reads these from context — never from the request body (the `deviceId` in the body is validated to match the one in the token).

### Database layout

`db.dart` holds a single global `Pool` initialised by `initDatabase()` (called once in `main`). Migrations run automatically on startup via `_runMigrations()` — all DDL uses `CREATE TABLE IF NOT EXISTS`.

Two logical layers:

1. **`sync_events`** — append-only log; never deleted. Each push inserts one row per event. Pull queries read from this table (`id > since AND device_id != myDevice`).

2. **`mat_*` tables** (`mat_species`, `mat_plants`, `mat_entries`, `mat_locations`, `mat_soils`) — materialised current state, updated on every push using Last-Write-Wins: `ON CONFLICT … DO UPDATE WHERE EXCLUDED.server_timestamp >= table.server_timestamp`. Delete events remove the row.

`device_cursors` tracks the highest `sync_events.id` each device has acknowledged.

### JSONB handling

PostgreSQL JSONB is inserted as a plain string with a `::jsonb` cast in the SQL (`@payload::jsonb`, parameter = `jsonEncode(map)`). When read back, results go through `_decodePayload(raw)` which accepts both `Map` (binary protocol) and `String` (text protocol), making the code robust across postgres driver versions.

### Conflict detection

Only checked for `update` operations. If the entity is absent from the `mat_*` table but a `delete` event exists in `sync_events` for that `entity_id`, the push response marks it as `entity_deleted_on_server` and returns the last known payload. The event is **not** written to the log.

### Adding a new entity type

1. Add the name to `_validEntityTypes` and `_matTable` in `sync_repository.dart`.
2. The migration in `db.dart` already creates `mat_<name>` if you add it to the loop's list.
3. No changes needed in handlers or middleware.
