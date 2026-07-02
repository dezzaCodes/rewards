import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

class PushNotificationSnapshot {
  const PushNotificationSnapshot({
    required this.authorizationStatus,
    this.token,
    this.lastMessageTitle,
    this.lastMessageBody,
    this.errorMessage,
  });

  final AuthorizationStatus authorizationStatus;
  final String? token;
  final String? lastMessageTitle;
  final String? lastMessageBody;
  final String? errorMessage;
}

class PushNotificationService {
  PushNotificationService({FirebaseMessaging? messaging})
    : _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _messaging;
  final StreamController<PushNotificationSnapshot> _controller =
      StreamController<PushNotificationSnapshot>.broadcast();

  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<String>? _tokenRefreshSubscription;

  PushNotificationSnapshot _current = const PushNotificationSnapshot(
    authorizationStatus: AuthorizationStatus.notDetermined,
  );

  PushNotificationSnapshot get current => _current;
  Stream<PushNotificationSnapshot> get snapshots => _controller.stream;

  Future<PushNotificationSnapshot> initialize() async {
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    final settings = await _messaging.getNotificationSettings();
    final token = await _safeGetToken();

    _setSnapshot(
      PushNotificationSnapshot(
        authorizationStatus: settings.authorizationStatus,
        token: token,
      ),
    );

    _foregroundSubscription ??= FirebaseMessaging.onMessage.listen(
      (message) {
        _setSnapshot(
          PushNotificationSnapshot(
            authorizationStatus: _current.authorizationStatus,
            token: _current.token,
            lastMessageTitle: message.notification?.title,
            lastMessageBody: message.notification?.body,
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Foreground messaging listener failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );

    _tokenRefreshSubscription ??= _messaging.onTokenRefresh.listen(
      (token) {
        _setSnapshot(
          PushNotificationSnapshot(
            authorizationStatus: _current.authorizationStatus,
            token: token,
            lastMessageTitle: _current.lastMessageTitle,
            lastMessageBody: _current.lastMessageBody,
          ),
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Token refresh listener failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      },
    );

    return _current;
  }

  Future<PushNotificationSnapshot> requestPermission() async {
    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        provisional: false,
        sound: true,
      );

      final token = await _safeGetToken();

      _setSnapshot(
        PushNotificationSnapshot(
          authorizationStatus: settings.authorizationStatus,
          token: token,
          lastMessageTitle: _current.lastMessageTitle,
          lastMessageBody: _current.lastMessageBody,
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Notification permission request failed: $error');
      debugPrintStack(stackTrace: stackTrace);

      _setSnapshot(
        PushNotificationSnapshot(
          authorizationStatus: _current.authorizationStatus,
          token: _current.token,
          lastMessageTitle: _current.lastMessageTitle,
          lastMessageBody: _current.lastMessageBody,
          errorMessage: error.toString(),
        ),
      );
    }

    return _current;
  }

  Future<void> dispose() async {
    await _foregroundSubscription?.cancel();
    await _tokenRefreshSubscription?.cancel();
    await _controller.close();
  }

  Future<String?> _safeGetToken() async {
    try {
      return await _messaging.getToken();
    } catch (error, stackTrace) {
      debugPrint('Unable to fetch an FCM token: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  void _setSnapshot(PushNotificationSnapshot snapshot) {
    _current = snapshot;
    _controller.add(snapshot);
  }
}
