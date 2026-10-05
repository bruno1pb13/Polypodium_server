import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:polypodium_server/core/token_service.dart';
import 'package:polypodium_server/features/auth/i_auth_repository.dart';
import 'package:polypodium_server/features/photos/photo_handler.dart';
import 'package:polypodium_server/routes/photo_routes.dart';

class _MockAuthRepo extends Mock implements IAuthRepository {}

void main() {
  late Directory dir;
  late Handler handler;
  const tokens = JwtTokenService('0123456789abcdef0123456789abcdef');
  final auth = {'Authorization': 'Bearer ${tokens.sign('user1', 'device1')}'};

  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    final authRepo = _MockAuthRepo();
    when(() => authRepo.getAuthInfo('user1'))
        .thenAnswer((_) async => {'role': 'user', 'disabled': false});
    handler = buildPhotoHandler(PhotoHandler(dir.path), tokens, authRepo);
  });

  tearDown(() => dir.delete(recursive: true));

  // The app checks for a photo with HEAD before uploading it again.
  test('HEAD tells whether a photo exists, without its bytes', () async {
    Future<Response> head() async => handler(
        Request('HEAD', Uri.parse('http://localhost/ph1.jpg'), headers: auth));

    expect((await head()).statusCode, 404);

    final put = await handler(Request(
        'PUT', Uri.parse('http://localhost/ph1.jpg'),
        headers: auth, body: [1, 2, 3]));
    expect(put.statusCode, 200);

    final found = await head();
    expect(found.statusCode, 200);
    expect(await found.read().expand((b) => b).toList(), isEmpty);
  });
}
