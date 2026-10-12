import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:polypodium_server/features/mcp/mcp_server.dart';
import 'package:polypodium_server/features/mcp/photo_intake.dart';

const _jpeg = [0xff, 0xd8, 0xff, 0xe0, 1, 2, 3];

void main() {
  late Directory dir;
  late PhotoIntake intake;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    intake = PhotoIntake(dir.path,
        maxBytes: 64,
        lookup: (host) async => switch (host) {
              'intranet.example' => [InternetAddress('192.168.0.10')],
              _ => [InternetAddress('93.184.216.34')],
            });
  });

  tearDown(() => dir.delete(recursive: true));

  Future<String> error(Object? spec) async {
    try {
      await intake.read(spec);
    } on McpToolError catch (e) {
      return e.message;
    }
    fail('no error for $spec');
  }

  test('reads base64, plain or as a data URL', () async {
    final plain = await intake.read({'data': base64.encode(_jpeg)});
    expect(plain.bytes, _jpeg);
    expect(plain.extension, '.jpg');

    final dataUrl = await intake
        .read({'data': 'data:image/jpeg;base64,${base64.encode(_jpeg)}'});
    expect(dataUrl.bytes, _jpeg);
  });

  test('rejects what is not a usable image', () async {
    expect(await error({'data': base64.encode([1, 2, 3])}),
        contains('not a JPEG'));
    expect(await error({'data': '***'}), contains('base64'));
    expect(await error({'data': base64.encode(List.filled(65, 0xff))}),
        contains('too large'));
    expect(await error({}), contains('either data or url'));
    expect(await error({'data': 'x', 'url': 'https://a.example/x.jpg'}),
        contains('either data or url'));
    expect(await error('photo.jpg'), contains('{"data"} or {"url"}'));
  });

  test('never fetches from the server\'s own network', () async {
    for (final url in [
      'http://127.0.0.1/x.jpg',
      'http://[::1]/x.jpg',
      'http://10.0.0.5/x.jpg',
      'http://169.254.169.254/latest',
      'http://intranet.example/x.jpg',
    ]) {
      expect(await error({'url': url}), contains('not a public address'),
          reason: url);
    }
    expect(await error({'url': 'file:///etc/passwd'}), contains('http(s)'));
  });

  test('isPublicAddress', () {
    bool public(String ip) => isPublicAddress(InternetAddress(ip));
    expect(public('8.8.8.8'), isTrue);
    expect(public('2001:4860:4860::8888'), isTrue);
    for (final ip in [
      '0.0.0.0',
      '172.16.1.1',
      '172.31.255.255',
      '100.64.0.1',
      '224.0.0.1',
      'fd00::1',
      'fe80::1',
      '::',
      '::ffff:127.0.0.1',
      '::ffff:192.168.1.1',
    ]) {
      expect(public(ip), isFalse, reason: ip);
    }
    expect(public('172.32.0.1'), isTrue);
  });

  test('imageExtension knows the formats the app shows', () {
    expect(imageExtension([0x89, 0x50, 0x4e, 0x47, 0x0d]), '.png');
    expect(imageExtension(ascii.encode('GIF89a')), '.gif');
    expect(imageExtension([...ascii.encode('RIFF'), 0, 0, 0, 0,
        ...ascii.encode('WEBP')]), '.webp');
    expect(imageExtension(ascii.encode('RIFF....WAVE')), isNull);
  });

  test('save writes where the sync serves photos from', () async {
    await intake.save('g1', 'e1.jpg', _jpeg);
    expect(File('${dir.path}/g1/e1.jpg').readAsBytesSync(), _jpeg);
  });
}
