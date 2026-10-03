import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';

import '../features/dashboard/dashboard_screen.dart';

/// Stores a signed-in person's rewards data in Firestore so it follows them
/// across devices.
///
/// Layout:
/// - `rewardsUsers/{uid}`: `{store: <json string>, updatedAt}`
/// - `rewardsUsers/{uid}/photos/{photoId}`: `{data: <base64>, mimeType}`
///
/// Photos live in their own documents to stay under Firestore's 1 MiB
/// document limit, and are referenced from cards as `cloud:{photoId}`.
class CloudRewardsRepository extends RewardsRepository {
  CloudRewardsRepository({required this.uid, FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  static const _cloudPrefix = 'cloud:';

  // Leaves headroom under the 1 MiB document limit after base64 encoding.
  static const _maxPhotoBytes = 700 * 1024;

  final String uid;
  final FirebaseFirestore _firestore;
  final _photoCache = <String, Uint8List>{};

  DocumentReference<Map<String, dynamic>> get _userDoc =>
      _firestore.collection('rewardsUsers').doc(uid);

  CollectionReference<Map<String, dynamic>> get _photos =>
      _userDoc.collection('photos');

  @override
  Future<RewardsStore> load() async {
    final snapshot = await _userDoc.get();
    final encoded = snapshot.data()?['store'] as String?;
    if (encoded != null) {
      return RewardsStore.fromJson(jsonDecode(encoded) as Map<String, Object?>);
    }

    return _migrateLocalStore();
  }

  @override
  Future<void> save(RewardsStore store) {
    return _userDoc.set({
      'store': jsonEncode(store.toJson()),
      'updatedAt': FieldValue.serverTimestamp(),
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

  Future<String> _uploadPhoto(Uint8List bytes, String mimeType) async {
    if (bytes.length > _maxPhotoBytes) {
      throw StateError('That photo is too large to sync. Try a smaller one.');
    }

    final photo = _photos.doc();
    await photo.set({'data': base64Encode(bytes), 'mimeType': mimeType});
    _photoCache[photo.id] = bytes;
    return '$_cloudPrefix${photo.id}';
  }

  /// On first sign-in, copies whatever was saved on this device into the
  /// account so nothing is lost.
  Future<RewardsStore> _migrateLocalStore() async {
    final localStore = await RewardsRepository().load();
    final cards = <RewardCard>[];
    for (final card in localStore.cards) {
      final bytes = await super.loadPhoto(card.photoPath);
      if (bytes == null) {
        continue;
      }

      cards.add(
        card.copyWith(photoPath: await _uploadPhoto(bytes, 'image/jpeg')),
      );
    }

    final store = localStore.copyWith(cards: cards);
    await save(store);
    return store;
  }
}
