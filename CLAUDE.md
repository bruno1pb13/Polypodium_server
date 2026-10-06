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
| `JWT_SECRET` | Minimum 32 chars; used for all token signing. In production the server refuses to boot if this is unset, still the built-in default, or under 32 chars (`Config.validate`) |
| `APP_ENV` | `development` disables SSL on the DB pool; any other value requires SSL |
| `SSL_CERT_PATH` / `SSL_KEY_PATH` | Serve HTTPS directly. In production you must set these **or** `BEHIND_PROXY=true`, else the server refuses to boot instead of silently serving HTTP |
| `BEHIND_PROXY` | `true` when TLS terminates at a reverse proxy (e.g. Nginx Proxy Manager); the app serves plain HTTP behind it and trusts `X-Forwarded-For` for client IP |
| `REGISTRATION_TOKEN` | Optional. When set, the bootstrap admin self-registration requires a matching `registrationToken` in the request body |
| `ALLOWED_ORIGINS` | CORS: `*` or a comma-separated allowlist (only listed origins are echoed back) |
| `AUTH_RATE_LIMIT_MAX` / `AUTH_RATE_LIMIT_WINDOW` | Optional brute-force limits on `/api/v1/auth/*` (default 20 req / 300 s per IP) |
| `MAX_JSON_BODY_BYTES` / `MAX_PHOTO_BYTES` | Optional request-body caps (default 1 MB / 15 MB) |
| `WEATHER_*` | Optional weather tuning (`Config.weatherOptions`; see `.env.example`). The feature itself is toggled by admins at runtime |

## Architecture

The server is a **pull/ack sync backend** for the Polypodium Flutter app: it behaves as just another sync peer, only a public/always-reachable one (JWT + per-garden scoping instead of LAN pairing: every account has a personal garden whose id equals its user id, and can share gardens with other accounts via `gardens`/`garden_members`; sync and photo routes take an optional `X-Polypodium-Garden` header, absent = personal garden). It never reassigns client IDs — all UUIDs are generated on the device.

### Request flow

```
shelf Pipeline
  errorMiddleware → corsMiddleware → logRequests
    Router /api/v1/auth/*   → AuthHandler   (no auth required)
    Router /api/v1/sync/*   → authMiddleware → SyncHandler
    GET /health
```

`authMiddleware` verifies the JWT Bearer token, **re-checks the account in the DB on every request** (rejecting deleted or `disabled` users so a token can't outlive a disable/delete), and injects `userId`, `deviceId`, and `role` into `request.context`. `adminOnlyMiddleware` reads `role` from context (no second query). Every sync handler reads `userId`/`deviceId` from context — never from the request body (the `deviceId` in the body is validated to match the one in the token).

### Database layout

`db.dart` holds a single global `Pool` initialised by `initDatabase()` (called once in `main`). Migrations run automatically on startup via `_runMigrations()` — all DDL uses `CREATE TABLE IF NOT EXISTS`.

There is no event log — sync is driven directly off versioned rows:

**`mat_*` tables** (`mat_species`, `mat_plants`, `mat_entries`, `mat_locations`, `mat_soils`, `mat_beds`) hold the materialised current state, one row per `(garden_id, entity_id)` (composite PK — a colliding client-generated UUID across two gardens must never let one overwrite the other's row; `user_id` is kept as the last account that wrote the row). Each row carries `updated_at` (real edit time), `deleted_at` (soft-delete tombstone — deletes are never physical), `device_id` (last writer), and `rev` (assigned from the single shared `mat_rev_seq` sequence on every insert/update/soft-delete, so ordering stays one monotonic stream across every entity type, the same guarantee the old `sync_events.id` sequence gave for free).

- `SyncRepository.serveChanges(...)` (scoped by garden) — reads `rev > since` across all `mat_*` tables and merge-sorts by `rev` (`GET /sync/changes`).
- `SyncRepository.receiveChanges(...)` (scoped by garden) — applies a batch via `INSERT ... ON CONFLICT (garden_id, entity_id) DO UPDATE ... WHERE EXCLUDED.updated_at > table.updated_at OR (EXCLUDED.updated_at = table.updated_at AND EXCLUDED.device_id > table.device_id)` (`POST /sync/receive`). This SQL comparator must match `incomingWins` from the shared `polypodium_core` package (git dependency). `test/features/sync/sync_repository_test.dart` runs the package's LWW vectors through the real `ON CONFLICT` to enforce it. The client applies the same `incomingWins` on pull (its rows store the last writer's deviceId), so both sides resolve ties identically.

`device_cursors` tracks the highest `rev` each device has acknowledged pulling (`POST /sync/ack`) — purely informational bookkeeping for `/sync/status` now, not required for correctness (a device's own local cursor state is what actually drives its next pull).

### JSONB handling

PostgreSQL JSONB is inserted as a plain string with a `::jsonb` cast in the SQL (`@payload::jsonb`, parameter = `jsonEncode(map)`). When read back, results go through `_decodePayload(raw)` which accepts both `Map` (binary protocol) and `String` (text protocol), making the code robust across postgres driver versions.

### Conflict handling

There is no explicit conflict detection/UI — merges are always resolved deterministically by last-write-wins (see comparator above). An older incoming write silently no-ops rather than erroring; the caller's own cursor still advances since delivery succeeded at the transport level regardless of the merge outcome.

### Weather

`WeatherService` (started in `main`) runs hourly while the `weather_enabled` server setting is on. It clusters the coordinates of every live `mat_locations` row (all gardens) into `weather_regions`. A coordinate joins the nearest region whose fixed center is within `clusterRadiusKm`; otherwise it creates a new region centered on itself. The service fetches each region in use from Open-Meteo (`IWeatherProvider`, faked in tests) about once a day, and then `WeatherRepository.housekeeping` thins the data: `weather_hourly` keeps the last few days, `weather_daily` drops whole months past the retention after rolling them into `weather_monthly`, and idle regions are deleted (cascade). A session advisory lock keeps two instances from running the job at once. `GET /weather/locations/<id>` resolves the location within the caller's garden. It never returns region coordinates, because a region can be shared with other accounts' locations.

### Adding a new entity type

1. Add the name to `_validEntityTypes` and `_matTable` in `sync_repository.dart`.
2. The migration in `db.dart` already creates `mat_<name>` if you add it to the loop's list.
3. No changes needed in handlers or middleware.
