import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

Middleware errorMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } catch (e, stack) {
        stderr.writeln('[ERROR] ${request.method} ${request.url}');
        stderr.writeln(e);
        stderr.writeln(stack);
        return Response.internalServerError(
          body: jsonEncode({'error': 'internal server error'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
    };
  };
}
