import 'package:shelf/shelf.dart';

import '../core/config.dart';

Middleware corsMiddleware() {
  final raw = Config.allowedOrigins.trim();
  final allowAll = raw == '*';
  final allowSet = allowAll
      ? const <String>{}
      : raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();

  return (Handler inner) {
    return (Request request) async {
      final origin = request.headers['origin'] ?? request.headers['Origin'];

      // With an explicit allowlist, only ever echo back an origin we actually
      // trust — never a blanket '*'. A non-matching origin gets no CORS header
      // at all, so the browser blocks the cross-origin read.
      String? allowOrigin;
      if (allowAll) {
        allowOrigin = '*';
      } else if (origin != null && allowSet.contains(origin)) {
        allowOrigin = origin;
      }

      final headers = _headers(allowOrigin, allowAll);

      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: headers);
      }
      final response = await inner(request);
      return response.change(headers: headers);
    };
  };
}

Map<String, String> _headers(String? allowOrigin, bool allowAll) => {
      if (allowOrigin != null) 'Access-Control-Allow-Origin': allowOrigin,
      'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Authorization, Content-Type',
      'Access-Control-Max-Age': '86400',
      // Responses vary by request Origin once we do per-origin matching, so
      // caches must key on it.
      if (!allowAll) 'Vary': 'Origin',
    };
