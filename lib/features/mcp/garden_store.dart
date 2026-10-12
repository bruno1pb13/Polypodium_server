import 'dart:convert';

import 'package:postgres/postgres.dart';

import '../sync/i_sync_repository.dart';

/// A live (not soft-deleted) synced row, as the devices wrote it.
class StoredEntity {
  const StoredEntity(this.id, this.payload, this.updatedAt);
  final String id;
  final Map<String, dynamic> payload;
  final DateTime updatedAt;
}

/// Read access to one garden's synced data for the MCP tools. Writes go
/// through [ISyncRepository.receiveChanges], the same LWW path devices use.
abstract interface class IGardenStore {
  /// Every live row of [entityType] (a [syncEntityTypes] name).
  Future<List<StoredEntity>> list(String gardenId, String entityType);

  Future<StoredEntity?> get(String gardenId, String entityType, String id);

  /// Live entries, newest `date` first, optionally of some plants, of one
  /// type and from/until a `YYYY-MM-DD` date (inclusive).
  Future<List<StoredEntity>> entries(
    String gardenId, {
    Set<String>? plantIds,
    String? type,
    String? from,
    String? until,
    required int limit,
  });

  /// The latest `date` of a live entry of [type], per plant id.
  Future<Map<String, String>> lastEntryDates(String gardenId, String type);
}

const _tables = {
  'species': 'mat_species',
  'plant': 'mat_plants',
  'entry': 'mat_entries',
  'entry_photo': 'mat_entry_photos',
  'location': 'mat_locations',
  'soil': 'mat_soils',
  'bed': 'mat_beds',
  'defensivo': 'mat_defensivos',
  'reminder': 'mat_reminders',
};

class GardenStore implements IGardenStore {
  const GardenStore(this._db);
  final Pool _db;

  @override
  Future<List<StoredEntity>> list(String gardenId, String entityType) async {
    final result = await _db.execute(
      Sql.named('''
        SELECT entity_id, payload, updated_at FROM ${_table(entityType)}
        WHERE garden_id = @gardenId AND deleted_at IS NULL
      '''),
      parameters: {'gardenId': gardenId},
    );
    return [for (final row in result) _entity(row)];
  }

  @override
  Future<StoredEntity?> get(
      String gardenId, String entityType, String id) async {
    final result = await _db.execute(
      Sql.named('''
        SELECT entity_id, payload, updated_at FROM ${_table(entityType)}
        WHERE garden_id = @gardenId AND entity_id = @id
          AND deleted_at IS NULL
      '''),
      parameters: {'gardenId': gardenId, 'id': id},
    );
    return result.isEmpty ? null : _entity(result.first);
  }

  @override
  Future<List<StoredEntity>> entries(
    String gardenId, {
    Set<String>? plantIds,
    String? type,
    String? from,
    String? until,
    required int limit,
  }) async {
    // Dates are ISO-8601 strings (local wall-clock from the app, UTC from
    // here), so text comparison against a `YYYY-MM-DD` bound orders them.
    final result = await _db.execute(
      Sql.named('''
        SELECT entity_id, payload, updated_at FROM mat_entries
        WHERE garden_id = @gardenId AND deleted_at IS NULL
          AND (@plantIds::text[] IS NULL
               OR payload->>'plantId' = ANY(@plantIds::text[]))
          AND (@type::text IS NULL OR payload->>'type' = @type::text)
          AND (@from::text IS NULL OR payload->>'date' >= @from::text)
          AND (@until::text IS NULL OR payload->>'date' < @until::text)
        ORDER BY payload->>'date' DESC, entity_id
        LIMIT @limit
      '''),
      parameters: {
        'gardenId': gardenId,
        'plantIds': plantIds?.toList(),
        'type': type,
        'from': from,
        // Inclusive day: everything before the start of the next one.
        'until': until == null ? null : '${until}T99',
        'limit': limit,
      },
    );
    return [for (final row in result) _entity(row)];
  }

  @override
  Future<Map<String, String>> lastEntryDates(
      String gardenId, String type) async {
    final result = await _db.execute(
      Sql.named('''
        SELECT payload->>'plantId', MAX(payload->>'date') FROM mat_entries
        WHERE garden_id = @gardenId AND deleted_at IS NULL
          AND payload->>'type' = @type
        GROUP BY 1
      '''),
      parameters: {'gardenId': gardenId, 'type': type},
    );
    return {
      for (final row in result)
        if (row[0] != null && row[1] != null) row[0] as String: row[1] as String,
    };
  }

  static String _table(String entityType) {
    final table = _tables[entityType];
    if (table == null) throw ArgumentError.value(entityType, 'entityType');
    return table;
  }

  static StoredEntity _entity(ResultRow row) => StoredEntity(
        row[0] as String,
        _decodePayload(row[1]),
        row[2] as DateTime,
      );

  static Map<String, dynamic> _decodePayload(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) return jsonDecode(raw) as Map<String, dynamic>;
    return {};
  }
}
