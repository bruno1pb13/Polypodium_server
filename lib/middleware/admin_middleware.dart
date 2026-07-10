import 'dart:convert';

import 'package:shelf/shelf.dart';

/// Requires the caller to be an admin. Relies on [authMiddleware] having already
/// run (it verifies the token, rejects disabled accounts, and injects `role`
/// into the request context), so this only has to check the role — no second
/// database round-trip.
Middleware adminOnlyMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      final role = request.context['role'] as String?;
      if (role == null) {
        return Response(
          401,
          body: jsonEncode({'error': 'missing or invalid Authorization header'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      if (role != 'admin') {
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
