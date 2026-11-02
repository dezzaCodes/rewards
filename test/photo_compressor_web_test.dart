@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:app_blueprint/src/services/photo_compressor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

/// A phone-sized PNG screenshot filled with noise, which compresses poorly.
Future<Uint8List> _noisyScreenshot() async {
  const width = 1170;
  const height = 2532;
  final canvas = web.HTMLCanvasElement()
    ..width = width
    ..height = height;
  final context = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
  final pixels = context.createImageData(width.toJS, height);
  final random = Random(1);
  for (var i = 0; i < width * height * 4; i++) {
    pixels.data.toDart[i] = i % 4 == 3 ? 255 : random.nextInt(256);
  }
  context.putImageData(pixels, 0, 0);

  final completer = Completer<web.Blob>();
  canvas.toBlob(((web.Blob? blob) => completer.complete(blob!)).toJS);
  final blob = await completer.future;
  return (await blob.arrayBuffer().toDart).toDart.asUint8List();
}

void main() {
  test('shrinks a large PNG screenshot into a JPEG under the limit', () async {
    final png = await _noisyScreenshot();
    expect(png.length, greaterThan(700 * 1024));

    final jpeg = await compressPhoto(png, maxBytes: 400 * 1024);

    expect(jpeg.length, lessThanOrEqualTo(400 * 1024));
    expect(jpeg.sublist(0, 2), [0xFF, 0xD8]); // JPEG magic number.
  });
}
