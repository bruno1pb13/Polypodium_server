import 'dart:convert';

import 'package:shelf/shelf.dart';

/// Thrown when a request body exceeds the allowed size. Mapped to HTTP 413 by
/// [errorMiddleware].
class PayloadTooLargeException implements Exception {
  const PayloadTooLargeException(this.maxBytes);
  final int maxBytes;
}

/// Thrown for malformed client input. Mapped to HTTP 400 by [errorMiddleware].
class BadRequestException implements Exception {
  const BadRequestException(this.message);
  final String message;
}

/// Reads the full request body but aborts (throwing [PayloadTooLargeException])
/// as soon as more than [maxBytes] have arrived, so an oversized or unbounded
/// (chunked, no Content-Length) upload can't exhaust memory.
Future<List<int>> readBodyCapped(Request request, int maxBytes) async {
  final bytes = <int>[];
  await for (final chunk in request.read()) {
    bytes.addAll(chunk);
    if (bytes.length > maxBytes) {
      throw PayloadTooLargeException(maxBytes);
    }
  }
  return bytes;
}

/// Reads, size-caps, and decodes a JSON object body, returning 400-worthy
/// errors instead of crashing to a 500 on malformed input.
Future<Map<String, dynamic>> readJsonMap(
  Request request, {
  required int maxBytes,
}) async {
  final bytes = await readBodyCapped(request, maxBytes);
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    throw const BadRequestException('invalid JSON body');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const BadRequestException('expected a JSON object');
  }
  return decoded;
}
