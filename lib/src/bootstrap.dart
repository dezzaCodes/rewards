import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';
import 'services/firestore_notice_repository.dart';
import 'services/push_notification_service.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (!FirebaseRuntimeConfig.isConfigured) {
    return;
  }

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

class AppBootstrap {
  const AppBootstrap({
    required this.firebaseReady,
    required this.statusMessage,
    this.errorMessage,
    this.noticeRepository,
    this.pushNotificationService,
  });

  final bool firebaseReady;
  final String statusMessage;
  final String? errorMessage;
  final FirestoreNoticeRepository? noticeRepository;
  final PushNotificationService? pushNotificationService;

  static Future<AppBootstrap> initialize() async {
    if (!FirebaseRuntimeConfig.isConfigured) {
      return const AppBootstrap(
        firebaseReady: false,
        statusMessage:
            'Firebase is not configured yet. Run flutterfire configure to '
            'replace lib/firebase_options.dart, then restart the app.',
      );
    }

    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );

      // Web push needs a service worker and VAPID key, so skip it there.
      PushNotificationService? pushNotificationService;
      if (!kIsWeb) {
        FirebaseMessaging.onBackgroundMessage(
          firebaseMessagingBackgroundHandler,
        );
        pushNotificationService = PushNotificationService();
        await pushNotificationService.initialize();
      }

      return AppBootstrap(
        firebaseReady: true,
        statusMessage:
            'Firebase initialized successfully. You can now validate Firestore '
            'reads and request an FCM token from this starter screen.',
        noticeRepository: FirestoreNoticeRepository(),
        pushNotificationService: pushNotificationService,
      );
    } catch (error, stackTrace) {
      debugPrint('Firebase bootstrap failed: $error');
      debugPrintStack(stackTrace: stackTrace);

      return AppBootstrap(
        firebaseReady: false,
        statusMessage:
            'A Firebase configuration file exists, but initialization failed.',
        errorMessage: error.toString(),
      );
    }
  }
}

class FirebaseRuntimeConfig {
  const FirebaseRuntimeConfig._();

  static bool get isConfigured {
    try {
      DefaultFirebaseOptions.currentPlatform;
      return true;
    } catch (_) {
      return false;
    }
  }
}
