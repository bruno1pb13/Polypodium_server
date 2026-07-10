import 'package:postgres/postgres.dart';

import 'i_settings_repository.dart';

class SettingsRepository implements ISettingsRepository {
  const SettingsRepository(this._db);
  final Pool _db;

  @override
  Future<bool> getBool(String key, {required bool defaultValue}) async {
    final result = await _db.execute(
      Sql.named('SELECT value FROM server_settings WHERE key = @key'),
      parameters: {'key': key},
    );
    if (result.isEmpty) return defaultValue;
    return result.first[0] as String == 'true';
  }

  @override
  Future<void> setBool(String key, bool value) async {
    await _db.execute(
      Sql.named('''
        INSERT INTO server_settings (key, value)
        VALUES (@key, @value)
        ON CONFLICT (key) DO UPDATE SET value = @value, updated_at = NOW()
      '''),
      parameters: {'key': key, 'value': value.toString()},
    );
  }
}
