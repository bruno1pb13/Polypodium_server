import 'event_model.dart';

abstract interface class ISyncRepository {
  Future<({List<int> accepted, List<ConflictResult> conflicts})> pushEvents(
    String userId,
    String deviceId,
    List<PushEvent> events,
  );
  Future<List<SyncEvent>> pullEvents(
    String userId,
    String deviceId,
    int since,
    int limit,
  );
  Future<void> ackCursor(String deviceId, int cursor);
  Future<Map<String, dynamic>> getStatus(String userId, String deviceId);
}
