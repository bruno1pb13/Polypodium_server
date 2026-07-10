import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

/// Simple in-memory fixed-window rate limiter, keyed by client IP. Adequate for
/// a single-instance self-hosted server; it is not shared across replicas.
///
/// When [behindProxy] is true the client IP is taken from `X-Forwarded-For`
/// (set by the reverse proxy) instead of the direct socket, which would
/// otherwise be the proxy's address for every request.
Middleware rateLimitMiddleware({
  required int maxRequests,
  required Duration window,
  required bool behindProxy,
}) {
  final hits = <String, List<int>>{};

  return (Handler inner) {
    return (Request request) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final windowStart = now - window.inMilliseconds;
      final ip = _clientIp(request, behindProxy);

      final timestamps = (hits[ip] ??= <int>[])
        ..removeWhere((t) => t < windowStart);

      if (timestamps.length >= maxRequests) {
        final retryAfter =
            ((timestamps.first + window.inMilliseconds - now) / 1000).ceil();
        return Response(
          429,
          body: jsonEncode({'error': 'too many requests, slow down'}),
          headers: {
            'Content-Type': 'application/json',
            'Retry-After': '${retryAfter < 1 ? 1 : retryAfter}',
          },
        );
      }

      timestamps.add(now);

      // Bound memory: occasionally drop entries whose whole window has expired.
      if (hits.length > 10000) {
        hits.removeWhere((_, ts) => ts.every((t) => t < windowStart));
      }

      return inner(request);
    };
  };
}

String _clientIp(Request request, bool behindProxy) {
  if (behindProxy) {
    final xff =
        request.headers['x-forwarded-for'] ?? request.headers['X-Forwarded-For'];
    if (xff != null && xff.isNotEmpty) {
      return xff.split(',').first.trim();
    }
  }
  final conn = request.context['shelf.io.connection_info'];
  if (conn is HttpConnectionInfo) return conn.remoteAddress.address;
  return 'unknown';
}
