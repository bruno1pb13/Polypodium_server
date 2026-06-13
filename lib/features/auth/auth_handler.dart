import 'dart:convert';

import 'package:bcrypt/bcrypt.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import '../../config.dart';
import 'auth_repository.dart';

final _uuid = const Uuid();

class AuthHandler {
  final _repo = AuthRepository();

  Future<Response> register(Request request) async {
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final email = (body['email'] as String?)?.trim();
    final password = body['password'] as String?;

    if (email == null || email.isEmpty || password == null || password.isEmpty) {
      return _error(400, 'email and password required');
    }
    if (password.length < 6) {
      return _error(400, 'password must be at least 6 characters');
    }

    final existing = await _repo.findUserByEmail(email);
    if (existing != null) {
      return _error(409, 'email already registered');
    }

    final userId = _uuid.v4();
    final deviceId = _uuid.v4();
    final hash = BCrypt.hashpw(password, BCrypt.gensalt());

    await _repo.createUser(userId, email, hash);
    await _repo.upsertDevice(deviceId, userId, null);

    return _json(201, {
      'token': _sign(userId, deviceId),
      'userId': userId,
      'deviceId': deviceId,
    });
  }

  Future<Response> login(Request request) async {
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final email = (body['email'] as String?)?.trim();
    final password = body['password'] as String?;
    final deviceId = body['deviceId'] as String?;
    final deviceName = body['deviceName'] as String?;

    if (email == null || password == null) {
      return _error(400, 'email and password required');
    }

    final user = await _repo.findUserByEmail(email);
    if (user == null ||
        !BCrypt.checkpw(password, user['passwordHash'] as String)) {
      return _error(401, 'invalid credentials');
    }

    final resolvedDeviceId = deviceId ?? _uuid.v4();
    await _repo.upsertDevice(
        resolvedDeviceId, user['id'] as String, deviceName);
    await _repo.touchDevice(resolvedDeviceId);

    return _json(200, {
      'token': _sign(user['id'] as String, resolvedDeviceId),
      'userId': user['id'],
      'deviceId': resolvedDeviceId,
    });
  }

  String _sign(String userId, String deviceId) {
    final jwt = JWT({'deviceId': deviceId}, subject: userId);
    return jwt.sign(
      SecretKey(Config.jwtSecret),
      expiresIn: const Duration(days: 30),
    );
  }
}

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

Response _error(int status, String message) =>
    _json(status, {'error': message});
