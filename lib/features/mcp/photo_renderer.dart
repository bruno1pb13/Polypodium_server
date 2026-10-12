import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:image/image.dart' as img;

import 'mcp_server.dart';

/// Loads a garden photo for the model, scaled down so it fits what MCP
/// clients accept (originals can be 15 MB). Null when the file is missing
/// or isn't an image.
typedef PhotoLoader = Future<McpImage?> Function(
    String gardenId, String photoKey, int maxSide);

/// [PhotoLoader] over the photo directory the sync stores files in
/// (`<photosDir>/<gardenId>/<photoKey>`). Decoding and re-encoding run in a
/// separate isolate so a large photo doesn't stall other requests; recent
/// results are kept in memory, since a conversation tends to ask for the
/// same photos again. At most [maxParallel] photos are decoded at once: a
/// decoded 12 MP photo takes about 40 MB.
class PhotoRenderer {
  PhotoRenderer(this._photosDir, {this.cacheSize = 48, this.maxParallel = 2});

  final String _photosDir;
  final int cacheSize;
  final int maxParallel;
  final _cache = LinkedHashMap<String, McpImage>();
  var _running = 0;
  final _waiting = Queue<Completer<void>>();

  Future<McpImage?> call(String gardenId, String photoKey, int maxSide) async {
    // Keys come from synced payloads: never let one leave the garden dir.
    if (photoKey.contains('/') ||
        photoKey.contains(r'\') ||
        photoKey.startsWith('.')) {
      return null;
    }
    final cacheKey = '$gardenId/$photoKey@$maxSide';
    final cached = _cache.remove(cacheKey);
    if (cached != null) return _cache[cacheKey] = cached;

    final path = '$_photosDir/$gardenId/$photoKey';
    if (!File(path).existsSync()) return null;
    final bytes =
        await _limited(() => Isolate.run(() => _shrink(path, maxSide)));
    if (bytes == null) return null;
    final image = McpImage(bytes, 'image/jpeg');
    _cache[cacheKey] = image;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    return image;
  }

  Future<T> _limited<T>(Future<T> Function() task) async {
    if (_running >= maxParallel) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await task();
    } finally {
      // Hand the slot straight to the next in line, if any.
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}

List<int>? _shrink(String path, int maxSide) {
  final decoded = img.decodeImage(File(path).readAsBytesSync());
  if (decoded == null) return null;
  // Phone photos are often stored sideways with an EXIF orientation.
  var image = img.bakeOrientation(decoded);
  if (image.width > maxSide || image.height > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide)
        : img.copyResize(image, height: maxSide);
  }
  return img.encodeJpg(image, quality: 80);
}
