import 'package:shelf/shelf.dart';

import '../core/config.dart';

Middleware corsMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: _headers);
      }
      final response = await inner(request);
      return response.change(headers: _headers);
    };
  };
}

Map<String, String> get _headers => {
      'Access-Control-Allow-Origin': Config.allowedOrigins,
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Authorization, Content-Type',
      'Access-Control-Max-Age': '86400',
    };
