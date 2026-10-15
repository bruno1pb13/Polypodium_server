import 'package:polypodium_server/features/admin/i_settings_repository.dart';
import 'package:polypodium_server/features/weather/watering_settings.dart';
import 'package:test/test.dart';

class _MemorySettings implements ISettingsRepository {
  final values = <String, String>{};

  @override
  Future<bool> getBool(String key, {required bool defaultValue}) async =>
      values[key] == null ? defaultValue : values[key] == 'true';

  @override
  Future<void> setBool(String key, bool value) async =>
      values[key] = value.toString();

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

void main() {
  test('starts enabled with the built-in rules', () async {
    final s = await WateringSettings.load(_MemorySettings());
    expect(s.enabled, isTrue);
    expect(s.rules.maxPostponeDays, WateringSettings.defaults.maxPostponeDays);
    expect(s.toJson()['minRainMm'], 2);
  });

  test('a patch changes only what it names and round-trips', () async {
    final repo = _MemorySettings();
    final patched = const WateringSettings().patch({
      'enabled': false,
      'maxAdvanceDays': 0,
      'minDemand': 1,
      'rainEfficiency': 0.7, // the default: not stored
    });
    expect(patched.overrides, {'maxAdvanceDays': 0, 'minDemand': 1});
    await patched.save(repo);

    final loaded = await WateringSettings.load(repo);
    expect(loaded.enabled, isFalse);
    expect(loaded.rules.maxAdvanceDays, 0);
    expect(loaded.rules.minDemand, 1);
    expect(loaded.rules.maxPostponeDays, 7);
  });

  test('null puts a rule back to its default', () {
    final s = const WateringSettings(overrides: {'minRainMm': 5})
        .patch({'minRainMm': null});
    expect(s.overrides, isEmpty);
    expect(s.rules.minRainMm, 2);
  });

  test('rejects unknown fields, wrong types and out-of-range values', () {
    const s = WateringSettings();
    for (final body in [
      <String, dynamic>{},
      {'foo': 1},
      {'enabled': 'yes'},
      {'maxPostponeDays': 1.5},
      {'maxPostponeDays': 31},
      {'rainEfficiency': 1.2},
      {'minDemand': 0},
      {'maxDemand': '2'},
    ]) {
      expect(() => s.patch(body), throwsA(isA<WateringSettingsError>()),
          reason: '$body');
    }
  });

  test('ignores stored values it does not know or allow', () async {
    final repo = _MemorySettings()
      ..values[settingWatering] =
          '{"enabled":true,"overrides":{"maxPostponeDays":99,"x":1,'
              '"minRainMm":4}}';
    final s = await WateringSettings.load(repo);
    expect(s.overrides, {'minRainMm': 4});

    repo.values[settingWatering] = 'not json';
    expect((await WateringSettings.load(repo)).enabled, isTrue);
  });
}
