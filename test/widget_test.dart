import 'package:flutter_test/flutter_test.dart';

import 'package:app_blueprint/src/app.dart';
import 'package:app_blueprint/src/bootstrap.dart';

void main() {
  testWidgets('renders setup guidance when Firebase is not configured', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const App(
        bootstrap: AppBootstrap(
          firebaseReady: false,
          statusMessage: 'Firebase is not configured yet.',
        ),
      ),
    );

    expect(find.text('App Blueprint'), findsOneWidget);
    expect(
      find.textContaining('Firebase is not configured yet'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Request notification permission'),
      findsOneWidget,
    );
  });
}
