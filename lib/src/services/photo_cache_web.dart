import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Card photos kept in the browser's Cache Storage.
///
/// Firestore's own offline cache can't be read until Firebase Auth has
/// finished starting, which takes seconds on mobile browsers. This cache can
/// be read the moment the app opens, so photos show instantly.
const _cacheName = 'rewards-card-photos-v1';

String _key(String photoId) =>
    Uri.base.resolve('__card-photos__/$photoId').toString();

Future<Uint8List?> readCachedPhoto(String photoId) async {
  try {
    final cache = await web.window.caches.open(_cacheName).toDart;
    final response = await cache.match(_key(photoId).toJS).toDart;
    if (response == null) {
      return null;
    }

    final buffer = await response.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  } catch (_) {
    // Cache Storage can be unavailable, for example in private browsing.
    return null;
  }
}

Future<void> writeCachedPhoto(String photoId, Uint8List bytes) async {
  try {
    final cache = await web.window.caches.open(_cacheName).toDart;
    await cache.put(_key(photoId).toJS, web.Response(bytes.toJS)).toDart;
  } catch (_) {
    // Not caching only makes the next load slower.
  }
}

/// Removes every cached photo, for example when someone signs out.
Future<void> clearCachedPhotos() async {
  try {
    await web.window.caches.delete(_cacheName).toDart;
  } catch (_) {}
}
