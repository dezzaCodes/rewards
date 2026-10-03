import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';

import '../features/dashboard/dashboard_screen.dart';

/// Stores rewards data in Firestore so it follows people across devices.
///
/// Data lives under a root document, either a person's own
/// `rewardsUsers/{uid}` or a shared `wallets/{walletId}`:
/// - `{root}`: `{store: <json string>, updatedAt}`
/// - `{root}/photos/{photoId}`: `{data: <base64>, mimeType}`
///
/// Photos live in their own documents to stay under Firestore's 1 MiB
/// document limit, and are referenced from cards as `cloud:{photoId}`.
class CloudRewardsRepository extends RewardsRepository {
  CloudRewardsRepository.personal({
    required String uid,
    FirebaseFirestore? firestore,
  }) : this._(
         (firestore ?? FirebaseFirestore.instance)
             .collection('rewardsUsers')
             .doc(uid),
         walletId: null,
       );

  CloudRewardsRepository.wallet({
    required String walletId,
    FirebaseFirestore? firestore,
  }) : this._(
         (firestore ?? FirebaseFirestore.instance)
             .collection('wallets')
             .doc(walletId),
         walletId: walletId,
       );

  CloudRewardsRepository._(this._root, {required this.walletId});

  static const _cloudPrefix = 'cloud:';

  // Leaves headroom under the 1 MiB document limit after base64 encoding.
  static const _maxPhotoBytes = 700 * 1024;

  /// The shared wallet this repository reads, or null for personal data.
  final String? walletId;

  final DocumentReference<Map<String, dynamic>> _root;
  final _photoCache = <String, Uint8List>{};

  CollectionReference<Map<String, dynamic>> get _photos =>
      _root.collection('photos');

  @override
  Future<RewardsStore> load() async {
    final snapshot = await _root.get();
    final store = _decode(snapshot);
    if (store != null) {
      return store;
    }

    // First sign-in: copy whatever was saved on this device into the account.
    if (walletId == null) {
      final imported = await importStore(
        await RewardsRepository().load(),
        from: RewardsRepository(),
      );
      await _write(imported);
      return imported;
    }

    return RewardsStore.empty();
  }

  /// Emits the store whenever another device changes it.
  @override
  Stream<RewardsStore> watch() {
    return _root
        .snapshots()
        .where((snapshot) => !snapshot.metadata.hasPendingWrites)
        .map(_decode)
        .where((store) => store != null)
        .cast<RewardsStore>();
  }

  /// Applies [change] to the latest saved data inside a transaction, so edits
  /// made at the same time on other devices are kept.
  @override
  Future<RewardsStore> update(
    RewardsStore Function(RewardsStore store) change,
  ) {
    return _root.firestore.runTransaction((transaction) async {
      final snapshot = await transaction.get(_root);
      final store = change(_decode(snapshot) ?? RewardsStore.empty());
      transaction.set(_root, _encode(store), SetOptions(merge: true));
      return store;
    });
  }

  @override
  Future<String> savePhoto(XFile photo) async {
    return _uploadPhoto(
      await photo.readAsBytes(),
      photo.mimeType ?? 'image/jpeg',
    );
  }

  @override
  Future<void> deletePhoto(String photoPath) async {
    if (!photoPath.startsWith(_cloudPrefix)) {
      return super.deletePhoto(photoPath);
    }

    final photoId = photoPath.substring(_cloudPrefix.length);
    _photoCache.remove(photoId);
    await _photos.doc(photoId).delete();
  }

  @override
  Future<Uint8List?> loadPhoto(String photoPath) async {
    if (!photoPath.startsWith(_cloudPrefix)) {
      return super.loadPhoto(photoPath);
    }

    final photoId = photoPath.substring(_cloudPrefix.length);
    final cached = _photoCache[photoId];
    if (cached != null) {
      return cached;
    }

    final snapshot = await _photos.doc(photoId).get();
    final data = snapshot.data()?['data'] as String?;
    if (data == null) {
      return null;
    }

    return _photoCache[photoId] = base64Decode(data);
  }

  /// Copies the photos of [store] from [from] into this repository and
  /// returns the store with its photo paths pointing here. Cards whose photo
  /// can't be found are dropped.
  Future<RewardsStore> importStore(
    RewardsStore store, {
    required RewardsRepository from,
  }) async {
    final cards = <RewardCard>[];
    for (final card in store.cards) {
      final bytes = await from.loadPhoto(card.photoPath);
      if (bytes == null) {
        continue;
      }

      cards.add(
        card.copyWith(photoPath: await _uploadPhoto(bytes, 'image/jpeg')),
      );
    }

    return store.copyWith(cards: cards);
  }

  Future<void> _write(RewardsStore store) {
    return _root.set(_encode(store), SetOptions(merge: true));
  }

  Future<String> _uploadPhoto(Uint8List bytes, String mimeType) async {
    if (bytes.length > _maxPhotoBytes) {
      throw StateError('That photo is too large to sync. Try a smaller one.');
    }

    final photo = _photos.doc();
    await photo.set({'data': base64Encode(bytes), 'mimeType': mimeType});
    _photoCache[photo.id] = bytes;
    return '$_cloudPrefix${photo.id}';
  }

  static Map<String, Object?> _encode(RewardsStore store) => {
    'store': jsonEncode(store.toJson()),
    'updatedAt': FieldValue.serverTimestamp(),
  };

  static RewardsStore? _decode(DocumentSnapshot<Map<String, dynamic>> doc) {
    final encoded = doc.data()?['store'] as String?;
    if (encoded == null) {
      return null;
    }

    return RewardsStore.fromJson(jsonDecode(encoded) as Map<String, Object?>);
  }
}
