import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Firebase project: rewards-cards-dezza.
///
/// Only the web app is registered so far. To add Android and iOS, run:
/// `flutterfire configure --project=rewards-cards-dezza --out=lib/firebase_options.dart`
///
/// These values are platform identifiers, not credentials, and should be
/// committed.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }

    throw UnsupportedError(
      'Firebase has not been configured for this platform yet. '
      'Run flutterfire configure and commit the generated '
      'lib/firebase_options.dart file.',
    );
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAxaHkFrLiTij_U9R3LqjdqP1JDdAIJLwA',
    appId: '1:1072431577020:web:2c9d08c9f3cf072271ddb9',
    messagingSenderId: '1072431577020',
    projectId: 'rewards-cards-dezza',
    authDomain: 'rewards-cards-dezza.firebaseapp.com',
    storageBucket: 'rewards-cards-dezza.firebasestorage.app',
  );
}
