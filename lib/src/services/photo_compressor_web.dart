import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

// Large enough to keep barcodes on card screenshots scannable.
const _maxEdge = 2000;
const _qualities = [0.85, 0.7, 0.55];

/// Re-encodes a photo as a JPEG no larger than [maxBytes], using the browser's
/// own image codecs so it stays fast.
///
/// Screenshots are usually PNGs, which ignore quality settings and can be
/// several megabytes, so they are converted. Quality drops first, then the
/// size, until the photo fits.
Future<Uint8List> compressPhoto(
  Uint8List bytes, {
  required int maxBytes,
}) async {
  final url = web.URL.createObjectURL(web.Blob([bytes.toJS].toJS));
  try {
    final image = web.HTMLImageElement()..src = url;
    await image.decode().toDart;

    final width = image.naturalWidth;
    final height = image.naturalHeight;
    var scale = math.min(1.0, _maxEdge / math.max(width, height));
    while (true) {
      final canvasWidth = math.max(1, (width * scale).round());
      final canvasHeight = math.max(1, (height * scale).round());
      final canvas = web.HTMLCanvasElement()
        ..width = canvasWidth
        ..height = canvasHeight;
      // JPEG has no transparency, so paint transparent areas white, not black.
      (canvas.getContext('2d')! as web.CanvasRenderingContext2D)
        ..fillStyle = 'white'.toJS
        ..fillRect(0, 0, canvasWidth, canvasHeight)
        ..drawImage(image, 0, 0, canvasWidth, canvasHeight);

      for (final quality in _qualities) {
        final blob = await _toJpeg(canvas, quality);
        if (blob.size <= maxBytes || scale < 0.1) {
          return (await blob.arrayBuffer().toDart).toDart.asUint8List();
        }
      }
      scale *= 0.75;
    }
  } finally {
    web.URL.revokeObjectURL(url);
  }
}

Future<web.Blob> _toJpeg(web.HTMLCanvasElement canvas, double quality) {
  final completer = Completer<web.Blob>();
  canvas.toBlob(
    (web.Blob? blob) {
      if (blob == null) {
        completer.completeError(StateError('Could not convert the photo.'));
      } else {
        completer.complete(blob);
      }
    }.toJS,
    'image/jpeg',
    quality.toJS,
  );
  return completer.future;
}
