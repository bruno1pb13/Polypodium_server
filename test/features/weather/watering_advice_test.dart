import 'package:polypodium_server/features/weather/watering_advice.dart';
import 'package:test/test.dart';

final _last = DateTime.utc(2026, 10, 10);

String _d(int daysAfterLast) =>
    dateKey(_last.add(Duration(days: daysAfterLast)));

WateringAdvice _advise({
  int frequency = 4,
  bool exposed = true,
  int todayAfterLast = 1,
  Map<String, WeatherDay> days = const {},
  double? baseline = 4,
}) =>
    adviseWatering(
      lastWateredOn: _last,
      frequencyDays: frequency,
      exposedToRain: exposed,
      today: _last.add(Duration(days: todayAfterLast)),
      days: days,
      baselineEt0: baseline,
    );

void main() {
  test('typical days keep the schedule', () {
    final a = _advise(days: {
      for (var k = 1; k <= 8; k++) _d(k): const WeatherDay(et0: 4),
    });
    expect(a.dueDate, DateTime.utc(2026, 10, 14));
    expect(a.shiftDays, 0);
    expect(a.reason, WateringReason.none);
  });

  test('no weather at all keeps the schedule', () {
    final a = _advise(baseline: null);
    expect(a.shiftDays, 0);
  });

  test('rain shortly before the due date postpones an exposed plant', () {
    final a = _advise(days: {
      for (var k = 1; k <= 10; k++) _d(k): const WeatherDay(et0: 4),
      _d(3): const WeatherDay(rainMm: 12, et0: 4),
    });
    // 12 mm * 0.7 / 4 mm = 2.1 typical days of water back.
    expect(a.shiftDays, 2);
    expect(a.reason, WateringReason.rain);
    expect(a.rainMm, 12);
  });

  test('rain does nothing for a plant that is not exposed', () {
    final a = _advise(exposed: false, days: {
      for (var k = 1; k <= 10; k++) _d(k): const WeatherDay(et0: 4),
      _d(3): const WeatherDay(rainMm: 12, et0: 4),
    });
    expect(a.shiftDays, 0);
  });

  test('rain right after watering is mostly wasted', () {
    final a = _advise(days: {
      for (var k = 1; k <= 10; k++) _d(k): const WeatherDay(et0: 4),
      _d(1): const WeatherDay(rainMm: 30, et0: 4),
    });
    // Only the first day's use can be given back.
    expect(a.shiftDays, 1);
  });

  test('drizzle below the minimum is ignored', () {
    final a = _advise(days: {
      for (var k = 1; k <= 10; k++) _d(k): const WeatherDay(rainMm: 1.5, et0: 4),
    });
    expect(a.shiftDays, 0);
  });

  test('postponing is capped by the interval and the rule', () {
    final days = {
      for (var k = 1; k <= 30; k++) _d(k): const WeatherDay(rainMm: 40, et0: 4),
    };
    expect(_advise(frequency: 3, days: days).shiftDays, 3);
    expect(_advise(frequency: 14, days: days).shiftDays, 7);
  });

  test('hot dry days bring the watering forward, at most half the interval',
      () {
    final hot = {
      for (var k = 1; k <= 10; k++) _d(k): const WeatherDay(et0: 8),
    };
    // Twice the typical use: 6 days' worth gone in 3.
    expect(_advise(frequency: 6, days: hot).shiftDays, -2);
    expect(_advise(frequency: 6, days: hot).reason, WateringReason.heat);
    expect(_advise(frequency: 2, days: hot).shiftDays, -1);
    expect(_advise(frequency: 1, days: hot).shiftDays, 0);
  });

  test('bringing forward never makes a watering overdue', () {
    final hot = {
      for (var k = 1; k <= 10; k++) _d(k): const WeatherDay(et0: 8),
    };
    // Due on day 6, the heat says day 4, but today is already day 5.
    final a = _advise(frequency: 6, todayAfterLast: 5, days: hot);
    expect(a.adjustedDueDate, _last.add(const Duration(days: 5)));
    expect(a.shiftDays, -1);
  });

  test('cool days push it back without rain', () {
    final cool = {
      for (var k = 1; k <= 10; k++) _d(k): const WeatherDay(et0: 2),
    };
    // Half the typical use: 4 days' worth lasts 7 (to the nearest day).
    final a = _advise(frequency: 4, days: cool);
    expect(a.shiftDays, 3);
    expect(a.reason, WateringReason.cool);
    expect(a.rainMm, 0);
  });

  test('an overdue plant can still be postponed by rain that fell', () {
    final a = _advise(frequency: 2, todayAfterLast: 5, days: {
      for (var k = 1; k <= 6; k++) _d(k): const WeatherDay(et0: 4),
      _d(2): const WeatherDay(rainMm: 20, et0: 4),
    });
    expect(a.shiftDays, 2);
  });
}
