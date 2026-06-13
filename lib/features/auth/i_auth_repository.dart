abstract interface class IAuthRepository {
  Future<Map<String, dynamic>?> findUserByEmail(String email);
  Future<Map<String, dynamic>> createUser(
      String id, String email, String passwordHash);
  Future<void> upsertDevice(
      String deviceId, String userId, String? deviceName);
  Future<Map<String, dynamic>?> findDeviceById(String deviceId);
  Future<void> touchDevice(String deviceId);
}
