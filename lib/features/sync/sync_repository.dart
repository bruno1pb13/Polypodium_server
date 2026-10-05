import 'dart:convert';

import 'package:polypodium_core/polypodium_core.dart';
import 'package:postgres/postgres.dart';

import 'i_sync_repository.dart';

const _matTable = {
  'species': 'mat_species',
  'plant': 'mat_plants',
  'entry': 'mat_entries',
  'location': 'mat_locations',
  'soil': 'mat_soils',
  'bed': 'mat_beds',
  'defensivo': 'mat_defensivos',
  'reminder': 'mat_reminders',
};

/// Entry types understood by every app release that predates the
/// `X-Polypodium-Entry-Types` header (frozen at v2.7.2). Those releases throw
/// on any other `payload.type` -- tombstones included -- so they must never
/// receive one.
const legacyEntryTypes = {
  'irrigation',
  'fertilizer',
  'pruning',
  'observation',
  'height',
  'chlorosis',
  'pest',
  'pesticide',
  'other',
  'history',
};

const _validEntityTypes = {
  'species',
  'plant',
  'entry',
  'location',
  'soil',
  'bed',
  'defensivo',
  'reminder',
};

class SyncRepository implements ISyncRepository {
  const SyncRepository(this._db);
  final Pool _db;

  @override
  Future<({List<SyncChange> changes, bool hasMore})> serveChanges(
    String userId, {
    required int since,
    required int limit,
    Set<String>? entryTypes,
    Set<String>? entityTypes,
  }) async {
    final candidates = <SyncChange>[];

    for (final entry in _matTable.entries) {
      if (entityTypes != null && !entityTypes.contains(entry.key)) continue;
      // Filtering inside the query (not after it) keeps hidden rows out of
      // both the page and the hasMore probe, so a client's cursor -- the rev
      // of the last change it applied -- always advances.
      final isEntries = entry.key == 'entry';
      final result = await _db.execute(
        Sql.named('''
          SELECT entity_id, payload, updated_at, deleted_at, device_id, rev
          FROM ${entry.value}
          WHERE user_id = @userId AND rev > @since
            ${isEntries ? "AND payload->>'type' = ANY(@entryTypes)" : ''}
          ORDER BY rev
          LIMIT @limit
        '''),
        parameters: {
          'userId': userId,
          'since': since,
          'limit': limit + 1,
          if (isEntries)
            'entryTypes': TypedValue(
                Type.textArray, (entryTypes ?? legacyEntryTypes).toList()),
        },
      );

      for (final row in result) {
        candidates.add(SyncChange(
          entityType: entry.key,
          entityId: row[0] as String,
          payload: _decodePayload(row[1]),
          updatedAt: row[2] as DateTime,
          deletedAt: row[3] as DateTime?,
          deviceId: row[4] as String,
          rev: (row[5] as num).toInt(),
        ));
      }
    }

    // Fetching each table's own smallest `limit + 1` revs is sufficient to
    // compute the true global top-`limit` across all tables (standard
    // k-way-merge property), and the "+1" doubles as a cheap hasMore probe
    // without an extra COUNT query.
    candidates.sort((a, b) => a.rev.compareTo(b.rev));
    final hasMore = candidates.length > limit;
    final changes =
        hasMore ? candidates.sublist(0, limit) : candidates;

    return (changes: changes, hasMore: hasMore);
  }

  @override
  Future<int> receiveChanges(
    String userId,
    String deviceId,
    List<SyncChange> changes,
  ) async {
    var applied = 0;

    await _db.runTx((session) async {
      for (final change in changes) {
        if (!_validEntityTypes.contains(change.entityType)) continue;
        final table = _matTable[change.entityType]!;

        final result = await session.execute(
          Sql.named('''
            INSERT INTO $table
              (entity_id, user_id, payload, updated_at, deleted_at, device_id, rev)
            VALUES
              (@entityId, @userId, @payload::jsonb, @updatedAt, @deletedAt, @deviceId, nextval('mat_rev_seq'))
            ON CONFLICT (user_id, entity_id) DO UPDATE
              SET payload = EXCLUDED.payload,
                  updated_at = EXCLUDED.updated_at,
                  deleted_at = EXCLUDED.deleted_at,
                  device_id = EXCLUDED.device_id,
                  rev = EXCLUDED.rev
              -- Last-write-wins by actual edit time, not arrival order.
              -- SQL form of incomingWins() from package:polypodium_core;
              -- sync_repository_test.dart runs the package's lwwVectors
              -- through this clause, so a drift here fails the tests.
              WHERE EXCLUDED.updated_at > $table.updated_at
                 OR (EXCLUDED.updated_at = $table.updated_at
                     AND EXCLUDED.device_id > $table.device_id)
          '''),
          parameters: {
            'entityId': change.entityId,
            'userId': userId,
            'payload': jsonEncode(change.payload),
            'updatedAt': change.updatedAt,
            'deletedAt': change.deletedAt,
            'deviceId': change.deviceId,
          },
        );

        if (result.affectedRows > 0) applied++;
      }
    });

    return applied;
  }

  @override
  Future<void> ackCursor(String deviceId, int cursor) async {
    await _db.execute(
      Sql.named('''
        INSERT INTO device_cursors (device_id, last_pulled_cursor)
        VALUES (@deviceId, @cursor)
        ON CONFLICT (device_id) DO UPDATE
          SET last_pulled_cursor = EXCLUDED.last_pulled_cursor
          WHERE EXCLUDED.last_pulled_cursor > device_cursors.last_pulled_cursor
      '''),
      parameters: {'deviceId': deviceId, 'cursor': cursor},
    );
  }

  @override
  Future<Map<String, dynamic>> getStatus(
      String userId, String deviceId) async {
    final cursorRow = await _db.execute(
      Sql.named(
          'SELECT last_pulled_cursor FROM device_cursors WHERE device_id = @id'),
      parameters: {'id': deviceId},
    );
    final lastPulled = cursorRow.isNotEmpty ? (cursorRow.first[0] as int) : 0;

    var serverLatest = 0;
    var pending = 0;

    for (final table in _matTable.values) {
      final latestRow = await _db.execute(
        Sql.named(
            'SELECT COALESCE(MAX(rev), 0) FROM $table WHERE user_id = @userId'),
        parameters: {'userId': userId},
      );
      final tableLatest = (latestRow.first[0] as num).toInt();
      if (tableLatest > serverLatest) serverLatest = tableLatest;

      final countRow = await _db.execute(
        Sql.named('''
          SELECT COUNT(*) FROM $table
          WHERE user_id = @userId AND rev > @cursor AND device_id != @deviceId
        '''),
        parameters: {
          'userId': userId,
          'cursor': lastPulled,
          'deviceId': deviceId,
        },
      );
      pending += (countRow.first[0] as num).toInt();
    }

    return {
      'pendingChangeCount': pending,
      'lastPulledCursor': lastPulled,
      'serverLatestCursor': serverLatest,
    };
  }
}

Map<String, dynamic> _decodePayload(dynamic raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
  return {};
}
