import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:shelf/shelf.dart';

import '../config.dart';

Middleware authMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      final authHeader =
          request.headers['Authorization'] ?? request.headers['authorization'];

      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response(
          401,
          body: jsonEncode({'error': 'missing or invalid Authorization header'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final token = authHeader.substring(7);

      try {
        final jwt = JWT.verify(token, SecretKey(Config.jwtSecret));
        final payload = jwt.payload as Map<String, dynamic>;
        final userId = jwt.subject;
        final deviceId = payload['deviceId'] as String?;

        if (userId == null || deviceId == null) {
          return Response(
            401,
            body: jsonEncode({'error': 'malformed token claims'}),
            headers: {'Content-Type': 'application/json'},
          );
        }

        return inner(request.change(
          context: {'userId': userId, 'deviceId': deviceId},
        ));
      } on JWTExpiredException {
        return Response(
          401,
          body: jsonEncode({'error': 'token expired'}),
          headers: {'Content-Type': 'application/json'},
        );
      } on JWTException catch (e) {
        return Response(
          401,
          body: jsonEncode({'error': 'invalid token: ${e.message}'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    };
  };
}
