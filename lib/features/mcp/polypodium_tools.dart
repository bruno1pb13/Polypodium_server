import 'dart:convert';

import 'package:polypodium_core/polypodium_core.dart';
import 'package:uuid/uuid.dart';

import '../sync/i_sync_repository.dart';
import '../weather/weather_handler.dart';
import 'garden_store.dart';
import 'i_mcp_token_repository.dart';
import 'mcp_server.dart';
import 'photo_renderer.dart';

/// Looks up a location's forecast (see [WeatherHandler.forecast]).
typedef ForecastLookup = Future<ForecastResult> Function(
    String gardenId, String locationId,
    {int days});

/// Entry types the app knows (`EntryType` in the app's enums.dart).
const _entryTypes = [
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
  'repotting',
  'harvest',
];

/// Types that can be recorded for a whole pot at once (the app's
/// `potCompatibleEntryTypes`).
const _potEntryTypes = {
  'irrigation',
  'fertilizer',
  'pesticide',
  'pest',
  'chlorosis',
  'pruning',
  'observation',
  'other',
};

const _plantStatuses = ['active', 'dead', 'donated', 'archived'];
const _lightValues = ['fullSun', 'partialShade', 'indirectBright', 'shade'];
const _humidityValues = ['low', 'medium', 'high'];
const _petToxicityValues = ['unknown', 'nonToxic', 'toxic'];

/// Ids of the soils every app install seeds (the app's `SoilType` names);
/// valid soil references even when no device has synced them yet.
const _seededSoilIds = {
  'sandy',
  'clay',
  'loamy',
  'peaty',
  'chalky',
  'silty',
  'latosol',
  'argisol',
  'terraRoxa',
  'massape',
  'alluvial',
  'terraVegetal',
  'pottingMix',
  'wormCastings',
  'succulentMix',
  'coconutFiber',
  'manure',
};

const _defaultSoilId = 'pottingMix';

/// Longest side, in pixels, of each photo size `get_photos` offers. Large
/// is the most Claude looks at without downscaling it itself.
const _photoSizes = {'small': 512, 'medium': 1024, 'large': 1568};
const _maxPhotosPerCall = 6;
const _shortCodeLength = 6;

const mcpInstructions = '''
Polypodium is a plant-care journal. This connection is bound to one garden
(workspace): every tool reads or writes only that garden. Plants belong to a
species and may sit in a location and in a pot; entries (watering,
fertilizer, observation...) form each plant's diary. Plants can be referred to
by id, by the 6-character short code printed on their labels, or by exact
nickname. Changes made here reach the members' devices on their next sync.''';

/// The MCP tools over one garden's synced data. Reads come from the
/// materialised `mat_*` rows; writes are built in the same payload shape the
/// app syncs and go through [ISyncRepository.receiveChanges], so devices
/// pull them like any other peer's edits.
List<McpTool> polypodiumTools({
  required IGardenStore store,
  required ISyncRepository sync,
  ForecastLookup? forecast,
  PhotoLoader? photos,
  DateTime Function() clock = DateTime.now,
}) {
  final tools = _Tools(store, sync, forecast, photos, clock);
  return [
    McpTool(
      name: 'garden_overview',
      title: 'Garden overview',
      description: 'Summary of the garden: counts of plants by status, '
          'species, locations and pots; active plants due for watering or '
          'for a pesticide reapplication; and the latest entries.',
      inputSchema: _schema({}),
      run: _json(tools.overview),
    ),
    McpTool(
      name: 'list_plants',
      title: 'List plants',
      description: 'Lists plants with their species, location, pot and '
          'watering state. Filters combine. Defaults to active plants.',
      inputSchema: _schema({
        'query': _string('Matches nickname, species names or short code.'),
        'status': _enum([..._plantStatuses, 'any'], 'Default: active.'),
        'locationId': _string('Only plants in this location.'),
        'potId': _string('Only plants in this pot.'),
        'speciesId': _string('Only plants of this species.'),
        'needsWater':
            _boolean('Only plants whose watering is due today or overdue.'),
        'limit': _integer('Max plants returned (default 50, max 200).'),
        'offset': _integer('Plants to skip, for paging.'),
      }),
      run: _json(tools.listPlants),
    ),
    McpTool(
      name: 'get_plant',
      title: 'Get plant',
      description: 'Full details of one plant: species care sheet, soil, '
          'location, pot, reminders, its most recent entries, how many photos '
          'it has and, by default, its cover photo as an image. Use '
          'list_plant_photos and get_photos for the others.',
      inputSchema: _schema({
        'plant': _string('Plant id, short code or exact nickname.'),
        'entriesLimit': _integer('Recent entries to include (default 20).'),
        if (photos != null)
          'includeCoverImage':
              _boolean('Attach the cover photo (default true).'),
      }, required: ['plant']),
      run: tools.getPlant,
    ),
    McpTool(
      name: 'list_entries',
      title: 'List entries',
      description: 'Diary entries, newest first. Without a plant, covers the '
          'whole garden.',
      inputSchema: _schema({
        'plant': _string('Plant id, short code or exact nickname.'),
        'type': _enum(_entryTypes, 'Only entries of this type.'),
        'from': _date('First day included (YYYY-MM-DD).'),
        'until': _date('Last day included (YYYY-MM-DD).'),
        'limit': _integer('Max entries (default 50, max 500).'),
      }),
      run: _json(tools.listEntries),
    ),
    McpTool(
      name: 'list_species',
      title: 'List species',
      description: 'Species catalog with care data and how many plants use '
          'each.',
      inputSchema: _schema({'query': _string('Matches popular or scientific '
          'name.')}),
      run: _json(tools.listSpecies),
    ),
    McpTool(
      name: 'list_locations',
      title: 'List locations',
      description: 'Locations (rooms, beds, balconies...) with coordinates '
          'and plant/pot counts.',
      inputSchema: _schema({}),
      run: _json(tools.listLocations),
    ),
    McpTool(
      name: 'list_pots',
      title: 'List pots',
      description: 'Pots and planters, each with the plants in it.',
      inputSchema: _schema({
        'locationId': _string('Only pots in this location.'),
      }),
      run: _json(tools.listPots),
    ),
    McpTool(
      name: 'list_soils',
      title: 'List soils',
      description: 'Soil types and substrates known to the garden.',
      inputSchema: _schema({}),
      run: _json(tools.listSoils),
    ),
    McpTool(
      name: 'list_defensivos',
      title: 'List pesticides',
      description: 'Pesticide/defensive products catalog (defensivos), with '
          'category and withholding period (carência) in days.',
      inputSchema: _schema({}),
      run: _json(tools.listDefensivos),
    ),
    if (forecast != null)
      McpTool(
        name: 'get_weather',
        title: 'Weather forecast',
        description: 'Forecast and recent weather for a location with '
            'coordinates (only when the server admin enabled weather).',
        inputSchema: _schema({
          'location': _string('Location id or exact name.'),
          'days': _integer('Past days of daily history (default 3).'),
        }, required: ['location']),
        run: _json(tools.weather),
      ),
    if (photos != null) ...[
      McpTool(
        name: 'list_plant_photos',
        title: 'List plant photos',
        description: 'A plant\'s photos, newest first, with the entry each '
            'belongs to (date, type, note). Fetch the images with '
            'get_photos.',
        inputSchema: _schema({
          'plant': _string('Plant id, short code or exact nickname.'),
          'limit': _integer('Max photos (default 50, max 500).'),
        }, required: ['plant']),
        run: _json(tools.listPlantPhotos),
      ),
      McpTool(
        name: 'get_photos',
        title: 'Get photos',
        description: 'Returns up to $_maxPhotosPerCall photos as images, '
            'scaled down: small (512 px), medium (1024 px, default) or large '
            '(1568 px) on the longest side. Photo ids come from '
            'list_plant_photos, get_plant or list_entries.',
        inputSchema: _schema({
          'photoIds': {
            'type': 'array',
            'items': {'type': 'string'},
            'minItems': 1,
            'maxItems': _maxPhotosPerCall,
          },
          'size': _enum(_photoSizes.keys.toList(), 'Default: medium.'),
        }, required: ['photoIds']),
        run: tools.getPhotos,
      ),
    ],
    McpTool(
      name: 'add_entry',
      title: 'Add entry',
      description: 'Records a diary entry (watering, fertilizer, '
          'observation...) for one or more plants, or for every active plant '
          'in a pot. numericValue: irrigation intensity 1-3 (light, moderate, '
          'heavy), height in cm, chlorosis/pest severity, observation health '
          'score. details: the type\'s structured fields, e.g. pest '
          '{"pestType"}, fertilizer {"products":[{"name","dose"}]}, '
          'pesticide {"products":[{"defensivoId","name","dose"}],'
          '"recurrenceDays"}, pruning {"reason"}, harvest '
          '{"quantity","unit"}.',
      inputSchema: _schema({
        'plants': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Plant ids, short codes or exact nicknames.',
        },
        'potId': _string('Record for every active plant in this pot instead.'),
        'type': _enum(_entryTypes, 'Entry type.'),
        'date': _string('YYYY-MM-DD or ISO-8601 date-time. Default: now.'),
        'note': _string('Free text.'),
        'numericValue': {'type': 'number'},
        'details': {'type': 'object'},
      }, required: ['type']),
      writes: true,
      run: _json(tools.addEntry),
    ),
    McpTool(
      name: 'delete_entry',
      title: 'Delete entry',
      description: 'Deletes a diary entry (and its photos) by id.',
      inputSchema: _schema({
        'entryId': _string('Entry id.'),
      }, required: ['entryId']),
      writes: true,
      destructive: true,
      run: _json(tools.deleteEntry),
    ),
    McpTool(
      name: 'create_plant',
      title: 'Create plant',
      description: 'Adds a plant. A plant put in a pot takes the pot\'s '
          'location unless one is given.',
      inputSchema: _schema({
        'nickname': _string('Name shown in the app.'),
        'speciesId': _string('Species id (see list_species).'),
        'soilId': _string('Soil id (see list_soils). Default: pottingMix.'),
        'locationId': _string('Location id.'),
        'potId': _string('Pot id.'),
        'irrigationFrequencyDays': _integer('Overrides the species default.'),
        'acquisitionDate': _date('Default: today.'),
        'parentPlantId': _string('Plant it was propagated from.'),
      }, required: ['nickname', 'speciesId']),
      writes: true,
      run: _json(tools.createPlant),
    ),
    McpTool(
      name: 'update_plant',
      title: 'Update plant',
      description: 'Changes a plant. Only the given fields change; pass an '
          'empty string to clear locationId, potId or '
          'irrigationFrequencyDays (back to the species default). Moving into '
          'a pot also moves the plant to the pot\'s location unless a '
          'location is given.',
      inputSchema: _schema({
        'plant': _string('Plant id, short code or exact nickname.'),
        'nickname': _string('New name.'),
        'status': _enum(_plantStatuses, 'New status.'),
        'speciesId': _string('Species id.'),
        'soilId': _string('Soil id.'),
        'locationId': _string('Location id, or "" for none.'),
        'potId': _string('Pot id, or "" for none.'),
        'irrigationFrequencyDays': {
          'type': ['integer', 'string'],
          'description': 'Days between waterings, or "" for the species '
              'default.',
        },
      }, required: ['plant']),
      writes: true,
      run: _json(tools.updatePlant),
    ),
    McpTool(
      name: 'create_species',
      title: 'Create species',
      description: 'Adds a species to the catalog.',
      inputSchema: _schema({
        'popularName': _string('Common name.'),
        'scientificName': _string('Scientific name.'),
        'defaultIrrigationFrequencyDays':
            _integer('Days between waterings.'),
        'light': _enum(_lightValues, 'Light requirement.'),
        'humidity': _enum(_humidityValues, 'Humidity requirement.'),
        'petToxicity': _enum(_petToxicityValues, 'Default: unknown.'),
        'floweringMonths': {
          'type': 'array',
          'items': {'type': 'integer', 'minimum': 1, 'maximum': 12},
        },
        'careNotes': _string('Free text care notes.'),
        'recommendedSoilIds': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      }, required: ['popularName', 'scientificName']),
      writes: true,
      run: _json(tools.createSpecies),
    ),
    McpTool(
      name: 'create_location',
      title: 'Create location',
      description: 'Adds a location. Coordinates enable weather forecasts.',
      inputSchema: _schema({
        'name': _string('Location name.'),
        'description': _string('Free text.'),
        'latitude': {'type': 'number'},
        'longitude': {'type': 'number'},
      }, required: ['name']),
      writes: true,
      run: _json(tools.createLocation),
    ),
  ];
}

class _Tools {
  _Tools(this._store, this._sync, this._forecast, this._photos, this._clock);
  final IGardenStore _store;
  final ISyncRepository _sync;
  final ForecastLookup? _forecast;
  final PhotoLoader? _photos;
  final DateTime Function() _clock;

  // -- reads -----------------------------------------------------------------

  Future<Map<String, Object?>> overview(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final today = _today();
    final byStatus = <String, int>{};
    for (final p in g.plants) {
      final status = _status(p);
      byStatus[status] = (byStatus[status] ?? 0) + 1;
    }
    final active = g.plants.where((p) => _status(p) == 'active');
    final summaries = [for (final p in active) g.summary(p, today)];
    final latest = await _store.entries(grant.gardenId, limit: 10);
    return {
      'garden': {'id': grant.gardenId, 'name': grant.gardenName},
      'canWrite': grant.canWrite,
      'today': _day(today),
      'plantsByStatus': byStatus,
      'species': g.species.length,
      'locations': g.locations.length,
      'pots': g.pots.length,
      'needsWater': [
        for (final s in summaries)
          if (s['needsWater'] == true) s,
      ],
      'pesticideDue': [
        for (final p in active)
          if (g.pesticideDue(p, today) case final due?)
            {'id': p.id, 'nickname': p.payload['nickname'], 'dueDate': due},
      ],
      'latestEntries': [for (final e in latest) g.entry(e)],
    };
  }

  Future<Map<String, Object?>> listPlants(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final today = _today();
    final status = _optEnum(args, 'status', [..._plantStatuses, 'any']) ??
        'active';
    final query = _optString(args, 'query')?.toLowerCase();
    final locationId = _optString(args, 'locationId');
    final potId = _optString(args, 'potId');
    final speciesId = _optString(args, 'speciesId');
    final needsWater = _optBool(args, 'needsWater');
    final limit = _optInt(args, 'limit', min: 1, max: 200) ?? 50;
    final offset = _optInt(args, 'offset', min: 0) ?? 0;

    final matches = <Map<String, Object?>>[];
    for (final p in g.plants) {
      if (status != 'any' && _status(p) != status) continue;
      if (locationId != null && p.payload['locationId'] != locationId) continue;
      if (potId != null && p.payload['potId'] != potId) continue;
      if (speciesId != null && p.payload['speciesId'] != speciesId) continue;
      if (query != null && !g.plantMatches(p, query)) continue;
      final summary = g.summary(p, today);
      if (needsWater != null && summary['needsWater'] != needsWater) continue;
      matches.add(summary);
    }
    matches.sort((a, b) => (a['nickname'] as String)
        .toLowerCase()
        .compareTo((b['nickname'] as String).toLowerCase()));
    return {
      'total': matches.length,
      'plants': matches.skip(offset).take(limit).toList(),
    };
  }

  Future<McpToolResult> getPlant(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final plant = g.resolvePlant(_reqString(args, 'plant'));
    final entriesLimit = _optInt(args, 'entriesLimit', min: 0, max: 200) ?? 20;
    final p = plant.payload;
    final species = g.speciesById[p['speciesId']];
    final soilId = (p['soilId'] ?? p['soilType']) as String?;
    final soil = g.soilsById[soilId];
    final reminders = await _store.list(grant.gardenId, 'reminder');
    final entries = entriesLimit == 0
        ? <StoredEntity>[]
        : await _store.entries(grant.gardenId,
            plantIds: {plant.id}, limit: entriesLimit);
    final parent = g.plantsById[p['parentPlantId']];
    final photos = await _store.photos(grant.gardenId, plantId: plant.id);
    final cover = _coverOf(photos, p['coverPhotoId'] as String?);
    final loader = _photos;
    final coverImage = cover == null ||
            loader == null ||
            _optBool(args, 'includeCoverImage') == false
        ? null
        : await loader(grant.gardenId, cover.photoKey, _photoSizes['small']!);
    return McpToolResult({
      ...g.summary(plant, _today()),
      'acquisitionDate': p['acquisitionDate'],
      'statusChangedAt': p['statusChangedAt'],
      'soil': soilId == null
          ? null
          : {'id': soilId, 'name': soil?.payload['name'] ?? soilId},
      'parentPlant': parent == null
          ? null
          : {'id': parent.id, 'nickname': parent.payload['nickname']},
      'lastPesticideAppliedAt': p['lastPesticideAppliedAt'],
      'pesticideReapplicationDays': p['pesticideReapplicationDays'],
      'pesticideDueDate': g.pesticideDue(plant, _today()),
      'speciesCare': species == null ? null : _speciesView(species),
      'reminders': [
        for (final r in reminders)
          if (r.payload['plantId'] == plant.id)
            {
              'id': r.id,
              'entryType': r.payload['entryType'],
              'intervalDays': r.payload['intervalDays'],
              'enabled': r.payload['enabled'] ?? true,
            },
      ],
      'recentEntries': [for (final e in entries) g.entry(e)],
      'photoCount': photos.length,
      'coverPhoto': cover == null ? null : _photoView(cover),
      'coverImageAttached': coverImage != null,
    }, images: [if (coverImage != null) coverImage]);
  }

  Future<Map<String, Object?>> listPlantPhotos(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final plant = g.resolvePlant(_reqString(args, 'plant'));
    final photos = await _store.photos(grant.gardenId,
        plantId: plant.id,
        limit: _optInt(args, 'limit', min: 1, max: 500) ?? 50);
    final all = await _store.photos(grant.gardenId, plantId: plant.id);
    final cover = _coverOf(all, plant.payload['coverPhotoId'] as String?);
    return {
      'plant': {'id': plant.id, 'nickname': plant.payload['nickname']},
      'total': all.length,
      'photos': [
        for (final photo in photos)
          {..._photoView(photo), 'isCover': photo.id == cover?.id},
      ],
    };
  }

  Future<McpToolResult> getPhotos(
      McpGrant grant, Map<String, Object?> args) async {
    final ids = _optStringList(args, 'photoIds') ?? const [];
    if (ids.isEmpty) throw const McpToolError('photoIds is required');
    if (ids.length > _maxPhotosPerCall) {
      throw const McpToolError(
          'at most $_maxPhotosPerCall photos per call');
    }
    final maxSide =
        _photoSizes[_optEnum(args, 'size', _photoSizes.keys.toList()) ??
            'medium']!;
    final found = {
      for (final ref in await _store.photos(grant.gardenId, photoIds: ids))
        ref.id: ref,
    };
    final unique = ids.toSet().toList();
    // Each photo is shrunk in its own isolate: load them side by side.
    final loaded = await Future.wait([
      for (final id in unique)
        if (found[id] case final ref?)
          _photos!(grant.gardenId, ref.photoKey, maxSide)
        else
          Future<McpImage?>.value(),
    ]);
    final images = <McpImage>[];
    final returned = <Map<String, Object?>>[];
    final missing = <String>[];
    for (var i = 0; i < unique.length; i++) {
      final id = unique[i];
      final ref = found[id];
      final image = loaded[i];
      if (image == null) {
        missing.add(id);
      } else {
        images.add(image);
        returned.add(_photoView(ref!));
      }
    }
    if (images.isEmpty) {
      throw McpToolError('no photo found for: ${missing.join(', ')}');
    }
    return McpToolResult({
      // Same order as the images that follow.
      'photos': returned,
      if (missing.isNotEmpty) 'notFound': missing,
    }, images: images);
  }

  Future<Map<String, Object?>> listEntries(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final plantRef = _optString(args, 'plant');
    final plant = plantRef == null ? null : g.resolvePlant(plantRef);
    final entries = await _store.entries(
      grant.gardenId,
      plantIds: plant == null ? null : {plant.id},
      type: _optEnum(args, 'type', _entryTypes),
      from: _optDate(args, 'from'),
      until: _optDate(args, 'until'),
      limit: _optInt(args, 'limit', min: 1, max: 500) ?? 50,
    );
    return {
      'entries': [for (final e in entries) g.entry(e)],
    };
  }

  Future<Map<String, Object?>> listSpecies(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final query = _optString(args, 'query')?.toLowerCase();
    final counts = <Object?, int>{};
    for (final p in g.plants) {
      counts[p.payload['speciesId']] = (counts[p.payload['speciesId']] ?? 0) + 1;
    }
    final species = [
      for (final s in g.species)
        if (query == null ||
            '${s.payload['popularName']} ${s.payload['scientificName']}'
                .toLowerCase()
                .contains(query))
          {..._speciesView(s), 'plants': counts[s.id] ?? 0},
    ]..sort((a, b) => '${a['popularName']}'
        .toLowerCase()
        .compareTo('${b['popularName']}'.toLowerCase()));
    return {'species': species};
  }

  Future<Map<String, Object?>> listLocations(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final locations = [
      for (final l in g.locations)
        {
          'id': l.id,
          'name': l.payload['name'],
          'description': l.payload['description'],
          'latitude': l.payload['latitude'],
          'longitude': l.payload['longitude'],
          'activePlants': g.plants
              .where((p) =>
                  p.payload['locationId'] == l.id && _status(p) == 'active')
              .length,
          'pots': g.pots.where((p) => p.payload['locationId'] == l.id).length,
        },
    ]..sort(_byName);
    return {'locations': locations};
  }

  Future<Map<String, Object?>> listPots(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final locationId = _optString(args, 'locationId');
    final pots = [
      for (final pot in g.pots)
        if (locationId == null || pot.payload['locationId'] == locationId)
          {
            'id': pot.id,
            'name': pot.payload['name'],
            'shortCode': _shortCode(pot.id),
            'kind': pot.payload['kind'],
            'diameterCm': pot.payload['diameterCm'],
            'material': pot.payload['material'],
            'notes': pot.payload['notes'],
            'location': g.locationRef(pot.payload['locationId']),
            'plants': [
              for (final p in g.plants)
                if (p.payload['potId'] == pot.id && _status(p) == 'active')
                  {'id': p.id, 'nickname': p.payload['nickname']},
            ],
          },
    ]..sort(_byName);
    return {'pots': pots};
  }

  Future<Map<String, Object?>> listSoils(
      McpGrant grant, Map<String, Object?> args) async {
    final soils = await _store.list(grant.gardenId, 'soil');
    return {
      'soils': [
        for (final s in soils)
          {
            'id': s.id,
            'name': s.payload['name'],
            'composition': s.payload['composition'],
          },
      ]..sort(_byName),
    };
  }

  Future<Map<String, Object?>> listDefensivos(
      McpGrant grant, Map<String, Object?> args) async {
    final products = await _store.list(grant.gardenId, 'defensivo');
    return {
      'defensivos': [
        for (final d in products)
          {
            'id': d.id,
            'name': d.payload['name'],
            'category': d.payload['category'] == 'custom'
                ? d.payload['customCategoryLabel']
                : d.payload['category'],
            'composition': d.payload['composition'],
            'carenciaDays': d.payload['carenciaDays'],
          },
      ]..sort(_byName),
    };
  }

  Future<Map<String, Object?>> weather(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final location = g.resolveLocation(_reqString(args, 'location'));
    final result = await _forecast!(grant.gardenId, location.id,
        days: _optInt(args, 'days', min: 0, max: 60) ?? 3);
    final error = result.error;
    if (error != null) throw McpToolError(error.message);
    return {'location': location.payload['name'], ...result.body!};
  }

  // -- writes ----------------------------------------------------------------

  Future<Map<String, Object?>> addEntry(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final type = _optEnum(args, 'type', _entryTypes) ??
        (throw const McpToolError('type is required'));
    final potId = _optString(args, 'potId');
    final refs = _optStringList(args, 'plants');

    final List<StoredEntity> plants;
    if (potId != null) {
      if (refs != null) {
        throw const McpToolError('give either plants or potId, not both');
      }
      if (g.potsById[potId] == null) throw McpToolError('pot not found: $potId');
      if (!_potEntryTypes.contains(type)) {
        throw McpToolError('$type can\'t be recorded for a whole pot; '
            'allowed: ${_potEntryTypes.join(', ')}');
      }
      plants = [
        for (final p in g.plants)
          if (p.payload['potId'] == potId && _status(p) == 'active') p,
      ];
      if (plants.isEmpty) {
        throw const McpToolError('the pot has no active plants');
      }
    } else {
      if (refs == null || refs.isEmpty) {
        throw const McpToolError('plants or potId is required');
      }
      plants = {for (final r in refs) g.resolvePlant(r)}.toList();
    }

    final details = args['details'];
    if (details != null && details is! Map) {
      throw const McpToolError('details must be an object');
    }
    final numeric = args['numericValue'];
    if (numeric != null && numeric is! num) {
      throw const McpToolError('numericValue must be a number');
    }
    final now = _clock().toUtc();
    final date = _entryDate(_optString(args, 'date'), now);
    final note = _optString(args, 'note');

    final changes = [
      for (final p in plants)
        _change(grant, 'entry', _newId(), now, {
          'plantId': p.id,
          'date': date,
          'photoPath': null,
          'note': note,
          'type': type,
          'numericValue': (numeric as num?)?.toDouble(),
          'extraData': details == null || (details as Map).isEmpty
              ? null
              : jsonEncode(details),
          'createdAt': now.toIso8601String(),
        }),
    ];
    await _sync.receiveChanges(
        grant.gardenId, grant.userId, grant.deviceId, changes);
    return {
      'created': [
        for (var i = 0; i < plants.length; i++)
          {
            'entryId': changes[i].entityId,
            'plantId': plants[i].id,
            'nickname': plants[i].payload['nickname'],
          },
      ],
      'type': type,
      'date': date,
    };
  }

  Future<Map<String, Object?>> deleteEntry(
      McpGrant grant, Map<String, Object?> args) async {
    final id = _reqString(args, 'entryId');
    final entry = await _store.get(grant.gardenId, 'entry', id);
    if (entry == null) throw McpToolError('entry not found: $id');
    final now = _clock().toUtc();
    // Tombstones keep the full payload: devices parse it even for a delete.
    final changes = [_change(grant, 'entry', id, now, entry.payload, now)];
    for (final photo in await _store.list(grant.gardenId, 'entry_photo')) {
      if (photo.payload['entryId'] == id) {
        changes
            .add(_change(grant, 'entry_photo', photo.id, now, photo.payload, now));
      }
    }

    // Devices recompute a plant's last watering/pesticide when they pull a
    // new entry, not a deleted one, so refresh the plant here.
    final type = entry.payload['type'];
    final plantId = entry.payload['plantId'] as String?;
    final plant = plantId == null
        ? null
        : await _store.get(grant.gardenId, 'plant', plantId);
    if (plant != null && (type == 'irrigation' || type == 'pesticide')) {
      final remaining = (await _store.entries(grant.gardenId,
              plantIds: {plant.id}, type: type as String, limit: 2))
          .where((e) => e.id != id)
          .toList();
      final last = remaining.isEmpty ? null : remaining.first;
      final payload = {...plant.payload};
      if (type == 'irrigation') {
        payload['lastIrrigatedAt'] = last?.payload['date'];
      } else {
        payload['lastPesticideAppliedAt'] = last?.payload['date'];
        payload['pesticideReapplicationDays'] =
            _recurrenceDays(last?.payload['extraData']);
      }
      changes.add(_change(grant, 'plant', plant.id, now, payload));
    }

    await _sync.receiveChanges(
        grant.gardenId, grant.userId, grant.deviceId, changes);
    return {'deleted': id};
  }

  Future<Map<String, Object?>> createPlant(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final nickname = _reqString(args, 'nickname');
    final speciesId = _reqString(args, 'speciesId');
    if (g.speciesById[speciesId] == null) {
      throw McpToolError('species not found: $speciesId');
    }
    final soilId = _optString(args, 'soilId') ?? _defaultSoilId;
    g.requireSoil(soilId);
    final potId = _optString(args, 'potId');
    final pot = potId == null ? null : g.requirePot(potId);
    final locationId =
        _optString(args, 'locationId') ?? pot?.payload['locationId'] as String?;
    if (locationId != null) g.requireLocation(locationId);
    final parentId = _optString(args, 'parentPlantId');
    if (parentId != null && g.plantsById[parentId] == null) {
      throw McpToolError('parent plant not found: $parentId');
    }

    final now = _clock().toUtc();
    final id = _newId();
    final payload = <String, Object?>{
      'id': id,
      'speciesId': speciesId,
      'nickname': nickname,
      'soilId': soilId,
      'irrigationFrequencyDays':
          _optInt(args, 'irrigationFrequencyDays', min: 1, max: 3650),
      'acquisitionDate':
          _dayStart(_optDate(args, 'acquisitionDate') ?? _day(_today())),
      'locationId': locationId,
      'lastIrrigatedAt': null,
      'lastPesticideAppliedAt': null,
      'pesticideReapplicationDays': null,
      'status': 'active',
      'statusChangedAt': null,
      'parentPlantId': parentId,
      'coverPhotoId': null,
      'potId': potId,
      'createdAt': now.toIso8601String(),
    };
    await _sync.receiveChanges(grant.gardenId, grant.userId, grant.deviceId,
        [_change(grant, 'plant', id, now, payload)]);
    return {'id': id, 'shortCode': _shortCode(id), 'nickname': nickname};
  }

  Future<Map<String, Object?>> updatePlant(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final plant = g.resolvePlant(_reqString(args, 'plant'));
    final payload = {...plant.payload};
    final now = _clock().toUtc();
    final changed = <String>[];

    void set(String key, Object? value) {
      if (payload[key] != value) changed.add(key);
      payload[key] = value;
    }

    if (_optString(args, 'nickname') case final nickname?) {
      set('nickname', nickname);
    }
    if (_optEnum(args, 'status', _plantStatuses) case final status?) {
      if (_status(plant) != status) {
        set('status', status);
        set('statusChangedAt', now.toIso8601String());
      }
    }
    if (_optString(args, 'speciesId') case final speciesId?) {
      if (g.speciesById[speciesId] == null) {
        throw McpToolError('species not found: $speciesId');
      }
      set('speciesId', speciesId);
    }
    if (_optString(args, 'soilId') case final soilId?) {
      g.requireSoil(soilId);
      payload.remove('soilType');
      set('soilId', soilId);
    }
    if (args.containsKey('potId')) {
      final potId = _optString(args, 'potId'); // "" clears it
      if (potId != null) {
        final pot = g.requirePot(potId);
        if (!args.containsKey('locationId')) {
          set('locationId', pot.payload['locationId']);
        }
      }
      set('potId', potId);
    }
    if (args.containsKey('locationId')) {
      final locationId = _optString(args, 'locationId');
      if (locationId != null) g.requireLocation(locationId);
      set('locationId', locationId);
    }
    if (args.containsKey('irrigationFrequencyDays')) {
      final raw = args['irrigationFrequencyDays'];
      set(
          'irrigationFrequencyDays',
          raw == '' || raw == null
              ? null
              : _optInt(args, 'irrigationFrequencyDays', min: 1, max: 3650));
    }

    if (changed.isEmpty) {
      return {'id': plant.id, 'changed': <String>[]};
    }
    final applied = await _sync.receiveChanges(grant.gardenId, grant.userId,
        grant.deviceId, [_change(grant, 'plant', plant.id, now, payload)]);
    if (applied == 0) {
      throw const McpToolError(
          'not saved: the plant has a newer edit; read it again and retry');
    }
    return {'id': plant.id, 'changed': changed.toSet().toList()};
  }

  Future<Map<String, Object?>> createSpecies(
      McpGrant grant, Map<String, Object?> args) async {
    final g = await _Snapshot.load(_store, grant.gardenId);
    final soils = _optStringList(args, 'recommendedSoilIds') ?? const [];
    soils.forEach(g.requireSoil);
    final months = args['floweringMonths'];
    final floweringMonths = <int>{};
    if (months != null) {
      if (months is! List ||
          months.any((m) => m is! int || m < 1 || m > 12)) {
        throw const McpToolError('floweringMonths must be months 1-12');
      }
      floweringMonths.addAll(months.cast<int>());
    }
    final now = _clock().toUtc();
    final id = _newId();
    final payload = <String, Object?>{
      'id': id,
      'scientificName': _reqString(args, 'scientificName'),
      'popularName': _reqString(args, 'popularName'),
      'defaultIrrigationFrequencyDays':
          _optInt(args, 'defaultIrrigationFrequencyDays', min: 1, max: 3650),
      'recommendedSoilIds': soils,
      'light': _optEnum(args, 'light', _lightValues),
      'humidity': _optEnum(args, 'humidity', _humidityValues),
      'petToxicity':
          _optEnum(args, 'petToxicity', _petToxicityValues) ?? 'unknown',
      'floweringMonths': floweringMonths.toList()..sort(),
      'careNotes': _optString(args, 'careNotes'),
      'createdAt': now.toIso8601String(),
    };
    await _sync.receiveChanges(grant.gardenId, grant.userId, grant.deviceId,
        [_change(grant, 'species', id, now, payload)]);
    return {'id': id, 'popularName': payload['popularName']};
  }

  Future<Map<String, Object?>> createLocation(
      McpGrant grant, Map<String, Object?> args) async {
    final lat = args['latitude'];
    final lon = args['longitude'];
    if ((lat == null) != (lon == null)) {
      throw const McpToolError('give both latitude and longitude, or neither');
    }
    if (lat != null &&
        (lat is! num ||
            lon is! num ||
            lat.abs() > 90 ||
            lon.abs() > 180)) {
      throw const McpToolError('invalid coordinates');
    }
    final now = _clock().toUtc();
    final id = _newId();
    final payload = <String, Object?>{
      'id': id,
      'name': _reqString(args, 'name'),
      'description': _optString(args, 'description'),
      'latitude': (lat as num?)?.toDouble(),
      'longitude': (lon as num?)?.toDouble(),
      'createdAt': now.toIso8601String(),
    };
    await _sync.receiveChanges(grant.gardenId, grant.userId, grant.deviceId,
        [_change(grant, 'location', id, now, payload)]);
    return {'id': id, 'name': payload['name']};
  }

  // -- helpers ---------------------------------------------------------------

  DateTime _today() {
    final now = _clock();
    return DateTime(now.year, now.month, now.day);
  }

  /// An entry `date`: a bare day becomes noon of that day (no offset, like
  /// the app's local times), so it stays on that day in any time zone.
  static String _entryDate(String? raw, DateTime now) {
    if (raw == null) return now.toIso8601String();
    if (_dayPattern.hasMatch(raw)) {
      _parseDay(raw, 'date');
      return '${raw}T12:00:00.000';
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw const McpToolError('date must be YYYY-MM-DD or ISO-8601');
    }
    return parsed.toIso8601String();
  }

  static String _dayStart(String day) => '${day}T00:00:00.000';

  static SyncChange _change(McpGrant grant, String type, String id,
          DateTime now, Map<String, Object?> payload,
          [DateTime? deletedAt]) =>
      SyncChange(
        entityType: type,
        entityId: id,
        payload: payload,
        updatedAt: now,
        deletedAt: deletedAt,
        deviceId: grant.deviceId,
        rev: 0,
      );

  static String _newId() => const Uuid().v4();
}

/// One garden's catalog and plants, loaded once per tool call.
class _Snapshot {
  _Snapshot._(this.plants, this.species, this.locations, this.pots,
      this.soils, this.lastWatered)
      : plantsById = {for (final p in plants) p.id: p},
        speciesById = {for (final s in species) s.id: s},
        locationsById = {for (final l in locations) l.id: l},
        potsById = {for (final p in pots) p.id: p},
        soilsById = {for (final s in soils) s.id: s};

  static Future<_Snapshot> load(IGardenStore store, String gardenId) async {
    final results = await Future.wait([
      store.list(gardenId, 'plant'),
      store.list(gardenId, 'species'),
      store.list(gardenId, 'location'),
      store.list(gardenId, 'bed'),
      store.list(gardenId, 'soil'),
    ]);
    return _Snapshot._(results[0], results[1], results[2], results[3],
        results[4], await store.lastEntryDates(gardenId, 'irrigation'));
  }

  final List<StoredEntity> plants;
  final List<StoredEntity> species;
  final List<StoredEntity> locations;
  final List<StoredEntity> pots;
  final List<StoredEntity> soils;

  /// Latest irrigation entry date per plant id.
  final Map<String, String> lastWatered;

  final Map<String, StoredEntity> plantsById;
  final Map<String, StoredEntity> speciesById;
  final Map<String, StoredEntity> locationsById;
  final Map<String, StoredEntity> potsById;
  final Map<String, StoredEntity> soilsById;

  StoredEntity resolvePlant(String ref) {
    final trimmed = ref.trim();
    if (plantsById[trimmed] case final p?) return p;
    final code = trimmed.replaceFirst('#', '').toUpperCase();
    if (code.length == _shortCodeLength) {
      final byCode = plants.where((p) => _shortCode(p.id) == code).toList();
      if (byCode.length == 1) return byCode.first;
    }
    final byName = plants
        .where((p) =>
            '${p.payload['nickname']}'.toLowerCase() == trimmed.toLowerCase())
        .toList();
    if (byName.length == 1) return byName.first;
    if (byName.length > 1) {
      throw McpToolError('several plants are named "$trimmed": '
          '${byName.map((p) => '${_shortCode(p.id)} (${_status(p)})').join(', ')}'
          '; use the short code');
    }
    throw McpToolError('plant not found: $ref');
  }

  StoredEntity resolveLocation(String ref) {
    final trimmed = ref.trim();
    if (locationsById[trimmed] case final l?) return l;
    final byName = locations
        .where((l) =>
            '${l.payload['name']}'.toLowerCase() == trimmed.toLowerCase())
        .toList();
    if (byName.length == 1) return byName.first;
    throw McpToolError(byName.isEmpty
        ? 'location not found: $ref'
        : 'several locations are named "$trimmed"; use the id');
  }

  void requireSoil(String id) {
    if (soilsById[id] == null && !_seededSoilIds.contains(id)) {
      throw McpToolError('soil not found: $id');
    }
  }

  StoredEntity requirePot(String id) =>
      potsById[id] ?? (throw McpToolError('pot not found: $id'));

  void requireLocation(String id) {
    if (locationsById[id] == null) throw McpToolError('location not found: $id');
  }

  bool plantMatches(StoredEntity p, String query) {
    final species = speciesById[p.payload['speciesId']]?.payload;
    final text = '${p.payload['nickname']} ${species?['popularName'] ?? ''} '
            '${species?['scientificName'] ?? ''}'
        .toLowerCase();
    if (text.contains(query)) return true;
    final code = query.replaceFirst('#', '');
    return code.length >= 4 && _shortCode(p.id).toLowerCase().startsWith(code);
  }

  Map<String, Object?>? locationRef(Object? id) {
    final l = locationsById[id];
    return l == null ? null : {'id': l.id, 'name': l.payload['name']};
  }

  /// A plant's list view, with the watering state the app would show.
  Map<String, Object?> summary(StoredEntity plant, DateTime today) {
    final p = plant.payload;
    final species = speciesById[p['speciesId']]?.payload;
    final pot = potsById[p['potId']];
    final frequency = (p['irrigationFrequencyDays'] ??
        species?['defaultIrrigationFrequencyDays']) as int?;
    final last = _latest(p['lastIrrigatedAt'] as String?, lastWatered[plant.id]);
    final daysSince = last == null ? null : _daysBetween(last, today);
    final status = _status(plant);
    return {
      'id': plant.id,
      'shortCode': _shortCode(plant.id),
      'nickname': p['nickname'],
      'status': status,
      'species': species == null
          ? null
          : {
              'id': p['speciesId'],
              'popularName': species['popularName'],
              'scientificName': species['scientificName'],
            },
      'location': locationRef(p['locationId']),
      'pot': pot == null ? null : {'id': pot.id, 'name': pot.payload['name']},
      'irrigationFrequencyDays': frequency,
      'lastWateredAt': last,
      'daysSinceWatered': daysSince,
      'nextWateringDate': last == null || frequency == null
          ? null
          : _day(_dayOf(last).add(Duration(days: frequency))),
      'needsWater': status == 'active' &&
          frequency != null &&
          (daysSince == null || daysSince >= frequency),
    };
  }

  /// The day a pesticide reapplication falls due when it is today or past.
  String? pesticideDue(StoredEntity plant, DateTime today) {
    final applied = plant.payload['lastPesticideAppliedAt'] as String?;
    final days = plant.payload['pesticideReapplicationDays'] as int?;
    if (applied == null || days == null || DateTime.tryParse(applied) == null) {
      return null;
    }
    final due = _dayOf(applied).add(Duration(days: days));
    return due.isAfter(today) ? null : _day(due);
  }

  Map<String, Object?> entry(StoredEntity e) {
    final p = e.payload;
    final plant = plantsById[p['plantId']];
    Object? details;
    if (p['extraData'] case final String raw) {
      try {
        details = jsonDecode(raw);
      } on FormatException {
        details = raw;
      }
    }
    return {
      'id': e.id,
      'plant': {
        'id': p['plantId'],
        'nickname': plant?.payload['nickname'],
      },
      'type': p['type'],
      'date': p['date'],
      'note': p['note'],
      'numericValue': p['numericValue'],
      'details': details,
      'hasPhoto': p['photoKey'] != null,
    };
  }
}

/// The cover the app shows: the picked photo while it still exists, else
/// the newest entry's own photo (`coverPhotoIdOf` in the app).
PhotoRef? _coverOf(List<PhotoRef> photos, String? picked) {
  for (final p in photos) {
    if (p.id == picked) return p;
  }
  for (final p in photos) {
    if (p.id == p.entryId) return p;
  }
  return null;
}

Map<String, Object?> _photoView(PhotoRef p) => {
      'photoId': p.id,
      'entryId': p.entryId,
      'date': p.date,
      'entryType': p.entryType,
      'note': p.note,
    };

/// Adapts a tool that only returns JSON.
Future<McpToolResult> Function(McpGrant, Map<String, Object?>) _json(
        Future<Map<String, Object?>> Function(McpGrant, Map<String, Object?>)
            run) =>
    (grant, args) async => McpToolResult(await run(grant, args));

Map<String, Object?> _speciesView(StoredEntity s) => {
      'id': s.id,
      'popularName': s.payload['popularName'],
      'scientificName': s.payload['scientificName'],
      'defaultIrrigationFrequencyDays':
          s.payload['defaultIrrigationFrequencyDays'],
      'light': s.payload['light'],
      'humidity': s.payload['humidity'],
      'petToxicity': s.payload['petToxicity'],
      'floweringMonths': s.payload['floweringMonths'],
      'careNotes': s.payload['careNotes'],
    };

String _status(StoredEntity plant) =>
    _plantStatuses.contains(plant.payload['status'])
        ? plant.payload['status'] as String
        : 'active';

/// The app's `plantShortCode`: the first 6 hex digits of the id.
String _shortCode(String id) {
  final compact = id.replaceAll('-', '').toUpperCase();
  return compact.length <= _shortCodeLength
      ? compact
      : compact.substring(0, _shortCodeLength);
}

String? _latest(String? a, String? b) {
  final da = a == null ? null : DateTime.tryParse(a);
  final db = b == null ? null : DateTime.tryParse(b);
  if (da == null) return db == null ? null : b;
  if (db == null) return a;
  return db.isAfter(da) ? b : a;
}

/// The calendar day of an ISO date as written (the app's are local times).
DateTime _dayOf(String iso) {
  final d = DateTime.parse(iso);
  return DateTime(d.year, d.month, d.day);
}

int _daysBetween(String iso, DateTime today) =>
    today.difference(_dayOf(iso)).inHours ~/ 24;

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

int? _recurrenceDays(Object? extraData) {
  if (extraData is! String) return null;
  try {
    final decoded = jsonDecode(extraData);
    if (decoded is Map && decoded['recurrenceDays'] is num) {
      return (decoded['recurrenceDays'] as num).toInt();
    }
  } on FormatException {
    return null;
  }
  return null;
}

int _byName(Map<String, Object?> a, Map<String, Object?> b) =>
    '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase());

// -- argument parsing ---------------------------------------------------------

final _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

String _reqString(Map<String, Object?> args, String key) =>
    _optString(args, key) ?? (throw McpToolError('$key is required'));

String? _optString(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is! String) throw McpToolError('$key must be a string');
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

List<String>? _optStringList(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is! List || value.any((v) => v is! String)) {
    throw McpToolError('$key must be a list of strings');
  }
  return value.cast<String>();
}

bool? _optBool(Map<String, Object?> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is! bool) throw McpToolError('$key must be a boolean');
  return value;
}

int? _optInt(Map<String, Object?> args, String key,
    {int? min, int? max}) {
  final value = args[key];
  if (value == null) return null;
  final parsed = switch (value) {
    int v => v,
    double v when v == v.roundToDouble() => v.toInt(),
    String v => int.tryParse(v.trim()),
    _ => null,
  };
  if (parsed == null) throw McpToolError('$key must be an integer');
  if ((min != null && parsed < min) || (max != null && parsed > max)) {
    throw McpToolError('$key must be between ${min ?? '-'} and ${max ?? '-'}');
  }
  return parsed;
}

String? _optEnum(Map<String, Object?> args, String key, List<String> values) {
  final value = _optString(args, key);
  if (value == null) return null;
  if (!values.contains(value)) {
    throw McpToolError('$key must be one of: ${values.join(', ')}');
  }
  return value;
}

String? _optDate(Map<String, Object?> args, String key) {
  final value = _optString(args, key);
  if (value == null) return null;
  _parseDay(value, key);
  return value;
}

DateTime _parseDay(String value, String key) {
  final parsed = _dayPattern.hasMatch(value) ? DateTime.tryParse(value) : null;
  if (parsed == null || _day(parsed) != value) {
    throw McpToolError('$key must be a date as YYYY-MM-DD');
  }
  return parsed;
}

// -- JSON Schema --------------------------------------------------------------

Map<String, Object?> _schema(Map<String, Object?> properties,
        {List<String> required = const []}) =>
    {
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
      'additionalProperties': false,
    };

Map<String, Object?> _string(String description) =>
    {'type': 'string', 'description': description};

Map<String, Object?> _integer(String description) =>
    {'type': 'integer', 'description': description};

Map<String, Object?> _boolean(String description) =>
    {'type': 'boolean', 'description': description};

Map<String, Object?> _date(String description) =>
    {'type': 'string', 'format': 'date', 'description': description};

Map<String, Object?> _enum(List<String> values, String description) =>
    {'type': 'string', 'enum': values, 'description': description};
