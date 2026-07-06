import 'dart:convert';

import 'package:mocktail/mocktail.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:polypodium_server/core/token_service.dart';
import 'package:polypodium_server/features/auth/auth_handler.dart';
import 'package:polypodium_server/features/auth/i_auth_repository.dart';

class _MockAuthRepo extends Mock implements IAuthRepository {}

class _MockTokenService extends Mock implements ITokenService {}

void main() {
  late _MockAuthRepo repo;
  late _MockTokenService tokens;
  late AuthHandler handler;

  setUp(() {
    repo = _MockAuthRepo();
    tokens = _MockTokenService();
    handler = AuthHandler(repo, tokens);
  });

  Request _post(String path, Map<String, dynamic> body) => Request(
        'POST',
        Uri.parse('http://localhost$path'),
        body: jsonEncode(body),
        headers: {'content-type': 'application/json'},
      );

  Request _get(String path) =>
      Request('GET', Uri.parse('http://localhost$path'));

  group('status', () {
    test('hasUsers is false when there are no users', () async {
      when(() => repo.countUsers()).thenAnswer((_) async => 0);

      final res = await handler.status(_get('/status'));
      final body =
          jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['hasUsers'], false);
    });

    test('hasUsers is true when at least one user exists', () async {
      when(() => repo.countUsers()).thenAnswer((_) async => 1);

      final res = await handler.status(_get('/status'));
      final body =
          jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['hasUsers'], true);
    });
  });

  group('register', () {
    test('400 when email is empty', () async {
      final res = await handler
          .register(_post('/register', {'email': '', 'password': 'secret123'}));
      expect(res.statusCode, 400);
    });

    test('400 when password is shorter than 6 chars', () async {
      final res = await handler.register(
          _post('/register', {'email': 'a@b.com', 'password': '123'}));
      expect(res.statusCode, 400);
    });

    test('409 when email already registered', () async {
      when(() => repo.findUserByEmail('a@b.com')).thenAnswer(
          (_) async => {'id': 'uid', 'email': 'a@b.com', 'passwordHash': 'h'});

      final res = await handler.register(
          _post('/register', {'email': 'a@b.com', 'password': 'secret123'}));
      expect(res.statusCode, 409);
    });

    test('201 with token on success', () async {
      when(() => repo.findUserByEmail(any())).thenAnswer((_) async => null);
      when(() => repo.createUser(any(), any(), any()))
          .thenAnswer((_) async => {});
      when(() => repo.upsertDevice(any(), any(), any()))
          .thenAnswer((_) async {});
      when(() => tokens.sign(any(), any())).thenReturn('tok123');

      final res = await handler.register(
          _post('/register', {'email': 'a@b.com', 'password': 'secret123'}));

      expect(res.statusCode, 201);
      final body =
          jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['token'], 'tok123');
      expect(body['userId'], isA<String>());
      expect(body['deviceId'], isA<String>());
    });
  });

  group('login', () {
    test('400 when email is missing', () async {
      final res = await handler
          .login(_post('/login', {'password': 'secret123'}));
      expect(res.statusCode, 400);
    });

    test('401 when email not found', () async {
      when(() => repo.findUserByEmail(any())).thenAnswer((_) async => null);

      final res = await handler
          .login(_post('/login', {'email': 'x@y.com', 'password': 'secret123'}));
      expect(res.statusCode, 401);
    });
  });
}
