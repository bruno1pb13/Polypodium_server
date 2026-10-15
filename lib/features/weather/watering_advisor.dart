import 'dart:math' as math;

import '../mcp/garden_store.dart';
import 'watering_advice.dart';
import 'weather_models.dart';
import 'weather_repository.dart';
import 'weather_service.dart';

/// Days of history the "typical day" ET0 is averaged over.
const _baselineDays = 30;

/// Applies [adviseWatering] to every plant of a garden that the weather can
/// say something about: active, with a watering interval, watered at least
/// once, and in a location whose region has a forecast.
///
/// Past days use the stored observations. Days from today on use the
/// latest snapshot, with forecast rain weighted by its probability and
/// capped by what the previous day's snapshot said for the same date, so a
/// rain that only the newest forecast shows doesn't postpone anything yet.
class WateringAdvisor {
  const WateringAdvisor(this._service, this._repo, this._store);

  final WeatherService _service;
  final WeatherRepository _repo;
  final IGardenStore _store;

  Future<List<Map<String, Object?>>> forGarden(String gardenId,
      {WateringRules rules = const WateringRules()}) async {
    final plants = await _store.list(gardenId, 'plant');
    final species = {
      for (final s in await _store.list(gardenId, 'species')) s.id: s.payload
    };
    final locations = {
      for (final l in await _store.list(gardenId, 'location')) l.id: l.payload
    };
    final lastEntries = await _store.lastEntryDates(gardenId, 'irrigation');

    final regionOfLocation = <String, WeatherRegion?>{};
    final byRegion = <String, List<_Candidate>>{};
    final regions = <String, WeatherRegion>{};
    for (final plant in plants) {
      final p = plant.payload;
      final status = p['status'];
      if (status != null && status != 'active') continue;
      final frequency = (p['irrigationFrequencyDays'] ??
          species[p['speciesId']]?['defaultIrrigationFrequencyDays']);
      if (frequency is! num || frequency < 1) continue;
      final last = _latest(p['lastIrrigatedAt'] as String?, lastEntries[plant.id]);
      if (last == null) continue;
      final locationId = p['locationId'];
      final location = locations[locationId];
      if (locationId is! String || location == null) continue;

      final region = regionOfLocation.containsKey(locationId)
          ? regionOfLocation[locationId]
          : regionOfLocation[locationId] = await _regionOf(location);
      if (region == null) continue;
      regions[region.id] = region;
      byRegion.putIfAbsent(region.id, () => []).add(_Candidate(
            plantId: plant.id,
            locationId: locationId,
            lastWateredAt: last,
            frequencyDays: frequency.toInt(),
            exposedToRain: location['exposedToRain'] == true,
          ));
    }

    final advice = <Map<String, Object?>>[];
    for (final MapEntry(key: regionId, value: candidates) in byRegion.entries) {
      final clock = await _repo.regionClock(regionId);
      final lastDates = {
        for (final c in candidates)
          c: _localDate(c.lastWateredAt, clock.utcOffset)
      };
      final from = lastDates.values.reduce((a, b) => a.isBefore(b) ? a : b);
      final weather = await _regionWeather(regionId, from, clock.today);
      for (final c in candidates) {
        final result = adviseWatering(
          lastWateredOn: lastDates[c]!,
          frequencyDays: c.frequencyDays,
          exposedToRain: c.exposedToRain,
          today: clock.today,
          days: weather.days,
          baselineEt0: weather.baselineEt0,
          rules: rules,
        );
        advice.add({
          'plantId': c.plantId,
          'locationId': c.locationId,
          'lastWateredAt': c.lastWateredAt,
          'frequencyDays': c.frequencyDays,
          'exposedToRain': c.exposedToRain,
          'dueDate': dateKey(result.dueDate),
          'adjustedDueDate': dateKey(result.adjustedDueDate),
          'shiftDays': result.shiftDays,
          'reason': result.reason.name,
          'rainMm': (result.rainMm * 10).roundToDouble() / 10,
          'forecastFetchedAt':
              regions[regionId]!.lastFetchedAt!.toUtc().toIso8601String(),
        });
      }
    }
    advice.sort((a, b) =>
        (a['plantId'] as String).compareTo(b['plantId'] as String));
    return advice;
  }

  Future<WeatherRegion?> _regionOf(Map<String, dynamic> location) async {
    final lat = location['latitude'];
    final lon = location['longitude'];
    if (lat is! num || lon is! num) return null;
    if (!isValidCoordinate(lat.toDouble(), lon.toDouble())) return null;
    final region = await _service.regionFor(lat.toDouble(), lon.toDouble());
    return region?.lastFetchedAt == null ? null : region;
  }

  Future<({Map<String, WeatherDay> days, double? baselineEt0})> _regionWeather(
      String regionId, DateTime from, DateTime today) async {
    final todayKey = dateKey(today);
    final days = <String, WeatherDay>{
      for (final d in await _repo.dailyBetween(regionId, dateKey(from), todayKey))
        d.date: WeatherDay(rainMm: d.precipitationSum, et0: d.et0),
    };

    final snapshots = await _repo.snapshots(regionId);
    final List<DailyWeather> forecast;
    Map<String, DailyWeather> previous = const {};
    if (snapshots.isEmpty) {
      // Data fetched before snapshots existed: the latest forecast alone.
      forecast = await _repo.dailyBetween(regionId, todayKey, '9999-12-31');
    } else {
      final latest = snapshots.first;
      forecast = latest.daily;
      for (final s in snapshots.skip(1)) {
        if (s.issuedOn.compareTo(latest.issuedOn) < 0) {
          previous = {for (final d in s.daily) d.date: d};
          break;
        }
      }
    }
    for (final d in forecast) {
      if (d.date.compareTo(todayKey) < 0) continue;
      var rain = _likelyRain(d);
      final before = previous[d.date];
      if (rain != null && before != null) {
        rain = math.min(rain, _likelyRain(before) ?? 0);
      }
      days[d.date] = WeatherDay(rainMm: rain, et0: d.et0);
    }

    var baseline = await _repo.averageEt0(regionId, todayKey, _baselineDays);
    if (baseline == null) {
      final known = [for (final d in days.values) if (d.et0 != null) d.et0!];
      if (known.isNotEmpty) {
        baseline = known.reduce((a, b) => a + b) / known.length;
      }
    }
    return (days: days, baselineEt0: baseline);
  }
}

class _Candidate {
  const _Candidate({
    required this.plantId,
    required this.locationId,
    required this.lastWateredAt,
    required this.frequencyDays,
    required this.exposedToRain,
  });

  final String plantId;
  final String locationId;
  final String lastWateredAt;
  final int frequencyDays;
  final bool exposedToRain;
}

/// Forecast rain weighted by its probability (mm).
double? _likelyRain(DailyWeather d) {
  final rain = d.precipitationSum;
  if (rain == null) return null;
  return rain * (d.precipitationProbabilityMax ?? 100).clamp(0, 100) / 100;
}

/// The region-local calendar date of an ISO timestamp. The app writes local
/// wall-clock times without an offset, taken as written; a UTC or offset
/// time (written here) is shifted by the region's offset.
DateTime _localDate(String iso, Duration utcOffset) {
  var d = DateTime.parse(iso);
  if (d.isUtc) d = d.add(utcOffset);
  return DateTime.utc(d.year, d.month, d.day);
}

String? _latest(String? a, String? b) {
  final da = a == null ? null : DateTime.tryParse(a);
  final db = b == null ? null : DateTime.tryParse(b);
  if (da == null) return db == null ? null : b;
  if (db == null) return a;
  return db.isAfter(da) ? b : a;
}
