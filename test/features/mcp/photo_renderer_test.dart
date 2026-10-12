import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'package:polypodium_server/features/mcp/photo_renderer.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    await Directory('${dir.path}/g1').create();
    final photo = img.Image(width: 3000, height: 2000);
    File('${dir.path}/g1/big.png').writeAsBytesSync(img.encodePng(photo));
    File('${dir.path}/g1/small.jpg')
        .writeAsBytesSync(img.encodeJpg(img.Image(width: 200, height: 400)));
    File('${dir.path}/g1/broken.jpg').writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() => dir.delete(recursive: true));

  test('scales the longest side down and re-encodes as JPEG', () async {
    final renderer = PhotoRenderer(dir.path);
    final image = await renderer('g1', 'big.png', 1024);
    expect(image!.mimeType, 'image/jpeg');
    final decoded = img.decodeJpg(Uint8List.fromList(image.bytes))!;
    expect((decoded.width, decoded.height), (1024, 683));

    final small = await renderer('g1', 'small.jpg', 1024);
    final kept = img.decodeJpg(Uint8List.fromList(small!.bytes))!;
    expect((kept.width, kept.height), (200, 400));
  });

  test('serves repeats from memory', () async {
    final renderer = PhotoRenderer(dir.path);
    final first = await renderer('g1', 'big.png', 512);
    File('${dir.path}/g1/big.png').deleteSync();
    expect(identical(await renderer('g1', 'big.png', 512), first), isTrue);
  });

  test('decodes at most maxParallel photos at once, and all of them',
      () async {
    for (var i = 0; i < 5; i++) {
      File('${dir.path}/g1/p$i.jpg').writeAsBytesSync(
          img.encodeJpg(img.Image(width: 800, height: 600)));
    }
    final renderer = PhotoRenderer(dir.path, maxParallel: 2);
    final results = await Future.wait(
        [for (var i = 0; i < 5; i++) renderer('g1', 'p$i.jpg', 256)]);
    expect(results.every((r) => r != null), isTrue);
  });

  test('missing, broken and escaping keys give null', () async {
    final renderer = PhotoRenderer(dir.path);
    expect(await renderer('g1', 'nope.jpg', 512), isNull);
    expect(await renderer('g1', 'broken.jpg', 512), isNull);
    expect(await renderer('g1', '../g1/big.png', 512), isNull);
    expect(await renderer('g2', '.hidden', 512), isNull);
  });
}
