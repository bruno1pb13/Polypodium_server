// End-to-end through the real router and Postgres: the request shapes of
// clients predating gardens, the membership API, and isolation between
// gardens. Skips when no Postgres is reachable (set DATABASE_URL).
import 'dart:convert';
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:image/image.dart' as img;
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:polypodium_server/core/token_service.dart';
import 'package:polypodium_server/database/db.dart';
import 'package:polypodium_server/features/admin/admin_handler.dart';
import 'package:polypodium_server/features/admin/i_settings_repository.dart';
import 'package:polypodium_server/features/admin/settings_repository.dart';
import 'package:polypodium_server/features/auth/auth_handler.dart';
import 'package:polypodium_server/features/auth/auth_repository.dart';
import 'package:polypodium_server/features/gardens/garden_handler.dart';
import 'package:polypodium_server/features/gardens/garden_repository.dart';
import 'package:polypodium_server/features/mcp/garden_store.dart';
import 'package:polypodium_server/features/mcp/mcp_handler.dart';
import 'package:polypodium_server/features/mcp/mcp_server.dart';
import 'package:polypodium_server/features/mcp/mcp_token_handler.dart';
import 'package:polypodium_server/features/mcp/mcp_token_repository.dart';
import 'package:polypodium_server/features/mcp/photo_renderer.dart';
import 'package:polypodium_server/features/mcp/polypodium_tools.dart';
import 'package:polypodium_server/features/photos/photo_handler.dart';
import 'package:polypodium_server/features/sync/sync_handler.dart';
import 'package:polypodium_server/features/sync/sync_repository.dart';
import 'package:polypodium_server/features/weather/weather_handler.dart';
import 'package:polypodium_server/features/weather/weather_provider.dart';
import 'package:polypodium_server/features/weather/weather_repository.dart';
import 'package:polypodium_server/features/weather/weather_service.dart';
import 'package:polypodium_server/routes/router.dart';

typedef _Res = ({int status, Map<String, dynamic> body});

class _Account {
  _Account(this.id, this.email, this.token, this.deviceId);
  final String id;
  final String email;
  final String token;
  final String deviceId;
}

void main() {
  Pool? pool;
  late Handler app;
  late Directory photosDir;
  final createdUsers = <String>[];
  final stamp = DateTime.now().microsecondsSinceEpoch;
  var seq = 0;

  setUpAll(() async {
    try {
      pool = await initDatabase();
    } catch (_) {
      pool = null;
      return;
    }
    photosDir = await Directory.systemTemp.createTemp();
    final db = pool!;
    final authRepo = AuthRepository(db);
    final gardenRepo = GardenRepository(db);
    const tokens = JwtTokenService('0123456789abcdef0123456789abcdef');
    app = buildRouter(
      auth: AuthHandler(authRepo, tokens),
      sync: SyncHandler(SyncRepository(db)),
      photos: PhotoHandler(photosDir.path),
      admin: AdminHandler(
          authRepo, SettingsRepository(db), DateTime.now(), 'test'),
      gardens: GardenHandler(gardenRepo, authRepo),
      weather: WeatherHandler(
          WeatherService(WeatherRepository(db), SettingsRepository(db),
              OpenMeteoProvider('http://localhost:9')),
          WeatherRepository(db)),
      mcp: McpHandler(McpServer(
          polypodiumTools(
          store: GardenStore(db),
          sync: SyncRepository(db),
          photos: PhotoRenderer(photosDir.path).call),
          version: 'test')),
      mcpTokens: McpTokenHandler(
          McpTokenRepository(db), gardenRepo, SettingsRepository(db)),
      mcpTokenRepo: McpTokenRepository(db),
      settings: SettingsRepository(db),
      gardenRepo: gardenRepo,
      authRepo: authRepo,
      tokens: tokens,
    ).call;
  });

  tearDownAll(() async {
    final db = pool;
    if (db == null) return;
    for (final id in createdUsers) {
      await db.execute(
        Sql.named('''
          DELETE FROM device_cursors
          WHERE device_id IN (SELECT id FROM devices WHERE user_id = @id)
        '''),
        parameters: {'id': id},
      );
      // Cascades to their devices and the gardens they own (and those
      // gardens' rows).
      await db.execute(Sql.named('DELETE FROM users WHERE id = @id'),
          parameters: {'id': id});
    }
    await photosDir.delete(recursive: true);
    await db.close();
  });

  Future<_Res> send(
    String method,
    String path, {
    _Account? as,
    String? garden,
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    final res = await app(Request(
      method,
      Uri.parse('http://localhost/api/v1$path'),
      headers: {
        ...headers,
        if (as != null) 'Authorization': 'Bearer ${as.token}',
        if (garden != null) 'X-Polypodium-Garden': garden,
      },
      body: body is List<int> ? body : (body == null ? null : jsonEncode(body)),
    ));
    final isJson =
        res.headers['content-type']?.startsWith('application/json') ?? false;
    final text = isJson ? await res.readAsString() : '';
    final decoded = text.isEmpty ? null : jsonDecode(text);
    return (
      status: res.statusCode,
      body: decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
    );
  }

  /// Creates an account the way an admin does and logs it in with the exact
  /// body an app predating gardens sends.
  Future<_Account> account() async {
    final id = 'garden-test-$stamp-${seq++}';
    final email = '$id@test.local';
    createdUsers.add(id);
    await AuthRepository(pool!).createUser(id, email,
        BCrypt.hashpw('password1', BCrypt.gensalt(logRounds: 4)), 'member');
    final login = await send('POST', '/auth/login', body: {
      'email': email,
      'password': 'password1',
      'deviceId': 'dev-$id',
      'deviceName': 'Polypodium',
    });
    expect(login.status, 200, reason: '${login.body}');
    return _Account(id, email, login.body['token'] as String,
        login.body['deviceId'] as String);
  }

  Map<String, dynamic> change(
          _Account by, String type, String id, Map<String, dynamic> payload,
          {DateTime? at}) =>
      {
        'entityType': type,
        'entityId': id,
        'payload': payload,
        'updatedAt': (at ?? DateTime.utc(2026, 1, 1)).toIso8601String(),
        'deletedAt': null,
        'deviceId': by.deviceId,
        'rev': 0,
      };

  Future<_Res> push(_Account by, List<Map<String, dynamic>> changes,
          {String? garden}) =>
      send('POST', '/sync/receive',
          as: by,
          garden: garden,
          body: {'deviceId': by.deviceId, 'changes': changes});

  Future<List<String>> pulledIds(_Account by, {String? garden}) async {
    final res = await send('GET', '/sync/changes?since=0&limit=1000',
        as: by, garden: garden);
    expect(res.status, 200, reason: '${res.body}');
    return [
      for (final c in res.body['changes'] as List) c['entityId'] as String
    ];
  }

  Future<String> createGarden(_Account owner, String name) async {
    final res = await send('POST', '/gardens', as: owner, body: {'name': name});
    expect(res.status, 201, reason: '${res.body}');
    return res.body['id'] as String;
  }

  bool skip() {
    if (pool != null) return false;
    markTestSkipped('no reachable Postgres (set DATABASE_URL)');
    return true;
  }

  group('clients predating gardens', () {
    test('sync and photos work unchanged, in the personal garden', () async {
      if (skip()) return;
      final a = await account();

      final pushed = await push(a, [
        change(a, 'plant', 'p-old', {'name': 'Samambaia'}),
        change(a, 'entry', 'e-old', {'type': 'irrigation', 'plantId': 'p-old'}),
      ]);
      expect(pushed.status, 200);
      expect(pushed.body['appliedCount'], 2);

      final pulled =
          await send('GET', '/sync/changes?since=0&limit=100', as: a);
      expect(pulled.status, 200);
      final changes = pulled.body['changes'] as List;
      expect(changes.map((c) => c['entityId']), ['p-old', 'e-old']);
      final cursor = pulled.body['nextCursor'] as int;

      final ack = await send('POST', '/sync/ack',
          as: a, body: {'deviceId': a.deviceId, 'cursor': cursor});
      expect(ack.status, 200);
      final status = await send('GET', '/sync/status', as: a);
      expect(status.status, 200);
      expect(status.body['lastPulledCursor'], cursor);
      expect(status.body['serverLatestCursor'], cursor);

      expect(
          (await send('PUT', '/photos/p-old.jpg', as: a, body: [1, 2])).status,
          200);
      expect((await send('HEAD', '/photos/p-old.jpg', as: a)).status, 200);
      expect((await send('GET', '/photos/p-old.jpg', as: a)).status, 200);
      // The personal garden's id is the account id: its pre-garden photo
      // directory, and the same rows when a newer app names it explicitly.
      expect(File('${photosDir.path}/${a.id}/p-old.jpg').existsSync(), isTrue);
      expect(await pulledIds(a, garden: a.id), ['p-old', 'e-old']);
    });

    test('a blank garden header counts as absent', () async {
      if (skip()) return;
      final a = await account();
      await push(a, [change(a, 'plant', 'p1', {})]);
      expect(await pulledIds(a, garden: '  '), ['p1']);
    });
  });

  group('membership API', () {
    test('lists the personal garden first, as owner', () async {
      if (skip()) return;
      final a = await account();
      for (final path in ['/gardens', '/gardens/']) {
        final res = await send('GET', path, as: a);
        expect(res.status, 200);
        final gardens = res.body['gardens'] as List;
        expect(gardens.first, {
          'id': a.id,
          'name': '',
          'personal': true,
          'role': 'owner',
          'ownerUserId': a.id,
          'ownerEmail': a.email,
        });
      }
    });

    test('owner manages members; members list and leave', () async {
      if (skip()) return;
      final owner = await account();
      final member = await account();
      final outsider = await account();

      expect(
          (await send('POST', '/gardens', as: owner, body: {'name': ' '}))
              .status,
          400);
      final gardenId = await createGarden(owner, 'Horta');

      final added = await send('POST', '/gardens/$gardenId/members',
          as: owner, body: {'email': member.email});
      expect(added.status, 201);
      expect(added.body['userId'], member.id);
      expect(
          (await send('POST', '/gardens/$gardenId/members',
                  as: owner, body: {'email': member.email}))
              .status,
          409);
      expect(
          (await send('POST', '/gardens/$gardenId/members',
                  as: owner, body: {'email': 'nobody-$stamp@test.local'}))
              .status,
          404);

      final memberGardens = await send('GET', '/gardens', as: member);
      expect(
        (memberGardens.body['gardens'] as List)
            .firstWhere((g) => g['id'] == gardenId),
        {
          'id': gardenId,
          'name': 'Horta',
          'personal': false,
          'role': 'member',
          'ownerUserId': owner.id,
          'ownerEmail': owner.email,
        },
      );
      final members =
          await send('GET', '/gardens/$gardenId/members', as: member);
      expect(members.status, 200);
      expect(
        [
          for (final m in members.body['members'] as List)
            [m['email'], m['role']]
        ],
        [
          [owner.email, 'owner'],
          [member.email, 'member'],
        ],
      );

      // A member can't manage the garden.
      expect(
          (await send('POST', '/gardens/$gardenId/members',
                  as: member, body: {'email': outsider.email}))
              .status,
          403);
      expect(
          (await send('DELETE', '/gardens/$gardenId/members/${owner.id}',
                  as: member))
              .status,
          403);
      expect(
          (await send('PATCH', '/gardens/$gardenId',
                  as: member, body: {'name': 'Minha'}))
              .status,
          403);

      // A non-member doesn't even learn the garden exists.
      for (final res in [
        await send('GET', '/gardens/$gardenId/members', as: outsider),
        await send('PATCH', '/gardens/$gardenId',
            as: outsider, body: {'name': 'x'}),
        await send('POST', '/gardens/$gardenId/members',
            as: outsider, body: {'email': outsider.email}),
        await send('DELETE', '/gardens/$gardenId/members/${member.id}',
            as: outsider),
      ]) {
        expect(res.status, 404);
      }

      final renamed = await send('PATCH', '/gardens/$gardenId',
          as: owner, body: {'name': 'Horta comunitária'});
      expect(renamed.status, 200);
      expect(renamed.body['name'], 'Horta comunitária');

      // The owner can't leave; a member can.
      expect(
          (await send('DELETE', '/gardens/$gardenId/members/${owner.id}',
                  as: owner))
              .status,
          400);
      expect(
          (await send('DELETE', '/gardens/$gardenId/members/${member.id}',
                  as: member))
              .status,
          200);
      expect(
          (await send('GET', '/sync/changes?since=0',
                  as: member, garden: gardenId))
              .status,
          403);

      // The owner removes a member.
      await send('POST', '/gardens/$gardenId/members',
          as: owner, body: {'email': member.email});
      expect(
          (await send('DELETE', '/gardens/$gardenId/members/${member.id}',
                  as: owner))
              .status,
          200);
      expect(
          (await send('DELETE', '/gardens/$gardenId/members/${member.id}',
                  as: owner))
              .status,
          404);
      final after = await send('GET', '/gardens', as: member);
      expect((after.body['gardens'] as List).map((g) => g['id']),
          isNot(contains(gardenId)));
    });

    test('a personal garden can be shared too', () async {
      if (skip()) return;
      final owner = await account();
      final member = await account();
      await push(owner, [change(owner, 'plant', 'p-mine', {})]);

      await send('POST', '/gardens/${owner.id}/members',
          as: owner, body: {'email': member.email});
      expect(await pulledIds(member, garden: owner.id), ['p-mine']);
      // The member's own default stays their personal garden.
      expect(await pulledIds(member), isEmpty);
    });
  });

  group('gardens are isolated', () {
    test('two accounts sync the same garden', () async {
      if (skip()) return;
      final a = await account();
      final b = await account();
      final gardenId = await createGarden(a, 'Estufa');
      await send('POST', '/gardens/$gardenId/members',
          as: a, body: {'email': b.email});

      expect(
          (await push(
                  a,
                  [
                    change(a, 'plant', 'p-shared', {'name': 'Orquídea'})
                  ],
                  garden: gardenId))
              .body['appliedCount'],
          1);
      expect(await pulledIds(b, garden: gardenId), ['p-shared']);

      // B edits the same row later: LWW across accounts as across devices.
      await push(
          b,
          [
            change(b, 'plant', 'p-shared', {'name': 'Orquídea-negra'},
                at: DateTime.utc(2026, 2, 1)),
            change(b, 'entry', 'e-shared',
                {'type': 'irrigation', 'plantId': 'p-shared'}),
          ],
          garden: gardenId);
      final pulled =
          await send('GET', '/sync/changes?since=0', as: a, garden: gardenId);
      final byId = {
        for (final c in pulled.body['changes'] as List) c['entityId']: c
      };
      expect(byId['p-shared']['payload']['name'], 'Orquídea-negra');
      expect(byId['p-shared']['deviceId'], b.deviceId);
      expect(byId.keys, containsAll(['p-shared', 'e-shared']));

      // The shared rows never leak into either personal garden.
      expect(await pulledIds(a), isEmpty);
      expect(await pulledIds(b), isEmpty);

      // Cursors are kept per (device, garden).
      final cursor = pulled.body['nextCursor'] as int;
      await send('POST', '/sync/ack',
          as: a,
          garden: gardenId,
          body: {'deviceId': a.deviceId, 'cursor': cursor});
      expect(
          (await send('GET', '/sync/status', as: a, garden: gardenId))
              .body['lastPulledCursor'],
          cursor);
      expect(
          (await send('GET', '/sync/status', as: a)).body['lastPulledCursor'],
          0);
    });

    test('a non-member can neither read nor write a garden', () async {
      if (skip()) return;
      final owner = await account();
      final intruder = await account();
      final gardenId = await createGarden(owner, 'Privado');
      await push(owner, [change(owner, 'plant', 'p-secret', {})],
          garden: gardenId);
      await push(owner, [change(owner, 'plant', 'p-personal', {})]);
      await send('PUT', '/photos/p-secret.jpg',
          as: owner, garden: gardenId, body: [7]);

      for (final garden in [gardenId, owner.id, 'no-such-garden']) {
        expect(
            (await send('GET', '/sync/changes?since=0',
                    as: intruder, garden: garden))
                .status,
            403,
            reason: garden);
        expect(
            (await push(
                    intruder,
                    [
                      change(intruder, 'plant', 'p-secret', {'name': 'pwned'})
                    ],
                    garden: garden))
                .status,
            403,
            reason: garden);
        expect(
            (await send('POST', '/sync/ack',
                    as: intruder,
                    garden: garden,
                    body: {'deviceId': intruder.deviceId, 'cursor': 1}))
                .status,
            403,
            reason: garden);
        expect(
            (await send('GET', '/sync/status', as: intruder, garden: garden))
                .status,
            403,
            reason: garden);
        for (final method in ['GET', 'HEAD']) {
          expect(
              (await send(method, '/photos/p-secret.jpg',
                      as: intruder, garden: garden))
                  .status,
              403,
              reason: '$method $garden');
        }
        expect(
            (await send('PUT', '/photos/p-secret.jpg',
                    as: intruder, garden: garden, body: [6]))
                .status,
            403,
            reason: garden);
      }

      // Writing the same entity id in their own garden touches only theirs.
      await push(intruder, [
        change(intruder, 'plant', 'p-secret', {'name': 'pwned'})
      ]);
      final pulled = await send('GET', '/sync/changes?since=0',
          as: owner, garden: gardenId);
      final secret = (pulled.body['changes'] as List).single;
      expect(secret['payload'], isEmpty);
      expect((await send('HEAD', '/photos/p-secret.jpg', as: intruder)).status,
          404);
      final photo = await app(Request(
          'GET', Uri.parse('http://localhost/api/v1/photos/p-secret.jpg'),
          headers: {
            'Authorization': 'Bearer ${owner.token}',
            'X-Polypodium-Garden': gardenId,
          }));
      expect(await photo.read().expand((b) => b).toList(), [7]);
    });
  });

  group('MCP', () {
    Future<void> setMcpEnabled(bool on) =>
        SettingsRepository(pool!).setBool(settingMcpEnabled, on);

    setUp(() async {
      if (pool != null) await setMcpEnabled(true);
    });
    tearDown(() async {
      if (pool != null) await setMcpEnabled(false);
    });

    Future<_Res> mcp(String token, String method,
        [Map<String, Object?>? params]) async {
      final res = await app(Request(
        'POST',
        Uri.parse('http://localhost/api/v1/mcp'),
        headers: {'Authorization': 'Bearer $token'},
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': method,
          if (params != null) 'params': params,
        }),
      ));
      final text = await res.readAsString();
      final decoded = text.isEmpty ? null : jsonDecode(text);
      return (
        status: res.statusCode,
        body: decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
      );
    }

    Future<Map<String, dynamic>> tool(
        String token, String name, Map<String, Object?> args) async {
      final res =
          await mcp(token, 'tools/call', {'name': name, 'arguments': args});
      expect(res.status, 200, reason: '${res.body}');
      return res.body['result'] as Map<String, dynamic>;
    }

    Future<Map<String, dynamic>> newToken(_Account by, String garden,
        {bool canWrite = false}) async {
      final res = await send('POST', '/gardens/$garden/mcp-tokens',
          as: by, body: {'name': 'Claude', 'canWrite': canWrite});
      expect(res.status, 201, reason: '${res.body}');
      return res.body;
    }

    test('a token reads and writes only its garden, like a synced peer',
        () async {
      if (skip()) return;
      final owner = await account();
      final member = await account();
      final garden = await createGarden(owner, 'Horta');
      await send('POST', '/gardens/$garden/members',
          as: owner, body: {'email': member.email});

      await push(owner, [
        change(owner, 'species', 'sp-mcp', {
          'popularName': 'Manjericão',
          'scientificName': 'Ocimum basilicum',
          'defaultIrrigationFrequencyDays': 2,
          'createdAt': '2026-01-01T00:00:00.000',
        }),
        change(owner, 'plant', 'p-mcp', {
          'nickname': 'Basil',
          'speciesId': 'sp-mcp',
          'soilId': 'loamy',
          'status': 'active',
          'acquisitionDate': '2026-01-01T00:00:00.000',
          'createdAt': '2026-01-01T00:00:00.000',
        }),
      ], garden: garden);
      // Same id in the personal garden: must stay invisible to the token.
      await push(owner, [
        change(owner, 'plant', 'p-personal', {'nickname': 'Private'}),
      ]);

      final created = await newToken(member, garden, canWrite: true);
      final secret = created['token'] as String;
      expect(secret, startsWith('pmcp_'));

      final init = await mcp(secret, 'initialize', {
        'protocolVersion': '2025-06-18',
        'capabilities': {},
        'clientInfo': {'name': 'test', 'version': '0'},
      });
      expect(init.status, 200);
      expect((init.body['result'] as Map)['serverInfo']['name'], 'polypodium');

      final plants = await tool(secret, 'list_plants', {});
      final listed = (plants['structuredContent'] as Map)['plants'] as List;
      expect(listed.map((p) => p['nickname']), ['Basil']);

      final added = await tool(secret, 'add_entry',
          {'plants': ['Basil'], 'type': 'irrigation', 'note': 'via MCP'});
      expect(added['isError'], false, reason: '$added');

      // The owner's device pulls the entry as another peer's write.
      final pulled = await send('GET', '/sync/changes?since=0&limit=100',
          as: owner, garden: garden);
      final entry = (pulled.body['changes'] as List)
          .singleWhere((c) => c['entityType'] == 'entry');
      expect(entry['deviceId'], 'mcp-${created['id']}');
      expect(entry['payload']['note'], 'via MCP');
      expect(entry['payload']['plantId'], 'p-mcp');

      // Read-only tokens don't get write tools.
      final readOnly = await newToken(member, garden);
      final denied = await mcp(readOnly['token'] as String, 'tools/call', {
        'name': 'add_entry',
        'arguments': {'plants': ['Basil'], 'type': 'irrigation'},
      });
      expect((denied.body['error'] as Map)['code'], -32602);
    });

    test('photos synced by a device come back as images', () async {
      if (skip()) return;
      final owner = await account();
      final garden = await createGarden(owner, 'Orquidário');
      final jpeg = img.encodeJpg(img.Image(width: 1200, height: 800));
      for (final key in ['e-own.jpg', 'ep-extra.jpg', 'e-new.jpg']) {
        expect(
            (await send('PUT', '/photos/$key',
                    as: owner, garden: garden, body: jpeg))
                .status,
            200);
      }
      DateTime at(int day) => DateTime.utc(2026, 10, day);
      await push(owner, [
        change(owner, 'plant', 'p-orq', {
          'nickname': 'Orquídea',
          'speciesId': 'sp',
          'soilId': 'loamy',
          'status': 'active',
          'coverPhotoId': 'ep-extra',
        }),
        change(owner, 'entry', 'e-own', {
          'plantId': 'p-orq',
          'type': 'observation',
          'date': '2026-10-01T10:00:00.000',
          'photoKey': 'e-own.jpg',
        }, at: at(1)),
        change(owner, 'entry_photo', 'ep-extra', {
          'entryId': 'e-own',
          'photoKey': 'ep-extra.jpg',
          'position': 0,
        }, at: at(1)),
        change(owner, 'entry', 'e-new', {
          'plantId': 'p-orq',
          'type': 'observation',
          'date': '2026-10-05T10:00:00.000',
          'photoKey': 'e-new.jpg',
        }, at: at(5)),
        // Deleted entries' photos are gone for the model too.
        {
          ...change(owner, 'entry', 'e-del', {
            'plantId': 'p-orq',
            'type': 'observation',
            'date': '2026-10-06T10:00:00.000',
            'photoKey': 'e-del.jpg',
          }, at: at(6)),
          'deletedAt': at(7).toIso8601String(),
        },
      ], garden: garden);

      final secret =
          (await newToken(owner, garden))['token'] as String;

      final plant = await tool(secret, 'get_plant', {'plant': 'Orquídea'});
      final data = plant['structuredContent'] as Map;
      expect(data['photoCount'], 3);
      expect(data['coverPhoto']['photoId'], 'ep-extra');
      final image = (plant['content'] as List)[1] as Map;
      expect(image['type'], 'image');
      final cover = img.decodeJpg(base64Decode(image['data'] as String))!;
      expect((cover.width, cover.height), (512, 341));

      final listed = await tool(secret, 'list_plant_photos', {'plant': 'p-orq'});
      expect(
          [
            for (final p in (listed['structuredContent'] as Map)['photos'])
              p['photoId']
          ],
          ['e-new', 'e-own', 'ep-extra']);

      final photos = await tool(secret, 'get_photos', {
        'photoIds': ['e-new', 'e-del'],
      });
      expect((photos['structuredContent'] as Map)['notFound'], ['e-del']);
      expect((photos['content'] as List).where((c) => c['type'] == 'image'),
          hasLength(1));
    });

    test('off by default: no endpoint and no new tokens', () async {
      if (skip()) return;
      final owner = await account();
      final garden = await createGarden(owner, 'Desligado');
      final token = await newToken(owner, garden);

      await setMcpEnabled(false);
      expect((await mcp(token['token'] as String, 'ping')).status, 404);
      final create = await send('POST', '/gardens/$garden/mcp-tokens',
          as: owner, body: {'name': 'x'});
      expect(create.status, 403);
      expect(create.body['code'], 'mcp_disabled');
      // Existing tokens can still be seen and revoked.
      final listed =
          await send('GET', '/gardens/$garden/mcp-tokens', as: owner);
      expect(listed.body['enabled'], false);
      expect(listed.body['tokens'] as List, hasLength(1));
      expect(
          (await send('DELETE', '/gardens/$garden/mcp-tokens/${token['id']}',
                  as: owner))
              .status,
          200);

      final me = await send('GET', '/admin/me', as: owner);
      expect(me.body['mcpEnabled'], false);

      await setMcpEnabled(true);
      expect((await send('GET', '/admin/me', as: owner)).body['mcpEnabled'],
          true);
    });

    test('tokens are listed, revoked and die with the membership', () async {
      if (skip()) return;
      final owner = await account();
      final member = await account();
      final outsider = await account();
      final garden = await createGarden(owner, 'Estufa');
      await send('POST', '/gardens/$garden/members',
          as: owner, body: {'email': member.email});

      final ownerToken = await newToken(owner, garden);
      final memberToken = await newToken(member, garden);

      expect(
          (await send('POST', '/gardens/$garden/mcp-tokens',
                  as: outsider, body: {'name': 'x'}))
              .status,
          404);
      expect(
          (await mcp('pmcp_not-a-real-token', 'ping')).status, 401);

      // A member sees only their own tokens; the owner sees all, never
      // the secret.
      final mine =
          await send('GET', '/gardens/$garden/mcp-tokens', as: member);
      expect((mine.body['tokens'] as List).map((t) => t['id']),
          [memberToken['id']]);
      final all = await send('GET', '/gardens/$garden/mcp-tokens', as: owner);
      expect(all.body['tokens'] as List, hasLength(2));
      expect((all.body['tokens'] as List).first.containsKey('token'), isFalse);

      // A member can't revoke the owner's token.
      expect(
          (await send('DELETE',
                  '/gardens/$garden/mcp-tokens/${ownerToken['id']}',
                  as: member))
              .status,
          404);
      expect((await mcp(memberToken['token'] as String, 'ping')).status, 200);

      // Leaving the garden kills the member's token without revoking it.
      await send('DELETE', '/gardens/$garden/members/${member.id}', as: member);
      expect((await mcp(memberToken['token'] as String, 'ping')).status, 401);

      // Revoked tokens stop working at once.
      expect(
          (await send('DELETE',
                  '/gardens/$garden/mcp-tokens/${ownerToken['id']}',
                  as: owner))
              .status,
          200);
      expect((await mcp(ownerToken['token'] as String, 'ping')).status, 401);
    });
  });
}
