import 'dart:convert';

import 'package:postgres/postgres.dart';

import '../../database/db.dart';
import 'event_model.dart';

const _matTable = {
  'species': 'mat_species',
  'plant': 'mat_plants',
  'entry': 'mat_entries',
  'location': 'mat_locations',
  'soil': 'mat_soils',
};

const _validEntityTypes = {'species', 'plant', 'entry', 'location', 'soil'};
const _validOperations = {'create', 'update', 'delete'};

class SyncRepository {
  Future<({List<int> accepted, List<ConflictResult> conflicts})> pushEvents(
    String userId,
    String deviceId,
    List<PushEvent> events,
  ) async {
    final accepted = <int>[];
    final conflicts = <ConflictResult>[];

    await db.runTx((session) async {
      for (final event in events) {
        if (!_validEntityTypes.contains(event.entityType) ||
            !_validOperations.contains(event.operation)) {
          continue;
        }

        if (event.operation == 'update') {
          final conflict =
              await _detectConflict(session, userId, event.entityId, event.entityType);
          if (conflict != null) {
            conflicts.add(ConflictResult(
              localQueueId: event.localQueueId,
              reason: conflict.reason,
              serverPayload: conflict.serverPayload,
            ));
            continue;
          }
        }

        final insertResult = await session.execute(
          Sql.named('''
            INSERT INTO sync_events
              (device_id, user_id, entity_type, entity_id, operation, payload, client_timestamp)
            VALUES
              (@deviceId, @userId, @entityType, @entityId, @operation, @payload::jsonb, @clientTs)
            RETURNING id, server_timestamp
          '''),
          parameters: {
            'deviceId': deviceId,
            'userId': userId,
            'entityType': event.entityType,
            'entityId': event.entityId,
            'operation': event.operation,
            'payload': jsonEncode(event.payload),
            'clientTs': event.clientTimestamp,
          },
        );

        final serverTs = insertResult.first[1] as DateTime;
        await _applyToMaterialized(session, userId, event, serverTs);
        accepted.add(event.localQueueId);
      }
    });

    return (accepted: accepted, conflicts: conflicts);
  }

  Future<({String reason, Map<String, dynamic>? serverPayload})?> _detectConflict(
    Session session,
    String userId,
    String entityId,
    String entityType,
  ) async {
    final table = _matTable[entityType];
    if (table == null) return null;

    final matRow = await session.execute(
      Sql.named(
          'SELECT 1 FROM $table WHERE entity_id = @id AND user_id = @userId'),
      parameters: {'id': entityId, 'userId': userId},
    );

    if (matRow.isNotEmpty) return null; // entity exists, no conflict

    // Entity missing from materialized state — was it deleted?
    final lastEvent = await session.execute(
      Sql.named('''
        SELECT payload FROM sync_events
        WHERE user_id = @userId AND entity_id = @entityId AND operation = 'delete'
        ORDER BY id DESC
        LIMIT 1
      '''),
      parameters: {'userId': userId, 'entityId': entityId},
    );

    if (lastEvent.isEmpty) return null; // entity never existed here, let it through

    return (
      reason: 'entity_deleted_on_server',
      serverPayload: _decodePayload(lastEvent.first[0]),
    );
  }

  Future<void> _applyToMaterialized(
    Session session,
    String userId,
    PushEvent event,
    DateTime serverTs,
  ) async {
    final table = _matTable[event.entityType];
    if (table == null) return;

    if (event.operation == 'delete') {
      await session.execute(
        Sql.named(
            'DELETE FROM $table WHERE entity_id = @id AND user_id = @userId'),
        parameters: {'id': event.entityId, 'userId': userId},
      );
    } else {
      // LWW: only update if the incoming event is newer
      await session.execute(
        Sql.named('''
          INSERT INTO $table (entity_id, user_id, payload, server_timestamp)
          VALUES (@id, @userId, @payload::jsonb, @ts)
          ON CONFLICT (entity_id) DO UPDATE
            SET payload = EXCLUDED.payload,
                server_timestamp = EXCLUDED.server_timestamp
            WHERE EXCLUDED.server_timestamp >= $table.server_timestamp
        '''),
        parameters: {
          'id': event.entityId,
          'userId': userId,
          'payload': jsonEncode(event.payload),
          'ts': serverTs,
        },
      );
    }
  }

  Future<List<SyncEvent>> pullEvents(
    String userId,
    String deviceId,
    int since,
    int limit,
  ) async {
    final result = await db.execute(
      Sql.named('''
        SELECT id, device_id, entity_type, entity_id, operation, payload, server_timestamp
        FROM sync_events
        WHERE user_id = @userId
          AND id > @since
          AND device_id != @deviceId
        ORDER BY id
        LIMIT @limit
      '''),
      parameters: {
        'userId': userId,
        'since': since,
        'deviceId': deviceId,
        'limit': limit,
      },
    );

    return result
        .map((row) => SyncEvent(
              id: (row[0] as int),
              deviceId: row[1] as String,
              entityType: row[2] as String,
              entityId: row[3] as String,
              operation: row[4] as String,
              payload: _decodePayload(row[5]),
              serverTimestamp: row[6] as DateTime,
            ))
        .toList();
  }

  Future<void> ackCursor(String deviceId, int cursor) async {
    await db.execute(
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

  Future<Map<String, dynamic>> getStatus(
      String userId, String deviceId) async {
    final cursorRow = await db.execute(
      Sql.named(
          'SELECT last_pulled_cursor FROM device_cursors WHERE device_id = @id'),
      parameters: {'id': deviceId},
    );
    final lastPulled =
        cursorRow.isNotEmpty ? (cursorRow.first[0] as int) : 0;

    final latestRow = await db.execute(
      Sql.named(
          'SELECT COALESCE(MAX(id), 0) FROM sync_events WHERE user_id = @userId'),
      parameters: {'userId': userId},
    );
    final serverLatest = (latestRow.first[0] as num).toInt();

    final countRow = await db.execute(
      Sql.named('''
        SELECT COUNT(*)
        FROM sync_events
        WHERE user_id = @userId
          AND id > @cursor
          AND device_id != @deviceId
      '''),
      parameters: {
        'userId': userId,
        'cursor': lastPulled,
        'deviceId': deviceId,
      },
    );
    final pending = (countRow.first[0] as num).toInt();

    return {
      'pendingEventCount': pending,
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
