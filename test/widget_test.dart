import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app_blueprint/src/app.dart';
import 'package:app_blueprint/src/bootstrap.dart';

void main() {
  testWidgets('renders rewards card organizer', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      App(
        bootstrap: Future.value(
          const AppBootstrap(
            firebaseReady: false,
            statusMessage: 'Firebase is not configured yet.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Rewards Cards'), findsOneWidget);
    expect(find.text('Flybuys'), findsAtLeastNWidgets(1));
    expect(find.text('Everyday Rewards'), findsOneWidget);
    expect(find.text('Qantas Frequent Flyer'), findsOneWidget);
    expect(find.text('Velocity'), findsOneWidget);
    expect(find.textContaining('images across'), findsNothing);
  });

  testWidgets('adds a program from the round + button', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      App(
        bootstrap: Future.value(
          const AppBootstrap(
            firebaseReady: false,
            statusMessage: 'Firebase is not configured yet.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add program'));
    await tester.pump();

    // The name field is focused straight away so the keyboard opens.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);

    await tester.enterText(find.byType(TextField), 'Myer one');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Done'));
    await tester.pumpAndSettle();

    expect(find.text('Myer one'), findsOneWidget);
  });

  testWidgets('saves points for a person and totals them on the program', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'rewards_store_v1': jsonEncode({
        'users': [
          {'id': 'ana', 'name': 'Ana'},
        ],
        'cards': [
          {
            'id': 'ana-card',
            'userId': 'ana',
            'programId': 'flybuys',
            'photoPath': 'data:image/png;base64,',
            'createdAt': '2026-11-01T00:00:00.000',
          },
        ],
      }),
    });
    await tester.pumpWidget(
      App(
        bootstrap: Future.value(
          const AppBootstrap(
            firebaseReady: false,
            statusMessage: 'Firebase is not configured yet.',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Flybuys'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add points'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '12450');
    await tester.tap(find.byTooltip('Done'));
    await tester.pumpAndSettle();

    expect(find.text('12,450 pts'), findsOneWidget);
    expect(find.textContaining('Updated '), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('12,450 points in total'), findsOneWidget);
  });
}
