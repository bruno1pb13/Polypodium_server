import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Fetches the tag of the newest published release, or null when there is
/// none. Throws when the source can't be reached.
typedef LatestTagFetcher = Future<String?> Function();

/// Polls GitHub for the newest server release so admins can be told this
/// server is behind. It only informs: updating the deployment (pulling the
/// new Docker image) stays the operator's job.
class ReleaseChecker {
  ReleaseChecker(
    this.currentVersion, {
    LatestTagFetcher? fetchLatestTag,
    String repository = 'bruno1pb13/Polypodium_server',
  }) : _fetchLatestTag = fetchLatestTag ?? _githubFetcher(repository);

  /// Version this binary was built as: `2.8.0`, `2.8.0-3-gabc1234` for a
  /// main build after that tag, or `dev` for a local build.
  final String currentVersion;
  final LatestTagFetcher _fetchLatestTag;

  Timer? _timer;
  String? _latestVersion;

  /// Newest released version (`2.9.0`), or null until a check succeeds.
  String? get latestVersion => _latestVersion;

  bool get updateAvailable =>
      _latestVersion != null && isNewerVersion(_latestVersion!, currentVersion);

  /// Checks shortly after boot and then every [every]. Releases are rare, so
  /// a twice-daily poll stays far below GitHub's anonymous rate limit.
  void start({
    Duration every = const Duration(hours: 12),
    Duration firstRunAfter = const Duration(seconds: 30),
  }) {
    _timer?.cancel();
    _timer = Timer(firstRunAfter, () {
      refresh();
      _timer = Timer.periodic(every, (_) => refresh());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One check. A failure keeps the last known answer: this is advisory and
  /// must never disturb the server.
  Future<void> refresh() async {
    try {
      final tag = await _fetchLatestTag();
      if (tag != null) _latestVersion = _parts(tag)?.join('.');
    } catch (e) {
      print('[ReleaseChecker] check failed: $e');
    }
  }
}

LatestTagFetcher _githubFetcher(String repository) => () async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final request = await client.getUrl(Uri.parse(
            'https://api.github.com/repos/$repository/releases/latest'));
        request.headers
          ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
          ..set(HttpHeaders.userAgentHeader, 'polypodium-server');
        final response =
            await request.close().timeout(const Duration(seconds: 15));
        final body = await response.transform(utf8.decoder).join();
        // 404: the repository has no published release yet.
        if (response.statusCode == 404) return null;
        if (response.statusCode != 200) {
          throw HttpException('GitHub releases: HTTP ${response.statusCode}');
        }
        // /latest already skips drafts and pre-releases.
        return (jsonDecode(body) as Map<String, dynamic>)['tag_name'] as String?;
      } finally {
        client.close(force: true);
      }
    };

/// Whether [candidate] is a higher x.y.z than [current]. Only the leading
/// x.y.z counts, so `2.8.0-3-gabc1234` compares as 2.8.0; a version without
/// one (`dev`) is never behind, since there is nothing to compare.
bool isNewerVersion(String candidate, String current) {
  final a = _parts(candidate);
  final b = _parts(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

/// `v2.8.0`, the legacy `v.2.8.0`, `2.8.0+4` and `2.8.0-3-gabc` → [2, 8, 0].
List<int>? _parts(String version) {
  final match =
      RegExp(r'^v?\.?(\d+)\.(\d+)\.(\d+)').firstMatch(version.trim());
  if (match == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
}
