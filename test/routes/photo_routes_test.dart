import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:polypodium_server/core/token_service.dart';
import 'package:polypodium_server/features/auth/i_auth_repository.dart';
import 'package:polypodium_server/features/gardens/i_garden_repository.dart';
import 'package:polypodium_server/features/photos/photo_handler.dart';
import 'package:polypodium_server/routes/photo_routes.dart';

class _MockAuthRepo extends Mock implements IAuthRepository {}

class _MockGardenRepo extends Mock implements IGardenRepository {}

void main() {
  late Directory dir;
  late Handler handler;
  const tokens = JwtTokenService('0123456789abcdef0123456789abcdef');
  final auth = {'Authorization': 'Bearer ${tokens.sign('user1', 'device1')}'};
  final outsider = {
    'Authorization': 'Bearer ${tokens.sign('user2', 'device2')}'
  };

  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    final authRepo = _MockAuthRepo();
    when(() => authRepo.getAuthInfo(any()))
        .thenAnswer((_) async => {'role': 'user', 'disabled': false});
    final gardens = _MockGardenRepo();
    when(() => gardens.memberRole(any(), any())).thenAnswer((inv) async {
      final gardenId = inv.positionalArguments[0] as String;
      final userId = inv.positionalArguments[1] as String;
      if (gardenId == userId) return 'owner';
      if (gardenId == 'shared' && userId == 'user1') return 'member';
      return null;
    });
    handler =
        buildPhotoHandler(PhotoHandler(dir.path), tokens, authRepo, gardens);
  });

  tearDown(() => dir.delete(recursive: true));

  Future<Response> send(String method, String key, Map<String, String> headers,
          {List<int>? body}) async =>
      handler(Request(method, Uri.parse('http://localhost/$key'),
          headers: headers, body: body));

  // The app checks for a photo with HEAD before uploading it again.
  test('HEAD tells whether a photo exists, without its bytes', () async {
    expect((await send('HEAD', 'ph1.jpg', auth)).statusCode, 404);

    final put = await send('PUT', 'ph1.jpg', auth, body: [1, 2, 3]);
    expect(put.statusCode, 200);

    final found = await send('HEAD', 'ph1.jpg', auth);
    expect(found.statusCode, 200);
    expect(await found.read().expand((b) => b).toList(), isEmpty);
  });

  test(
      'without a garden header photos live in the personal garden, '
      'i.e. the pre-garden per-user directory', () async {
    await send('PUT', 'ph1.jpg', auth, body: [1, 2, 3]);
    expect(File('${dir.path}/user1/ph1.jpg').existsSync(), isTrue);
  });

  test('photos are scoped per garden', () async {
    final shared = {...auth, 'X-Polypodium-Garden': 'shared'};
    await send('PUT', 'ph1.jpg', shared, body: [9]);
    expect(File('${dir.path}/shared/ph1.jpg').existsSync(), isTrue);
    expect((await send('HEAD', 'ph1.jpg', auth)).statusCode, 404);
    final got = await send('GET', 'ph1.jpg', shared);
    expect(await got.read().expand((b) => b).toList(), [9]);
  });

  test(
      'a non-member cannot PUT, GET or HEAD a garden photo, even with a '
      'valid key', () async {
    final shared = {...auth, 'X-Polypodium-Garden': 'shared'};
    await send('PUT', 'ph1.jpg', shared, body: [9]);

    final intruder = {...outsider, 'X-Polypodium-Garden': 'shared'};
    expect((await send('GET', 'ph1.jpg', intruder)).statusCode, 403);
    expect((await send('HEAD', 'ph1.jpg', intruder)).statusCode, 403);
    expect((await send('PUT', 'ph1.jpg', intruder, body: [6])).statusCode, 403);
    // Nor reach another account's personal garden by naming it.
    final personal = {...outsider, 'X-Polypodium-Garden': 'user1'};
    expect((await send('GET', 'ph1.jpg', personal)).statusCode, 403);

    final got = await send('GET', 'ph1.jpg', shared);
    expect(await got.read().expand((b) => b).toList(), [9]);
  });
}
