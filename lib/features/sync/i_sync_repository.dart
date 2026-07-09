import 'mat_change_model.dart';

abstract interface class ISyncRepository {
  /// Serves this user's changes with `rev > since`, across all entity
  /// types, merged into a single rev-ordered stream (mirrors the same
  /// role a peer's `serveChanges` would play in a future direct-peer
  /// sync, just scoped to `userId` and reachable publicly here).
  Future<({List<MatChange> changes, bool hasMore})> serveChanges(
    String userId, {
    required int since,
    required int limit,
  });

  /// Accepts a batch of changes from a device (the client-server
  /// equivalent of a peer initiating `receiveChanges` on us). Applies each
  /// via last-write-wins on `updatedAt` and returns how many rows were
  /// actually mutated.
  Future<int> receiveChanges(
    String userId,
    String deviceId,
    List<MatChange> changes,
  );

  Future<void> ackCursor(String deviceId, int cursor);
  Future<Map<String, dynamic>> getStatus(String userId, String deviceId);
}
