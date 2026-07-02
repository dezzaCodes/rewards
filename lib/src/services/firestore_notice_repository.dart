import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreNotice {
  const FirestoreNotice({
    required this.id,
    required this.title,
    required this.body,
    this.updatedAt,
  });

  final String id;
  final String title;
  final String body;
  final DateTime? updatedAt;

  factory FirestoreNotice.fromDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();

    return FirestoreNotice(
      id: document.id,
      title: data['title'] as String? ?? 'Untitled message',
      body: data['body'] as String? ?? 'Add a `body` field to this document.',
      updatedAt: _readDateTime(data['updatedAt']),
    );
  }
}

class FirestoreNoticeRepository {
  FirestoreNoticeRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<List<FirestoreNotice>> watchAnnouncements() {
    return _firestore
        .collection('announcements')
        .limit(10)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(FirestoreNotice.fromDocument)
              .toList(growable: false),
        );
  }
}

DateTime? _readDateTime(Object? value) {
  if (value is Timestamp) {
    return value.toDate();
  }

  if (value is DateTime) {
    return value;
  }

  return null;
}
