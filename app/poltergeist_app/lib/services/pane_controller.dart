import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'engine_session.dart';
import 'pane_engine_lanes.dart';
import 'pane_location.dart';

/// Where a pane currently stands in the binding lifecycle. Listing-level
/// loading/error state is separate ([PaneController.loading],
/// [PaneController.error]) and only meaningful while browsing.
enum PanePhase {
  /// Nothing bound and nothing in flight (no engine, or a cancelled first
  /// open). The pane is never blank — it renders its unbound state.
  unbound,

  /// The initial local-home channel open is in flight.
  openingLocal,

  /// A remote channel open (the connect itself) is in flight.
  connectingRemote,

  /// A channel is live; navigation and listings answer on it.
  browsing,
}

/// The last quiescent state, captured on every not-loading → loading
/// transition (02 §2.8): Esc-cancel restores exactly this, never a
/// transient mid-navigation state.
class _QuiescentSnapshot {
  const _QuiescentSnapshot(this.location, this.entries, this.error);

  final PaneLocation? location;
  final List<RemoteFileEntry> entries;
  final RemoteFileException? error;
}

/// One pane-tab's browsing controller (03 §6): navigation state per 02
/// §2.8's normative machine — optimistic location, monotonic generations,
/// stale answers dropped, errors inline over cached entries, Esc restores
/// the last quiescent snapshot. Local and remote locations are symmetric:
/// both browse through the one VFS's engine channels (D3/D8).
///
/// 09 §3's idioms are load-bearing here: every await rechecks `_disposed`
/// and the captured generation/attempt before mutating state, and channels
/// are `identical()`-rechecked so a rebound pane can never apply a stale
/// channel's answer.
class PaneController extends ChangeNotifier {
  PaneController({
    required this.paneTabId,
    PaneEngineLanes? lanes,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) : // Keep the lanes seam private to the pane.
       // ignore: prefer_initializing_formals
       _lanes = lanes,
       // Keep the reporter private while allowing test-only injection.
       // ignore: prefer_initializing_formals
       _onError = onError;

  /// The engine-side channel identity (03 §3.2); the shell assigns the
  /// stable pane ids ('pane.left', 'pane.right') until tabs per pane land.
  /// Construction stays inert: the shell binds the initial location
  /// ([openLocalHome]) so a session replacement can re-drive it.
  final String paneTabId;

  final PaneEngineLanes? _lanes;
  final void Function(Object error, StackTrace)? _onError;

  PanePhase _phase = PanePhase.unbound;
  PaneLocation? _location;
  List<RemoteFileEntry> _entries = const [];
  RemoteFileException? _error;
  int _issuedGeneration = 0;
  int _answeredGeneration = 0;
  _QuiescentSnapshot? _snapshot;
  AppBrowseChannel? _channel;
  StreamSubscription<ServerStatus>? _statusWatch;
  ServerStatus? _connectionStatus;
  Bookmark? _pendingRemote;
  int? _cursorIndex;
  bool _disposed = false;

  /// Binds and rebinds are serialized by this attempt counter: a stale
  /// bind's completions (open, teardown, watch events) drop themselves.
  int _bindAttempt = 0;

  PanePhase get phase => _phase;
  PaneLocation? get location => _location;

  /// Whether an engine session backs this pane. False panes render the
  /// no-engine state instead of failing to boot (the composition root's
  /// null-session posture).
  bool get hasEngine => _lanes != null;

  /// The visible listing: sorted (directories first, then name), dotfiles
  /// hidden by default, an unmodifiable copy written only when a listing
  /// is accepted or Esc restores a snapshot.
  List<RemoteFileEntry> get entries => _entries;

  /// The typed error of the pane's current surface: the listing taxonomy
  /// while browsing, or the connect/open failure otherwise.
  RemoteFileException? get error => _error;

  /// 02 §2.8's derived state: an issued navigation is outstanding and no
  /// error answered it. A failed or cancelled generation is NOT loading.
  bool get loading => _issuedGeneration > _answeredGeneration && _error == null;

  /// Verbs act on `location` and are live only on a fresh, error-free
  /// listing of a live binding (02 §2.8): unbound and mid-open phases
  /// carry nothing to act on, and neither does the post-first-cancel
  /// state (browsing phase, snapshot restored, no location).
  bool get verbsEnabled =>
      _phase == PanePhase.browsing &&
      _location != null &&
      _error == null &&
      !loading;

  /// The remote binding's live connection truth (current value first from
  /// the engine's watch); null for local panes and unbound panes.
  ServerStatus? get connectionStatus => _connectionStatus;

  /// The 02 §2.7 connection-lost banner: keyed on connection state, not on
  /// listing state — transport-level reconnect shows the banner over the
  /// cached listing instead of a pane error.
  bool get connectionLost =>
      _connectionStatus?.state == ServerConnectionState.reconnecting;

  /// The bookmark whose remote binding is live or connecting; the retry
  /// after a failed connect reuses it.
  Bookmark? get remoteBookmark => _pendingRemote;

  /// The keyboard cursor row into [entries]; null until the first key
  /// press or row tap.
  int? get cursorIndex => _cursorIndex;

  /// Binds the pane to a remote bookmark: closes any previous channel,
  /// subscribes to the server's state lane BEFORE connecting (live
  /// streams keep no replay, 03 §5), opens the browse channel, and
  /// navigates to the bookmark's path ('/' meaning the canonical home).
  Future<void> connectRemote(Bookmark bookmark) async {
    if (_disposed || _lanes == null) return;
    _pendingRemote = bookmark;
    await _bind(
      connectingPhase: PanePhase.connectingRemote,
      operation: 'connect',
      failMessage: 'The connection could not be opened.',
      connect: (lanes, attempt) async {
        // Subscribe before connecting: a connect that raises state (or
        // a prompt the coordinator answers) must find this pane
        // listening.
        _statusWatch = lanes
            .watchServer(bookmark.id)
            .listen(
              (status) {
                if (_disposed || attempt != _bindAttempt) return;
                _connectionStatus = status;
                notifyListeners();
              },
              onError: (Object error, StackTrace stackTrace) {
                if (_disposed || attempt != _bindAttempt) return;
                _report(error, stackTrace);
              },
            );
        final channel = await lanes.openBrowseChannel(
          serverId: bookmark.id,
          paneTabId: paneTabId,
          config: serverConfigForBookmark(bookmark),
        );
        if (_disposed || attempt != _bindAttempt) {
          await _closeChannel(channel);
          return;
        }
        _channel = channel;
        _phase = PanePhase.browsing;
        notifyListeners();

        final remotePath = bookmark.remotePath;
        final target =
            remotePath == null || remotePath == '/'
                ? channel.homePath
                : remotePath;
        _issueNavigation(
          RemotePaneLocation(bookmark.id, target),
          target,
          channel,
        );
      },
    );
  }

  /// Navigates to [path] on the live channel (path bar, entries,
  /// refresh). The target's kind comes from the BINDING, not the last
  /// location: a cancelled first listing leaves the location null while
  /// the channel stays live, and a null location on a remote pane must
  /// never mint a local one.
  void navigate(String path) {
    if (_disposed || _channel == null) return;
    final serverId = _pendingRemote?.id;
    _issueNavigation(
      serverId != null
          ? RemotePaneLocation(serverId, path)
          : LocalPaneLocation(path),
      path,
      _channel!,
    );
  }

  /// Opens one row (Enter / double-click): only entries the listing
  /// itself types as directories navigate — a symlink is not a directory
  /// from listing metadata alone (02 §2.3 classifies without a target
  /// round trip), so opening it does nothing this slice. Files do
  /// nothing yet — the double-click action
  /// setting and the file verbs land with their own slices.
  void openEntry(RemoteFileEntry entry) {
    if (entry.type == RemoteFileType.directory) {
      navigate(entry.path);
    }
  }

  /// Navigates to the parent folder; the root is its own parent (no-op).
  void goUp() {
    final current = _location;
    if (current == null) return;
    final parent = paneParentPath(current.path);
    if (parent == current.path) return;
    navigate(parent);
  }

  /// Re-lists the current location (a fresh generation, so in-flight
  /// answers for the same path go stale).
  void refresh() {
    final current = _location;
    if (current == null || _channel == null) return;
    navigate(current.path);
  }

  /// The Esc tier that cancels navigation (02 §2.8): drops every in-flight
  /// generation by advancing the counters (never backward — a late answer
  /// from the cancelled navigation arrives stale and is swallowed) and
  /// restores the last quiescent snapshot, including its error.
  void cancelNavigation() {
    if (_disposed || !_loadingActive()) return;

    final snapshot = _snapshot;
    _location = snapshot?.location;
    _entries = snapshot?.entries ?? const [];
    _error = snapshot?.error;
    _issuedGeneration++;
    _answeredGeneration = _issuedGeneration;
    _snapshot = null;
    _cursorIndex = null;
    notifyListeners();
  }

  /// Retries whatever failed: a failed connect reopens the channel, a
  /// failed first local open retries it, and a listing error re-issues
  /// the navigation.
  Future<void> retry() async {
    if (_disposed) return;
    if (_phase == PanePhase.connectingRemote && _error != null) {
      final bookmark = _pendingRemote;
      if (bookmark != null) {
        await connectRemote(bookmark);
        return;
      }
    }
    if (_phase == PanePhase.openingLocal && _error != null) {
      await openLocalHome();
      return;
    }
    final current = _location;
    if (current != null && _error != null) {
      refresh();
    }
  }

  /// Moves the cursor by [delta], clamped to the listing. An unset
  /// cursor seeds from the list's far end (first Down selects the first
  /// row, first Up the last — the Finder convention).
  void moveCursorBy(int delta) {
    if (_entries.isEmpty) return;
    final seed = delta > 0 ? -1 : _entries.length;
    final next = (_cursorIndex ?? seed) + delta;
    setCursorIndex(next.clamp(0, _entries.length - 1));
  }

  /// Sets the cursor to [index] (a row tap or a direct jump), clamped.
  void setCursorIndex(int index) {
    if (_disposed || _entries.isEmpty) return;
    final clamped = index.clamp(0, _entries.length - 1);
    if (_cursorIndex == clamped) return;
    _cursorIndex = clamped;
    notifyListeners();
  }

  /// Drops the remote binding's server reference: the banner's cancel —
  /// transport-level recovery stops, the watch reports disconnected, and
  /// the next navigation re-raises the failure to retry against (02 §2.7).
  ///
  /// The engine keys pool references by serverId, so this severs every
  /// pane bound to the same server — the shell routes the banner's cancel
  /// through [detachRemote] when a sibling still browses the server.
  /// Keyed on the pending binding, not the location: the post-first-cancel
  /// state keeps a live remote channel with no location, and its unbind
  /// must not dead-end.
  Future<void> cancelRecovery() async {
    final lanes = _lanes;
    final serverId = _pendingRemote?.id;
    if (_disposed || lanes == null || serverId == null) return;
    try {
      await lanes.disconnectServer(serverId);
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace);
    }
  }

  /// Detaches a remote binding without touching the shared server:
  /// the pane's channel closes (the pool refcounts pane bindings), the
  /// binding state resets, and the server reference stays for any
  /// sibling pane still browsing it. The banner's cancel path when the
  /// server is shared (02 §2.7's cancel, made two-pane-safe). Keyed on
  /// the pending binding — it is set for the whole remote-bind lifetime,
  /// including the post-first-cancel state and an in-flight connect.
  Future<void> detachRemote() async {
    if (_disposed || _pendingRemote == null) return;
    _bindAttempt++; // invalidate the bind this detach replaces
    _cancelListing();
    _phase = PanePhase.unbound;
    _location = null;
    _entries = const [];
    _error = null;
    _snapshot = null;
    _cursorIndex = null;
    _connectionStatus = null;
    _pendingRemote = null;
    unawaited(_statusWatch?.cancel());
    _statusWatch = null;
    notifyListeners();

    await _releaseBinding();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindAttempt++;
    unawaited(_statusWatch?.cancel());
    _statusWatch = null;
    unawaited(_releaseBinding());
    super.dispose();
  }

  // ── internals ──────────────────────────────────────────────────────────

  /// The one shared bind lifecycle (local and remote differ only in the
  /// open and the first navigation): attempt capture, binding reset,
  /// previous-channel release, then the kind-specific [connect] under
  /// the shared error surface. Every await rechecks `_disposed` and the
  /// attempt counter; a stale attempt's channel is closed, never kept.
  Future<void> _bind({
    required PanePhase connectingPhase,
    required String operation,
    required String failMessage,
    required Future<void> Function(PaneEngineLanes lanes, int attempt)
        connect,
  }) async {
    final lanes = _lanes;
    if (_disposed || lanes == null) return;

    final attempt = ++_bindAttempt;
    _phase = connectingPhase;
    _beginBinding();
    notifyListeners();

    await _releaseBinding();
    if (_disposed || attempt != _bindAttempt) return;

    try {
      await connect(lanes, attempt);
    } on RemoteFileException catch (error) {
      if (_disposed || attempt != _bindAttempt) return;
      _dropStatusWatch();
      _error = error;
      notifyListeners();
    } on Object catch (error, stackTrace) {
      if (_disposed || attempt != _bindAttempt) return;
      _report(error, stackTrace);
      _dropStatusWatch();
      _error = RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: operation,
        message: failMessage,
      );
      notifyListeners();
    }
  }

  /// A failed bind keeps no server watch: the subscription is inert
  /// (the attempt guard drops its events) but it pins the engine's
  /// per-server stream open until the next bind replaces it.
  void _dropStatusWatch() {
    unawaited(_statusWatch?.cancel());
    _statusWatch = null;
  }

  bool _loadingActive() =>
      _issuedGeneration > _answeredGeneration && _error == null;

  /// Resets listing state for a new binding (02 §2.8's transitions apply
  /// within a binding; a rebind starts fresh and cancels everything).
  void _beginBinding() {
    _cancelListing();
    _location = null;
    _entries = const [];
    _error = null;
    _snapshot = null;
    _cursorIndex = null;
    _connectionStatus = null;
    unawaited(_statusWatch?.cancel());
    _statusWatch = null;
  }

  /// Invalidates every in-flight listing answer without touching the
  /// visible state (the rebind resets it separately).
  void _cancelListing() {
    _issuedGeneration++;
    _answeredGeneration = _issuedGeneration;
  }

  Future<void> openLocalHome() async {
    _pendingRemote = null;
    await _bind(
      connectingPhase: PanePhase.openingLocal,
      operation: 'open',
      failMessage: 'The local browser could not be opened.',
      connect: (lanes, attempt) async {
        // '~' expands to the user's home inside the engine (03 §2.2);
        // the channel answers the canonicalized home path.
        final channel = await lanes.openLocalChannel(rootPath: '~');
        if (_disposed || attempt != _bindAttempt) {
          await _closeChannel(channel);
          return;
        }
        _channel = channel;
        _phase = PanePhase.browsing;
        notifyListeners();
        _issueNavigation(
          LocalPaneLocation(channel.homePath),
          channel.homePath,
          channel,
        );
      },
    );
  }

  /// 02 §2.8's navigation-issue transition: snapshot the quiescent state
  /// (only on the not-loading → loading edge), set the location
  /// optimistically, bump the generation, clear the error — then run the
  /// listing against the captured channel.
  void _issueNavigation(
    PaneLocation target,
    String path,
    AppBrowseChannel channel,
  ) {
    if (!_loadingActive()) {
      _snapshot = _QuiescentSnapshot(_location, _entries, _error);
    }
    _location = target;
    _issuedGeneration++;
    _error = null;
    _cursorIndex = null;
    notifyListeners();

    unawaited(_load(path, channel, _issuedGeneration));
  }

  Future<void> _load(
    String path,
    AppBrowseChannel channel,
    int generation,
  ) async {
    try {
      final listed = await channel.listDirectory(path);
      if (_disposed ||
          generation != _issuedGeneration ||
          !identical(channel, _channel)) {
        return;
      }
      _entries = _visibleSorted(listed);
      _answeredGeneration = generation;
      _error = null;
      _cursorIndex = null;
      notifyListeners();
    } on RemoteFileException catch (error) {
      if (_disposed ||
          generation != _issuedGeneration ||
          !identical(channel, _channel)) {
        return;
      }
      _answeredGeneration = generation;
      _error = error;
      notifyListeners();
    } on Object catch (error, stackTrace) {
      if (_disposed ||
          generation != _issuedGeneration ||
          !identical(channel, _channel)) {
        return;
      }
      _report(error, stackTrace);
      _answeredGeneration = generation;
      _error = RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: 'list',
        message: 'The folder could not be listed.',
      );
      notifyListeners();
    }
  }

  /// Closes the pane's current channel and drops the watch — a rebind
  /// must not leave the previous binding's engine-side session alive.
  /// The channel close is the per-pane teardown the pool keys on (03
  /// §3.2); sibling panes on the same server keep theirs.
  Future<void> _releaseBinding() async {
    final channel = _channel;
    _channel = null;
    unawaited(_statusWatch?.cancel());
    _statusWatch = null;
    if (channel != null) {
      try {
        await channel.close();
      } on Object catch (error, stackTrace) {
        _report(error, stackTrace);
      }
    }
  }

  Future<void> _closeChannel(AppBrowseChannel channel) async {
    try {
      await channel.close();
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace);
    }
  }

  /// The visible listing order: directories first, then case-insensitive
  /// name with a case-sensitive tiebreak — the §2.3 natural comparator's
  /// placeholder (digit-run comparison lands in `poltergeist_core` with
  /// its slice). Dotfiles are hidden by default (02 §2.5; the toggle and
  /// the §2.4 precedence chain land with the view-options slice).
  List<RemoteFileEntry> _visibleSorted(List<RemoteFileEntry> listed) {
    final visible = listed
        .where((entry) => !entry.name.startsWith('.'))
        .toList(growable: false)
      ..sort(_compareEntries);
    return List.unmodifiable(visible);
  }

  int _compareEntries(RemoteFileEntry a, RemoteFileEntry b) {
    if (a.isDirectory != b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    final fold = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (fold != 0) return fold;
    return a.name.compareTo(b.name);
  }

  void _report(Object error, StackTrace stackTrace) {
    final sink = _onError;
    if (sink != null) {
      sink(error, stackTrace);
    } else {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stackTrace),
      );
    }
  }
}
