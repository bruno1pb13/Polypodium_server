/// Server-wide settings admins can change at runtime (stored in the
/// `server_settings` table), as opposed to boot-time env config in Config.
abstract interface class ISettingsRepository {
  Future<bool> getBool(String key, {required bool defaultValue});
  Future<void> setBool(String key, bool value);
}

/// Whether accounts with role == 'member' may export their data from the
/// client app. Admins are always allowed regardless of these flags.
const settingAllowMemberExport = 'allow_member_export';

/// Whether accounts with role == 'member' may import data into the client.
const settingAllowMemberImport = 'allow_member_import';
