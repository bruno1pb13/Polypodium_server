abstract interface class IAuthRepository {
  Future<int> countUsers();
  Future<int> countActiveAdmins();
  Future<Map<String, dynamic>?> findUserByEmail(String email);
  Future<Map<String, dynamic>> createUser(
      String id, String email, String passwordHash, String role);
  Future<Map<String, dynamic>?> getAuthInfo(String userId);
  Future<List<Map<String, dynamic>>> listUsers();
  Future<void> setRole(String userId, String role);
  Future<void> setDisabled(String userId, bool disabled);
  Future<void> upsertDevice(
      String deviceId, String userId, String? deviceName);
  Future<Map<String, dynamic>?> findDeviceById(String deviceId);
  Future<void> touchDevice(String deviceId);
}
