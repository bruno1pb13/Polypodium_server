import 'package:polypodium_core/polypodium_core.dart';

/// Entity types the server stores and serves; changes of any other type are
/// dropped on receive.
const syncEntityTypes = {
  'species',
  'plant',
  'entry',
  'entry_photo',
  'location',
  'soil',
  'bed',
  'defensivo',
  'reminder',
};

abstract interface class ISyncRepository {
  /// Serves this garden's changes with `rev > since`, across all entity
  /// types, merged into a single rev-ordered stream (mirrors the same
  /// role a peer's `serveChanges` would play in a future direct-peer
  /// sync, just scoped to `gardenId` and reachable publicly here).
  ///
  /// Only entries whose `payload.type` is in [entryTypes] are served (null
  /// means a client that didn't declare them: `legacyEntryTypes`), and
  /// only the entity types in [entityTypes] (null means all of them).
  Future<({List<SyncChange> changes, bool hasMore})> serveChanges(
    String gardenId, {
    required int since,
    required int limit,
    Set<String>? entryTypes,
    Set<String>? entityTypes,
  });

  /// Accepts a batch of changes from a device (the client-server
  /// equivalent of a peer initiating `receiveChanges` on us). Applies each
  /// via last-write-wins on `updatedAt` and returns how many rows were
  /// actually mutated. [userId] is recorded as the row's last writer.
  Future<int> receiveChanges(
    String gardenId,
    String userId,
    String deviceId,
    List<SyncChange> changes,
  );

  Future<void> ackCursor(String deviceId, String gardenId, int cursor);
  Future<Map<String, dynamic>> getStatus(String gardenId, String deviceId);
}
