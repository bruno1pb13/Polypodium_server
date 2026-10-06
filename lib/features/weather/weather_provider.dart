import 'dart:convert';
import 'dart:io';

import 'weather_models.dart';

/// Source of forecasts. Injected so tests never hit the network.
abstract interface class IWeatherProvider {
  Future<WeatherForecast> fetch(
    double latitude,
    double longitude, {
    required int pastDays,
    required int forecastDays,
  });
}

class WeatherProviderException implements Exception {
  const WeatherProviderException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Open-Meteo (https://open-meteo.com): free, no API key. Only the region
/// center's coordinates leave the server.
class OpenMeteoProvider implements IWeatherProvider {
  OpenMeteoProvider(this._baseUrl, {HttpClient? client})
      : _client = client ??
            (HttpClient()..connectionTimeout = const Duration(seconds: 15));

  final String _baseUrl;
  final HttpClient _client;

  static const _hourly = [
    'temperature_2m',
    'relative_humidity_2m',
    'precipitation',
    'precipitation_probability',
    'weather_code',
    'wind_speed_10m',
  ];
  static const _daily = [
    'weather_code',
    'temperature_2m_max',
    'temperature_2m_min',
    'precipitation_sum',
    'precipitation_probability_max',
    'wind_speed_10m_max',
    'et0_fao_evapotranspiration',
  ];

  @override
  Future<WeatherForecast> fetch(
    double latitude,
    double longitude, {
    required int pastDays,
    required int forecastDays,
  }) async {
    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'latitude': latitude.toStringAsFixed(4),
      'longitude': longitude.toStringAsFixed(4),
      'timezone': 'auto',
      'past_days': '$pastDays',
      'forecast_days': '$forecastDays',
      'hourly': _hourly.join(','),
      'daily': _daily.join(','),
    });

    final String body;
    final int status;
    try {
      final request = await _client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'polypodium-server');
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      status = response.statusCode;
      body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
    } on Exception catch (e) {
      throw WeatherProviderException('request failed: $e');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw WeatherProviderException('HTTP $status: invalid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw WeatherProviderException('HTTP $status: unexpected response');
    }
    if (status != 200) {
      throw WeatherProviderException(
          'HTTP $status: ${decoded['reason'] ?? 'request rejected'}');
    }
    return parseOpenMeteo(decoded);
  }
}

/// Converts Open-Meteo's column-oriented response into rows.
WeatherForecast parseOpenMeteo(Map<String, dynamic> json) {
  List<Object?> col(Map<String, dynamic>? block, String key) =>
      (block?[key] as List?) ?? const [];
  double? num_(List<Object?> list, int i) =>
      i < list.length ? (list[i] as num?)?.toDouble() : null;
  int? int_(List<Object?> list, int i) =>
      i < list.length ? (list[i] as num?)?.toInt() : null;

  final hourly = json['hourly'] as Map<String, dynamic>?;
  final hTime = col(hourly, 'time');
  final hTemp = col(hourly, 'temperature_2m');
  final hHum = col(hourly, 'relative_humidity_2m');
  final hPrec = col(hourly, 'precipitation');
  final hProb = col(hourly, 'precipitation_probability');
  final hCode = col(hourly, 'weather_code');
  final hWind = col(hourly, 'wind_speed_10m');

  final daily = json['daily'] as Map<String, dynamic>?;
  final dTime = col(daily, 'time');
  final dCode = col(daily, 'weather_code');
  final dMax = col(daily, 'temperature_2m_max');
  final dMin = col(daily, 'temperature_2m_min');
  final dPrec = col(daily, 'precipitation_sum');
  final dProb = col(daily, 'precipitation_probability_max');
  final dWind = col(daily, 'wind_speed_10m_max');
  final dEt0 = col(daily, 'et0_fao_evapotranspiration');

  return WeatherForecast(
    timezone: json['timezone'] as String?,
    elevation: (json['elevation'] as num?)?.toDouble(),
    hourly: [
      for (var i = 0; i < hTime.length; i++)
        if (hTime[i] is String)
          HourlyWeather(
            time: hTime[i] as String,
            temperature: num_(hTemp, i),
            humidity: num_(hHum, i),
            precipitation: num_(hPrec, i),
            precipitationProbability: num_(hProb, i),
            weatherCode: int_(hCode, i),
            windSpeed: num_(hWind, i),
          ),
    ],
    daily: [
      for (var i = 0; i < dTime.length; i++)
        if (dTime[i] is String)
          DailyWeather(
            date: dTime[i] as String,
            weatherCode: int_(dCode, i),
            temperatureMax: num_(dMax, i),
            temperatureMin: num_(dMin, i),
            precipitationSum: num_(dPrec, i),
            precipitationProbabilityMax: num_(dProb, i),
            windSpeedMax: num_(dWind, i),
            et0: num_(dEt0, i),
          ),
    ],
  );
}
