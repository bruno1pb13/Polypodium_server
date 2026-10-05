import 'package:polypodium_core/polypodium_core.dart';

abstract interface class ISyncRepository {
  /// Serves this user's changes with `rev > since`, across all entity
  /// types, merged into a single rev-ordered stream (mirrors the same
  /// role a peer's `serveChanges` would play in a future direct-peer
  /// sync, just scoped to `userId` and reachable publicly here).
  ///
  /// Only entries whose `payload.type` is in [entryTypes] are served (null
  /// means a client that didn't declare them: `legacyEntryTypes`).
  Future<({List<SyncChange> changes, bool hasMore})> serveChanges(
    String userId, {
    required int since,
    required int limit,
    Set<String>? entryTypes,
  });

  /// Accepts a batch of changes from a device (the client-server
  /// equivalent of a peer initiating `receiveChanges` on us). Applies each
  /// via last-write-wins on `updatedAt` and returns how many rows were
  /// actually mutated.
  Future<int> receiveChanges(
    String userId,
    String deviceId,
    List<SyncChange> changes,
  );

  Future<void> ackCursor(String deviceId, int cursor);
  Future<Map<String, dynamic>> getStatus(String userId, String deviceId);
}
