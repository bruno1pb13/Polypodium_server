import 'dart:convert';

import 'package:polypodium_core/polypodium_core.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:polypodium_server/features/mcp/garden_store.dart';
import 'package:polypodium_server/features/mcp/i_mcp_token_repository.dart';
import 'package:polypodium_server/features/mcp/mcp_handler.dart';
import 'package:polypodium_server/features/mcp/mcp_server.dart';
import 'package:polypodium_server/features/mcp/photo_intake.dart';
import 'package:polypodium_server/features/mcp/polypodium_tools.dart';
import 'package:polypodium_server/features/sync/i_sync_repository.dart';
import 'package:polypodium_server/middleware/mcp_auth_middleware.dart';

/// One garden's live rows in memory; [_FakeSync] writes into it.
class _FakeStore implements IGardenStore {
  final rows = <String, Map<String, StoredEntity>>{};
  final received = <SyncChange>[];

  void put(String type, String id, Map<String, dynamic> payload) =>
      (rows[type] ??= {})[id] = StoredEntity(id, payload, DateTime.utc(2026));

  @override
  Future<List<StoredEntity>> list(String gardenId, String entityType) async =>
      (rows[entityType] ?? {}).values.toList();

  @override
  Future<StoredEntity?> get(
          String gardenId, String entityType, String id) async =>
      rows[entityType]?[id];

  @override
  Future<List<StoredEntity>> entries(
    String gardenId, {
    Set<String>? plantIds,
    String? type,
    String? from,
    String? until,
    required int limit,
  }) async {
    final all = (rows['entry'] ?? {}).values.where((e) {
      final p = e.payload;
      final date = p['date'] as String;
      return (plantIds == null || plantIds.contains(p['plantId'])) &&
          (type == null || p['type'] == type) &&
          (from == null || date.compareTo(from) >= 0) &&
          (until == null || date.compareTo('${until}T99') < 0);
    }).toList()
      ..sort((a, b) =>
          (b.payload['date'] as String).compareTo(a.payload['date'] as String));
    return all.take(limit).toList();
  }

  @override
  Future<List<PhotoRef>> photos(String gardenId,
          {String? plantId, List<String>? photoIds, int? limit}) async =>
      _allPhotos()
          .where((p) =>
              (plantId == null || p.plantId == plantId) &&
              (photoIds == null || photoIds.contains(p.id)))
          .take(limit ?? 1000)
          .toList();

  @override
  Future<Map<String, String>> lastEntryDates(
      String gardenId, String type) async {
    final result = <String, String>{};
    for (final e in (rows['entry'] ?? {}).values) {
      if (e.payload['type'] != type) continue;
      final plantId = e.payload['plantId'] as String;
      final date = e.payload['date'] as String;
      if ((result[plantId] ?? '').compareTo(date) < 0) result[plantId] = date;
    }
    return result;
  }
}

extension on _FakeStore {
  List<PhotoRef> _allPhotos() {
    final entries = (rows['entry'] ?? {}).values
        .where((e) => e.payload['photoKey'] != null)
        .toList()
      ..sort((a, b) =>
          (b.payload['date'] as String).compareTo(a.payload['date'] as String));
    PhotoRef ref(String id, StoredEntity e, String key) => PhotoRef(
          id: id,
          entryId: e.id,
          plantId: e.payload['plantId'] as String,
          photoKey: key,
          date: e.payload['date'] as String,
          entryType: e.payload['type'] as String,
          note: e.payload['note'] as String?,
        );
    return [
      for (final e in entries) ...[
        ref(e.id, e, e.payload['photoKey'] as String),
        for (final p in (rows['entry_photo'] ?? {}).values.toList()
          ..sort((a, b) => (a.payload['position'] as int)
              .compareTo(b.payload['position'] as int)))
          if (p.payload['entryId'] == e.id)
            ref(p.id, e, p.payload['photoKey'] as String),
      ],
    ];
  }
}

/// Takes `{"data": "jpg"|"png"}` and records what it saves.
class _FakeIntake implements IPhotoIntake {
  final saved = <String, List<int>>{};

  @override
  Future<IncomingPhoto> read(Object? spec) async => switch (spec) {
        {'data': 'jpg'} => const IncomingPhoto([0xff, 0xd8, 0xff], '.jpg'),
        {'data': 'png'} => const IncomingPhoto([0x89, 0x50], '.png'),
        _ => throw const McpToolError('not a JPEG, PNG, WebP or GIF image'),
      };

  @override
  Future<void> save(String gardenId, String photoKey, List<int> bytes) async =>
      saved['$gardenId/$photoKey'] = bytes;
}

class _FakeSync implements ISyncRepository {
  _FakeSync(this.store);
  final _FakeStore store;

  @override
  Future<int> receiveChanges(String gardenId, String userId, String deviceId,
      List<SyncChange> changes) async {
    for (final c in changes) {
      store.received.add(c);
      if (c.deletedAt != null) {
        store.rows[c.entityType]?.remove(c.entityId);
      } else {
        store.put(c.entityType, c.entityId, c.payload);
      }
    }
    return changes.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _readGrant = McpGrant(
    tokenId: 't1',
    gardenId: 'g1',
    gardenName: 'Casa',
    userId: 'u1',
    canWrite: false);
const _writeGrant = McpGrant(
    tokenId: 't2',
    gardenId: 'g1',
    gardenName: 'Casa',
    userId: 'u1',
    canWrite: true);

// Ids whose short codes are AAAAAA, BBBBBB...
const _fern = 'aaaaaaaa-0000-4000-8000-000000000001';
const _cactus = 'bbbbbbbb-0000-4000-8000-000000000002';
const _deadFern = 'cccccccc-0000-4000-8000-000000000003';

void main() {
  late _FakeStore store;
  late McpServer server;
  late List<String> loaded;
  late _FakeIntake intake;
  var nextId = 0;

  setUp(() {
    store = _FakeStore()
      ..put('species', 'sp1', {
        'popularName': 'Samambaia',
        'scientificName': 'Nephrolepis exaltata',
        'defaultIrrigationFrequencyDays': 3,
      })
      ..put('species', 'sp2', {
        'popularName': 'Cacto',
        'scientificName': 'Cactaceae',
        'defaultIrrigationFrequencyDays': 14,
      })
      ..put('location', 'loc1', {'name': 'Varanda'})
      ..put('location', 'loc2', {'name': 'Sala'})
      ..put('bed', 'pot1', {'name': 'Jardineira', 'locationId': 'loc1'})
      ..put('bed', 'pot2', {
        'name': 'Vaso grande',
        'locationId': 'loc2',
        'diameterCm': 30.0,
        'material': 'clay',
      })
      ..put('plant', _fern, {
        'nickname': 'Fern',
        'speciesId': 'sp1',
        'soilId': 'loamy',
        'status': 'active',
        'potId': 'pot1',
        'locationId': 'loc1',
        'lastIrrigatedAt': '2026-10-05T08:00:00.000',
        'createdAt': '2026-01-01T00:00:00.000',
      })
      ..put('plant', _cactus, {
        'nickname': 'Spiky',
        'speciesId': 'sp2',
        'soilId': 'sandy',
        'status': 'active',
        'locationId': 'loc2',
        'lastIrrigatedAt': '2026-10-01T08:00:00.000',
        'createdAt': '2026-01-01T00:00:00.000',
      })
      ..put('plant', _deadFern, {
        'nickname': 'Fern',
        'speciesId': 'sp1',
        'soilId': 'loamy',
        'status': 'dead',
        'potId': 'pot1',
        'createdAt': '2026-01-01T00:00:00.000',
      })
      ..put('entry', 'e1', {
        'plantId': _fern,
        'type': 'irrigation',
        'date': '2026-10-08T09:00:00.000',
        'createdAt': '2026-10-08T09:00:00.000',
      })
      ..put('entry', 'e2', {
        'plantId': _fern,
        'type': 'irrigation',
        'date': '2026-10-10T09:00:00.000',
        'createdAt': '2026-10-10T09:00:00.000',
      })
      ..put('entry', 'e3', {
        'plantId': _cactus,
        'type': 'observation',
        'date': '2026-09-01T09:00:00.000',
        'note': 'first flower',
        'photoKey': 'e3.jpg',
        'createdAt': '2026-09-01T09:00:00.000',
      })
      ..put('entry_photo', 'ep1', {
        'entryId': 'e3',
        'photoKey': 'ep1.jpg',
        'position': 0,
      })
      ..put('entry', 'e4', {
        'plantId': _cactus,
        'type': 'observation',
        'date': '2026-10-02T09:00:00.000',
        'photoKey': 'e4.jpg',
        'createdAt': '2026-10-02T09:00:00.000',
      });
    loaded = [];
    intake = _FakeIntake();
    server = McpServer(
      polypodiumTools(
        store: store,
        sync: _FakeSync(store),
        photos: (gardenId, key, maxSide) async {
          loaded.add('$gardenId/$key@$maxSide');
          return key == 'gone.jpg' ? null : McpImage([1, 2, 3], 'image/jpeg');
        },
        intake: intake,
        clock: () => DateTime(2026, 10, 12, 15),
      ),
      version: 'test',
    );
    nextId = 0;
  });

  Future<Map<String, Object?>> rpc(String method,
      {Map<String, Object?>? params, McpGrant grant = _writeGrant}) async {
    final response = await server.handle({
      'jsonrpc': '2.0',
      'id': ++nextId,
      'method': method,
      if (params != null) 'params': params,
    }, grant);
    return response!;
  }

  Future<Map<String, Object?>> call(String tool, Map<String, Object?> args,
      {McpGrant grant = _writeGrant}) async {
    final response =
        await rpc('tools/call', params: {'name': tool, 'arguments': args}, grant: grant);
    return response['result'] as Map<String, Object?>;
  }

  Map<String, Object?> ok(Map<String, Object?> result) {
    expect(result['isError'], false,
        reason: '${(result['content'] as List).first}');
    return result['structuredContent'] as Map<String, Object?>;
  }

  String errorText(Map<String, Object?> result) {
    expect(result['isError'], true);
    return ((result['content'] as List).first as Map)['text'] as String;
  }

  group('protocol', () {
    test('initialize echoes a supported version, else offers the newest',
        () async {
      final known = await rpc('initialize',
          params: {'protocolVersion': '2025-03-26'});
      expect((known['result'] as Map)['protocolVersion'], '2025-03-26');

      final unknown = await rpc('initialize',
          params: {'protocolVersion': '2099-01-01'});
      final result = unknown['result'] as Map;
      expect(result['protocolVersion'], mcpProtocolVersions.first);
      expect((result['capabilities'] as Map).containsKey('tools'), isTrue);
    });

    test('notifications get no response', () async {
      expect(
          await server.handle(
              {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
              _readGrant),
          isNull);
    });

    test('unknown methods are JSON-RPC errors', () async {
      final res = await rpc('resources/list');
      expect((res['error'] as Map)['code'], -32601);
    });

    test('read-only tokens neither see nor call write tools', () async {
      Future<Set<String>> names(McpGrant grant) async {
        final res = await rpc('tools/list', grant: grant);
        return {
          for (final t in (res['result'] as Map)['tools'] as List)
            (t as Map)['name'] as String
        };
      }

      expect(await names(_readGrant), contains('list_plants'));
      expect(await names(_readGrant), isNot(contains('add_entry')));
      expect(await names(_writeGrant), contains('add_entry'));
      expect(await names(_writeGrant), contains('update_species'));
      expect(await names(_readGrant), isNot(contains('update_species')));

      final res = await rpc('tools/call',
          params: {
            'name': 'add_entry',
            'arguments': {'plants': [_fern], 'type': 'irrigation'},
          },
          grant: _readGrant);
      expect((res['error'] as Map)['code'], -32602);
      expect(store.received, isEmpty);
    });
  });

  group('reads', () {
    test('list_plants derives watering state from entries', () async {
      final result = ok(await call('list_plants', {}));
      expect(result['total'], 2); // the dead fern is filtered out
      final plants = {
        for (final p in result['plants'] as List)
          (p as Map)['nickname']: p,
      };
      // Last watered by entry e2 (newer than the stored lastIrrigatedAt).
      expect(plants['Fern']!['lastWateredAt'], '2026-10-10T09:00:00.000');
      expect(plants['Fern']!['daysSinceWatered'], 2);
      expect(plants['Fern']!['needsWater'], false);
      expect(plants['Fern']!['nextWateringDate'], '2026-10-13');
      expect(plants['Spiky']!['needsWater'], false);
      expect(plants['Fern']!['shortCode'], 'AAAAAA');

      final due = ok(await call('list_plants', {'needsWater': true}));
      expect(due['total'], 0);
    });

    test('get_plant resolves short codes and rejects ambiguous names',
        () async {
      final plant = ok(await call('get_plant', {'plant': '#bbbbbb'}));
      expect(plant['nickname'], 'Spiky');

      final ambiguous = await call('get_plant', {'plant': 'fern'});
      expect(errorText(ambiguous), contains('several plants'));
    });

    test('list_entries filters by plant and day range', () async {
      final result = ok(await call('list_entries',
          {'plant': 'AAAAAA', 'from': '2026-10-09', 'until': '2026-10-10'}));
      expect([for (final e in result['entries'] as List) (e as Map)['id']],
          ['e2']);
    });

    test('bad arguments are tool errors, not crashes', () async {
      expect(errorText(await call('list_plants', {'limit': 'lots'})),
          contains('limit'));
      expect(errorText(await call('list_entries', {'from': '12/10/2026'})),
          contains('YYYY-MM-DD'));
    });
  });

  group('photos', () {
    test('get_plant attaches the cover photo, small', () async {
      final result = await call('get_plant', {'plant': 'Spiky'});
      final data = ok(result);
      expect(data['photoCount'], 3);
      // No cover picked: the newest entry's own photo.
      expect((data['coverPhoto'] as Map)['photoId'], 'e4');
      final content = result['content'] as List;
      expect(content[1], {
        'type': 'image',
        'data': base64Encode([1, 2, 3]),
        'mimeType': 'image/jpeg',
      });
      expect(loaded, ['g1/e4.jpg@512']);

      loaded.clear();
      final plain = await call(
          'get_plant', {'plant': 'Spiky', 'includeCoverImage': false});
      expect(plain['content'] as List, hasLength(1));
      expect(loaded, isEmpty);
    });

    test('a picked cover wins while it exists', () async {
      store.rows['plant']![_cactus]!.payload['coverPhotoId'] = 'ep1';
      final data = ok(await call('list_plant_photos', {'plant': 'Spiky'}));
      expect(data['total'], 3);
      expect([for (final p in data['photos'] as List) p['photoId']],
          ['e4', 'e3', 'ep1']);
      expect([for (final p in data['photos'] as List) p['isCover']],
          [false, false, true]);
      expect((data['photos'] as List)[2]['note'], 'first flower');
    });

    test('get_photos returns images in order and names the missing ones',
        () async {
      final result = await call('get_photos', {
        'photoIds': ['ep1', 'nope', 'e3'],
        'size': 'large',
      });
      final data = ok(result);
      expect([for (final p in data['photos'] as List) p['photoId']],
          ['ep1', 'e3']);
      expect(data['notFound'], ['nope']);
      expect((result['content'] as List).skip(1).map((c) => c['type']),
          ['image', 'image']);
      expect(loaded, ['g1/ep1.jpg@1568', 'g1/e3.jpg@1568']);
    });

    test('get_photos limits how many and fails when none load', () async {
      expect(
          errorText(await call('get_photos', {
            'photoIds': [for (var i = 0; i < 7; i++) 'p$i'],
          })),
          contains('at most'));
      expect(errorText(await call('get_photos', {'photoIds': ['nope']})),
          contains('no photo found'));
    });

    test('entries say whether they have a photo', () async {
      final data = ok(await call('list_entries', {'plant': 'Spiky'}));
      expect([for (final e in data['entries'] as List) e['hasPhoto']],
          [true, true]);
    });
  });

  group('writes', () {
    test('add_entry for a pot covers its active plants only', () async {
      final result = ok(await call('add_entry', {
        'potId': 'pot1',
        'type': 'irrigation',
        'date': '2026-10-12',
        'numericValue': 2,
      }));
      expect((result['created'] as List).single, containsPair('plantId', _fern));

      final change = store.received.single;
      expect(change.entityType, 'entry');
      expect(change.deviceId, 'mcp-t2');
      expect(change.payload['date'], '2026-10-12T12:00:00.000');
      expect(change.payload['numericValue'], 2.0);
      expect(change.payload['createdAt'], isNotNull);
    });

    test('add_entry rejects types that are per plant only for a pot',
        () async {
      final result =
          await call('add_entry', {'potId': 'pot1', 'type': 'height'});
      expect(errorText(result), contains('whole pot'));
      expect(store.received, isEmpty);
    });

    test('delete_entry tombstones it and rewinds the last watering',
        () async {
      ok(await call('delete_entry', {'entryId': 'e2'}));
      final tombstone =
          store.received.firstWhere((c) => c.entityType == 'entry');
      expect(tombstone.deletedAt, isNotNull);
      expect(tombstone.payload['plantId'], _fern); // full payload kept

      final plant = store.received.firstWhere((c) => c.entityType == 'plant');
      expect(plant.payload['lastIrrigatedAt'], '2026-10-08T09:00:00.000');
      expect(plant.payload['nickname'], 'Fern');
    });

    test('create_plant validates references and inherits the pot location',
        () async {
      expect(
          errorText(await call(
              'create_plant', {'nickname': 'X', 'speciesId': 'nope'})),
          contains('species not found'));

      final created = ok(await call('create_plant',
          {'nickname': 'Baby fern', 'speciesId': 'sp1', 'potId': 'pot1'}));
      final payload = store.received.single.payload;
      expect(payload['id'], created['id']);
      expect(payload['locationId'], 'loc1');
      expect(payload['soilId'], 'pottingMix');
      expect(payload['status'], 'active');
      expect(payload['acquisitionDate'], '2026-10-12T00:00:00.000');
    });

    test('update_species changes only the given fields', () async {
      store.rows['species']!['sp1']!.payload
        ..['light'] = 'shade'
        ..['careNotes'] = 'Gosta de umidade'
        ..['createdAt'] = '2026-01-01T00:00:00.000';

      final result = ok(await call('update_species', {
        'species': 'nephrolepis exaltata',
        'defaultIrrigationFrequencyDays': 4,
        'light': '',
        'floweringMonths': [12, 3, 3],
        'recommendedSoilIds': ['loamy'],
      }));
      expect(result['changed'], [
        'defaultIrrigationFrequencyDays',
        'light',
        'floweringMonths',
        'recommendedSoilIds',
      ]);
      final change = store.received.single;
      expect(change.entityType, 'species');
      expect(change.entityId, 'sp1');
      expect(change.deviceId, 'mcp-t2');
      final payload = change.payload;
      expect(payload['defaultIrrigationFrequencyDays'], 4);
      expect(payload['light'], isNull);
      expect(payload['floweringMonths'], [3, 12]);
      expect(payload['recommendedSoilIds'], ['loamy']);
      // Fields not given stay as they were.
      expect(payload['popularName'], 'Samambaia');
      expect(payload['careNotes'], 'Gosta de umidade');
      expect(payload['createdAt'], '2026-01-01T00:00:00.000');
    });

    test('update_species without changes writes nothing', () async {
      final result = ok(await call('update_species',
          {'species': 'sp2', 'popularName': 'Cacto', 'floweringMonths': null}));
      expect(result['changed'], isEmpty);
      expect(store.received, isEmpty);
    });

    test('update_species validates what it is given', () async {
      expect(errorText(await call('update_species', {'species': 'Rosa'})),
          contains('species not found'));
      expect(
          errorText(await call('update_species',
              {'species': 'sp1', 'recommendedSoilIds': ['lava']})),
          contains('soil not found'));
      expect(
          errorText(await call(
              'update_species', {'species': 'sp1', 'floweringMonths': [13]})),
          contains('months 1-12'));
      expect(
          errorText(await call(
              'update_species', {'species': 'sp1', 'light': 'dark'})),
          contains('light must be one of'));
      expect(store.received, isEmpty);
    });

    test('update_plant changes only the given fields', () async {
      final result = ok(await call('update_plant', {
        'plant': 'Spiky',
        'status': 'donated',
        'potId': 'pot1',
      }));
      expect(result['changed'],
          containsAll(['status', 'statusChangedAt', 'potId', 'locationId']));
      final payload = store.received.single.payload;
      expect(payload['status'], 'donated');
      expect(payload['locationId'], 'loc1'); // followed the pot
      expect(payload['soilId'], 'sandy');

      ok(await call('update_plant', {'plant': _cactus, 'potId': ''}));
      expect(store.received.last.payload['potId'], isNull);
      expect(store.received.last.payload['locationId'], 'loc1');
    });
  });

  group('pots, cuttings and repotting', () {
    test('create_pot writes a bed row in the app\'s shape', () async {
      expect(
          errorText(await call('create_pot',
              {'name': 'X', 'locationId': 'nowhere'})),
          contains('location not found'));
      expect(
          errorText(await call('create_pot', {'name': 'X', 'diameterCm': 0})),
          contains('positive'));

      final created = ok(await call('create_pot', {
        'name': 'Cachepô',
        'diameterCm': 18,
        'material': 'ceramic',
        'locationId': 'loc2',
      }));
      final change = store.received.single;
      expect(change.entityType, 'bed');
      expect(change.entityId, created['id']);
      expect(change.payload, {
        'id': created['id'],
        'name': 'Cachepô',
        'kind': 'pot',
        'diameterCm': 18.0,
        'material': 'ceramic',
        'locationId': 'loc2',
        'notes': null,
        // The test clock is local time: its UTC form depends on the zone.
        'createdAt': DateTime(2026, 10, 12, 15).toUtc().toIso8601String(),
      });
      final pots = ok(await call('list_pots', {}))['pots'] as List;
      expect(pots.map((p) => (p as Map)['name']), contains('Cachepô'));
    });

    test('create_cutting starts from the parent, outside any pot', () async {
      final created = ok(await call(
          'create_cutting', {'parent': 'AAAAAA', 'nickname': 'Fern (muda)'}));
      expect(created['parent'], {'id': _fern, 'nickname': 'Fern'});
      final payload = store.received.single.payload;
      expect(payload['parentPlantId'], _fern);
      expect(payload['speciesId'], 'sp1');
      expect(payload['soilId'], 'loamy');
      expect(payload['locationId'], 'loc1');
      expect(payload['potId'], isNull);
      expect(payload['irrigationFrequencyDays'], isNull);
      expect(payload['status'], 'active');

      ok(await call('create_cutting', {
        'parent': _fern,
        'nickname': 'Fern 2',
        'potId': 'pot2',
        'soilId': 'sandy',
      }));
      final second = store.received.last.payload;
      expect(second['locationId'], 'loc2'); // the pot's, not the parent's
      expect(second['soilId'], 'sandy');
    });

    test('repot_plant moves plants into a pot and records the move',
        () async {
      final result = ok(await call('repot_plant', {
        'plants': ['AAAAAA', 'Spiky'],
        'pot': 'vaso grande',
        'soilId': 'succulentMix',
        'date': '2026-10-11',
        'note': 'raízes apertadas',
      }));
      expect(result['pot'], {'id': 'pot2', 'name': 'Vaso grande'});

      final plants = {
        for (final c in store.received)
          if (c.entityType == 'plant') c.entityId: c.payload,
      };
      expect(plants[_fern]!['potId'], 'pot2');
      expect(plants[_fern]!['locationId'], 'loc2');
      expect(plants[_fern]!['soilId'], 'succulentMix');
      expect(plants[_cactus]!['potId'], 'pot2');

      final entries = {
        for (final c in store.received)
          if (c.entityType == 'entry') c.payload['plantId']: c.payload,
      };
      expect(entries[_fern]!['type'], 'repotting');
      expect(entries[_fern]!['date'], '2026-10-11T12:00:00.000');
      expect(entries[_fern]!['note'], 'raízes apertadas');
      expect(jsonDecode(entries[_fern]!['extraData'] as String), {
        'potDiameterCm': 30.0,
        'potMaterial': 'clay',
        'newSoilId': 'succulentMix',
        'fromPotId': 'pot1',
        'toPotId': 'pot2',
        'toPotName': 'Vaso grande',
      });
      // The cactus wasn't in a pot: nothing to leave.
      expect(jsonDecode(entries[_cactus]!['extraData'] as String),
          isNot(contains('fromPotId')));
    });

    test('repot_plant with pot "" takes the plant out of its pot', () async {
      ok(await call('repot_plant', {
        'plants': [_fern],
        'pot': '',
        'potDiameterCm': 25,
      }));
      final plant =
          store.received.firstWhere((c) => c.entityType == 'plant').payload;
      expect(plant['potId'], isNull);
      expect(plant['locationId'], 'loc1');
      final entry =
          store.received.firstWhere((c) => c.entityType == 'entry').payload;
      expect(jsonDecode(entry['extraData'] as String),
          {'potDiameterCm': 25.0, 'fromPotId': 'pot1'});
    });

    test('repot_plant only changing the soil leaves the pot alone', () async {
      ok(await call('repot_plant', {'plants': ['Spiky'], 'soilId': 'loamy'}));
      final plant =
          store.received.firstWhere((c) => c.entityType == 'plant').payload;
      expect(plant['soilId'], 'loamy');
      expect(plant['locationId'], 'loc2');
      expect(errorText(await call('repot_plant',
              {'plants': ['Spiky'], 'pot': 'Nenhum'})),
          contains('pot not found'));
    });
  });

  group('entry photos', () {
    test('add_entry stores photos as the entry\'s own plus extras', () async {
      final result = ok(await call('add_entry', {
        'plants': ['Spiky'],
        'type': 'observation',
        'photos': [
          {'data': 'jpg'},
          {'data': 'png'},
        ],
      }));
      final entryId = ((result['created'] as List).single as Map)['entryId'];
      final entry = store.received.firstWhere((c) => c.entityType == 'entry');
      expect(entry.payload['photoKey'], '$entryId.jpg');
      final extra =
          store.received.firstWhere((c) => c.entityType == 'entry_photo');
      expect(extra.payload['entryId'], entryId);
      expect(extra.payload['photoKey'], '${extra.entityId}.png');
      expect(extra.payload['position'], 0);
      expect(intake.saved.keys,
          {'g1/$entryId.jpg', 'g1/${extra.entityId}.png'});

      final photos = ok(await call('list_plant_photos', {'plant': 'Spiky'}));
      expect((photos['photos'] as List).first,
          containsPair('photoId', entryId));
    });

    test('a bad photo fails the call before anything is written', () async {
      final result = await call('add_entry', {
        'plants': ['Spiky'],
        'type': 'observation',
        'photos': [
          {'data': 'jpg'},
          {'data': 'heic'},
        ],
      });
      expect(errorText(result), contains('not a JPEG'));
      expect(store.received, isEmpty);
      expect(intake.saved, isEmpty);
    });

    test('add_entry_photos appends after the existing ones', () async {
      final result = ok(await call('add_entry_photos', {
        'entryId': 'e3',
        'photos': [
          {'data': 'jpg'},
        ],
      }));
      expect(result['photoCount'], 3);
      final extra = store.received.single;
      expect(extra.entityType, 'entry_photo');
      expect(extra.payload['position'], 1);

      // An entry without its own photo gets it first.
      ok(await call('add_entry_photos', {
        'entryId': 'e1',
        'photos': [
          {'data': 'png'},
          {'data': 'jpg'},
        ],
      }));
      final entry = store.received.firstWhere(
          (c) => c.entityType == 'entry' && c.entityId == 'e1');
      expect(entry.payload['photoKey'], 'e1.png');
      expect(entry.payload['type'], 'irrigation'); // rest of the entry kept
      expect(store.rows['entry_photo']!.values
          .where((p) => p.payload['entryId'] == 'e1')
          .single
          .payload['position'], 0);
    });

    test('add_entry_photos keeps an entry within five photos', () async {
      final result = await call('add_entry_photos', {
        'entryId': 'e3',
        'photos': List.filled(4, {'data': 'jpg'}),
      });
      expect(errorText(result), contains('at most 5'));
      expect(errorText(await call('add_entry_photos', {
        'entryId': 'nope',
        'photos': [
          {'data': 'jpg'},
        ],
      })), contains('entry not found'));
      expect(store.received, isEmpty);
    });
  });

  group('HTTP transport', () {
    final handler = McpHandler(McpServer(const [], version: 'test'));

    Request post(Object body, {Map<String, String> headers = const {}}) =>
        Request('POST', Uri.parse('http://localhost/'),
            body: jsonEncode(body),
            headers: headers,
            context: {'mcpGrant': _readGrant});

    test('answers requests with JSON and notifications with 202', () async {
      final res = await handler
          .post(post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}));
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'application/json');
      expect(jsonDecode(await res.readAsString()),
          {'jsonrpc': '2.0', 'id': 1, 'result': {}});

      final note = await handler.post(
          post({'jsonrpc': '2.0', 'method': 'notifications/initialized'}));
      expect(note.statusCode, 202);
    });

    test('rejects unsupported protocol versions and bad JSON', () async {
      final res = await handler.post(post(
          {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
          headers: {'MCP-Protocol-Version': '1999-01-01'}));
      expect(res.statusCode, 400);

      final bad = await handler.post(Request(
          'POST', Uri.parse('http://localhost/'),
          body: '{', context: {'mcpGrant': _readGrant}));
      expect(bad.statusCode, 400);
    });

    test('the middleware demands a token it can resolve', () async {
      final guarded = mcpAuthMiddleware(_Tokens())((_) => Response.ok(''));
      final missing =
          await guarded(Request('POST', Uri.parse('http://localhost/')));
      expect(missing.statusCode, 401);
      expect(missing.headers['www-authenticate'], startsWith('Bearer'));

      final good = await guarded(Request('POST', Uri.parse('http://localhost/'),
          headers: {'Authorization': 'Bearer pmcp_good'}));
      expect(good.statusCode, 200);
    });
  });
}

class _Tokens implements IMcpTokenRepository {
  @override
  Future<McpGrant?> resolve(String secret) async =>
      secret == 'pmcp_good' ? _readGrant : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
