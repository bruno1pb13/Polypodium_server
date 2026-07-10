import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../features/auth/i_auth_repository.dart';

Middleware adminOnlyMiddleware(IAuthRepository authRepo) {
  return (Handler inner) {
    return (Request request) async {
      final userId = request.context['userId'] as String?;
      if (userId == null) {
        return Response(
          401,
          body: jsonEncode({'error': 'missing or invalid Authorization header'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      final info = await authRepo.getAuthInfo(userId);
      if (info == null || info['role'] != 'admin') {
        return Response(
          403,
          body: jsonEncode({'error': 'admin access required'}),
          headers: {'Content-Type': 'application/json'},
        );
      }

      return inner(request);
    };
  };
}
