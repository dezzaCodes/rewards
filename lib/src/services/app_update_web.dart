import 'dart:js_interop';

import 'package:web/web.dart' as web;

@JS('rewardsDownloadUpdate')
external JSPromise<JSBoolean> _downloadUpdate();

/// Downloads a newer version of the web app if one has been deployed, and
/// returns whether it did. Call [restartApp] to switch to it.
///
/// The app never updates by itself (see web/sw.js); this is what the refresh
/// button uses.
Future<bool> downloadAppUpdate() async {
  try {
    return (await _downloadUpdate().toDart).toDart;
  } catch (_) {
    // No service worker, for example while developing locally.
    return false;
  }
}

void restartApp() => web.window.location.reload();
