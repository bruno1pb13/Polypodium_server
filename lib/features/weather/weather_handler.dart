import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'weather_models.dart';
import 'weather_repository.dart';
import 'weather_service.dart';

class WeatherHandler {
  const WeatherHandler(this._service, this._repo);
  final WeatherService _service;
  final WeatherRepository _repo;

  /// `GET /weather/locations/<id>?days=&months=` — the forecast for one of
  /// the garden's locations: hourly detail for the retained hours, daily
  /// rows from `days` ago (default 7) through the forecast, and the last
  /// `months` monthly summaries (default none).
  ///
  /// Regions are shared across gardens, so their center -- possibly another
  /// account's location -- is never part of the response.
  Future<Response> forLocation(Request request, String id) async {
    if (!await _service.isEnabled()) {
      return _error(404, 'weather_disabled', 'weather is disabled');
    }
    final gardenId = request.context['gardenId'] as String;

    final location = await _repo.locationInGarden(gardenId, id);
    if (!location.found) {
      return _error(404, 'location_not_found', 'location not found');
    }
    final lat = location.latitude;
    final lon = location.longitude;
    if (lat == null || lon == null || !isValidCoordinate(lat, lon)) {
      return _error(404, 'no_coordinates', 'location has no coordinates');
    }

    final region = await _service.regionFor(lat, lon);
    if (region == null || region.lastFetchedAt == null) {
      return _error(404, 'weather_pending',
          'no forecast for this location yet; try again later');
    }

    final params = request.url.queryParameters;
    final days = (int.tryParse(params['days'] ?? '') ?? 7)
        .clamp(0, _service.options.dailyRetentionDays + 31);
    final months = (int.tryParse(params['months'] ?? '') ?? 0).clamp(0, 600);

    return _json(200, {
      'locationId': id,
      'timezone': region.timezone,
      'elevation': region.elevation,
      'fetchedAt': region.lastFetchedAt!.toUtc().toIso8601String(),
      'hourly': await _repo.hourly(region.id),
      'daily': await _repo.daily(region.id, days),
      'monthly': await _repo.monthly(region.id, months),
    });
  }
}

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

Response _error(int status, String code, String message) =>
    _json(status, {'error': message, 'code': code});
