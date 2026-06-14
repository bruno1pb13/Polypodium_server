import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';

class PhotoHandler {
  const PhotoHandler(this._photosDir);
  final String _photosDir;

  Future<Response> upload(Request request, String photoKey) async {
    final userId = request.context['userId'] as String;
    final userDir = Directory('$_photosDir/$userId');
    if (!userDir.existsSync()) await userDir.create(recursive: true);

    final bytes = await request
        .read()
        .fold<List<int>>([], (acc, chunk) => acc..addAll(chunk));
    if (bytes.isEmpty) return _error(400, 'empty body');

    await File('${userDir.path}/$photoKey').writeAsBytes(bytes);
    return _json(200, {'ok': true, 'photoKey': photoKey});
  }

  Future<Response> download(Request request, String photoKey) async {
    final userId = request.context['userId'] as String;
    final file = File('$_photosDir/$userId/$photoKey');
    if (!file.existsSync()) return _error(404, 'photo not found');

    return Response.ok(
      await file.readAsBytes(),
      headers: {'Content-Type': _contentType(photoKey)},
    );
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
