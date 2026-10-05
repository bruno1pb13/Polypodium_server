import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../../core/config.dart';
import '../../core/http_utils.dart';
import '../auth/i_auth_repository.dart';
import 'i_garden_repository.dart';

const _maxNameLength = 100;

/// `/gardens/*`: lists the caller's gardens and manages who shares them.
/// Only the owner adds or removes members and renames a garden; any member
/// lists the members and may leave. A garden the caller doesn't belong to
/// answers 404, so its existence isn't disclosed.
class GardenHandler {
  const GardenHandler(this._gardens, this._auth);
  final IGardenRepository _gardens;
  final IAuthRepository _auth;

  Future<Response> list(Request request) async {
    final userId = request.context['userId'] as String;
    await _gardens.ensurePersonalGarden(userId);
    return _json(200, {'gardens': await _gardens.listForUser(userId)});
  }

  Future<Response> create(Request request) async {
    final userId = request.context['userId'] as String;
    final name = await _readName(request);
    if (name == null) return _nameError();
    return _json(201, await _gardens.create(userId, name));
  }

  Future<Response> rename(Request request, String id) async {
    final userId = request.context['userId'] as String;
    final denied = await _requireOwner(id, userId);
    if (denied != null) return denied;
    final name = await _readName(request);
    if (name == null) return _nameError();
    await _gardens.rename(id, name);
    return _json(200, {'id': id, 'name': name});
  }

  Future<Response> members(Request request, String id) async {
    final userId = request.context['userId'] as String;
    if (await _gardens.memberRole(id, userId) == null) return _notFound();
    return _json(200, {'members': await _gardens.listMembers(id)});
  }

  Future<Response> addMember(Request request, String id) async {
    final userId = request.context['userId'] as String;
    final denied = await _requireOwner(id, userId);
    if (denied != null) return denied;

    final body = await readJsonMap(request, maxBytes: Config.maxJsonBodyBytes);
    final email = (body['email'] as String?)?.trim();
    if (email == null || email.isEmpty) return _error(400, 'email required');

    final user = await _auth.findUserByEmail(email);
    if (user == null) return _error(404, 'account not found');
    final memberId = user['id'] as String;
    if (!await _gardens.addMember(id, memberId)) {
      return _error(409, 'already a member');
    }
    return _json(201, {
      'userId': memberId,
      'email': user['email'],
      'role': 'member',
    });
  }

  /// Removes a member (owner only) or, with the caller's own id, leaves the
  /// garden. The owner can't leave their own garden.
  Future<Response> removeMember(
      Request request, String id, String memberId) async {
    final userId = request.context['userId'] as String;
    final role = await _gardens.memberRole(id, userId);
    if (role == null) return _notFound();
    if (memberId == userId) {
      if (role == 'owner') {
        return _error(400, 'the owner cannot leave their own garden');
      }
    } else if (role != 'owner') {
      return _error(403, 'only the garden owner can remove members');
    }
    if (!await _gardens.removeMember(id, memberId)) {
      return _error(404, 'member not found');
    }
    return _json(200, {'ok': true});
  }

  Future<Response?> _requireOwner(String gardenId, String userId) async {
    final role = await _gardens.memberRole(gardenId, userId);
    if (role == null) return _notFound();
    if (role != 'owner') {
      return _error(403, 'only the garden owner can do this');
    }
    return null;
  }

  static Future<String?> _readName(Request request) async {
    final body = await readJsonMap(request, maxBytes: Config.maxJsonBodyBytes);
    final name = body['name'];
    if (name is! String) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > _maxNameLength) return null;
    return trimmed;
  }

  static Response _nameError() =>
      _error(400, 'name must be 1-$_maxNameLength characters');

  static Response _notFound() => _error(404, 'garden not found');
}

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

Response _error(int status, String message) =>
    _json(status, {'error': message});
