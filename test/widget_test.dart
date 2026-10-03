import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app_blueprint/src/app.dart';
import 'package:app_blueprint/src/bootstrap.dart';

void main() {
  testWidgets('renders rewards card organizer', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const App(
        bootstrap: AppBootstrap(
          firebaseReady: false,
          statusMessage: 'Firebase is not configured yet.',
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
}
