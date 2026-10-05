import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../../core/config.dart';
import '../../core/http_utils.dart';

class PhotoHandler {
  const PhotoHandler(this._photosDir);
  final String _photosDir;

  Future<Response> upload(Request request, String photoKey) async {
    final safeKey = _sanitizeKey(photoKey);
    if (safeKey == null) return _error(400, 'invalid photo key');

    // A personal garden's id is its owner's user id, so photos stored per
    // user before gardens existed are already where this looks for them.
    final gardenId = request.context['gardenId'] as String;
    final gardenDir = Directory('$_photosDir/$gardenId');
    if (!gardenDir.existsSync()) await gardenDir.create(recursive: true);

    final List<int> bytes;
    try {
      bytes = await readBodyCapped(request, Config.maxPhotoBytes);
    } on PayloadTooLargeException {
      return _error(413, 'photo too large (max ${Config.maxPhotoBytes} bytes)');
    }
    if (bytes.isEmpty) return _error(400, 'empty body');

    await File('${gardenDir.path}/$safeKey').writeAsBytes(bytes);
    return _json(200, {'ok': true, 'photoKey': safeKey});
  }

  Future<Response> download(Request request, String photoKey) async {
    final safeKey = _sanitizeKey(photoKey);
    if (safeKey == null) return _error(400, 'invalid photo key');

    final gardenId = request.context['gardenId'] as String;
    final file = File('$_photosDir/$gardenId/$safeKey');
    if (!file.existsSync()) return _error(404, 'photo not found');

    return Response.ok(
      await file.readAsBytes(),
      headers: {'Content-Type': _contentType(safeKey)},
    );
  }

  /// Returns a filename safe to join under the garden's photo directory, or null
  /// if the key tries to escape it. `basename` collapses any path components;
  /// requiring the result to equal the input rejects `..`, slashes, and
  /// leading-dot tricks rather than silently rewriting them.
  static String? _sanitizeKey(String photoKey) {
    final base = p.basename(photoKey);
    if (base.isEmpty || base == '.' || base == '..') return null;
    if (base != photoKey) return null;
    return base;
  }

  static String _contentType(String key) {
    final lower = key.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'application/octet-stream';
  }
}

Response _json(int status, Object body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'Content-Type': 'application/json'},
    );

Response _error(int status, String message) =>
    _json(status, {'error': message});
