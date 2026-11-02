import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';

import '../features/dashboard/dashboard_screen.dart';
import 'photo_cache.dart';
import 'photo_compressor.dart';

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

  static const _cloudPrefix = RewardsRepository.cloudPhotoPrefix;

  // Leaves headroom under the 1 MiB document limit after base64 encoding.
  static const _maxPhotoBytes = 700 * 1024;

  // Photos are compressed below this so they download quickly.
  static const _targetPhotoBytes = 400 * 1024;

  /// The shared wallet this repository reads, or null for personal data.
  final String? walletId;

  final DocumentReference<Map<String, dynamic>> _root;
  final _photoCache = <String, Uint8List>{};

  CollectionReference<Map<String, dynamic>> get _photos =>
      _root.collection('photos');

  /// With [preferCache], returns the copy saved on this device when there is
  /// one, so the app opens instantly. The refresh button loads without it.
  @override
  Future<RewardsStore> load({bool preferCache = false}) async {
    if (preferCache) {
      final cached = await _readCache(_root);
      final store = cached == null ? null : _decode(cached);
      if (store != null) {
        return store;
      }
    }

    final snapshot = await _root.get(const GetOptions(source: Source.server));
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
    // Photos never change once uploaded, so any copy on this device will do.
    final cached = _photoCache[photoId] ?? await readCachedPhoto(photoId);
    if (cached != null) {
      return _photoCache[photoId] = cached;
    }

    final photo = _photos.doc(photoId);
    final snapshot = await _readCache(photo) ?? await photo.get();
    final data = snapshot.data()?['data'] as String?;
    if (data == null) {
      return null;
    }

    final bytes = base64Decode(data);
    writeCachedPhoto(photoId, bytes).ignore();
    return _photoCache[photoId] = bytes;
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

  Future<String> _uploadPhoto(Uint8List original, String mimeType) async {
    var bytes = original;
    if (bytes.length > _targetPhotoBytes) {
      bytes = await compressPhoto(bytes, maxBytes: _targetPhotoBytes);
      mimeType = 'image/jpeg';
    }
    if (bytes.length > _maxPhotoBytes) {
      throw StateError('That photo is too large to sync. Try a smaller one.');
    }

    final photo = _photos.doc();
    await photo.set({'data': base64Encode(bytes), 'mimeType': mimeType});
    _photoCache[photo.id] = bytes;
    writeCachedPhoto(photo.id, bytes).ignore();
    return '$_cloudPrefix${photo.id}';
  }

  /// Reads [doc] from this device's cache, or returns null if it isn't there.
  static Future<DocumentSnapshot<Map<String, dynamic>>?> _readCache(
    DocumentReference<Map<String, dynamic>> doc,
  ) async {
    try {
      final snapshot = await doc.get(const GetOptions(source: Source.cache));
      return snapshot.exists ? snapshot : null;
    } on FirebaseException {
      return null;
    }
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
