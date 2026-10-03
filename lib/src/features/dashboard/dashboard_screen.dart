import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../bootstrap.dart';
import '../../services/cloud_rewards_repository.dart';
import '../../services/shared_wallet_service.dart';

const _defaultPrograms = <RewardsProgram>[
  RewardsProgram(
    id: 'flybuys',
    name: 'Flybuys',
    shortName: 'FB',
    color: Color(0xFF243C8F),
    accentColor: Color(0xFFF5D547),
  ),
  RewardsProgram(
    id: 'everyday-rewards',
    name: 'Everyday Rewards',
    shortName: 'ER',
    color: Color(0xFFE9232E),
    accentColor: Color(0xFFFFD400),
  ),
  RewardsProgram(
    id: 'qantas-frequent-flyer',
    name: 'Qantas Frequent Flyer',
    shortName: 'QF',
    color: Color(0xFFB20D1E),
    accentColor: Color(0xFFF4F4F0),
  ),
  RewardsProgram(
    id: 'velocity',
    name: 'Velocity',
    shortName: 'VA',
    color: Color(0xFF6E1E78),
    accentColor: Color(0xFFE11B7B),
  ),
];

const _customProgramColors = <Color>[
  Color(0xFF0D6B57),
  Color(0xFF375A7F),
  Color(0xFF7A4E2D),
  Color(0xFF5B4B8A),
  Color(0xFF2F6F73),
  Color(0xFF8A3D54),
];

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.bootstrap});

  final AppBootstrap bootstrap;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final _sharing = SharedWalletService();
  RewardsRepository _repository = RewardsRepository();
  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<RewardsStore>? _storeSubscription;
  User? _user;

  /// Invite code from a `?join=` link this page was opened with.
  String? _pendingJoinCode = kIsWeb ? Uri.base.queryParameters['join'] : null;

  RewardsStore _store = RewardsStore.empty();
  var _loading = true;

  String? get _walletId => switch (_repository) {
    CloudRewardsRepository(:final walletId) => walletId,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    if (widget.bootstrap.firebaseReady) {
      _authSubscription = FirebaseAuth.instance.authStateChanges().listen(
        _onAuthChanged,
      );
    } else {
      _loadStore();
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _storeSubscription?.cancel();
    super.dispose();
  }

  Future<void> _onAuthChanged(User? user) async {
    setState(() {
      _user = user;
      _loading = true;
    });

    RewardsRepository repository = RewardsRepository();
    if (user != null) {
      try {
        repository = await _sharing.repositoryFor(user);
      } catch (error) {
        debugPrint('Could not find shared cards: $error');
        repository = CloudRewardsRepository.personal(uid: user.uid);
      }
    }
    if (!mounted || user != _user) {
      return;
    }

    _useRepository(repository);
    _showInviteBanner(visible: user == null && _pendingJoinCode != null);
    if (user != null && _pendingJoinCode != null) {
      await _joinFromLink(user);
    }
  }

  void _showInviteBanner({required bool visible}) {
    final messenger = ScaffoldMessenger.of(context)
      ..hideCurrentMaterialBanner();
    if (!visible) {
      return;
    }

    messenger.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.group_add_outlined),
        content: const Text(
          'You were invited to share rewards cards. Sign in to join.',
        ),
        actions: [TextButton(onPressed: _signIn, child: const Text('Sign in'))],
      ),
    );
  }

  void _useRepository(RewardsRepository repository) {
    _storeSubscription?.cancel();
    setState(() {
      _repository = repository;
      _loading = true;
    });
    _loadStore();
  }

  Future<void> _loadStore() async {
    final repository = _repository;
    try {
      final store = await repository.load();
      if (!mounted || repository != _repository) {
        return;
      }

      setState(() {
        _store = store;
        _loading = false;
      });
      _storeSubscription = repository.watch().listen(
        (store) {
          if (mounted && repository == _repository) {
            setState(() => _store = store);
          }
        },
        onError: (Object error) {
          // Access to shared cards ends when the owner removes someone.
          if (mounted && repository == _repository && _walletId != null) {
            _showMessage('You no longer have access to the shared cards.');
            _onAuthChanged(_user);
          }
        },
      );
    } catch (error) {
      if (!mounted || repository != _repository) {
        return;
      }

      setState(() => _loading = false);
      _showMessage('Could not load cards: $error');
    }
  }

  Future<void> _signIn() async {
    try {
      final provider = GoogleAuthProvider();
      if (kIsWeb) {
        await FirebaseAuth.instance.signInWithPopup(provider);
      } else {
        await FirebaseAuth.instance.signInWithProvider(provider);
      }
    } on FirebaseAuthException catch (error) {
      if (error.code == 'popup-closed-by-user' ||
          error.code == 'cancelled-popup-request') {
        return;
      }

      _showMessage('Sign-in failed: ${error.message}');
    }
  }

  Future<void> _signOut() async {
    final confirmed = await _confirm(
      context: context,
      title: 'Sign out?',
      message:
          'Your cards stay saved in your account. This device will show '
          'only the cards stored on it.',
      actionLabel: 'Sign out',
    );
    if (confirmed) {
      await FirebaseAuth.instance.signOut();
    }
  }

  Future<void> _joinFromLink(User user) async {
    final code = _pendingJoinCode!;
    _pendingJoinCode = null;

    final current = _repository;
    if (current is! CloudRewardsRepository) {
      return;
    }

    final confirmed = await _confirm(
      context: context,
      title: 'Join shared cards?',
      message: current.walletId == null
          ? 'You were invited to share rewards cards. Your cards will be '
                'added to the shared cards, and everyone in it can see and '
                'change them.'
          : 'You were invited to a different set of shared cards. Your '
                'current cards will be added to it, and you will leave the '
                'cards you share now.',
      actionLabel: 'Join',
    );
    if (!confirmed) {
      return;
    }

    await _runSharingAction(
      () async =>
          _useRepository(await _sharing.joinWallet(user, code, current)),
      failure: 'Could not join',
    );
  }

  Future<void> _shareCards(User user) async {
    final current = _repository;
    if (current is! CloudRewardsRepository) {
      return;
    }

    final shared = await _runSharingAction(
      () => _sharing.createWallet(user, current),
      failure: 'Could not share cards',
    );
    if (shared != null) {
      _useRepository(shared);
      await _openAccountSheet();
    }
  }

  Future<void> _leaveSharedCards(User user, String walletId) async {
    final confirmed = await _confirm(
      context: context,
      title: 'Leave shared cards?',
      message:
          'You will stop seeing the shared cards on all your devices. '
          'Everyone else keeps them.',
      actionLabel: 'Leave',
    );
    if (!confirmed) {
      return;
    }

    await _runSharingAction(() async {
      await _sharing.leaveWallet(user, walletId);
      _useRepository(CloudRewardsRepository.personal(uid: user.uid));
    }, failure: 'Could not leave');
  }

  Future<T?> _runSharingAction<T>(
    Future<T> Function() action, {
    required String failure,
  }) async {
    setState(() => _loading = true);
    try {
      return await action();
    } catch (error) {
      if (mounted) {
        setState(() => _loading = false);
      }
      _showMessage('$failure: $error');
      return null;
    }
  }

  Future<void> _openAccountSheet() async {
    final user = _user;
    if (user == null) {
      return;
    }

    final walletId = _walletId;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => AccountSheet(
        user: user,
        walletId: walletId,
        sharing: _sharing,
        onShare: () {
          Navigator.pop(context);
          _shareCards(user);
        },
        onLeave: () {
          Navigator.pop(context);
          _leaveSharedCards(user, walletId!);
        },
        onSignOut: () {
          Navigator.pop(context);
          _signOut();
        },
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<RewardsStore> _updateStore(StoreChange change) async {
    final store = await _repository.update(change);
    if (mounted) {
      setState(() => _store = store);
    }
    return store;
  }

  Future<void> _openUsers(RewardsProgram program) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => ProgramUsersScreen(
          program: program,
          store: _store,
          repository: _repository,
          onStoreChanged: _updateStore,
        ),
      ),
    );
  }

  Future<void> _addProgram() async {
    final name = await _showNameDialog(
      context: context,
      title: 'Add rewards program',
      label: 'Program name',
      actionLabel: 'Add',
    );
    if (name == null) {
      return;
    }

    final program = RewardsProgram.custom(name);
    await _updateStore(
      (store) => store.copyWith(programs: [...store.programs, program]),
    );
  }

  Future<bool> _deleteProgram(RewardsProgram program) async {
    final confirmed = await _confirm(
      context: context,
      title: 'Delete ${program.name}?',
      message: 'This removes this rewards program and its saved card images.',
      actionLabel: 'Delete',
    );
    if (!confirmed) {
      return false;
    }

    final cardsToRemove = _store.cards
        .where((card) => card.programId == program.id)
        .toList(growable: false);
    for (final card in cardsToRemove) {
      await _repository.deletePhoto(card.photoPath);
    }

    await _updateStore(
      (store) => store.copyWith(
        programs: store.programs
            .where((item) => item.id != program.id)
            .toList(),
        cards: store.cards
            .where((card) => card.programId != program.id)
            .toList(),
      ),
    );
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rewards Cards'),
        actions: [
          if (widget.bootstrap.firebaseReady)
            _AccountButton(
              user: _user,
              shared: _walletId != null,
              onSignIn: _signIn,
              onOpenAccount: _openAccountSheet,
            ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _loading ? null : _addProgram,
        icon: const Icon(Icons.add),
        label: const Text('Add program'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                itemCount: _store.programs.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final program = _store.programs[index];

                  return Dismissible(
                    key: ValueKey('program-${program.id}'),
                    direction: DismissDirection.endToStart,
                    background: const _DeleteSwipeBackground(),
                    confirmDismiss: (_) => _deleteProgram(program),
                    child: _ProgramListTile(
                      program: program,
                      onTap: () => _openUsers(program),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

class ProgramUsersScreen extends StatefulWidget {
  const ProgramUsersScreen({
    super.key,
    required this.program,
    required this.store,
    required this.repository,
    required this.onStoreChanged,
  });

  final RewardsProgram program;
  final RewardsStore store;
  final RewardsRepository repository;
  final Future<RewardsStore> Function(StoreChange change) onStoreChanged;

  @override
  State<ProgramUsersScreen> createState() => _ProgramUsersScreenState();
}

class _ProgramUsersScreenState extends State<ProgramUsersScreen> {
  final _picker = ImagePicker();

  late RewardsStore _store = widget.store;

  List<RewardsUser> get _programUsers {
    final userIds = _store.cards
        .where((card) => card.programId == widget.program.id)
        .map((card) => card.userId)
        .toSet();

    return _store.users
        .where((user) => userIds.contains(user.id))
        .toList(growable: false);
  }

  Future<RewardsStore> _updateStore(StoreChange change) async {
    final store = await widget.onStoreChanged(change);
    if (mounted) {
      setState(() => _store = store);
    }
    return store;
  }

  Future<void> _addUser() async {
    try {
      final name = await _showNameDialog(
        context: context,
        title: 'Add user',
        label: 'Name',
        actionLabel: 'Next',
      );
      if (name == null) {
        return;
      }
      if (!mounted) {
        return;
      }

      final source = await _choosePhotoSource(context);
      if (source == null) {
        return;
      }

      final photo = await _picker.pickImage(
        source: source,
        // Web photos are stored inline in browser storage, so keep them small.
        imageQuality: kIsWeb ? 70 : 88,
        maxWidth: kIsWeb ? 1000 : 1800,
      );
      if (photo == null) {
        return;
      }

      final now = DateTime.now();
      final user = RewardsUser(
        id: now.microsecondsSinceEpoch.toString(),
        name: name,
      );
      final savedPath = await widget.repository.savePhoto(photo);
      final card = RewardCard(
        id: '${now.microsecondsSinceEpoch}-card',
        userId: user.id,
        programId: widget.program.id,
        photoPath: savedPath,
        createdAt: now,
      );

      await _updateStore(
        (store) => store.copyWith(
          users: [...store.users, user],
          cards: [card, ...store.cards],
        ),
      );
      if (!mounted) {
        return;
      }

      await _openCards(user);
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not add user: $error')));
    }
  }

  Future<bool> _deleteUser(RewardsUser user) async {
    final confirmed = await _confirm(
      context: context,
      title: 'Delete ${user.name}?',
      message: 'This removes their saved card photos from every program.',
      actionLabel: 'Delete',
    );
    if (!confirmed) {
      return false;
    }

    final cardsToRemove = _store.cards
        .where((card) => card.userId == user.id)
        .toList(growable: false);
    for (final card in cardsToRemove) {
      await widget.repository.deletePhoto(card.photoPath);
    }

    await _updateStore(
      (store) => store.copyWith(
        users: store.users.where((item) => item.id != user.id).toList(),
        cards: store.cards.where((card) => card.userId != user.id).toList(),
      ),
    );
    return true;
  }

  Future<void> _openCards(RewardsUser user) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => UserCardsScreen(
          program: widget.program,
          user: user,
          store: _store,
          repository: widget.repository,
          onStoreChanged: _updateStore,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.program.name)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addUser,
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: const Text('Add user'),
      ),
      body: SafeArea(
        child: _programUsers.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: _EmptyState(
                  icon: Icons.group_add_outlined,
                  title: 'Add your first user',
                  message:
                      'Users let you keep each person’s rewards cards separate under ${widget.program.name}.',
                  actionLabel: 'Add user',
                  onPressed: _addUser,
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                itemCount: _programUsers.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final user = _programUsers[index];

                  return Dismissible(
                    key: ValueKey('user-${user.id}'),
                    direction: DismissDirection.endToStart,
                    background: const _DeleteSwipeBackground(),
                    confirmDismiss: (_) => _deleteUser(user),
                    child: _UserListTile(
                      user: user,
                      onTap: () => _openCards(user),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class UserCardsScreen extends StatefulWidget {
  const UserCardsScreen({
    super.key,
    required this.program,
    required this.user,
    required this.store,
    required this.repository,
    required this.onStoreChanged,
  });

  final RewardsProgram program;
  final RewardsUser user;
  final RewardsStore store;
  final RewardsRepository repository;
  final Future<RewardsStore> Function(StoreChange change) onStoreChanged;

  @override
  State<UserCardsScreen> createState() => _UserCardsScreenState();
}

class _UserCardsScreenState extends State<UserCardsScreen> {
  late RewardsStore _store = widget.store;

  List<RewardCard> get _cards => _store.cards
      .where(
        (card) =>
            card.programId == widget.program.id &&
            card.userId == widget.user.id,
      )
      .toList(growable: false);

  Future<RewardsStore> _updateStore(StoreChange change) async {
    final store = await widget.onStoreChanged(change);
    if (mounted) {
      setState(() => _store = store);
    }
    return store;
  }

  Future<bool> _deleteCard(RewardCard card) async {
    final confirmed = await _confirm(
      context: context,
      title: 'Remove card photo?',
      message: 'The saved image will be removed from this app.',
      actionLabel: 'Remove',
    );
    if (!confirmed) {
      return false;
    }

    await widget.repository.deletePhoto(card.photoPath);
    await _updateStore(
      (store) => store.copyWith(
        cards: store.cards.where((item) => item.id != card.id).toList(),
      ),
    );
    return true;
  }

  void _leaveIfNoCardsRemain() {
    if (_cards.isEmpty) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = '${widget.user.name} - ${widget.program.name}';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: _cards.isEmpty
            ? const SizedBox.shrink()
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 380,
                  mainAxisExtent: 245,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                ),
                itemCount: _cards.length,
                itemBuilder: (context, index) {
                  final card = _cards[index];

                  return Dismissible(
                    key: ValueKey('card-${card.id}'),
                    direction: DismissDirection.endToStart,
                    background: const _DeleteSwipeBackground(),
                    confirmDismiss: (_) => _deleteCard(card),
                    onDismissed: (_) => _leaveIfNoCardsRemain(),
                    child: _RewardCardTile(
                      card: card,
                      program: widget.program,
                      repository: widget.repository,
                    ),
                  );
                },
              ),
      ),
    );
  }
}

class _ProgramListTile extends StatelessWidget {
  const _ProgramListTile({required this.program, required this.onTap});

  final RewardsProgram program;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        leading: _ProgramBadge(program: program),
        title: Text(
          program.name,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _UserListTile extends StatelessWidget {
  const _UserListTile({required this.user, required this.onTap});

  final RewardsUser user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        leading: CircleAvatar(
          child: Text(user.name.characters.first.toUpperCase()),
        ),
        title: Text(
          user.name,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _AccountButton extends StatelessWidget {
  const _AccountButton({
    required this.user,
    required this.shared,
    required this.onSignIn,
    required this.onOpenAccount,
  });

  final User? user;
  final bool shared;
  final VoidCallback onSignIn;
  final VoidCallback onOpenAccount;

  @override
  Widget build(BuildContext context) {
    final user = this.user;
    if (user == null) {
      return TextButton.icon(
        onPressed: onSignIn,
        icon: const Icon(Icons.cloud_sync_outlined),
        label: const Text('Sign in to sync'),
      );
    }

    final avatar = _UserAvatar(user: user, radius: 16);
    return IconButton(
      tooltip: shared ? 'Account and sharing (shared)' : 'Account and sharing',
      onPressed: onOpenAccount,
      icon: shared
          ? Badge(
              label: const Icon(Icons.group, size: 10, color: Colors.white),
              child: avatar,
            )
          : avatar,
    );
  }
}

class _UserAvatar extends StatelessWidget {
  const _UserAvatar({required this.user, required this.radius});

  final User user;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final label = user.displayName ?? user.email ?? 'Account';
    final photoUrl = user.photoURL;

    return CircleAvatar(
      radius: radius,
      backgroundImage: photoUrl == null ? null : NetworkImage(photoUrl),
      child: photoUrl == null
          ? Text(label.characters.first.toUpperCase())
          : null,
    );
  }
}

/// Shows who is signed in and lets them share their cards with others.
class AccountSheet extends StatefulWidget {
  const AccountSheet({
    super.key,
    required this.user,
    required this.walletId,
    required this.sharing,
    required this.onShare,
    required this.onLeave,
    required this.onSignOut,
  });

  final User user;
  final String? walletId;
  final SharedWalletService sharing;
  final VoidCallback onShare;
  final VoidCallback onLeave;
  final VoidCallback onSignOut;

  @override
  State<AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<AccountSheet> {
  Future<List<WalletMember>>? _members;
  Future<String?>? _inviteCode;

  @override
  void initState() {
    super.initState();
    final walletId = widget.walletId;
    if (walletId != null) {
      _members = widget.sharing.members(walletId);
      _inviteCode = widget.sharing.inviteCode(walletId);
    }
  }

  Future<void> _copyLink(String code) async {
    await Clipboard.setData(
      ClipboardData(text: SharedWalletService.inviteLink(code).toString()),
    );
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Invite link copied')));
  }

  Future<void> _resetLink() async {
    final confirmed = await _confirm(
      context: context,
      title: 'Reset invite link?',
      message:
          'The current link will stop working. People who already joined '
          'keep access.',
      actionLabel: 'Reset',
    );
    if (confirmed) {
      setState(() {
        _inviteCode = widget.sharing.resetInvite(widget.walletId!);
      });
    }
  }

  Future<void> _removeMember(WalletMember member) async {
    final confirmed = await _confirm(
      context: context,
      title: 'Remove ${member.name}?',
      message: 'They will no longer see or change the shared cards.',
      actionLabel: 'Remove',
    );
    if (!confirmed) {
      return;
    }

    await widget.sharing.removeMember(widget.walletId!, member.uid);
    setState(() => _members = widget.sharing.members(widget.walletId!));
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _UserAvatar(user: user, radius: 20),
              title: Text(user.displayName ?? 'Signed in'),
              subtitle: user.email == null ? null : Text(user.email!),
            ),
            const Divider(),
            if (widget.walletId == null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.group_add_outlined),
                title: const Text('Share these cards'),
                subtitle: const Text(
                  'Get a link so family or friends can see and add cards.',
                ),
                onTap: widget.onShare,
              )
            else ...[
              Text('Invite link', style: textTheme.titleSmall),
              const SizedBox(height: 4),
              FutureBuilder<String?>(
                future: _inviteCode,
                builder: (context, snapshot) {
                  final code = snapshot.data;
                  if (code == null) {
                    return snapshot.connectionState == ConnectionState.done
                        ? const Text('Could not load the invite link.')
                        : const LinearProgressIndicator();
                  }

                  return Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          SharedWalletService.inviteLink(code).toString(),
                          maxLines: 1,
                          style: textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        onPressed: () => _copyLink(code),
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy'),
                      ),
                    ],
                  );
                },
              ),
              Text(
                'Anyone with this link can join after signing in.',
                style: textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Text('Shared with', style: textTheme.titleSmall),
              FutureBuilder<List<WalletMember>>(
                future: _members,
                builder: (context, snapshot) {
                  final members = snapshot.data;
                  if (members == null) {
                    return snapshot.connectionState == ConnectionState.done
                        ? const Text('Could not load who has access.')
                        : const LinearProgressIndicator();
                  }

                  final isOwner = members.any(
                    (member) => member.isOwner && member.uid == user.uid,
                  );
                  return Column(
                    children: [
                      for (final member in members)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(Icons.person_outline),
                          title: Text(
                            member.uid == user.uid
                                ? '${member.name} (you)'
                                : member.name,
                          ),
                          subtitle: member.isOwner ? const Text('Owner') : null,
                          trailing: isOwner && member.uid != user.uid
                              ? IconButton(
                                  tooltip: 'Remove ${member.name}',
                                  onPressed: () => _removeMember(member),
                                  icon: const Icon(
                                    Icons.person_remove_outlined,
                                  ),
                                )
                              : null,
                        ),
                    ],
                  );
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link_off),
                title: const Text('Reset invite link'),
                onTap: _resetLink,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.logout),
                title: const Text('Leave shared cards'),
                onTap: widget.onLeave,
              ),
            ],
            const Divider(),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.power_settings_new),
              title: const Text('Sign out'),
              onTap: widget.onSignOut,
            ),
          ],
        ),
      ),
    );
  }
}

class _RewardCardTile extends StatelessWidget {
  const _RewardCardTile({
    required this.card,
    required this.program,
    required this.repository,
  });

  final RewardCard card;
  final RewardsProgram program;
  final RewardsRepository repository;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: InkWell(
              onTap: () => _showPhoto(context, card.photoPath),
              child: _CardPhoto(
                photoPath: card.photoPath,
                repository: repository,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => ColoredBox(
                  color: program.color.withValues(alpha: 0.10),
                  child: const Center(
                    child: Icon(Icons.broken_image_outlined, size: 42),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _formatDate(card.createdAt),
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showPhoto(BuildContext context, String photoPath) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: _ZoomedPhotoViewer(photoPath: photoPath, repository: repository),
      ),
    );
  }
}

class _ZoomedPhotoViewer extends StatefulWidget {
  const _ZoomedPhotoViewer({required this.photoPath, required this.repository});

  final String photoPath;
  final RewardsRepository repository;

  @override
  State<_ZoomedPhotoViewer> createState() => _ZoomedPhotoViewerState();
}

class _ZoomedPhotoViewerState extends State<_ZoomedPhotoViewer> {
  late final TransformationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TransformationController(
      Matrix4.identity()..scaleByDouble(1.08, 1.08, 1, 1),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
      ),
      body: InteractiveViewer(
        transformationController: _controller,
        boundaryMargin: const EdgeInsets.all(80),
        minScale: 0.8,
        maxScale: 5,
        child: Center(
          child: _CardPhoto(
            photoPath: widget.photoPath,
            repository: widget.repository,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) =>
                const Icon(Icons.broken_image_outlined, size: 48),
          ),
        ),
      ),
    );
  }
}

class _CardPhoto extends StatefulWidget {
  const _CardPhoto({
    required this.photoPath,
    required this.repository,
    required this.fit,
    required this.errorBuilder,
  });

  final String photoPath;
  final RewardsRepository repository;
  final BoxFit fit;
  final ImageErrorWidgetBuilder errorBuilder;

  @override
  State<_CardPhoto> createState() => _CardPhotoState();
}

class _CardPhotoState extends State<_CardPhoto> {
  late Future<Uint8List?> _bytes = widget.repository.loadPhoto(
    widget.photoPath,
  );

  @override
  void didUpdateWidget(_CardPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photoPath != widget.photoPath ||
        oldWidget.repository != widget.repository) {
      _bytes = widget.repository.loadPhoto(widget.photoPath);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return Image.memory(
            bytes,
            fit: widget.fit,
            errorBuilder: widget.errorBuilder,
          );
        }

        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        return widget.errorBuilder(
          context,
          snapshot.error ?? 'Photo not found',
          snapshot.stackTrace,
        );
      },
    );
  }
}

class _DeleteSwipeBackground extends StatelessWidget {
  const _DeleteSwipeBackground();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: EdgeInsets.only(right: 20),
          child: Icon(Icons.delete_outline, color: Colors.white),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 34),
          const SizedBox(height: 14),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(message),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.add),
            label: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

class _ProgramBadge extends StatelessWidget {
  const _ProgramBadge({required this.program});

  final RewardsProgram program;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: program.color,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: program.accentColor, width: 2),
      ),
      child: Text(
        program.shortName,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

Future<ImageSource?> _choosePhotoSource(BuildContext context) {
  return showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from library'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<String?> _showNameDialog({
  required BuildContext context,
  required String title,
  required String label,
  required String actionLabel,
}) async {
  final controller = TextEditingController();

  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (_) {
          final value = controller.text.trim();
          if (value.isNotEmpty) {
            Navigator.pop(context, value);
          }
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final value = controller.text.trim();
            if (value.isNotEmpty) {
              Navigator.pop(context, value);
            }
          },
          child: Text(actionLabel),
        ),
      ],
    ),
  );
}

Future<bool> _confirm({
  required BuildContext context,
  required String title,
  required String message,
  required String actionLabel,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(actionLabel),
            ),
          ],
        ),
      ) ??
      false;
}

String _formatDate(DateTime date) {
  final local = date.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/'
      '${local.year}';
}

typedef StoreChange = RewardsStore Function(RewardsStore store);

class RewardsRepository {
  static const _storeKey = 'rewards_store_v1';

  Future<RewardsStore> load() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_storeKey);
    if (encoded == null) {
      return RewardsStore.empty();
    }

    return RewardsStore.fromJson(jsonDecode(encoded) as Map<String, Object?>);
  }

  Future<void> save(RewardsStore store) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_storeKey, jsonEncode(store.toJson()));
  }

  /// Applies [change] to the latest saved data and returns the result.
  Future<RewardsStore> update(StoreChange change) async {
    final store = change(await load());
    await save(store);
    return store;
  }

  /// Emits the store when another device changes it. Data saved only on this
  /// device never changes elsewhere.
  Stream<RewardsStore> watch() => const Stream.empty();

  Future<String> savePhoto(XFile photo) async {
    if (kIsWeb) {
      final bytes = await photo.readAsBytes();
      final mimeType = photo.mimeType ?? 'image/jpeg';
      return 'data:$mimeType;base64,${base64Encode(bytes)}';
    }

    final directory = await getApplicationDocumentsDirectory();
    final photoDirectory = Directory(path.join(directory.path, 'card_photos'));
    if (!photoDirectory.existsSync()) {
      photoDirectory.createSync(recursive: true);
    }

    final extension = path.extension(photo.path).isEmpty
        ? '.jpg'
        : path.extension(photo.path);
    final destination = path.join(
      photoDirectory.path,
      '${DateTime.now().microsecondsSinceEpoch}$extension',
    );
    await photo.saveTo(destination);
    return destination;
  }

  Future<Uint8List?> loadPhoto(String photoPath) async {
    if (photoPath.startsWith('data:')) {
      return UriData.parse(photoPath).contentAsBytes();
    }

    if (kIsWeb) {
      return null;
    }

    final file = File(photoPath);
    return file.existsSync() ? file.readAsBytes() : null;
  }

  Future<void> deletePhoto(String photoPath) async {
    if (kIsWeb || photoPath.startsWith('data:')) {
      return;
    }

    final file = File(photoPath);
    if (file.existsSync()) {
      await file.delete();
    }
  }
}

class RewardsStore {
  const RewardsStore({
    required this.programs,
    required this.users,
    required this.cards,
  });

  final List<RewardsProgram> programs;
  final List<RewardsUser> users;
  final List<RewardCard> cards;

  factory RewardsStore.empty() {
    return const RewardsStore(programs: _defaultPrograms, users: [], cards: []);
  }

  RewardsStore copyWith({
    List<RewardsProgram>? programs,
    List<RewardsUser>? users,
    List<RewardCard>? cards,
  }) {
    return RewardsStore(
      programs: programs ?? this.programs,
      users: users ?? this.users,
      cards: cards ?? this.cards,
    );
  }

  /// Combines two stores, keeping one copy of anything with the same id.
  RewardsStore mergedWith(RewardsStore other) {
    List<T> union<T>(List<T> mine, List<T> theirs, String Function(T) id) {
      final ids = mine.map(id).toSet();
      return [...mine, ...theirs.where((item) => !ids.contains(id(item)))];
    }

    return RewardsStore(
      programs: union(programs, other.programs, (program) => program.id),
      users: union(users, other.users, (user) => user.id),
      cards: union(cards, other.cards, (card) => card.id),
    );
  }

  factory RewardsStore.fromJson(Map<String, Object?> json) {
    final encodedPrograms = json['programs'] as List<Object?>?;

    return RewardsStore(
      programs: encodedPrograms == null
          ? _defaultPrograms
          : encodedPrograms
                .map(
                  (item) =>
                      RewardsProgram.fromJson(item! as Map<String, Object?>),
                )
                .toList(),
      users: ((json['users'] as List<Object?>?) ?? [])
          .map((item) => RewardsUser.fromJson(item! as Map<String, Object?>))
          .toList(),
      cards: ((json['cards'] as List<Object?>?) ?? [])
          .map((item) => RewardCard.fromJson(item! as Map<String, Object?>))
          .toList(),
    );
  }

  Map<String, Object?> toJson() => {
    'programs': programs.map((program) => program.toJson()).toList(),
    'users': users.map((user) => user.toJson()).toList(),
    'cards': cards.map((card) => card.toJson()).toList(),
  };
}

class RewardsProgram {
  const RewardsProgram({
    required this.id,
    required this.name,
    required this.shortName,
    required this.color,
    required this.accentColor,
  });

  final String id;
  final String name;
  final String shortName;
  final Color color;
  final Color accentColor;

  factory RewardsProgram.custom(String name) {
    final trimmedName = name.trim();
    final now = DateTime.now().microsecondsSinceEpoch;
    final color = _customProgramColors[now % _customProgramColors.length];

    return RewardsProgram(
      id: 'custom-$now',
      name: trimmedName,
      shortName: _shortNameFor(trimmedName),
      color: color,
      accentColor: Colors.white,
    );
  }

  factory RewardsProgram.fromJson(Map<String, Object?> json) {
    return RewardsProgram(
      id: json['id']! as String,
      name: json['name']! as String,
      shortName: json['shortName']! as String,
      color: Color(json['color']! as int),
      accentColor: Color(json['accentColor']! as int),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'shortName': shortName,
    'color': color.toARGB32(),
    'accentColor': accentColor.toARGB32(),
  };
}

String _shortNameFor(String name) {
  final words = name
      .split(RegExp(r'\s+'))
      .where((word) => word.trim().isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) {
    return 'RP';
  }

  if (words.length == 1) {
    final word = words.first;
    return word.characters.take(2).toString().toUpperCase();
  }

  return words
      .take(2)
      .map((word) => word.characters.first.toUpperCase())
      .join();
}

class RewardsUser {
  const RewardsUser({required this.id, required this.name});

  final String id;
  final String name;

  factory RewardsUser.fromJson(Map<String, Object?> json) {
    return RewardsUser(
      id: json['id']! as String,
      name: json['name']! as String,
    );
  }

  Map<String, Object?> toJson() => {'id': id, 'name': name};
}

class RewardCard {
  const RewardCard({
    required this.id,
    required this.userId,
    required this.programId,
    required this.photoPath,
    required this.createdAt,
  });

  final String id;
  final String userId;
  final String programId;
  final String photoPath;
  final DateTime createdAt;

  RewardCard copyWith({String? photoPath}) {
    return RewardCard(
      id: id,
      userId: userId,
      programId: programId,
      photoPath: photoPath ?? this.photoPath,
      createdAt: createdAt,
    );
  }

  factory RewardCard.fromJson(Map<String, Object?> json) {
    return RewardCard(
      id: json['id']! as String,
      userId: json['userId']! as String,
      programId: json['programId']! as String,
      photoPath: json['photoPath']! as String,
      createdAt: DateTime.parse(json['createdAt']! as String),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'userId': userId,
    'programId': programId,
    'photoPath': photoPath,
    'createdAt': createdAt.toIso8601String(),
  };
}
