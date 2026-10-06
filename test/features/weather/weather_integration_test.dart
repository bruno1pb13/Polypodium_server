// The weather job and endpoint against real Postgres, with a fake provider.
// Skips when no Postgres is reachable (set DATABASE_URL). The job reads every
// location in the database, so assertions only look at regions near the
// test's own coordinates (in the Southern Ocean), and every region the test
// run created is removed afterwards.
import 'dart:convert';
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:polypodium_server/core/token_service.dart';
import 'package:polypodium_server/database/db.dart';
import 'package:polypodium_server/features/admin/admin_handler.dart';
import 'package:polypodium_server/features/admin/i_settings_repository.dart';
import 'package:polypodium_server/features/admin/settings_repository.dart';
import 'package:polypodium_server/features/auth/auth_handler.dart';
import 'package:polypodium_server/features/auth/auth_repository.dart';
import 'package:polypodium_server/features/gardens/garden_handler.dart';
import 'package:polypodium_server/features/gardens/garden_repository.dart';
import 'package:polypodium_server/features/photos/photo_handler.dart';
import 'package:polypodium_server/features/sync/sync_handler.dart';
import 'package:polypodium_server/features/sync/sync_repository.dart';
import 'package:polypodium_server/features/weather/weather_handler.dart';
import 'package:polypodium_server/features/weather/weather_models.dart';
import 'package:polypodium_server/features/weather/weather_provider.dart';
import 'package:polypodium_server/features/weather/weather_repository.dart';
import 'package:polypodium_server/features/weather/weather_service.dart';
import 'package:polypodium_server/routes/router.dart';

typedef _Res = ({int status, Map<String, dynamic> body});

const _baseLat = -61.0;
const _baseLon = -150.0;

bool _nearTestArea(double lat, double lon) =>
    distanceKm(lat, lon, _baseLat, _baseLon) < 200;

String _day(DateTime d) => d.toIso8601String().substring(0, 10);

class _FakeProvider implements IWeatherProvider {
  final calls = <({double lat, double lon})>[];
  bool fail = false;

  int get testAreaCalls => calls.where((c) => _nearTestArea(c.lat, c.lon)).length;

  @override
  Future<WeatherForecast> fetch(double latitude, double longitude,
      {required int pastDays, required int forecastDays}) async {
    calls.add((lat: latitude, lon: longitude));
    if (fail && _nearTestArea(latitude, longitude)) {
      throw const WeatherProviderException('HTTP 503: unavailable');
    }
    final today = DateTime.now().toUtc();
    final start = DateTime.utc(today.year, today.month, today.day)
        .subtract(Duration(days: pastDays));
    return WeatherForecast(
      timezone: 'UTC',
      elevation: 12,
      hourly: [
        for (var h = 0; h < 24 * (pastDays + 2); h += 6)
          HourlyWeather(
            time: start
                .add(Duration(hours: h))
                .toIso8601String()
                .substring(0, 16),
            temperature: 4.0 + h % 5,
            precipitation: 0.2,
          ),
      ],
      daily: [
        for (var d = 0; d < pastDays + forecastDays; d++)
          DailyWeather(
            date: _day(start.add(Duration(days: d))),
            weatherCode: 61,
            temperatureMax: 8,
            temperatureMin: 1,
            precipitationSum: 3,
          ),
      ],
    );
  }
}

class _Account {
  _Account(this.id, this.token, this.deviceId);
  final String id;
  final String token;
  final String deviceId;
}

void main() {
  Pool? pool;
  late Handler app;
  late Directory photosDir;
  late WeatherService service;
  late WeatherRepository repo;
  late SettingsRepository settings;
  final provider = _FakeProvider();
  final createdUsers = <String>[];
  final preexistingRegions = <String>{};
  bool? previousEnabled;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  var seq = 0;

  setUpAll(() async {
    try {
      pool = await initDatabase();
    } catch (_) {
      pool = null;
      return;
    }
    final db = pool!;
    photosDir = await Directory.systemTemp.createTemp();
    final existing = await db.execute(Sql('SELECT id FROM weather_regions'));
    preexistingRegions.addAll(existing.map((r) => r[0] as String));
    final setting = await db.execute(
      Sql.named('SELECT value FROM server_settings WHERE key = @key'),
      parameters: {'key': settingWeatherEnabled},
    );
    if (setting.isNotEmpty) previousEnabled = setting.first[0] == 'true';

    final authRepo = AuthRepository(db);
    final gardenRepo = GardenRepository(db);
    settings = SettingsRepository(db);
    repo = WeatherRepository(db);
    service = WeatherService(repo, settings, provider);
    const tokens = JwtTokenService('0123456789abcdef0123456789abcdef');
    app = buildRouter(
      auth: AuthHandler(authRepo, tokens),
      sync: SyncHandler(SyncRepository(db)),
      photos: PhotoHandler(photosDir.path),
      admin: AdminHandler(authRepo, settings, DateTime.now(), 'test',
          weather: service),
      gardens: GardenHandler(gardenRepo, authRepo),
      weather: WeatherHandler(service, repo),
      gardenRepo: gardenRepo,
      authRepo: authRepo,
      tokens: tokens,
    ).call;
  });

  tearDownAll(() async {
    final db = pool;
    if (db == null) return;
    await db.execute(
      Sql.named('DELETE FROM weather_regions WHERE NOT id = ANY(@ids::text[])'),
      parameters: {'ids': preexistingRegions.toList()},
    );
    if (previousEnabled == null) {
      await db.execute(
        Sql.named('DELETE FROM server_settings WHERE key = @key'),
        parameters: {'key': settingWeatherEnabled},
      );
    } else {
      await settings.setBool(settingWeatherEnabled, previousEnabled!);
    }
    for (final id in createdUsers) {
      await db.execute(
        Sql.named('''
          DELETE FROM device_cursors
          WHERE device_id IN (SELECT id FROM devices WHERE user_id = @id)
        '''),
        parameters: {'id': id},
      );
      await db.execute(Sql.named('DELETE FROM users WHERE id = @id'),
          parameters: {'id': id});
    }
    await photosDir.delete(recursive: true);
    await db.close();
  });

  Future<_Res> send(String method, String path,
      {_Account? as, Object? body}) async {
    final res = await app(Request(
      method,
      Uri.parse('http://localhost/api/v1$path'),
      headers: {if (as != null) 'Authorization': 'Bearer ${as.token}'},
      body: body == null ? null : jsonEncode(body),
    ));
    final text = await res.readAsString();
    final decoded = text.isEmpty ? null : jsonDecode(text);
    return (
      status: res.statusCode,
      body: decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
    );
  }

  Future<_Account> account({String role = 'member'}) async {
    final id = 'weather-test-$stamp-${seq++}';
    createdUsers.add(id);
    await AuthRepository(pool!).createUser(id, '$id@test.local',
        BCrypt.hashpw('password1', BCrypt.gensalt(logRounds: 4)), role);
    final login = await send('POST', '/auth/login', body: {
      'email': '$id@test.local',
      'password': 'password1',
      'deviceId': 'dev-$id',
      'deviceName': 'Polypodium',
    });
    expect(login.status, 200, reason: '${login.body}');
    return _Account(id, login.body['token'] as String,
        login.body['deviceId'] as String);
  }

  Future<void> pushLocation(_Account by, String id,
      {double? lat, double? lon, bool deleted = false}) async {
    final res = await send('POST', '/sync/receive', as: by, body: {
      'deviceId': by.deviceId,
      'changes': [
        {
          'entityType': 'location',
          'entityId': id,
          'payload': {
            'id': id,
            'name': id,
            'latitude': lat,
            'longitude': lon,
          },
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'deletedAt':
              deleted ? DateTime.now().toUtc().toIso8601String() : null,
          'deviceId': by.deviceId,
          'rev': 0,
        }
      ],
    });
    expect(res.status, 200, reason: '${res.body}');
  }

  Future<List<WeatherRegion>> testRegions() async => [
        for (final r in await repo.listRegions())
          if (_nearTestArea(r.latitude, r.longitude)) r
      ];

  Future<void> resetTestRegions() async {
    for (final r in await testRegions()) {
      await pool!.execute(
          Sql.named('DELETE FROM weather_regions WHERE id = @id'),
          parameters: {'id': r.id});
    }
  }

  late _Account owner;
  final loc = 'loc-$stamp';

  setUp(() async {
    if (pool == null) return;
    provider.fail = false;
    provider.calls.clear();
    await settings.setBool(settingWeatherEnabled, true);
    await resetTestRegions();
    // Earlier tests' locations would otherwise keep their regions in use.
    await pool!.execute(
      Sql.named('DELETE FROM mat_locations WHERE garden_id = ANY(@ids::text[])'),
      parameters: {'ids': createdUsers},
    );
    owner = await account();
    // A and B are ~1 km apart and share a region; C is ~55 km away.
    await pushLocation(owner, '$loc-a', lat: _baseLat, lon: _baseLon);
    await pushLocation(owner, '$loc-b',
        lat: _baseLat - 0.005, lon: _baseLon - 0.01);
    await pushLocation(owner, '$loc-c', lat: _baseLat - 0.5, lon: _baseLon);
    await pushLocation(owner, '$loc-none');
    await pushLocation(owner, '$loc-gone',
        lat: _baseLat + 1, lon: _baseLon, deleted: true);
  });

  test('nearby coordinates share one region and one fetch', () async {
    if (pool == null) return markTestSkipped('no Postgres');

    await service.runOnce();
    final regions = await testRegions();
    expect(regions, hasLength(2));
    expect(provider.testAreaCalls, 2);
    expect(regions.every((r) => r.lastFetchedAt != null), isTrue);
    expect(regions.first.timezone, 'UTC');
  });

  test('regions are refetched only once the refresh interval passes',
      () async {
    if (pool == null) return markTestSkipped('no Postgres');

    await service.runOnce();
    await service.runOnce();
    expect(provider.testAreaCalls, 2);

    await pool!.execute(
      Sql.named('''
        UPDATE weather_regions
        SET last_fetched_at = NOW() - INTERVAL '25 hours',
            last_attempt_at = NOW() - INTERVAL '25 hours'
        WHERE id = ANY(@ids::text[])
      '''),
      parameters: {'ids': [for (final r in await testRegions()) r.id]},
    );
    await service.runOnce();
    expect(provider.testAreaCalls, 4);

    final res = await send('POST', '/admin/weather/refresh',
        as: await account(role: 'admin'));
    expect(res.status, 200, reason: '${res.body}');
    expect(provider.testAreaCalls, 6);
  });

  test('a failed fetch is recorded and waits before retrying', () async {
    if (pool == null) return markTestSkipped('no Postgres');

    provider.fail = true;
    await service.runOnce();
    final regions = await testRegions();
    expect(regions.map((r) => r.lastError),
        everyElement(contains('HTTP 503')));
    expect(regions.every((r) => r.lastFetchedAt == null), isTrue);

    provider.fail = false;
    await service.runOnce();
    expect(provider.testAreaCalls, 2, reason: 'retry waits retryInterval');
  });

  test('serves a location\'s forecast without revealing the region',
      () async {
    if (pool == null) return markTestSkipped('no Postgres');

    var res = await send('GET', '/weather/locations/$loc-a', as: owner);
    expect(res.status, 404);
    expect(res.body['code'], 'weather_pending');

    await service.runOnce();
    res = await send('GET', '/weather/locations/$loc-a?days=1', as: owner);
    expect(res.status, 200, reason: '${res.body}');
    expect(res.body['timezone'], 'UTC');
    expect(res.body['hourly'], isNotEmpty);
    final daily = (res.body['daily'] as List).cast<Map<String, dynamic>>();
    final yesterday =
        _day(DateTime.now().toUtc().subtract(const Duration(days: 1)));
    expect(daily.first['date'], yesterday);
    expect(daily.first['temperatureMax'], 8.0);
    expect(res.body.keys, isNot(contains('latitude')));
    expect(jsonEncode(res.body), isNot(contains('$_baseLat')));

    res = await send('GET', '/weather/locations/$loc-none', as: owner);
    expect(res.body['code'], 'no_coordinates');
    res = await send('GET', '/weather/locations/$loc-gone', as: owner);
    expect(res.body['code'], 'location_not_found');

    // Another account's garden doesn't hold the location.
    res = await send('GET', '/weather/locations/$loc-a', as: await account());
    expect(res.status, 404);
    expect(res.body['code'], 'location_not_found');
  });

  test('disabled: nothing is fetched or served', () async {
    if (pool == null) return markTestSkipped('no Postgres');

    final admin = await account(role: 'admin');
    var res = await send('PATCH', '/admin/settings',
        as: admin, body: {'weatherEnabled': false});
    expect(res.status, 200, reason: '${res.body}');
    expect(res.body['weatherEnabled'], false);

    final result = await service.runOnce();
    expect(result.skipped, isTrue);
    expect(provider.calls, isEmpty);

    res = await send('GET', '/weather/locations/$loc-a', as: owner);
    expect(res.body['code'], 'weather_disabled');
    res = await send('GET', '/admin/me', as: owner);
    expect(res.body['weatherEnabled'], false);
  });

  test('old data thins out: hourly dropped, daily rolled up by month',
      () async {
    if (pool == null) return markTestSkipped('no Postgres');

    await service.runOnce();
    final region = (await service.regionFor(_baseLat, _baseLon))!;
    final db = pool!;
    await db.execute(
      Sql.named('''
        INSERT INTO weather_hourly (region_id, time, temperature)
        VALUES (@id, NOW()::date - 10, 5)
      '''),
      parameters: {'id': region.id},
    );
    // Two whole months well past the daily retention (~14 months ago),
    // with rain on 2 of the first month's days.
    await db.execute(
      Sql.named('''
        INSERT INTO weather_daily (region_id, date, temperature_max,
          temperature_min, precipitation_sum, et0)
        SELECT @id, d::date,
               CASE WHEN d::date = m THEN 20 ELSE 10 END, 2,
               CASE WHEN extract(day FROM d) <= 2 THEN 5 ELSE 0 END, 1
        FROM (SELECT date_trunc('month', NOW() - INTERVAL '14 months')::date
                AS m) s,
             generate_series(s.m, s.m + INTERVAL '2 months' - INTERVAL '1 day',
                             INTERVAL '1 day') d
      '''),
      parameters: {'id': region.id},
    );

    await repo.housekeeping(service.options);

    final hourly = await db.execute(
      Sql.named('''
        SELECT COUNT(*) FROM weather_hourly
        WHERE region_id = @id AND time < NOW()::date - 5
      '''),
      parameters: {'id': region.id},
    );
    expect(hourly.first[0], 0);
    final oldDaily = await db.execute(
      Sql.named('''
        SELECT COUNT(*) FROM weather_daily
        WHERE region_id = @id AND date < NOW()::date - 400
      '''),
      parameters: {'id': region.id},
    );
    expect(oldDaily.first[0], 0);
    // Recent forecast days are untouched.
    expect(await repo.daily(region.id, 1), isNotEmpty);

    final monthly = await repo.monthly(region.id, 24);
    expect(monthly.length, greaterThanOrEqualTo(2));
    final first = monthly.first;
    final days = first['days'] as int;
    expect(days, inInclusiveRange(28, 31));
    expect(first['temperatureMax'], 20.0);
    expect(first['temperatureMin'], 2.0);
    expect(first['temperatureMaxAvg'], closeTo((20 + 10 * (days - 1)) / days, 1e-9));
    expect(first['precipitationSum'], 10.0);
    expect(first['rainyDays'], 2);
    expect(first['et0Sum'], days.toDouble());

    final res = await send(
        'GET', '/weather/locations/$loc-a?months=24&days=0', as: owner);
    expect(res.status, 200, reason: '${res.body}');
    expect((res.body['monthly'] as List).first['month'], first['month']);
  });

  test('a region no location is near any more is pruned', () async {
    if (pool == null) return markTestSkipped('no Postgres');

    await service.runOnce();
    await pushLocation(owner, '$loc-c',
        lat: _baseLat - 0.5, lon: _baseLon, deleted: true);
    await pool!.execute(
      Sql.named('''
        UPDATE weather_regions SET last_used_at = NOW() - INTERVAL '31 days'
        WHERE id = ANY(@ids::text[])
      '''),
      parameters: {'ids': [for (final r in await testRegions()) r.id]},
    );
    await service.runOnce();

    final regions = await testRegions();
    expect(regions, hasLength(1));
    expect(distanceKm(regions.single.latitude, regions.single.longitude,
            _baseLat, _baseLon),
        lessThan(5));
  });

  test('admin sees every region with its coordinates', () async {
    if (pool == null) return markTestSkipped('no Postgres');

    await service.runOnce();
    var res =
        await send('GET', '/admin/weather', as: await account(role: 'admin'));
    expect(res.status, 200, reason: '${res.body}');
    expect(res.body['enabled'], true);
    final near = [
      for (final r in res.body['regions'] as List)
        if (_nearTestArea(r['latitude'] as double, r['longitude'] as double))
          r
    ];
    expect(near, hasLength(2));

    res = await send('GET', '/admin/weather', as: owner);
    expect(res.status, 403);
  });
}
