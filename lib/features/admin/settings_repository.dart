import 'package:postgres/postgres.dart';

import 'i_settings_repository.dart';

class SettingsRepository implements ISettingsRepository {
  const SettingsRepository(this._db);
  final Pool _db;

  @override
  Future<bool> getBool(String key, {required bool defaultValue}) async {
    final value = await getString(key);
    return value == null ? defaultValue : value == 'true';
  }

  @override
  Future<void> setBool(String key, bool value) =>
      setString(key, value.toString());

  @override
  Future<String?> getString(String key) async {
    final result = await _db.execute(
      Sql.named('SELECT value FROM server_settings WHERE key = @key'),
      parameters: {'key': key},
    );
    return result.isEmpty ? null : result.first[0] as String;
  }

  @override
  Future<void> setString(String key, String value) async {
    await _db.execute(
      Sql.named('''
        INSERT INTO server_settings (key, value)
        VALUES (@key, @value)
        ON CONFLICT (key) DO UPDATE SET value = @value, updated_at = NOW()
      '''),
      parameters: {'key': key, 'value': value},
    );
  }
}
