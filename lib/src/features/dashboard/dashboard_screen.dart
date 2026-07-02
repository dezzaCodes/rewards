import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../../bootstrap.dart';
import '../../services/firestore_notice_repository.dart';
import '../../services/push_notification_service.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.bootstrap});

  final AppBootstrap bootstrap;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  StreamSubscription<PushNotificationSnapshot>? _pushSubscription;
  late PushNotificationSnapshot _pushSnapshot;
  bool _requestInFlight = false;

  @override
  void initState() {
    super.initState();
    _pushSnapshot =
        widget.bootstrap.pushNotificationService?.current ??
        const PushNotificationSnapshot(
          authorizationStatus: AuthorizationStatus.notDetermined,
        );

    _pushSubscription = widget.bootstrap.pushNotificationService?.snapshots
        .listen((snapshot) {
          if (!mounted) {
            return;
          }

          setState(() {
            _pushSnapshot = snapshot;
          });
        });
  }

  @override
  void dispose() {
    _pushSubscription?.cancel();
    super.dispose();
  }

  Future<void> _requestNotificationPermission() async {
    final service = widget.bootstrap.pushNotificationService;
    if (service == null || _requestInFlight) {
      return;
    }

    setState(() {
      _requestInFlight = true;
    });

    final snapshot = await service.requestPermission();

    if (!mounted) {
      return;
    }

    setState(() {
      _pushSnapshot = snapshot;
      _requestInFlight = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SelectionArea(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('App Blueprint'),
          backgroundColor: Colors.transparent,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Text(
              'Flutter + Firebase delivery scaffold',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Use this as the starting point for each new mobile app. '
              'Rename the template, connect Firebase, add signing secrets, and '
              'ship through GitHub Actions.',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 20),
            _SectionCard(
              title: 'Readiness',
              icon: Icons.rocket_launch_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StatusPill(
                    label: widget.bootstrap.firebaseReady
                        ? 'Firebase ready'
                        : 'Setup required',
                    color: widget.bootstrap.firebaseReady
                        ? colorScheme.primary
                        : colorScheme.secondary,
                  ),
                  const SizedBox(height: 12),
                  Text(widget.bootstrap.statusMessage),
                  if (widget.bootstrap.errorMessage case final error?)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Push Notifications',
              icon: Icons.notifications_active_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Permission status: '
                    '${_authorizationLabel(_pushSnapshot.authorizationStatus)}',
                  ),
                  const SizedBox(height: 8),
                  if (_pushSnapshot.token case final token?)
                    Text('FCM token:\n$token')
                  else
                    const Text(
                      'No FCM token yet. Configure Firebase, run the app on a '
                      'device, then request permission.',
                    ),
                  if (_pushSnapshot.lastMessageTitle case final title?)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Last foreground message:\n$title'),
                          if (_pushSnapshot.lastMessageBody case final body?)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(body),
                            ),
                        ],
                      ),
                    ),
                  if (_pushSnapshot.errorMessage case final error?)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: widget.bootstrap.pushNotificationService == null
                        ? null
                        : _requestNotificationPermission,
                    child: Text(
                      _requestInFlight
                          ? 'Requesting permission...'
                          : 'Request notification permission',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'Firestore Smoke Test',
              icon: Icons.cloud_done_outlined,
              child: _FirestorePanel(
                repository: widget.bootstrap.noticeRepository,
              ),
            ),
            const SizedBox(height: 16),
            const _SectionCard(
              title: 'Next Steps',
              icon: Icons.checklist_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '1. Run scripts/bootstrap_new_app.sh after duplicating the repo.',
                  ),
                  SizedBox(height: 6),
                  Text(
                    '2. Run flutterfire configure and commit lib/firebase_options.dart.',
                  ),
                  SizedBox(height: 6),
                  Text(
                    '3. Add store signing secrets and repository variables.',
                  ),
                  SizedBox(height: 6),
                  Text(
                    '4. Use the Android and iOS workflows to move through test tracks.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FirestorePanel extends StatelessWidget {
  const _FirestorePanel({required this.repository});

  final FirestoreNoticeRepository? repository;

  @override
  Widget build(BuildContext context) {
    if (repository == null) {
      return const Text(
        'Firestore is disabled until Firebase is configured. '
        'After setup, this panel streams the first 10 documents from the '
        '`announcements` collection.',
      );
    }

    return StreamBuilder<List<FirestoreNotice>>(
      stream: repository!.watchAnnouncements(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text(
            'Firestore read failed: ${snapshot.error}\n'
            'Check Firestore rules, indexes, and the bundle IDs used in '
            'firebase_options.dart.',
          );
        }

        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: CircularProgressIndicator(),
          );
        }

        final notices = snapshot.data!;
        if (notices.isEmpty) {
          return const Text(
            'No documents found yet. Create an `announcements` document with '
            '`title`, `body`, and optional `updatedAt` fields to validate '
            'Firestore connectivity.',
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: notices
              .map(
                (notice) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            notice.title,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          Text(notice.body),
                          if (notice.updatedAt case final updatedAt?)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                'Updated: ${updatedAt.toLocal()}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
              .toList(growable: false),
        );
      },
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

String _authorizationLabel(AuthorizationStatus status) {
  switch (status) {
    case AuthorizationStatus.authorized:
      return 'authorized';
    case AuthorizationStatus.denied:
      return 'denied';
    case AuthorizationStatus.notDetermined:
      return 'not determined';
    case AuthorizationStatus.provisional:
      return 'provisional';
  }
}
