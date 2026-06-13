import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../core/token_service.dart';

Middleware authMiddleware(ITokenService tokens) {
  return (Handler inner) {
    return (Request request) async {
      final authHeader =
          request.headers['Authorization'] ?? request.headers['authorization'];

      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response(
          401,
          body: jsonEncode(
              {'error': 'missing or invalid Authorization header'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final token = authHeader.substring(7);

      try {
        final claims = tokens.verify(token);
        return inner(request.change(
          context: {'userId': claims.userId, 'deviceId': claims.deviceId},
        ));
      } on TokenExpiredException {
        return Response(
          401,
          body: jsonEncode({'error': 'token expired'}),
          headers: {'Content-Type': 'application/json'},
        );
      } on InvalidTokenException catch (e) {
        return Response(
          401,
          body: jsonEncode({'error': e.message}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    };
  };
}
