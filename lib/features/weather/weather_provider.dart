import 'dart:convert';
import 'dart:io';

import 'package:polypodium_core/weather.dart';

export 'package:polypodium_core/weather.dart' show parseOpenMeteo;

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

  @override
  Future<WeatherForecast> fetch(
    double latitude,
    double longitude, {
    required int pastDays,
    required int forecastDays,
  }) async {
    final uri = Uri.parse(_baseUrl).replace(
        queryParameters: openMeteoQuery(latitude, longitude,
            pastDays: pastDays, forecastDays: forecastDays));

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
