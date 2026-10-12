import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_server.dart';

/// A photo handed to a write tool, checked and ready to store.
class IncomingPhoto {
  const IncomingPhoto(this.bytes, this.extension);
  final List<int> bytes;

  /// `.jpg`, `.png`, `.webp` or `.gif`, from the file's own signature.
  final String extension;
}

/// Takes photos for the write tools: reads one given as base64 or as a URL,
/// and stores it where the sync serves photos from.
abstract interface class IPhotoIntake {
  /// Reads `{"data": base64}` or `{"url": "https://…"}`. Throws
  /// [McpToolError] for anything that isn't a usable image.
  Future<IncomingPhoto> read(Object? spec);

  /// Writes [bytes] as `<photosDir>/<gardenId>/<photoKey>`, the file a
  /// device downloads for a synced `photoKey`.
  Future<void> save(String gardenId, String photoKey, List<int> bytes);
}

/// [IPhotoIntake] over the sync's photo directory. URLs are fetched only
/// from public addresses (no loopback, private or link-local hosts, so a
/// token can't make the server probe its own network), following at most
/// [maxRedirects] redirects, each checked again.
class PhotoIntake implements IPhotoIntake {
  PhotoIntake(
    this._photosDir, {
    required this.maxBytes,
    this.timeout = const Duration(seconds: 30),
    this.maxRedirects = 3,
    Future<List<InternetAddress>> Function(String host)? lookup,
  }) : _lookup = lookup ?? InternetAddress.lookup;

  final String _photosDir;
  final int maxBytes;
  final Duration timeout;
  final int maxRedirects;
  final Future<List<InternetAddress>> Function(String host) _lookup;

  @override
  Future<IncomingPhoto> read(Object? spec) async {
    if (spec is! Map) {
      throw const McpToolError('each photo must be {"data"} or {"url"}');
    }
    final data = spec['data'];
    final url = spec['url'];
    if ((data == null) == (url == null)) {
      throw const McpToolError('each photo needs either data or url');
    }
    final bytes = data != null ? _decode(data) : await _fetch(url);
    if (bytes.isEmpty) throw const McpToolError('empty photo');
    if (bytes.length > maxBytes) {
      throw McpToolError('photo too large (max $maxBytes bytes)');
    }
    final extension = imageExtension(bytes) ??
        (throw const McpToolError(
            'not a JPEG, PNG, WebP or GIF image'));
    return IncomingPhoto(bytes, extension);
  }

  @override
  Future<void> save(String gardenId, String photoKey, List<int> bytes) async {
    final dir = Directory('$_photosDir/$gardenId');
    if (!dir.existsSync()) await dir.create(recursive: true);
    await File('${dir.path}/$photoKey').writeAsBytes(bytes, flush: true);
  }

  List<int> _decode(Object? data) {
    if (data is! String) throw const McpToolError('data must be base64 text');
    // Accept a data URL too: `data:image/jpeg;base64,…`.
    final comma = data.startsWith('data:') ? data.indexOf(',') : -1;
    final text = data.substring(comma + 1).replaceAll(RegExp(r'\s'), '');
    if (text.length > maxBytes * 4 ~/ 3 + 4) {
      throw McpToolError('photo too large (max $maxBytes bytes)');
    }
    try {
      return base64.decode(base64.normalize(text));
    } on FormatException {
      throw const McpToolError('data is not valid base64');
    }
  }

  Future<List<int>> _fetch(Object? raw) async {
    if (raw is! String) throw const McpToolError('url must be a string');
    var uri = Uri.tryParse(raw.trim());
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = 'Polypodium-MCP';
    try {
      for (var hop = 0;; hop++) {
        if (uri == null ||
            !(uri.isScheme('http') || uri.isScheme('https')) ||
            uri.host.isEmpty) {
          throw const McpToolError('url must be an http(s) URL');
        }
        await _requirePublicHost(uri.host);
        final request = await client.getUrl(uri).timeout(timeout);
        request.followRedirects = false;
        final response = await request.close().timeout(timeout);
        if (response.isRedirect) {
          await response.drain<void>();
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (hop >= maxRedirects || location == null) {
            throw const McpToolError('too many redirects');
          }
          uri = uri.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
          throw McpToolError('url answered ${response.statusCode}');
        }
        if (response.contentLength > maxBytes) {
          throw McpToolError('photo too large (max $maxBytes bytes)');
        }
        final bytes = <int>[];
        await for (final chunk in response.timeout(timeout)) {
          bytes.addAll(chunk);
          if (bytes.length > maxBytes) {
            throw McpToolError('photo too large (max $maxBytes bytes)');
          }
        }
        return bytes;
      }
    } on McpToolError {
      rethrow;
    } on TimeoutException {
      throw const McpToolError('url took too long to answer');
    } on Exception catch (e) {
      throw McpToolError('could not download the photo: $e');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _requirePublicHost(String host) async {
    final List<InternetAddress> addresses;
    try {
      final ip = InternetAddress.tryParse(host);
      addresses = ip != null ? [ip] : await _lookup(host).timeout(timeout);
    } on Exception {
      throw McpToolError('could not resolve $host');
    }
    if (addresses.isEmpty || addresses.any((a) => !isPublicAddress(a))) {
      throw McpToolError('url host is not a public address: $host');
    }
  }
}

/// Whether [address] is routable on the public internet: not loopback,
/// private, carrier-grade NAT, link-local, multicast or unspecified.
bool isPublicAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return false;
  }
  var b = address.rawAddress;
  if (address.type == InternetAddressType.IPv6) {
    // IPv4-mapped (::ffff:a.b.c.d): judge the IPv4 address.
    final mapped = b.sublist(0, 10).every((x) => x == 0) &&
        b[10] == 0xff &&
        b[11] == 0xff;
    if (!mapped) {
      if (b.every((x) => x == 0)) return false; // ::
      return (b[0] & 0xfe) != 0xfc; // fc00::/7 unique local
    }
    b = b.sublist(12);
  }
  return !(b[0] == 0 ||
      b[0] == 10 ||
      b[0] == 127 ||
      (b[0] == 100 && b[1] >= 64 && b[1] < 128) ||
      (b[0] == 169 && b[1] == 254) ||
      (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
      (b[0] == 192 && b[1] == 168) ||
      b[0] >= 224);
}

/// The file extension for an image the app can show, from its signature.
String? imageExtension(List<int> b) {
  bool startsWith(List<int> sig, [int at = 0]) {
    if (b.length < at + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[at + i] != sig[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0xff, 0xd8, 0xff])) return '.jpg';
  if (startsWith(const [0x89, 0x50, 0x4e, 0x47])) return '.png';
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return '.gif';
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return '.webp';
  }
  return null;
}
