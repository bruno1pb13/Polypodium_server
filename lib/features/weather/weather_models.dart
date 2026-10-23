import 'package:polypodium_core/weather.dart';

// The forecast rows and coordinate helpers are shared with the app.
export 'package:polypodium_core/weather.dart'
    show
        DailyWeather,
        HourlyWeather,
        WeatherForecast,
        distanceKm,
        isValidCoordinate;

/// The daily forecast one fetch issued, from its `issuedOn` date (the
/// region's local date then) onwards.
class WeatherSnapshot {
  const WeatherSnapshot({
    required this.fetchedAt,
    required this.issuedOn,
    required this.daily,
  });

  final DateTime fetchedAt;
  final String issuedOn;
  final List<DailyWeather> daily;
}

/// A point the server fetches weather for. Nearby location coordinates share
/// one region (see [WeatherOptions.clusterRadiusKm]); its center is the first
/// coordinate that created it and never moves, so assignments stay stable.
class WeatherRegion {
  const WeatherRegion({
    required this.id,
    required this.latitude,
    required this.longitude,
    this.timezone,
    this.elevation,
    this.lastFetchedAt,
    this.lastAttemptAt,
    this.lastUsedAt,
    this.lastError,
  });

  final String id;
  final double latitude;
  final double longitude;
  final String? timezone;
  final double? elevation;
  final DateTime? lastFetchedAt;
  final DateTime? lastAttemptAt;
  final DateTime? lastUsedAt;
  final String? lastError;
}

/// Tunables for fetching and retention; defaults come from Config.
class WeatherOptions {
  const WeatherOptions({
    this.clusterRadiusKm = 5,
    this.refreshInterval = const Duration(hours: 24),
    this.retryInterval = const Duration(hours: 1),
    this.forecastDays = 7,
    this.hourlyPastDays = 2,
    this.dailyRetentionDays = 365,
    this.regionIdleDays = 30,
    this.snapshotRetentionDays = 30,
  });

  /// Coordinates closer than this to a region's center reuse that region.
  final double clusterRadiusKm;

  /// How often a region in use is fetched again.
  final Duration refreshInterval;

  /// How long to wait before retrying a region whose last fetch failed.
  final Duration retryInterval;

  final int forecastDays;

  /// Past days that keep hourly detail; older hours are dropped.
  final int hourlyPastDays;

  /// Past days that keep daily detail. Older months are rolled up into
  /// monthly summaries, which are kept for as long as the region exists.
  final int dailyRetentionDays;

  /// A region no location has been near for this long is deleted with all
  /// of its data.
  final int regionIdleDays;

  /// How long each fetch's forecast, as issued, is kept in
  /// `weather_snapshots`.
  final int snapshotRetentionDays;
}

/// The region whose center is nearest to the point, if within [radiusKm].
WeatherRegion? nearestRegion(
    Iterable<WeatherRegion> regions, double lat, double lon, double radiusKm) {
  WeatherRegion? best;
  var bestKm = double.infinity;
  for (final region in regions) {
    final km = distanceKm(lat, lon, region.latitude, region.longitude);
    if (km <= radiusKm && km < bestKm) {
      best = region;
      bestKm = km;
    }
  }
  return best;
}
