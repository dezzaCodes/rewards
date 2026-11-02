import 'dart:typed_data';

/// The image picker already resizes and re-encodes photos on Android and iOS,
/// so they are uploaded as-is there.
Future<Uint8List> compressPhoto(
  Uint8List bytes, {
  required int maxBytes,
}) async => bytes;
