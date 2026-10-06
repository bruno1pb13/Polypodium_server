// End-to-end through the real router and Postgres: the request shapes of
// clients predating gardens, the membership API, and isolation between
// gardens. Skips when no Postgres is reachable (set DATABASE_URL).
import 'dart:convert';
import 'dart:io';

import 'package:bcrypt/bcrypt.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:polypodium_server/core/token_service.dart';
import 'package:polypodium_server/database/db.dart';
import 'package:polypodium_server/features/admin/admin_handler.dart';
import 'package:polypodium_server/features/admin/settings_repository.dart';
import 'package:polypodium_server/features/auth/auth_handler.dart';
import 'package:polypodium_server/features/auth/auth_repository.dart';
import 'package:polypodium_server/features/gardens/garden_handler.dart';
import 'package:polypodium_server/features/gardens/garden_repository.dart';
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
}
