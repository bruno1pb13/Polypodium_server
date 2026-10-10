import 'package:polypodium_server/features/admin/release_checker.dart';
import 'package:test/test.dart';

void main() {
  group('isNewerVersion', () {
    test('compares the leading x.y.z numerically', () {
      expect(isNewerVersion('v2.10.0', '2.9.3'), isTrue);
      expect(isNewerVersion('v.3.0.0', '2.9.9'), isTrue);
      expect(isNewerVersion('v2.8.0', '2.8.0'), isFalse);
      expect(isNewerVersion('v2.7.9', '2.8.0'), isFalse);
    });

    test('a main build after a tag counts as that tag', () {
      expect(isNewerVersion('v2.8.0', '2.8.0-3-gabc1234'), isFalse);
      expect(isNewerVersion('v2.9.0', '2.8.0-3-gabc1234'), isTrue);
    });

    test('a local dev build or a malformed tag is never behind', () {
      expect(isNewerVersion('v9.9.9', 'dev'), isFalse);
      expect(isNewerVersion('nightly', '2.8.0'), isFalse);
    });
  });

  test('reports a newer release', () async {
    final checker =
        ReleaseChecker('2.8.0', fetchLatestTag: () async => 'v2.9.0');
    expect(checker.latestVersion, isNull);
    expect(checker.updateAvailable, isFalse);

    await checker.refresh();
    expect(checker.latestVersion, '2.9.0');
    expect(checker.updateAvailable, isTrue);
  });

  test('up to date when the latest release is this version', () async {
    final checker =
        ReleaseChecker('2.9.0', fetchLatestTag: () async => 'v2.9.0');
    await checker.refresh();
    expect(checker.latestVersion, '2.9.0');
    expect(checker.updateAvailable, isFalse);
  });

  test('a failed check keeps the last known answer', () async {
    var fail = false;
    final checker = ReleaseChecker('2.8.0', fetchLatestTag: () async {
      if (fail) throw Exception('offline');
      return 'v2.9.0';
    });
    await checker.refresh();
    fail = true;
    await checker.refresh();
    expect(checker.latestVersion, '2.9.0');
    expect(checker.updateAvailable, isTrue);
  });

  test('no release published yet means nothing to report', () async {
    final checker = ReleaseChecker('2.8.0', fetchLatestTag: () async => null);
    await checker.refresh();
    expect(checker.latestVersion, isNull);
    expect(checker.updateAvailable, isFalse);
  });
}
