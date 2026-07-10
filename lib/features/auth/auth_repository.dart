import 'package:postgres/postgres.dart';
import 'i_auth_repository.dart';

class AuthRepository implements IAuthRepository {
  const AuthRepository(this._db);
  final Pool _db;

  @override
  Future<int> countUsers() async {
    final result = await _db.execute(Sql.named('SELECT COUNT(*) FROM users'));
    return (result.first[0] as num).toInt();
  }

  @override
  Future<int> countActiveAdmins() async {
    final result = await _db.execute(Sql.named(
        "SELECT COUNT(*) FROM users WHERE role = 'admin' AND disabled = FALSE"));
    return (result.first[0] as num).toInt();
  }

  @override
  Future<Map<String, dynamic>?> findUserByEmail(String email) async {
    final result = await _db.execute(
      Sql.named(
          'SELECT id, email, password_hash, role, disabled FROM users WHERE email = @email'),
      parameters: {'email': email},
    );
    if (result.isEmpty) return null;
    final row = result.first;
    return {
      'id': row[0] as String,
      'email': row[1] as String,
      'passwordHash': row[2] as String,
      'role': row[3] as String,
      'disabled': row[4] as bool,
    };
  }

  @override
  Future<Map<String, dynamic>> createUser(
      String id, String email, String passwordHash, String role) async {
    await _db.execute(
      Sql.named('''
        INSERT INTO users (id, email, password_hash, role)
        VALUES (@id, @email, @hash, @role)
      '''),
      parameters: {'id': id, 'email': email, 'hash': passwordHash, 'role': role},
    );
    return {'id': id, 'email': email, 'role': role};
  }

  @override
  Future<Map<String, dynamic>?> getAuthInfo(String userId) async {
    final result = await _db.execute(
      Sql.named('SELECT role, disabled FROM users WHERE id = @id'),
      parameters: {'id': userId},
    );
    if (result.isEmpty) return null;
    final row = result.first;
    return {'role': row[0] as String, 'disabled': row[1] as bool};
  }

  @override
  Future<List<Map<String, dynamic>>> listUsers() async {
    final result = await _db.execute(Sql.named(
        'SELECT id, email, role, disabled, created_at FROM users ORDER BY created_at'));
    return [
      for (final row in result)
        {
          'id': row[0] as String,
          'email': row[1] as String,
          'role': row[2] as String,
          'disabled': row[3] as bool,
          'createdAt': (row[4] as DateTime).toIso8601String(),
        }
    ];
  }

  @override
  Future<void> setRole(String userId, String role) async {
    await _db.execute(
      Sql.named('UPDATE users SET role = @role WHERE id = @id'),
      parameters: {'id': userId, 'role': role},
    );
  }

  @override
  Future<void> setDisabled(String userId, bool disabled) async {
    await _db.execute(
      Sql.named('UPDATE users SET disabled = @disabled WHERE id = @id'),
      parameters: {'id': userId, 'disabled': disabled},
    );
  }

  @override
  Future<void> upsertDevice(
      String deviceId, String userId, String? deviceName) async {
    await _db.execute(
      Sql.named('''
        INSERT INTO devices (id, user_id, name)
        VALUES (@id, @userId, @name)
        ON CONFLICT (id) DO NOTHING
      '''),
      parameters: {'id': deviceId, 'userId': userId, 'name': deviceName},
    );
    await _db.execute(
      Sql.named('''
        INSERT INTO device_cursors (device_id, last_pulled_cursor)
        VALUES (@deviceId, 0)
        ON CONFLICT (device_id) DO NOTHING
      '''),
      parameters: {'deviceId': deviceId},
    );
  }

  @override
  Future<Map<String, dynamic>?> findDeviceById(String deviceId) async {
    final result = await _db.execute(
      Sql.named('SELECT id, user_id FROM devices WHERE id = @id'),
      parameters: {'id': deviceId},
    );
    if (result.isEmpty) return null;
    final row = result.first;
    return {'id': row[0] as String, 'userId': row[1] as String};
  }

  @override
  Future<void> touchDevice(String deviceId) async {
    await _db.execute(
      Sql.named('UPDATE devices SET last_seen_at = NOW() WHERE id = @id'),
      parameters: {'id': deviceId},
    );
  }
}
