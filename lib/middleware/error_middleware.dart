import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

import '../core/http_utils.dart';

Middleware errorMiddleware() {
  return (Handler inner) {
    return (Request request) async {
      try {
        return await inner(request);
      } on BadRequestException catch (e) {
        return _json(400, {'error': e.message});
      } on PayloadTooLargeException catch (e) {
        return _json(413, {'error': 'request body too large (max ${e.maxBytes} bytes)'});
      } catch (e, stack) {
        stderr.writeln('[ERROR] ${request.method} ${request.url}');
        stderr.writeln(e);
        stderr.writeln(stack);
        return _json(500, {'error': 'internal server error'});
      }
    };
  };
}

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );
