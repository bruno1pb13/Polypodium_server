import 'dart:convert';

import '../admin/i_settings_repository.dart';
import 'watering_advice.dart';

/// One tunable of [WateringRules] that admins may change: its JSON name,
/// allowed range and how to read it from / write it to the rules.
class _Field {
  const _Field(this.name, this.min, this.max, this.read,
      {this.integer = false});

  final String name;
  final num min;
  final num max;
  final num Function(WateringRules) read;
  final bool integer;
}

final _fields = [
  _Field('minRainMm', 0, 50, (r) => r.minRainMm),
  _Field('rainEfficiency', 0, 1, (r) => r.rainEfficiency),
  _Field('maxPostponeDays', 0, 30, (r) => r.maxPostponeDays, integer: true),
  _Field('maxAdvanceDays', 0, 30, (r) => r.maxAdvanceDays, integer: true),
  _Field('minDemand', 0.1, 1, (r) => r.minDemand),
  _Field('maxDemand', 1, 5, (r) => r.maxDemand),
];

/// Thrown by [WateringSettings.patch] for a body it can't apply.
class WateringSettingsError implements Exception {
  const WateringSettingsError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Server-wide settings of the weather-adjusted watering: whether the
/// server computes it at all and the [WateringRules] it uses.
///
/// Only the values an admin changed are stored ([overrides]), so a field
/// left alone follows the built-in default even if a later version tunes
/// it.
class WateringSettings {
  const WateringSettings({this.enabled = true, this.overrides = const {}});

  /// Off: `GET /weather/watering` answers 404 `watering_disabled` and the
  /// app stops shifting schedules.
  final bool enabled;

  /// Changed tunables by JSON name (see [_fields]).
  final Map<String, num> overrides;

  static const defaults = WateringRules();

  WateringRules get rules {
    num v(String name, num fallback) => overrides[name] ?? fallback;
    return WateringRules(
      minRainMm: v('minRainMm', defaults.minRainMm).toDouble(),
      rainEfficiency: v('rainEfficiency', defaults.rainEfficiency).toDouble(),
      maxPostponeDays: v('maxPostponeDays', defaults.maxPostponeDays).toInt(),
      maxAdvanceDays: v('maxAdvanceDays', defaults.maxAdvanceDays).toInt(),
      minDemand: v('minDemand', defaults.minDemand).toDouble(),
      maxDemand: v('maxDemand', defaults.maxDemand).toDouble(),
      fallbackEt0: defaults.fallbackEt0,
    );
  }

  /// The admin API body: the effective values, plus the defaults and the
  /// allowed ranges so a client can offer a reset and bound its inputs.
  Map<String, Object?> toJson() {
    final effective = rules;
    return {
      'enabled': enabled,
      for (final f in _fields) f.name: f.read(effective),
      'defaults': {for (final f in _fields) f.name: f.read(defaults)},
      'limits': {
        for (final f in _fields) f.name: {'min': f.min, 'max': f.max}
      },
    };
  }

  /// Applies an admin's PATCH: any subset of `enabled` and the tunables; a
  /// tunable set to null goes back to its default.
  WateringSettings patch(Map<String, dynamic> body) {
    final known = {'enabled', for (final f in _fields) f.name};
    final unknown = body.keys.where((k) => !known.contains(k)).toList();
    if (unknown.isNotEmpty) {
      throw WateringSettingsError('unknown field: ${unknown.first}');
    }
    if (body.isEmpty) {
      throw const WateringSettingsError('nothing to change');
    }
    final enabled = body['enabled'];
    if (body.containsKey('enabled') && enabled is! bool) {
      throw const WateringSettingsError('enabled must be a boolean');
    }
    final next = {...overrides};
    for (final f in _fields) {
      if (!body.containsKey(f.name)) continue;
      final value = body[f.name];
      if (value == null) {
        next.remove(f.name);
        continue;
      }
      if (value is! num ||
          (f.integer && value != value.roundToDouble()) ||
          value < f.min ||
          value > f.max) {
        throw WateringSettingsError('${f.name} must be '
            '${f.integer ? 'a whole number' : 'a number'} '
            'from ${f.min} to ${f.max}');
      }
      final normalized = f.integer ? value.toInt() : value;
      if (normalized == f.read(defaults)) {
        next.remove(f.name);
      } else {
        next[f.name] = normalized;
      }
    }
    return WateringSettings(
      enabled: enabled is bool ? enabled : this.enabled,
      overrides: next,
    );
  }

  static Future<WateringSettings> load(ISettingsRepository settings) async {
    final raw = await settings.getString(settingWatering);
    if (raw == null) return const WateringSettings();
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final stored = json['overrides'] as Map? ?? const {};
      return WateringSettings(
        enabled: json['enabled'] as bool? ?? true,
        overrides: {
          // Ignores what a newer or older version stored that this one
          // doesn't know or allow.
          for (final f in _fields)
            if (stored[f.name] case final num v when v >= f.min && v <= f.max)
              f.name: f.integer ? v.toInt() : v,
        },
      );
    } on Object {
      return const WateringSettings();
    }
  }

  Future<void> save(ISettingsRepository settings) => settings.setString(
      settingWatering,
      jsonEncode({'enabled': enabled, 'overrides': overrides}));
}
