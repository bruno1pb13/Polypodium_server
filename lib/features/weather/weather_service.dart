import 'dart:async';

import 'package:postgres/postgres.dart';
import 'package:uuid/uuid.dart';

import '../admin/i_settings_repository.dart';
import 'weather_models.dart';
import 'weather_provider.dart';
import 'weather_repository.dart';

const _uuid = Uuid();

/// Session advisory lock so only one server instance runs the job at a time.
const _jobLockKey = 918273647;

class WeatherRunResult {
  const WeatherRunResult({
    this.skipped = false,
    this.regions = 0,
    this.fetched = 0,
    this.failed = 0,
  });

  /// Weather is disabled or another instance holds the job lock.
  final bool skipped;
  final int regions;
  final int fetched;
  final int failed;

  Map<String, Object> toJson() => {
        'skipped': skipped,
        'regions': regions,
        'fetched': fetched,
        'failed': failed,
      };
}

/// Keeps forecasts for every location with coordinates while the admin
/// setting is on: groups nearby coordinates into regions, fetches each
/// region about once a day, and thins old data.
class WeatherService {
  WeatherService(
    this._repo,
    this._settings,
    this._provider, {
    this.options = const WeatherOptions(),
  });

  final WeatherRepository _repo;
  final ISettingsRepository _settings;
  final IWeatherProvider _provider;
  final WeatherOptions options;

  Timer? _timer;
  Future<WeatherRunResult>? _running;

  Future<bool> isEnabled() =>
      _settings.getBool(settingWeatherEnabled, defaultValue: false);

  /// Checks hourly, so a new location gets its forecast within the hour
  /// while regions already fetched wait for [WeatherOptions.refreshInterval].
  void start({
    Duration every = const Duration(hours: 1),
    Duration firstRunAfter = const Duration(minutes: 1),
  }) {
    _timer?.cancel();
    _timer = Timer(firstRunAfter, () {
      _tick();
      _timer = Timer.periodic(every, (_) => _tick());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    try {
      final result = await runOnce();
      if (result.fetched > 0 || result.failed > 0) {
        print('Weather: fetched ${result.fetched}, failed ${result.failed} '
            'of ${result.regions} regions.');
      }
    } catch (e) {
      print('Weather job failed: $e');
    }
  }

  /// Runs the job now; [force] refetches every region in use regardless of
  /// when it was last fetched. A call while a run is in progress joins it.
  Future<WeatherRunResult> runOnce({bool force = false}) =>
      _running ??= _run(force).whenComplete(() => _running = null);

  Future<WeatherRunResult> _run(bool force) async {
    if (!await isEnabled()) return const WeatherRunResult(skipped: true);

    return _repo.db.withConnection((conn) async {
      final locked = await conn
          .execute(Sql('SELECT pg_try_advisory_lock($_jobLockKey)'));
      if (!(locked.first[0] as bool)) {
        return const WeatherRunResult(skipped: true);
      }
      try {
        return await _runLocked(force);
      } finally {
        await conn.execute(Sql('SELECT pg_advisory_unlock($_jobLockKey)'));
      }
    });
  }

  Future<WeatherRunResult> _runLocked(bool force) async {
    final regions = await assignRegions();
    await _repo.touchRegions(regions.map((r) => r.id));

    final now = DateTime.now();
    var fetched = 0;
    var failed = 0;
    for (final region in regions) {
      if (!force && !_isDue(region, now)) continue;
      try {
        final forecast = await _provider.fetch(
          region.latitude,
          region.longitude,
          // At least a couple of past days so the latest fetch corrects
          // what the previous forecasts said about them.
          pastDays: options.hourlyPastDays < 2 ? 2 : options.hourlyPastDays,
          forecastDays: options.forecastDays,
        );
        await _repo.saveForecast(region.id, forecast);
        fetched++;
      } catch (e) {
        await _repo.recordFailure(region.id, '$e');
        failed++;
      }
    }

    await _repo.housekeeping(options);
    return WeatherRunResult(
        regions: regions.length, fetched: fetched, failed: failed);
  }

  bool _isDue(WeatherRegion region, DateTime now) {
    final fetched = region.lastFetchedAt;
    final attempted = region.lastAttemptAt;
    // A failed attempt after the last success waits retryInterval.
    if (attempted != null &&
        (fetched == null || attempted.isAfter(fetched)) &&
        now.difference(attempted) < options.retryInterval) {
      return false;
    }
    if (fetched == null) return true;
    // Slack so an hourly tick that lands a few minutes early still counts.
    return now.difference(fetched) >=
        options.refreshInterval - const Duration(minutes: 10);
  }

  /// Maps every location coordinate to a region, creating regions for
  /// coordinates farther than [WeatherOptions.clusterRadiusKm] from all
  /// existing ones. Returns the regions currently in use.
  Future<List<WeatherRegion>> assignRegions() async {
    final regions = await _repo.listRegions();
    final coords = (await _repo.locationCoordinates())
        .where((c) => isValidCoordinate(c.latitude, c.longitude))
        .toList()
      // Deterministic order, so the same set of locations always clusters
      // the same way.
      ..sort((a, b) {
        final byLat = a.latitude.compareTo(b.latitude);
        return byLat != 0 ? byLat : a.longitude.compareTo(b.longitude);
      });

    final used = <String, WeatherRegion>{};
    for (final c in coords) {
      var region = nearestRegion(
          regions, c.latitude, c.longitude, options.clusterRadiusKm);
      if (region == null) {
        region = WeatherRegion(
            id: _uuid.v4(), latitude: c.latitude, longitude: c.longitude);
        await _repo.createRegion(region.id, region.latitude, region.longitude);
        regions.add(region);
      }
      used[region.id] = region;
    }
    return used.values.toList();
  }

  Future<List<WeatherRegion>> regions() => _repo.listRegions();

  /// The region serving a coordinate, if the job has created one yet.
  Future<WeatherRegion?> regionFor(double latitude, double longitude) async =>
      nearestRegion(await _repo.listRegions(), latitude, longitude,
          options.clusterRadiusKm);
}
