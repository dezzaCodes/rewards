import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'cloud_rewards_repository.dart';

class WalletMember {
  const WalletMember({
    required this.uid,
    required this.name,
    required this.isOwner,
  });

  final String uid;
  final String name;
  final bool isOwner;
}

/// Lets several people share one set of rewards cards.
///
/// - `rewardsUsers/{uid}.walletId` points at the shared wallet someone is in.
/// - `wallets/{walletId}` holds the shared cards, its `ownerUid` and the
///   current `inviteCode`.
/// - `wallets/{walletId}/members/{uid}` lists who has access.
/// - `invites/{code}` maps an invite link's code to its wallet.
class SharedWalletService {
  SharedWalletService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _userDoc(String uid) =>
      _firestore.collection('rewardsUsers').doc(uid);

  DocumentReference<Map<String, dynamic>> _wallet(String walletId) =>
      _firestore.collection('wallets').doc(walletId);

  DocumentReference<Map<String, dynamic>> _invite(String code) =>
      _firestore.collection('invites').doc(code);

  /// Builds the invite link for [code], relative to the page's own address.
  static Uri inviteLink(String code) =>
      Uri.base.removeFragment().replace(queryParameters: {'join': code});

  /// The repository [user] should see: their shared wallet if they're in one,
  /// otherwise their own cards.
  Future<CloudRewardsRepository> repositoryFor(User user) async {
    final snapshot = await _userDoc(user.uid).get();
    final walletId = snapshot.data()?['walletId'] as String?;
    if (walletId == null) {
      return CloudRewardsRepository.personal(uid: user.uid);
    }

    final membership = await _wallet(walletId)
        .collection('members')
        .doc(user.uid)
        .get()
        .then<bool>(
          (doc) => doc.exists,
          // Reading fails once someone has been removed from the wallet.
          onError: (Object _) => false,
        );
    if (!membership) {
      await _userDoc(user.uid).update({'walletId': FieldValue.delete()});
      return CloudRewardsRepository.personal(uid: user.uid);
    }

    return CloudRewardsRepository.wallet(walletId: walletId);
  }

  /// Turns [user]'s own cards into a shared wallet and returns the wallet's
  /// repository.
  Future<CloudRewardsRepository> createWallet(
    User user,
    CloudRewardsRepository personal,
  ) async {
    final wallet = _wallet(_firestore.collection('wallets').doc().id);
    final batch = _firestore.batch()
      ..set(wallet, {
        'ownerUid': user.uid,
        'createdAt': FieldValue.serverTimestamp(),
      })
      ..set(wallet.collection('members').doc(user.uid), _memberData(user));
    await batch.commit();

    final shared = CloudRewardsRepository.wallet(walletId: wallet.id);
    final imported = await shared.importStore(
      await personal.load(),
      from: personal,
    );
    await shared.update((_) => imported);
    await resetInvite(wallet.id);
    await _userDoc(
      user.uid,
    ).set({'walletId': wallet.id}, SetOptions(merge: true));
    return shared;
  }

  /// Adds [user] to the wallet behind invite [code], merging their own cards
  /// in, and returns the wallet's repository.
  Future<CloudRewardsRepository> joinWallet(
    User user,
    String code,
    CloudRewardsRepository current,
  ) async {
    final invite = await _invite(code).get();
    final walletId = invite.data()?['walletId'] as String?;
    if (walletId == null) {
      throw StateError(
        'This invite link is no longer valid. Ask for a new one.',
      );
    }
    if (walletId == current.walletId) {
      return current;
    }

    await _wallet(walletId).collection('members').doc(user.uid).set({
      ..._memberData(user),
      'inviteCode': code,
    });

    final shared = CloudRewardsRepository.wallet(walletId: walletId);
    final imported = await shared.importStore(
      await current.load(),
      from: current,
    );
    await shared.update((store) => store.mergedWith(imported));
    await _userDoc(
      user.uid,
    ).set({'walletId': walletId}, SetOptions(merge: true));

    // Their cards came along, so leave any wallet they were in before.
    final previousWalletId = current.walletId;
    if (previousWalletId != null) {
      await _wallet(
        previousWalletId,
      ).collection('members').doc(user.uid).delete();
    }
    return shared;
  }

  /// Removes [user] from [walletId]. They go back to their own cards.
  Future<void> leaveWallet(User user, String walletId) async {
    await _userDoc(user.uid).update({'walletId': FieldValue.delete()});
    await _wallet(walletId).collection('members').doc(user.uid).delete();
  }

  /// Returns the current invite code for [walletId].
  Future<String?> inviteCode(String walletId) async {
    final snapshot = await _wallet(walletId).get();
    return snapshot.data()?['inviteCode'] as String?;
  }

  /// Replaces the wallet's invite link, so old links stop working.
  Future<String> resetInvite(String walletId) async {
    final oldCode = await inviteCode(walletId);
    final code = _randomCode();
    await _invite(code).set({'walletId': walletId});
    await _wallet(walletId).update({'inviteCode': code});
    if (oldCode != null) {
      await _invite(oldCode).delete();
    }
    return code;
  }

  Future<List<WalletMember>> members(String walletId) async {
    final ownerUid =
        (await _wallet(walletId).get()).data()?['ownerUid'] as String?;
    final snapshot = await _wallet(walletId).collection('members').get();
    return snapshot.docs
        .map(
          (doc) => WalletMember(
            uid: doc.id,
            name: doc.data()['name'] as String? ?? 'Someone',
            isOwner: doc.id == ownerUid,
          ),
        )
        .toList(growable: false);
  }

  Future<void> removeMember(String walletId, String uid) {
    return _wallet(walletId).collection('members').doc(uid).delete();
  }

  static Map<String, Object?> _memberData(User user) => {
    'name': user.displayName ?? user.email ?? 'Someone',
    'joinedAt': FieldValue.serverTimestamp(),
  };

  static String _randomCode() {
    const alphabet =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    final random = Random.secure();
    return List.generate(
      24,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }
}
