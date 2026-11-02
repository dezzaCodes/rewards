import 'dart:typed_data';

// Android and iOS keep Firestore's offline cache available straight away, so
// they don't need a separate photo cache.

Future<Uint8List?> readCachedPhoto(String photoId) async => null;

Future<void> writeCachedPhoto(String photoId, Uint8List bytes) async {}

Future<void> clearCachedPhotos() async {}
