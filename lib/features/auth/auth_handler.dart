import 'dart:convert';

import 'package:bcrypt/bcrypt.dart';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import '../../core/config.dart';
import '../../core/http_utils.dart';
import '../../core/token_service.dart';
import 'i_auth_repository.dart';

final _uuid = const Uuid();

const _minPasswordLength = 8;

class AuthHandler {
  const AuthHandler(this._repo, this._tokens);
  final IAuthRepository _repo;
  final ITokenService _tokens;

  // A precomputed hash used to run bcrypt even when the account doesn't exist,
  // so a "no such user" response takes the same time as a wrong password and
  // can't be told apart by timing. Computed once, lazily.
  static final String _dummyHash = BCrypt.hashpw('*', BCrypt.gensalt());

  Future<Response> status(Request request) async {
    final count = await _repo.countUsers();
    return _json(200, {'hasUsers': count > 0});
  }

  Future<Response> register(Request request) async {
    final body = await readJsonMap(request, maxBytes: Config.maxJsonBodyBytes);
    final email = (body['email'] as String?)?.trim();
    final password = body['password'] as String?;

    if (email == null || email.isEmpty || password == null || password.isEmpty) {
      return _error(400, 'email and password required');
    }
    if (password.length < _minPasswordLength) {
      return _error(400, 'password must be at least $_minPasswordLength characters');
    }

    // Optional bootstrap gate: when configured, the first account can only be
    // created by someone who knows the server's registration token, so an
    // attacker can't grab admin by being the first to hit a fresh server.
    if (Config.registrationToken != null &&
        body['registrationToken'] != Config.registrationToken) {
      return _error(403, 'invalid or missing registration token');
    }

    // Public self-registration only exists to bootstrap the very first
    // account on a fresh server (which becomes admin). Every account after
    // that must be created by an admin via /api/v1/admin/users.
    if (await _repo.countUsers() > 0) {
      return _error(
          403, 'registration is closed, ask a server admin to create your account');
    }

    final userId = _uuid.v4();
    final deviceId = _uuid.v4();
    final hash = BCrypt.hashpw(password, BCrypt.gensalt());

    // Atomic + advisory-locked: guarantees only one first admin even under
    // concurrent bootstrap requests (the countUsers check above is just a fast,
    // friendly path; this is the real guard).
    final created = await _repo.createFirstAdmin(userId, email, hash);
    if (!created) {
      return _error(
          403, 'registration is closed, ask a server admin to create your account');
    }

    await _repo.upsertDevice(deviceId, userId, null);

    return _json(201, {
      'token': _tokens.sign(userId, deviceId),
      'userId': userId,
      'deviceId': deviceId,
      'role': 'admin',
    });
  }

  Future<Response> login(Request request) async {
    final body = await readJsonMap(request, maxBytes: Config.maxJsonBodyBytes);
    final email = (body['email'] as String?)?.trim();
    final password = body['password'] as String?;
    final deviceId = body['deviceId'] as String?;
    final deviceName = body['deviceName'] as String?;

    if (email == null || password == null) {
      return _error(400, 'email and password required');
    }

    final user = await _repo.findUserByEmail(email);
    // Always run bcrypt (against a dummy hash when the user is absent) to keep
    // the response time independent of whether the email exists.
    final storedHash = (user?['passwordHash'] as String?) ?? _dummyHash;
    final passwordOk = BCrypt.checkpw(password, storedHash);

    if (user == null || !passwordOk) {
      return _error(401, 'invalid credentials');
    }
    if (user['disabled'] as bool) {
      return _error(401, 'account disabled');
    }

    final userId = user['id'] as String;

    // A client may present its own deviceId, but never claim one already bound
    // to a different account (which would let it interfere with that account's
    // sync bookkeeping).
    if (deviceId != null) {
      final existing = await _repo.findDeviceById(deviceId);
      if (existing != null && existing['userId'] != userId) {
        return _error(403, 'device belongs to another account');
      }
    }

    final resolvedDeviceId = deviceId ?? _uuid.v4();
    await _repo.upsertDevice(resolvedDeviceId, userId, deviceName);
    await _repo.touchDevice(resolvedDeviceId);

    return _json(200, {
      'token': _tokens.sign(userId, resolvedDeviceId),
      'userId': userId,
      'deviceId': resolvedDeviceId,
      'role': user['role'],
    });
  }
}

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

Response _error(int status, String message) =>
    _json(status, {'error': message});
