import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'watering_advisor.dart';
import 'weather_models.dart';
import 'weather_repository.dart';
import 'weather_service.dart';

/// A forecast body, or the code and message of why there is none.
typedef ForecastResult = ({
  Map<String, Object?>? body,
  ({String code, String message})? error,
});

class WeatherHandler {
  const WeatherHandler(this._service, this._repo, this._advisor);
  final WeatherService _service;
  final WeatherRepository _repo;
  final WateringAdvisor _advisor;

  /// `GET /weather/locations/<id>?days=&months=` — the forecast for one of
  /// the garden's locations: hourly detail for the retained hours, daily
  /// rows from `days` ago (default 7) through the forecast, and the last
  /// `months` monthly summaries (default none).
  ///
  /// Regions are shared across gardens, so their center -- possibly another
  /// account's location -- is never part of the response.
  Future<Response> forLocation(Request request, String id) async {
    final params = request.url.queryParameters;
    final result = await forecast(
      request.context['gardenId'] as String,
      id,
      days: int.tryParse(params['days'] ?? '') ?? 7,
      months: int.tryParse(params['months'] ?? '') ?? 0,
    );
    final error = result.error;
    if (error != null) return _error(404, error.code, error.message);
    return _json(200, result.body!);
  }

  /// The body of [forLocation], or why there is none (always a 404 there).
  /// Shared with the MCP `get_weather` tool.
  Future<ForecastResult> forecast(
    String gardenId,
    String id, {
    int days = 7,
    int months = 0,
  }) async {
    ForecastResult fail(String code, String message) =>
        (body: null, error: (code: code, message: message));

    if (!await _service.isEnabled()) {
      return fail('weather_disabled', 'weather is disabled');
    }

    final location = await _repo.locationInGarden(gardenId, id);
    if (!location.found) {
      return fail('location_not_found', 'location not found');
    }
    final lat = location.latitude;
    final lon = location.longitude;
    if (lat == null || lon == null || !isValidCoordinate(lat, lon)) {
      return fail('no_coordinates', 'location has no coordinates');
    }

    final region = await _service.regionFor(lat, lon);
    if (region == null || region.lastFetchedAt == null) {
      return fail(
          'weather_pending', 'no forecast for this location yet; try again later');
    }

    final clampedDays = days.clamp(0, _service.options.dailyRetentionDays + 31);
    final clampedMonths = months.clamp(0, 600);

    return (
      body: <String, Object?>{
        'locationId': id,
        'timezone': region.timezone,
        'elevation': region.elevation,
        'fetchedAt': region.lastFetchedAt!.toUtc().toIso8601String(),
        'hourly': await _repo.hourly(region.id),
        'daily': await _repo.daily(region.id, clampedDays),
        'monthly': await _repo.monthly(region.id, clampedMonths),
      },
      error: null,
    );
  }

  /// `GET /weather/watering` — how the weather moves each plant's next
  /// watering (see [WateringAdvisor]).
  Future<Response> watering(Request request) async {
    final result = await wateringAdvice(request.context['gardenId'] as String);
    final error = result.error;
    if (error != null) return _error(404, error.code, error.message);
    return _json(200, result.body!);
  }

  /// The body of [watering], or why there is none. Shared with the MCP
  /// `watering_advice` tool.
  Future<ForecastResult> wateringAdvice(String gardenId) async {
    if (!await _service.isEnabled()) {
      return (
        body: null,
        error: (code: 'weather_disabled', message: 'weather is disabled'),
      );
    }
    return (
      body: <String, Object?>{
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'plants': await _advisor.forGarden(gardenId),
      },
      error: null,
    );
  }
}

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

Response _error(int status, String code, String message) =>
    _json(status, {'error': message, 'code': code});
