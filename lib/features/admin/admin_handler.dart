import 'dart:convert';

import 'package:bcrypt/bcrypt.dart';
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import '../auth/i_auth_repository.dart';

final _uuid = const Uuid();

class AdminHandler {
  const AdminHandler(this._repo, this._serverStartedAt, this._version);
  final IAuthRepository _repo;
  final DateTime _serverStartedAt;
  final String _version;

  /// Any authenticated user can call this — used by the client to decide
  /// whether to show admin UI, not gated behind adminOnlyMiddleware.
  Future<Response> me(Request request) async {
    final userId = request.context['userId'] as String;
    final info = await _repo.getAuthInfo(userId);
    if (info == null) return _error(404, 'user not found');
    return _json(200, info);
  }

  Future<Response> status(Request request) async {
    final userCount = await _repo.countUsers();
    final uptimeSeconds =
        DateTime.now().difference(_serverStartedAt).inSeconds;
    return _json(200, {
      'uptimeSeconds': uptimeSeconds,
      'version': _version,
      'userCount': userCount,
    });
  }

  Future<Response> listUsers(Request request) async {
    final users = await _repo.listUsers();
    return _json(200, {'users': users});
  }

  Future<Response> createUser(Request request) async {
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final email = (body['email'] as String?)?.trim();
    final password = body['password'] as String?;

    if (email == null ||
        email.isEmpty ||
        password == null ||
        password.isEmpty) {
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
    final hash = BCrypt.hashpw(password, BCrypt.gensalt());
    final user = await _repo.createUser(userId, email, hash, 'member');
    return _json(201, user);
  }

  Future<Response> setRole(Request request, String id) async {
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final role = body['role'] as String?;
    if (role == null || (role != 'admin' && role != 'member')) {
      return _error(400, "role must be 'admin' or 'member'");
    }

    if (role == 'member') {
      final guardError = await _guardLastAdmin(id);
      if (guardError != null) return guardError;
    }

    await _repo.setRole(id, role);
    return _json(200, {'id': id, 'role': role});
  }

  Future<Response> setDisabled(Request request, String id) async {
    final body =
        jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    final disabled = body['disabled'] as bool?;
    if (disabled == null) {
      return _error(400, 'disabled must be a boolean');
    }

    if (disabled) {
      final guardError = await _guardLastAdmin(id);
      if (guardError != null) return guardError;
    }

    await _repo.setDisabled(id, disabled);
    return _json(200, {'id': id, 'disabled': disabled});
  }

  /// Blocks demoting/disabling [targetUserId] if doing so would leave the
  /// server with zero active admins.
  Future<Response?> _guardLastAdmin(String targetUserId) async {
    final target = await _repo.getAuthInfo(targetUserId);
    if (target == null) return _error(404, 'user not found');
    if (target['role'] == 'admin' && target['disabled'] == false) {
      final activeAdmins = await _repo.countActiveAdmins();
      if (activeAdmins <= 1) {
        return _error(400, 'cannot remove the last remaining admin');
      }
    }
    return null;
  }
}

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

Response _error(int status, String message) =>
    _json(status, {'error': message});
