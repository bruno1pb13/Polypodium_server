abstract interface class IAuthRepository {
  Future<int> countUsers();
  Future<int> countActiveAdmins();
  Future<Map<String, dynamic>?> findUserByEmail(String email);
  Future<Map<String, dynamic>> createUser(
      String id, String email, String passwordHash, String role);

  /// Atomically creates the bootstrap admin, but only if the server has no
  /// users yet. Returns true if this call created it, false if another
  /// concurrent request won the race. Serialized with an advisory lock so two
  /// simultaneous first-registrations can never both succeed.
  Future<bool> createFirstAdmin(String id, String email, String passwordHash);
  Future<Map<String, dynamic>?> getAuthInfo(String userId);
  Future<List<Map<String, dynamic>>> listUsers();
  Future<void> setRole(String userId, String role);
  Future<void> setDisabled(String userId, bool disabled);
  Future<void> upsertDevice(
      String deviceId, String userId, String? deviceName);
  Future<Map<String, dynamic>?> findDeviceById(String deviceId);
  Future<void> touchDevice(String deviceId);
}
