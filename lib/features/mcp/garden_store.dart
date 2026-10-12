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

/// A photo of an entry, as the server stores it: the entry's own photo
/// (whose id is the entry id) or one of its extra `entry_photo` rows. The
/// file is `photoKey` in the garden's photo directory.
class PhotoRef {
  const PhotoRef({
    required this.id,
    required this.entryId,
    required this.plantId,
    required this.photoKey,
    required this.date,
    required this.entryType,
    this.note,
  });

  final String id;
  final String entryId;
  final String plantId;
  final String photoKey;

  /// The entry's `date`.
  final String date;
  final String entryType;
  final String? note;
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

  /// Live photos of one plant's entries, or the ones with [photoIds];
  /// newest entry first, then in the entry's order. Like the app, extra
  /// photos only count for an entry that has its own.
  Future<List<PhotoRef>> photos(
    String gardenId, {
    String? plantId,
    List<String>? photoIds,
    int? limit,
  });
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

  @override
  Future<List<PhotoRef>> photos(
    String gardenId, {
    String? plantId,
    List<String>? photoIds,
    int? limit,
  }) async {
    final result = await _db.execute(
      Sql.named('''
        WITH entries AS (
          SELECT entity_id, payload FROM mat_entries
          WHERE garden_id = @gardenId AND deleted_at IS NULL
            AND payload->>'photoKey' IS NOT NULL
            AND (@plantId::text IS NULL
                 OR payload->>'plantId' = @plantId::text)
        ), photos AS (
          SELECT e.entity_id AS id, e.entity_id AS entry_id,
                 e.payload->>'photoKey' AS photo_key, -1 AS position,
                 e.payload AS entry
          FROM entries e
          UNION ALL
          SELECT p.entity_id, e.entity_id, p.payload->>'photoKey',
                 CASE WHEN jsonb_typeof(p.payload->'position') = 'number'
                      THEN (p.payload->>'position')::int ELSE 0 END,
                 e.payload
          FROM mat_entry_photos p
          JOIN entries e ON e.entity_id = p.payload->>'entryId'
          WHERE p.garden_id = @gardenId AND p.deleted_at IS NULL
            AND p.payload->>'photoKey' IS NOT NULL
        )
        SELECT id, entry_id, entry->>'plantId', photo_key, entry->>'date',
               entry->>'type', entry->>'note'
        FROM photos
        WHERE @photoIds::text[] IS NULL OR id = ANY(@photoIds::text[])
        ORDER BY entry->>'date' DESC, entry_id, position, id
        LIMIT @limit
      '''),
      parameters: {
        'gardenId': gardenId,
        'plantId': plantId,
        'photoIds': photoIds,
        'limit': limit ?? 1000,
      },
    );
    return [
      for (final row in result)
        PhotoRef(
          id: row[0] as String,
          entryId: row[1] as String,
          plantId: row[2] as String? ?? '',
          photoKey: row[3] as String,
          date: row[4] as String? ?? '',
          entryType: row[5] as String? ?? '',
          note: row[6] as String?,
        ),
    ];
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
