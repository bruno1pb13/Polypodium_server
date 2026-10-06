import 'dart:math' as math;

/// One forecast as returned by a provider for a single point. Times are the
/// region's local wall-clock time (`2026-10-06T13:00`), dates are local dates
/// (`2026-10-06`), so they're stored and served exactly as received.
class WeatherForecast {
  const WeatherForecast({
    required this.timezone,
    required this.elevation,
    required this.hourly,
    required this.daily,
  });

  final String? timezone;
  final double? elevation;
  final List<HourlyWeather> hourly;
  final List<DailyWeather> daily;
}

class HourlyWeather {
  const HourlyWeather({
    required this.time,
    this.temperature,
    this.humidity,
    this.precipitation,
    this.precipitationProbability,
    this.weatherCode,
    this.windSpeed,
  });

  final String time;
  final double? temperature;
  final double? humidity;
  final double? precipitation;
  final double? precipitationProbability;
  final int? weatherCode;
  final double? windSpeed;

  Map<String, Object?> toJson() => {
        'time': time,
        'temperature': temperature,
        'humidity': humidity,
        'precipitation': precipitation,
        'precipitationProbability': precipitationProbability,
        'weatherCode': weatherCode,
        'windSpeed': windSpeed,
      };
}

class DailyWeather {
  const DailyWeather({
    required this.date,
    this.weatherCode,
    this.temperatureMax,
    this.temperatureMin,
    this.precipitationSum,
    this.precipitationProbabilityMax,
    this.windSpeedMax,
    this.et0,
  });

  final String date;
  final int? weatherCode;
  final double? temperatureMax;
  final double? temperatureMin;
  final double? precipitationSum;
  final double? precipitationProbabilityMax;
  final double? windSpeedMax;

  /// Reference evapotranspiration (FAO-56), in mm.
  final double? et0;

  Map<String, Object?> toJson() => {
        'date': date,
        'weatherCode': weatherCode,
        'temperatureMax': temperatureMax,
        'temperatureMin': temperatureMin,
        'precipitationSum': precipitationSum,
        'precipitationProbabilityMax': precipitationProbabilityMax,
        'windSpeedMax': windSpeedMax,
        'et0': et0,
      };
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
}

/// Great-circle distance between two coordinates, in km.
double distanceKm(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusKm = 6371.0;
  double rad(double deg) => deg * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * earthRadiusKm * math.asin(math.min(1, math.sqrt(a)));
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

bool isValidCoordinate(double lat, double lon) =>
    lat.isFinite &&
    lon.isFinite &&
    lat >= -90 &&
    lat <= 90 &&
    lon >= -180 &&
    lon <= 180;
