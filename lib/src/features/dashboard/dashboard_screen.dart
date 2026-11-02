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
import '../../services/photo_cache.dart';
import '../../services/photo_compressor.dart';
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

  /// Firebase starts in the background so cards can show straight away.
  final Future<AppBootstrap> bootstrap;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final _sharing = SharedWalletService();

  /// Every screen reads and writes through this, and it follows whichever
  /// store is current, so screens opened earlier never use a stale one.
  final _repository = ActiveRewardsRepository();
  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<RewardsStore>? _storeSubscription;
  AppBootstrap? _bootstrap;
  User? _user;

  /// Invite code from a `?join=` link this page was opened with.
  String? _pendingJoinCode = kIsWeb ? Uri.base.queryParameters['join'] : null;

  /// Whose cloud cards are showing, or null for cards saved on this device.
  String? _repositoryUid;

  /// Whether Firebase has reported who is signed in yet.
  var _authResolved = false;

  RewardsStore _store = RewardsStore.empty();
  var _loading = true;

  bool get _firebaseReady => _bootstrap?.firebaseReady ?? false;

  String? get _walletId => switch (_repository.target) {
    CloudRewardsRepository(:final walletId) => walletId,
    _SavedCardsRepository(:final walletId) => walletId,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    _showSavedCards();
    widget.bootstrap.then(_onBootstrapped);
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _storeSubscription?.cancel();
    _entryController.dispose();
    _entryFocus.dispose();
    super.dispose();
  }

  /// Shows the cards from last time the moment the app opens. Firebase takes
  /// seconds to start on mobile browsers, so it catches up in the background.
  Future<void> _showSavedCards() async {
    final session = await _Session.read();
    if (!mounted || session == null || _authResolved) {
      return;
    }

    final uid = session.uid;
    final store = session.store;
    if (uid == null) {
      _useRepository(RewardsRepository());
    } else if (store != null) {
      _useRepository(
        _SavedCardsRepository(store, walletId: session.walletId),
        uid: uid,
      );
    }
  }

  void _onBootstrapped(AppBootstrap bootstrap) {
    if (!mounted) {
      return;
    }

    setState(() => _bootstrap = bootstrap);
    if (bootstrap.firebaseReady) {
      _authSubscription = FirebaseAuth.instance.authStateChanges().listen(
        _onAuthChanged,
      );
    } else if (_repositoryUid == null) {
      _useRepository(RewardsRepository());
    }
    // Otherwise Firebase couldn't start (for example with no signal), so keep
    // showing the signed-in person's saved cards rather than this device's.
  }

  Future<void> _onAuthChanged(User? user) async {
    _authResolved = true;
    final previousUid = _repositoryUid;
    setState(() => _user = user);

    if (user == null) {
      await const _Session.signedOut().save();
      if (previousUid != null) {
        await clearCachedPhotos();
      }
      if (previousUid != null || _loading) {
        _useRepository(RewardsRepository());
      }
    } else {
      // Keep showing the saved cards while checking, in the background,
      // whether this person joined or left shared cards elsewhere.
      final alreadyShowing = previousUid == user.uid;
      CloudRewardsRepository repository;
      try {
        repository = await _sharing.repositoryFor(user);
      } catch (error) {
        debugPrint('Could not find shared cards: $error');
        final walletId = alreadyShowing ? _walletId : null;
        repository = walletId == null
            ? CloudRewardsRepository.personal(uid: user.uid)
            : CloudRewardsRepository.wallet(walletId: walletId);
      }
      if (!mounted || user != _user) {
        return;
      }

      if (!alreadyShowing ||
          _repository.target is! CloudRewardsRepository ||
          repository.walletId != _walletId) {
        _useRepository(
          repository,
          uid: user.uid,
          showSpinner: !alreadyShowing || repository.walletId != _walletId,
        );
      }
    }

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

  void _useRepository(
    RewardsRepository repository, {
    String? uid,
    bool showSpinner = true,
  }) {
    _storeSubscription?.cancel();
    _repository.target = repository;
    setState(() {
      _repositoryUid = uid;
      _loading = showSpinner;
    });
    if (uid == null) {
      const _Session.signedOut().save();
    }
    _loadStore();
  }

  Future<void> _loadStore() async {
    final repository = _repository.target;
    try {
      final store = await repository.load(preferCache: true);
      if (!mounted || repository != _repository.target) {
        return;
      }

      _setStore(store);
      _prefetchPhotos(repository, store);
      _storeSubscription = repository.watch().listen(
        (store) {
          if (mounted && repository == _repository.target) {
            _setStore(store);
          }
        },
        onError: (Object error) {
          // Access to shared cards ends when the owner removes someone.
          if (mounted &&
              repository == _repository.target &&
              _walletId != null) {
            _showMessage('You no longer have access to the shared cards.');
            _onAuthChanged(_user);
          }
        },
      );
    } catch (error) {
      if (!mounted || repository != _repository.target) {
        return;
      }

      setState(() => _loading = false);
      _showMessage('Could not load cards: $error');
    }
  }

  /// Shows [store] and, for cloud cards, saves a copy on this device so the
  /// next visit can show it instantly.
  void _setStore(RewardsStore store) {
    setState(() {
      _store = store;
      _loading = false;
    });

    final uid = _repositoryUid;
    final repository = _repository.target;
    if (uid != null && repository is CloudRewardsRepository) {
      _Session(uid: uid, walletId: repository.walletId, store: store).save();
    }
  }

  /// Downloads card photos in the background so they open instantly.
  void _prefetchPhotos(RewardsRepository repository, RewardsStore store) {
    for (final card in store.cards) {
      repository.loadPhoto(card.photoPath).ignore();
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

    final current = _repository.target;
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
      () async => _useRepository(
        await _sharing.joinWallet(user, code, current),
        uid: user.uid,
      ),
      failure: 'Could not join',
    );
  }

  Future<void> _shareCards(User user) async {
    final current = _repository.target;
    if (current is! CloudRewardsRepository) {
      return;
    }

    final shared = await _runSharingAction(
      () => _sharing.createWallet(user, current),
      failure: 'Could not share cards',
    );
    if (shared != null) {
      _useRepository(shared, uid: user.uid);
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
      _useRepository(
        CloudRewardsRepository.personal(uid: user.uid),
        uid: user.uid,
      );
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
      _setStore(store);
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

  final _entryController = TextEditingController();
  final _entryFocus = FocusNode();
  var _addingProgram = false;

  // Focus has to be requested during the tap itself, or iOS Safari won't
  // show the keyboard, so this must not await anything first.
  void _startAddProgram() {
    _entryController.clear();
    setState(() => _addingProgram = true);
    _entryFocus.requestFocus();
  }

  void _closeEntry() {
    _entryFocus.unfocus();
    setState(() => _addingProgram = false);
  }

  Future<void> _addProgram() async {
    final name = _entryController.text.trim();
    if (name.isEmpty) {
      return;
    }

    _closeEntry();
    final program = RewardsProgram.custom(name);
    try {
      await _updateStore(
        (store) => store.copyWith(programs: [...store.programs, program]),
      );
    } catch (error) {
      _showMessage('Could not add program: $error');
    }
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
    return Stack(
      children: [
        _buildScaffold(),
        _InputModal(
          visible: _addingProgram,
          title: 'Add rewards program',
          label: 'Program name',
          actionLabel: 'Add',
          controller: _entryController,
          focusNode: _entryFocus,
          onSubmit: _addProgram,
          onCancel: _closeEntry,
        ),
      ],
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rewards Cards'),
        actions: [
          if (_firebaseReady && _authResolved)
            _AccountButton(
              user: _user,
              shared: _walletId != null,
              onSignIn: _signIn,
              onOpenAccount: _openAccountSheet,
            ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: _loading
          ? null
          : _AddButton(tooltip: 'Add program', onPressed: _startAddProgram),
      body: _buildPrograms(),
    );
  }

  Widget _buildPrograms() {
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : SafeArea(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: _store.programs.length + 1,
              separatorBuilder: (context, index) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _AirlineTotals(store: _store);
                }
                final program = _store.programs[index - 1];

                return Dismissible(
                  key: ValueKey('program-${program.id}'),
                  direction: DismissDirection.endToStart,
                  background: const _DeleteSwipeBackground(),
                  confirmDismiss: (_) => _deleteProgram(program),
                  child: _ProgramListTile(
                    program: program,
                    totalPoints: _store.totalPoints(program.id),
                    onTap: () => _openUsers(program),
                  ),
                );
              },
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

  final _entryController = TextEditingController();
  final _entryFocus = FocusNode();
  var _entryVisible = false;

  /// Whose points are being entered, or null when adding a new person.
  RewardsUser? _pointsUser;

  @override
  void dispose() {
    _entryController.dispose();
    _entryFocus.dispose();
    super.dispose();
  }

  // Focus has to be requested during the tap itself, or iOS Safari won't
  // show the keyboard, so these must not await anything first.
  void _startAddUser() {
    _entryController.clear();
    setState(() {
      _pointsUser = null;
      _entryVisible = true;
    });
    _entryFocus.requestFocus();
  }

  void _startEditPoints(RewardsUser user) {
    final points = user.points?.toString() ?? '';
    _entryController.value = TextEditingValue(
      text: points,
      selection: TextSelection(baseOffset: 0, extentOffset: points.length),
    );
    setState(() {
      _pointsUser = user;
      _entryVisible = true;
    });
    _entryFocus.requestFocus();
  }

  void _closeEntry() {
    _entryFocus.unfocus();
    setState(() => _entryVisible = false);
  }

  void _submitEntry() {
    final text = _entryController.text.trim();
    if (text.isEmpty) {
      return;
    }

    final pointsUser = _pointsUser;
    _closeEntry();
    if (pointsUser == null) {
      // Called straight from the tap so the browser allows the photo picker.
      _addUser(text);
    } else {
      _savePoints(pointsUser, int.parse(text));
    }
  }

  Future<void> _savePoints(RewardsUser user, int points) async {
    final now = DateTime.now();
    try {
      await _updateStore(
        (store) => store.copyWith(
          users: [
            for (final item in store.users)
              item.id == user.id ? item.withPoints(points, now) : item,
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save points: $error')),
        );
      }
    }
  }

  Future<void> _addUser(String name) async {
    try {
      final photo = await _picker.pickImage(
        source: ImageSource.gallery,
        // On web, photos are compressed when saved instead (see compressPhoto).
        imageQuality: kIsWeb ? null : 88,
        maxWidth: kIsWeb ? null : 1800,
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
    final cards = _store.cards
        .where(
          (card) =>
              card.programId == widget.program.id && card.userId == user.id,
        )
        .toList(growable: false);

    // Each person normally has a single card photo, so show it straight away.
    if (cards.length == 1) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (context) => _ZoomedPhotoViewer(
            title: user.name,
            photoPath: cards.single.photoPath,
            repository: widget.repository,
          ),
        ),
      );
      return;
    }

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
    final pointsUser = _pointsUser;

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(title: Text(widget.program.name)),
          // An empty program shows its own + button in the middle instead.
          floatingActionButton: _programUsers.isEmpty
              ? null
              : _AddButton(tooltip: 'Add user', onPressed: _startAddUser),
          body: _buildUsers(),
        ),
        _InputModal(
          visible: _entryVisible,
          title: pointsUser == null
              ? 'Add user'
              : '${pointsUser.name}’s points',
          label: pointsUser == null ? 'Name' : 'Points',
          actionLabel: pointsUser == null ? 'Next' : 'Save',
          numeric: pointsUser != null,
          controller: _entryController,
          focusNode: _entryFocus,
          onSubmit: _submitEntry,
          onCancel: _closeEntry,
        ),
      ],
    );
  }

  Widget _buildUsers() {
    return SafeArea(
      child: _programUsers.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: _EmptyState(
                icon: Icons.group_add_outlined,
                title: 'Add your first user',
                message:
                    'Users let you keep each person’s rewards cards separate under ${widget.program.name}.',
                actionLabel: 'Add user',
                onPressed: _startAddUser,
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: _programUsers.length,
              separatorBuilder: (context, index) => const SizedBox(height: 10),
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
                    onEditPoints: () => _startEditPoints(user),
                  ),
                );
              },
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

/// Airline points including what the supermarket points convert to:
/// Flybuys and Everyday Rewards transfer to Velocity and Qantas Frequent
/// Flyer at half their value.
class _AirlineTotals extends StatelessWidget {
  const _AirlineTotals({required this.store});

  final RewardsStore store;

  @override
  Widget build(BuildContext context) {
    final velocity = store.totalPoints('velocity');
    final flybuys = store.totalPoints('flybuys');
    final qantas = store.totalPoints('qantas-frequent-flyer');
    final everyday = store.totalPoints('everyday-rewards');
    if ([velocity, flybuys, qantas, everyday].every((p) => p == null)) {
      // Keeps the list's spacing consistent while there's nothing to show.
      return const SizedBox.shrink();
    }

    return Card(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Points totals',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            _AirlineTotalRow(
              airline: 'Velocity',
              points: velocity ?? 0,
              partnerPoints: flybuys ?? 0,
            ),
            _AirlineTotalRow(
              airline: 'Qantas Frequent Flyer',
              points: qantas ?? 0,
              partnerPoints: everyday ?? 0,
            ),
          ],
        ),
      ),
    );
  }
}

class _AirlineTotalRow extends StatelessWidget {
  const _AirlineTotalRow({
    required this.airline,
    required this.points,
    required this.partnerPoints,
  });

  final String airline;
  final int points;
  final int partnerPoints;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(airline),
      trailing: Text(
        _formatPoints(points + partnerPoints ~/ 2),
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _ProgramListTile extends StatelessWidget {
  const _ProgramListTile({
    required this.program,
    required this.totalPoints,
    required this.onTap,
  });

  final RewardsProgram program;
  final int? totalPoints;
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
        subtitle: totalPoints == null
            ? null
            : Text('${_formatPoints(totalPoints!)} points in total'),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _UserListTile extends StatelessWidget {
  const _UserListTile({
    required this.user,
    required this.onTap,
    required this.onEditPoints,
  });

  final RewardsUser user;
  final VoidCallback onTap;
  final VoidCallback onEditPoints;

  @override
  Widget build(BuildContext context) {
    final points = user.points;
    final updatedAt = user.pointsUpdatedAt;
    final textTheme = Theme.of(context).textTheme;

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
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        subtitle: updatedAt == null
            ? null
            : Text('Updated ${_formatDate(updatedAt)}'),
        trailing: TextButton(
          onPressed: onEditPoints,
          child: points == null
              ? const Text('Add points')
              : Text(
                  '${_formatPoints(points)} pts',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Remembers what was showing last time, including a copy of cloud cards, so
/// the next visit can show it instantly without waiting for Firebase.
class _Session {
  const _Session({required this.uid, required this.walletId, this.store});

  const _Session.signedOut() : uid = null, walletId = null, store = null;

  static const _key = 'rewards_session_v2';

  /// Who was signed in, or null if nobody was.
  final String? uid;
  final String? walletId;
  final RewardsStore? store;

  static Future<_Session?> read() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final encoded = preferences.getString(_key);
      if (encoded == null) {
        return null;
      }

      final json = jsonDecode(encoded) as Map<String, Object?>;
      final store = json['store'] as Map<String, Object?>?;
      return _Session(
        uid: json['uid'] as String?,
        walletId: json['walletId'] as String?,
        store: store == null ? null : RewardsStore.fromJson(store),
      );
    } catch (error) {
      debugPrint('Ignoring unreadable saved session: $error');
      return null;
    }
  }

  Future<void> save() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _key,
      jsonEncode({'uid': uid, 'walletId': walletId, 'store': store?.toJson()}),
    );
  }
}

/// Forwards to whichever repository is current.
class ActiveRewardsRepository extends RewardsRepository {
  RewardsRepository target = RewardsRepository();

  @override
  Future<RewardsStore> load({bool preferCache = false}) =>
      target.load(preferCache: preferCache);

  @override
  Future<void> save(RewardsStore store) => target.save(store);

  @override
  Future<RewardsStore> update(StoreChange change) => target.update(change);

  @override
  Stream<RewardsStore> watch() => target.watch();

  @override
  Future<String> savePhoto(XFile photo) => target.savePhoto(photo);

  @override
  Future<void> deletePhoto(String photoPath) => target.deletePhoto(photoPath);

  @override
  Future<Uint8List?> loadPhoto(String photoPath) => target.loadPhoto(photoPath);
}

/// The cards saved on this device from last time, shown while Firebase
/// starts. Photos come from the browser's photo cache; changes wait until
/// Firebase is ready.
class _SavedCardsRepository extends RewardsRepository {
  _SavedCardsRepository(this.store, {required this.walletId});

  final RewardsStore store;
  final String? walletId;

  static Never _notReady() =>
      throw StateError('Still connecting. Try again in a moment.');

  @override
  Future<RewardsStore> load({bool preferCache = false}) async => store;

  @override
  Future<void> save(RewardsStore store) async => _notReady();

  @override
  Future<RewardsStore> update(StoreChange change) async => _notReady();

  @override
  Future<String> savePhoto(XFile photo) async => _notReady();

  @override
  Future<void> deletePhoto(String photoPath) async => _notReady();
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

class _ZoomedPhotoViewer extends StatelessWidget {
  const _ZoomedPhotoViewer({
    required this.photoPath,
    required this.repository,
    this.title,
  });

  final String? title;
  final String photoPath;
  final RewardsRepository repository;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        surfaceTintColor: Colors.transparent,
        title: title == null ? null : Text(title!),
        leading: IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
      ),
      // Fill the screen with the whole photo: no cropping, zooming or panning.
      body: SafeArea(
        child: SizedBox.expand(
          child: _CardPhoto(
            photoPath: photoPath,
            repository: repository,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => const Center(
              child: Icon(Icons.broken_image_outlined, size: 48),
            ),
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
          _AddButton(tooltip: actionLabel, onPressed: onPressed),
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

/// The round + button used for everything that adds something.
class _AddButton extends StatelessWidget {
  const _AddButton({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      heroTag: null,
      tooltip: tooltip,
      shape: const CircleBorder(),
      onPressed: onPressed,
      child: const Icon(Icons.add),
    );
  }
}

/// A dialog asking for one piece of text, such as a name or a number.
///
/// Unlike a dialog pushed with showDialog, it stays in the widget tree while
/// hidden, so the tap that opens it can focus its field straight away. iOS
/// Safari only opens the keyboard for focus requested during a tap, which a
/// pushed dialog's field (built a frame later) always misses.
class _InputModal extends StatelessWidget {
  const _InputModal({
    required this.visible,
    required this.title,
    required this.label,
    required this.actionLabel,
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    required this.onCancel,
    this.numeric = false,
  });

  final bool visible;
  final String title;
  final String label;
  final String actionLabel;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool numeric;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  static const _duration = Duration(milliseconds: 150);

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: PopScope(
        canPop: !visible,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            onCancel();
          }
        },
        child: IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: _duration,
            child: Stack(
              children: [
                ModalBarrier(
                  color: Colors.black54,
                  onDismiss: onCancel,
                  semanticsLabel: 'Cancel',
                ),
                AnimatedScale(
                  scale: visible ? 1 : 0.95,
                  duration: _duration,
                  curve: Curves.easeOut,
                  child: AlertDialog(
                    title: Text(title),
                    content: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      keyboardType: numeric
                          ? TextInputType.number
                          : TextInputType.text,
                      textCapitalization: numeric
                          ? TextCapitalization.none
                          : TextCapitalization.words,
                      inputFormatters: numeric
                          ? [FilteringTextInputFormatter.digitsOnly]
                          : null,
                      decoration: InputDecoration(labelText: label),
                      onSubmitted: (_) => onSubmit(),
                    ),
                    actions: [
                      TextButton(
                        onPressed: onCancel,
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: onSubmit,
                        child: Text(actionLabel),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatPoints(int points) {
  final digits = points.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
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

  /// Marks photos stored in Firestore, as `cloud:{photoId}`.
  static const cloudPhotoPrefix = 'cloud:';

  /// [preferCache] lets cloud repositories answer from this device first.
  Future<RewardsStore> load({bool preferCache = false}) async {
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
      // Browser storage only holds a few megabytes, so keep photos small.
      final bytes = await compressPhoto(
        await photo.readAsBytes(),
        maxBytes: 300 * 1024,
      );
      return 'data:image/jpeg;base64,${base64Encode(bytes)}';
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
    if (photoPath.startsWith(cloudPhotoPrefix)) {
      return readCachedPhoto(photoPath.substring(cloudPhotoPrefix.length));
    }

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

  /// The total points of everyone with a card in [programId], or null if
  /// nobody there has entered points.
  int? totalPoints(String programId) {
    final userIds = cards
        .where((card) => card.programId == programId)
        .map((card) => card.userId)
        .toSet();
    final balances = users
        .where((user) => userIds.contains(user.id) && user.points != null)
        .map((user) => user.points!);
    return balances.isEmpty ? null : balances.reduce((a, b) => a + b);
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
  const RewardsUser({
    required this.id,
    required this.name,
    this.points,
    this.pointsUpdatedAt,
  });

  final String id;
  final String name;

  /// The person's current points balance, if they've entered one.
  final int? points;
  final DateTime? pointsUpdatedAt;

  RewardsUser withPoints(int points, DateTime updatedAt) {
    return RewardsUser(
      id: id,
      name: name,
      points: points,
      pointsUpdatedAt: updatedAt,
    );
  }

  factory RewardsUser.fromJson(Map<String, Object?> json) {
    final updatedAt = json['pointsUpdatedAt'] as String?;
    return RewardsUser(
      id: json['id']! as String,
      name: json['name']! as String,
      points: json['points'] as int?,
      pointsUpdatedAt: updatedAt == null ? null : DateTime.parse(updatedAt),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (points != null) 'points': points,
    if (pointsUpdatedAt != null)
      'pointsUpdatedAt': pointsUpdatedAt!.toIso8601String(),
  };
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
