import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../core/token_service.dart';
import '../features/auth/i_auth_repository.dart';

Middleware authMiddleware(ITokenService tokens, IAuthRepository authRepo) {
  return (Handler inner) {
    return (Request request) async {
      final authHeader =
          request.headers['Authorization'] ?? request.headers['authorization'];

      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return _unauthorized('missing or invalid Authorization header');
      }

      final token = authHeader.substring(7);

      final ({String userId, String deviceId}) claims;
      try {
        claims = tokens.verify(token);
      } on TokenExpiredException {
        return _unauthorized('token expired');
      } on InvalidTokenException catch (e) {
        return _unauthorized(e.message);
      }

      // A valid signature is not enough: re-check the account on every request
      // so disabling a user (or deleting it) revokes their existing tokens
      // immediately, instead of leaving them usable until the 30-day expiry.
      final info = await authRepo.getAuthInfo(claims.userId);
      if (info == null) {
        return _unauthorized('account no longer exists');
      }
      if (info['disabled'] == true) {
        return _forbidden('account disabled');
      }

      return inner(request.change(
        context: {
          'userId': claims.userId,
          'deviceId': claims.deviceId,
          'role': info['role'],
        },
      ));
    };
  };
}

Response _unauthorized(String message) => Response(
      401,
      body: jsonEncode({'error': message}),
      headers: {'Content-Type': 'application/json'},
    );

Response _forbidden(String message) => Response(
      403,
      body: jsonEncode({'error': message}),
      headers: {'Content-Type': 'application/json'},
    );
