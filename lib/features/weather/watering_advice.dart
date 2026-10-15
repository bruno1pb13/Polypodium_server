import 'dart:math' as math;

/// Tunables of [adviseWatering]. The defaults are deliberately cautious:
/// the advice nudges a schedule the user chose, it doesn't replace it.
class WateringRules {
  const WateringRules({
    this.minRainMm = 2,
    this.rainEfficiency = 0.7,
    this.maxPostponeDays = 7,
    this.maxAdvanceDays = 2,
    this.minDemand = 0.5,
    this.maxDemand = 2,
    this.fallbackEt0 = 3,
  });

  /// Daily rain below this (mm) is ignored: a drizzle barely wets a pot.
  final double minRainMm;

  /// Share of the rain that reaches the roots (pots catch less than open
  /// ground, and part of it runs off).
  final double rainEfficiency;

  /// The most a schedule is pushed back, also never more than the plant's
  /// own interval.
  final int maxPostponeDays;

  /// The most a schedule is brought forward, also never more than half the
  /// plant's interval (a daily plant is never advanced).
  final int maxAdvanceDays;

  /// Bounds on one day's water use relative to a typical day, so a single
  /// odd forecast can't swing the schedule too far.
  final double minDemand;
  final double maxDemand;

  /// Typical daily evapotranspiration (mm) used to convert rain into days
  /// of water when the region has no ET0 history yet.
  final double fallbackEt0;
}

/// One day's weather as the advice sees it: rain already weighted by how
/// likely it is (forecast days), and the reference evapotranspiration.
class WeatherDay {
  const WeatherDay({this.rainMm, this.et0});

  final double? rainMm;

  /// FAO-56 reference evapotranspiration, in mm.
  final double? et0;
}

enum WateringReason {
  /// The weather doesn't change the schedule.
  none,

  /// Rain (fallen since the last watering, or forecast) pushes it back.
  rain,

  /// Cooler, more humid days than usual: the plant uses less water.
  cool,

  /// Hotter, drier days than usual: the plant uses more water.
  heat,
}

class WateringAdvice {
  const WateringAdvice({
    required this.dueDate,
    required this.adjustedDueDate,
    required this.reason,
    required this.rainMm,
  });

  /// When the plant's interval alone says to water.
  final DateTime dueDate;

  /// When to water given the weather.
  final DateTime adjustedDueDate;

  final WateringReason reason;

  /// Rain counted between the last watering and [adjustedDueDate] (mm, as
  /// fallen or forecast, before [WateringRules.rainEfficiency]).
  final double rainMm;

  /// Positive = postponed, negative = brought forward.
  int get shiftDays => _daysBetween(dueDate, adjustedDueDate);
}

/// Where a watering falls given the weather, with a simple water balance.
///
/// The plant's interval is taken as how long a full watering lasts on a
/// typical day, a day whose ET0 is [baselineEt0] (the region's recent
/// average). Each day after [lastWateredOn] the plant uses `et0 /
/// baselineEt0` of a typical day (bounded by [WateringRules.minDemand] and
/// [WateringRules.maxDemand]), and rain on a plant [exposedToRain] gives
/// some of it back, never more than the plant has used since its last
/// watering, so rain right after watering is worth little. The plant is
/// due on the day its use adds up to its interval (to the nearest day).
///
/// [days] maps `YYYY-MM-DD` to the weather of that day; a missing day
/// counts as typical and dry. All dates are calendar dates (time ignored).
/// The result is never earlier than [today] unless the plain schedule
/// already was: bringing a watering forward never makes it overdue.
WateringAdvice adviseWatering({
  required DateTime lastWateredOn,
  required int frequencyDays,
  required bool exposedToRain,
  required DateTime today,
  required Map<String, WeatherDay> days,
  double? baselineEt0,
  WateringRules rules = const WateringRules(),
}) {
  final last = _date(lastWateredOn);
  final todayDate = _date(today);
  final interval = math.max(frequencyDays, 1);
  final due = _addDays(last, interval);
  final maxPostpone = math.min(rules.maxPostponeDays, interval);
  final maxAdvance = math.min(rules.maxAdvanceDays, interval ~/ 2);
  final hasBaseline = baselineEt0 != null && baselineEt0 > 0;
  final typicalEt0 = hasBaseline ? baselineEt0 : rules.fallbackEt0;

  var used = 0.0;
  var rainMm = 0.0;
  DateTime? waterOn;
  for (var k = 1; k <= interval + maxPostpone; k++) {
    final day = _addDays(last, k);
    final w = days[dateKey(day)];
    final et0 = w?.et0;
    final demand = hasBaseline && et0 != null
        ? (et0 / typicalEt0).clamp(rules.minDemand, rules.maxDemand)
        : 1.0;
    used += demand;
    final rain = w?.rainMm;
    if (exposedToRain && rain != null && rain >= rules.minRainMm) {
      used = math.max(0, used - rain * rules.rainEfficiency / typicalEt0);
      rainMm += rain;
    }
    // Due once less than half a typical day's water is left, so a partial
    // day of rain rounds to the nearest day instead of always up.
    if (used >= interval - 0.5) {
      waterOn = day;
      break;
    }
  }

  var shift = waterOn == null ? maxPostpone : _daysBetween(due, waterOn);
  shift = shift.clamp(-maxAdvance, maxPostpone);
  var adjusted = _addDays(due, shift);
  final floor = due.isBefore(todayDate) ? due : todayDate;
  if (adjusted.isBefore(floor)) adjusted = floor;
  shift = _daysBetween(due, adjusted);

  final reason = shift > 0
      ? (rainMm > 0 ? WateringReason.rain : WateringReason.cool)
      : shift < 0
          ? WateringReason.heat
          : WateringReason.none;
  return WateringAdvice(
    dueDate: due,
    adjustedDueDate: adjusted,
    reason: reason,
    rainMm: shift > 0 && reason == WateringReason.rain ? rainMm : 0,
  );
}

/// `YYYY-MM-DD` of a date's calendar fields.
String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

DateTime _date(DateTime d) => DateTime.utc(d.year, d.month, d.day);

DateTime _addDays(DateTime d, int days) =>
    DateTime.utc(d.year, d.month, d.day + days);

int _daysBetween(DateTime from, DateTime to) =>
    _date(to).difference(_date(from)).inDays;
