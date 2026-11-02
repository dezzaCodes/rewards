import 'package:app_blueprint/src/features/dashboard/dashboard_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final updatedAt = DateTime.utc(2026, 11, 2);

  RewardCard card(String userId, String programId) => RewardCard(
    id: '$userId-$programId',
    userId: userId,
    programId: programId,
    photoPath: 'cloud:$userId',
    createdAt: updatedAt,
  );

  test('totals points for everyone in a program', () {
    final store = RewardsStore.empty().copyWith(
      users: [
        RewardsUser(id: 'a', name: 'Ana').withPoints(1200, updatedAt),
        RewardsUser(id: 'b', name: 'Ben').withPoints(300, updatedAt),
        const RewardsUser(id: 'c', name: 'Cy'),
        RewardsUser(id: 'd', name: 'Dee').withPoints(9999, updatedAt),
      ],
      cards: [
        card('a', 'flybuys'),
        card('b', 'flybuys'),
        card('c', 'flybuys'),
        card('d', 'velocity'),
      ],
    );

    expect(store.totalPoints('flybuys'), 1500);
    expect(store.totalPoints('velocity'), 9999);
    expect(store.totalPoints('qantas-frequent-flyer'), isNull);
  });

  test('keeps points and their date when saved and loaded', () {
    final user = RewardsUser(id: 'a', name: 'Ana').withPoints(42, updatedAt);

    final loaded = RewardsUser.fromJson(user.toJson());

    expect(loaded.points, 42);
    expect(loaded.pointsUpdatedAt, updatedAt);
  });

  test('loads people saved before points existed', () {
    final loaded = RewardsUser.fromJson({'id': 'a', 'name': 'Ana'});

    expect(loaded.points, isNull);
    expect(loaded.pointsUpdatedAt, isNull);
  });
}
