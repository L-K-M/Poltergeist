import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'engine_session.dart';
import 'pane_engine_lanes.dart';
import 'pane_location.dart';
import 'selection_state.dart';

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

enum _RecoveryPhase { none, waiting, listing, failed, reopening }

enum _BindingPresentation { replace, retainCache }

// Connection loss is rendered by the localized banner, not a raw diagnostic.
const _connectionLostError = RemoteFileException(
  kind: RemoteFileErrorKind.disconnected,
  operation: 'reconnect',
  message: '',
);

/// The last quiescent state, captured on every not-loading → loading
/// transition (02 §2.8): Esc-cancel restores exactly this, never a
/// transient mid-navigation state. The selection is immutable, so the
/// snapshot shares it without copying.
class _QuiescentSnapshot {
  const _QuiescentSnapshot(
    this.location,
    this.entries,
    this.error,
    this.selection,
  );

  final PaneLocation? location;
  final List<RemoteFileEntry> entries;
  final RemoteFileException? error;
  final SelectionState<_RowKey> selection;
}

/// Stable identity of one visible row within a listing: the entry's
/// full path plus an occurrence ordinal. Paths are unique per row in
/// every listing the engine can produce EXCEPT decoded-name collisions
/// (two raw byte names decoding to the same string share a path
/// string); the ordinal keeps every such row a distinct identity
/// without inventing a name heuristic (raw-byte disambiguation stays
/// open with STATUS item 13 — two colliding rows may swap ordinals
/// across a reorder until it lands).
@immutable
class _RowKey {
  const _RowKey(this.path, this.occurrence);

  final String path;
  final int occurrence;

  @override
  bool operator ==(Object other) =>
      other is _RowKey && other.path == path && other.occurrence == occurrence;

  @override
  int get hashCode => Object.hash(path, occurrence);
}

/// Which app-side operation failed for a non-VFS fault: the pane view
/// maps this to an ARB-authored diagnostic line (D20 — the controller
/// never authors user copy).
enum PaneFault { connectionOpen, localOpen, listFolder }

/// A non-VFS fault surfacing on the pane: the taxonomy message is a
/// machine sentinel (never rendered); [fault] carries the renderable
/// identity for the view's localized diagnostic line.
class PaneFaultException extends RemoteFileException {
  PaneFaultException(this.fault, {required super.operation})
    : super(kind: RemoteFileErrorKind.other, message: 'fault:${fault.name}');

  final PaneFault fault;
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
  _RecoveryPhase _recovery = _RecoveryPhase.none;
  Bookmark? _pendingRemote;
  bool _disposed = false;

  // Row identity and selection (02 §2.5): keys mirror [_entries] and the
  // immutable SelectionState owns cursor, anchor, and selected keys as
  // identities, so reorders and same-location refreshes keep surviving
  // rows selected and never re-target a moved index.
  List<_RowKey> _rowKeys = const [];
  Map<_RowKey, int> _rowKeyIndex = const {};
  SelectionState<_RowKey> _selection = SelectionState<_RowKey>.begin(
    rows: const [],
  );

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
      !connectionLost &&
      !loading;

  /// The remote binding's live connection truth (current value first from
  /// the engine's watch); null for local panes and unbound panes.
  ServerStatus? get connectionStatus => _connectionStatus;

  /// Transport recovery starts the banner; only a healed listing ends it.
  /// The engine can report connected while this pane's binding still fails.
  bool get connectionLost => _recovery != _RecoveryPhase.none;

  /// A failed healed listing needs an explicit reopen, not a dead-lane relist.
  bool get canRetryRecovery => _recovery == _RecoveryPhase.failed;

  /// The bookmark whose remote binding is live or connecting; the retry
  /// after a failed connect reuses it.
  Bookmark? get remoteBookmark => _pendingRemote;

  /// The keyboard cursor row into [entries]; null until the first key
  /// press or row tap. Derived from the selection state's cursor
  /// identity, so the observable cursor API keeps its contract while
  /// the cursor stays an identity that row replacement can prune.
  int? get cursorIndex => _rowKeyIndex[_selection.cursorKey];

  /// How many visible rows are selected.
  int get selectedCount => _selection.selectedKeys.length;

  /// Whether the visible row at [index] is selected.
  bool isRowSelected(int index) =>
      index >= 0 &&
      index < _rowKeys.length &&
      _selection.selectedKeys.contains(_rowKeys[index]);

  /// Binds the pane to a remote bookmark: closes any previous channel,
  /// subscribes to the server's state lane BEFORE connecting (live
  /// streams keep no replay, 03 §5), opens the browse channel, and
  /// navigates to the bookmark's path ('/' meaning the canonical home).
  /// Binds the pane to a remote bookmark: closes any previous channel,
  /// subscribes to the server's state lane BEFORE connecting (live
  /// streams keep no replay, 03 §5), opens the browse channel, and
  /// navigates to the bookmark's path ('/' meaning the canonical home).
  /// [initialPath] overrides the landing directory — retry after a
  /// severed transport uses it to return the user where they were.
  /// The intended landing directory for the pending remote bind: set
  /// by every remote bind, consumed on the first SUCCESSFUL navigation,
  /// and cleared on unbind — so a reconnect that fails and is retried
  /// still returns the user where they were, not the bookmark root.
  String? _pendingRemotePath;

  Future<void> connectRemote(Bookmark bookmark, {String? initialPath}) =>
      _connectRemote(bookmark, initialPath: initialPath);

  Future<void> _connectRemote(
    Bookmark bookmark, {
    String? initialPath,
    _BindingPresentation presentation = _BindingPresentation.replace,
  }) async {
    if (_disposed || _lanes == null) return;

    // Preserve retries, but never carry one bookmark's path into another.
    if (bookmark.id != _pendingRemote?.id) _pendingRemotePath = null;
    _pendingRemote = bookmark;
    _pendingRemotePath = initialPath ?? _pendingRemotePath;
    await _bind(
      connectingPhase: PanePhase.connectingRemote,
      operation: 'connect',
      fault: PaneFault.connectionOpen,
      presentation: presentation,
      connect: (lanes, attempt) async {
        // Subscribe before connecting: a connect that raises state (or
        // a prompt the coordinator answers) must find this pane
        // listening.
        _statusWatch = lanes
            .watchServer(bookmark.id)
            .listen(
              (status) {
                if (_disposed || attempt != _bindAttempt) return;
                _acceptStatus(status);
              },
              onError: (Object error, StackTrace stackTrace) {
                if (_disposed || attempt != _bindAttempt) return;
                _report(error, stackTrace);
                // A dead status lane must not leave the banner pinned on
                // its last state (a 'reconnecting' that never resolves);
                // if the stream survives the error, the next event
                // restores the truth.
                _connectionStatus = null;
                _endRecoveryWatch();
                notifyListeners();
              },
              onDone: () {
                if (_disposed || attempt != _bindAttempt) return;
                // A lane that closes cleanly must not pin the banner
                // on its last state either (same rule as a dead lane).
                _connectionStatus = null;
                _endRecoveryWatch();
                notifyListeners();
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

        final remotePath =
            initialPath ?? _pendingRemotePath ?? bookmark.remotePath;
        final target = remotePath == null || remotePath == '/'
            ? channel.homePath
            : remotePath;
        final location = RemotePaneLocation(bookmark.id, target);
        if (_recovery == _RecoveryPhase.waiting &&
            _connectionStatus?.state != ServerConnectionState.connected) {
          _location = location;
          notifyListeners();
          return;
        }
        if (connectionLost) _recovery = _RecoveryPhase.listing;
        _issueNavigation(location, target, channel);
        // The landing directory is consumed by the bind that used it.
        _pendingRemotePath = null;
      },
    );
  }

  /// Navigates to [path] on the live channel (path bar, entries,
  /// refresh). The target's kind comes from the BINDING, not the last
  /// location: a cancelled first listing leaves the location null while
  /// the channel stays live, and a null location on a remote pane must
  /// never mint a local one.
  void navigate(String path) {
    if (_disposed || _channel == null || connectionLost) return;
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
  /// restores the last quiescent snapshot, including its error and
  /// selection.
  void cancelNavigation() {
    if (_disposed || connectionLost || !_loadingActive()) return;

    final snapshot = _snapshot;
    _location = snapshot?.location;
    _error = snapshot?.error;
    _selection =
        snapshot?.selection ?? SelectionState<_RowKey>.begin(rows: const []);
    _applyEntries(snapshot?.entries ?? const []);
    _issuedGeneration++;
    _answeredGeneration = _issuedGeneration;
    _snapshot = null;
    notifyListeners();
  }

  /// Retries whatever failed: a failed connect reopens the channel, a
  /// failed first local open retries it, and a listing error re-issues
  /// the navigation — except when the listing failed because the
  /// transport is gone (typed `disconnected` on a remote binding):
  /// refreshing the dead channel would loop forever, so the bind
  /// reopens and lands on the directory the user was in.
  Future<void> retry() async {
    if (_disposed) return;
    if (connectionLost) {
      final bookmark = _pendingRemote;
      if (!canRetryRecovery || bookmark == null) return;
      await _connectRemote(
        bookmark,
        initialPath: _location?.path ?? _pendingRemotePath,
        presentation: _BindingPresentation.retainCache,
      );
      return;
    }
    if (_phase == PanePhase.connectingRemote && _error != null) {
      final bookmark = _pendingRemote;
      if (bookmark != null) {
        await connectRemote(bookmark, initialPath: _pendingRemotePath);
        return;
      }
    }
    if (_phase == PanePhase.openingLocal && _error != null) {
      await openLocalHome();
      return;
    }
    final current = _location;
    if (current != null && _error != null) {
      final bookmark = _pendingRemote;
      if (bookmark != null &&
          current is RemotePaneLocation &&
          _error!.kind == RemoteFileErrorKind.disconnected) {
        await connectRemote(bookmark, initialPath: current.path);
        return;
      }
      refresh();
    }
  }

  /// Moves the cursor by [delta], clamped to the listing. An unset
  /// cursor seeds from the list's far end (first Down selects the first
  /// row, first Up the last — the Finder convention). [update] selects
  /// the gesture: plain movement single-selects the target row, a range
  /// update extends the anchored selection to it (02 §2.5).
  void moveCursorBy(
    int delta, {
    SelectionUpdate update = SelectionUpdate.single,
  }) {
    if (_entries.isEmpty) return;
    final seed = delta > 0 ? -1 : _entries.length;
    final next = (cursorIndex ?? seed) + delta;
    setCursorIndex(next.clamp(0, _entries.length - 1), update: update);
  }

  /// Sets the cursor to [index] (a row tap or a direct jump), clamped,
  /// applying [update] to the selection (plain taps single-select).
  void setCursorIndex(
    int index, {
    SelectionUpdate update = SelectionUpdate.single,
  }) {
    if (_disposed || _entries.isEmpty) return;
    // Internal invariant: row identity mirrors the accepted listing.
    // A future listing mutation that bypasses _applyEntries must fail
    // loudly here, not activate the wrong row.
    assert(
      _rowKeys.length == _entries.length,
      'row keys out of sync with entries',
    );
    final clamped = index.clamp(0, _entries.length - 1);
    final before = _selection;
    _selection = _selection.activate(_rowKeys[clamped], update);
    if (identical(before, _selection)) return;
    notifyListeners();
  }

  /// `edit.selectAll` (02 §2.5): selects every visible row; the cursor
  /// and anchor keep their positions.
  void selectAll() {
    if (_disposed || _entries.isEmpty) return;
    final before = _selection;
    _selection = _selection.selectAll();
    if (identical(before, _selection)) return;
    notifyListeners();
  }

  /// `edit.invertSelection` (02 §2.5): replaces the selection with its
  /// complement among the visible rows; cursor and anchor keep their
  /// positions.
  void invertSelection() {
    if (_disposed || _entries.isEmpty) return;
    final before = _selection;
    _selection = _selection.invert();
    if (identical(before, _selection)) return;
    notifyListeners();
  }

  /// Detaches the pane and drops its server reference (02 §2.7's Cancel).
  /// Recovery stops; pending healing cannot restore the cancelled binding.
  ///
  /// The engine keys pool references by serverId, so this severs every
  /// pane bound to the same server — the shell routes the banner's cancel
  /// through [detachRemote] when a sibling still browses the server.
  /// Keyed on the pending binding, not the location: the post-first-cancel
  /// state keeps a live remote channel with no location, and its unbind
  /// must not dead-end.
  ///
  /// [serverStillUnshared] re-checks that solitude AFTER the detach's
  /// awaited channel release: a sibling pane may bind the same server
  /// while that release is in flight, and dropping the reference then
  /// would sever the sibling's fresh binding (the engine removes
  /// whatever reference is current for the id). The controller owns no
  /// sibling knowledge — the shell supplies the late re-check.
  Future<void> cancelRecovery({bool Function()? serverStillUnshared}) async {
    final lanes = _lanes;
    final serverId = _pendingRemote?.id;
    if (_disposed || lanes == null || serverId == null) return;
    // Cancel invalidates pending healing as well as pending opens. Close
    // this pane before dropping the reference; newer same-id binds own it.
    final detachedAttempt = _bindAttempt + 1;
    await detachRemote();
    if (_disposed || _bindAttempt != detachedAttempt) return;
    if (serverStillUnshared != null && !serverStillUnshared()) return;
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
    _applyEntries(const []);
    _error = null;
    _snapshot = null;
    _connectionStatus = null;
    _recovery = _RecoveryPhase.none;
    _pendingRemote = null;
    _pendingRemotePath = null;
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
    required PaneFault fault,
    _BindingPresentation presentation = _BindingPresentation.replace,
    required Future<void> Function(PaneEngineLanes lanes, int attempt) connect,
  }) async {
    final lanes = _lanes;
    if (_disposed || lanes == null) return;

    final attempt = ++_bindAttempt;
    _phase = connectingPhase;
    _beginBinding(presentation);
    notifyListeners();

    await _releaseBinding();
    if (_disposed || attempt != _bindAttempt) return;

    try {
      await connect(lanes, attempt);
    } on RemoteFileException catch (error) {
      if (_disposed || attempt != _bindAttempt) return;
      _dropStatusWatch();
      if (presentation == _BindingPresentation.retainCache) {
        _recovery = _RecoveryPhase.failed;
      }
      _error = error;
      notifyListeners();
    } on Object catch (error, stackTrace) {
      if (_disposed || attempt != _bindAttempt) return;
      _report(error, stackTrace);
      _dropStatusWatch();
      if (presentation == _BindingPresentation.retainCache) {
        _recovery = _RecoveryPhase.failed;
      }
      _error = PaneFaultException(fault, operation: operation);
      notifyListeners();
    }
  }

  /// A failed bind keeps no server watch: the subscription is inert
  /// (the attempt guard drops its events) but it pins the engine's
  /// per-server stream open until the next bind replaces it — and the
  /// last observed status (e.g. a `reconnecting` that will never update
  /// again) must not keep the connection-lost banner alive over the
  /// terminal error surface.
  void _dropStatusWatch() {
    unawaited(_statusWatch?.cancel());
    _statusWatch = null;
    _connectionStatus = null;
    _recovery = _RecoveryPhase.none;
  }

  void _endRecoveryWatch() {
    if (!connectionLost) return;
    _cancelListing();
    _error ??= _connectionLostError;
    // EOF/error cannot prove healing; offer Retry rather than endless waiting.
    _recovery = _RecoveryPhase.failed;
  }

  void _acceptStatus(ServerStatus status) {
    _connectionStatus = status;
    if (status.state == ServerConnectionState.reconnecting) {
      // Old transport answers must not clear loss or replace cached rows.
      _cancelListing();
      _snapshot = null;
      _error = _connectionLostError;
      if (_recovery != _RecoveryPhase.reopening) {
        _recovery = _RecoveryPhase.waiting;
      }
    } else if (status.state == ServerConnectionState.connected &&
        _recovery == _RecoveryPhase.waiting) {
      final channel = _channel;
      final bookmark = _pendingRemote;
      if (channel != null && bookmark != null) {
        // Cancelling the first listing leaves no location but keeps the lane.
        final location =
            _location ?? RemotePaneLocation(bookmark.id, channel.homePath);
        // The engine rebinds healthy PaneChannels before emitting connected.
        // Listing proves this particular binding healed; pool state cannot.
        _recovery = _RecoveryPhase.listing;
        _issueNavigation(location, location.path, channel);
      }
    } else if (connectionLost &&
        (status.state == ServerConnectionState.disconnected ||
            status.state == ServerConnectionState.blocked) &&
        _recovery != _RecoveryPhase.reopening) {
      _cancelListing();
      _error = _connectionLostError;
      _recovery = _RecoveryPhase.failed;
    }
    notifyListeners();
  }

  bool _loadingActive() =>
      _issuedGeneration > _answeredGeneration && _error == null;

  /// A new location starts fresh; recovery retains the cached presentation.
  /// Both invalidate every old answer before releasing the prior channel.
  void _beginBinding(_BindingPresentation presentation) {
    _cancelListing();
    if (presentation == _BindingPresentation.replace) {
      _location = null;
      _applyEntries(const []);
      _error = null;
      _recovery = _RecoveryPhase.none;
    } else {
      _recovery = _RecoveryPhase.reopening;
    }
    _snapshot = null;
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
    _pendingRemotePath = null;
    await _bind(
      connectingPhase: PanePhase.openingLocal,
      operation: 'open',
      fault: PaneFault.localOpen,
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
  /// listing against the captured channel. An actual location change
  /// resets the selection; a same-location refresh (or a recovery
  /// re-list) keeps every identity, pruned when the new listing is
  /// accepted.
  void _issueNavigation(
    PaneLocation target,
    String path,
    AppBrowseChannel channel,
  ) {
    if (!_loadingActive()) {
      _snapshot = _QuiescentSnapshot(_location, _entries, _error, _selection);
    }
    if (_location != target) {
      // The old entries stay visible (dimmed) during the load, but the
      // selection belongs to the old listing — the cursor convention.
      _selection = SelectionState<_RowKey>.begin(rows: const []);
    }
    _location = target;
    _issuedGeneration++;
    _error = null;
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
      _applyEntries(_visibleSorted(listed));
      _recovery = _RecoveryPhase.none;
      _answeredGeneration = generation;
      _error = null;
      notifyListeners();
    } on RemoteFileException catch (error) {
      if (_disposed ||
          generation != _issuedGeneration ||
          !identical(channel, _channel)) {
        return;
      }
      _answeredGeneration = generation;
      if (connectionLost) _recovery = _RecoveryPhase.failed;
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
      if (connectionLost) _recovery = _RecoveryPhase.failed;
      _error = PaneFaultException(PaneFault.listFolder, operation: 'list');
      notifyListeners();
    }
  }

  /// Adopts [entries] as the pane's accepted listing and prunes the
  /// selection against the new row identities (02 §2.5): surviving keys
  /// keep their selection, cursor, and anchor; missing keys drop out
  /// instead of re-targeting a moved index.
  void _applyEntries(List<RemoteFileEntry> entries) {
    _entries = entries;
    _rowKeys = List.unmodifiable(_keysFor(entries));
    _rowKeyIndex = {for (var i = 0; i < _rowKeys.length; i++) _rowKeys[i]: i};
    _selection = _selection.withRows(_rowKeys);
  }

  static Iterable<_RowKey> _keysFor(List<RemoteFileEntry> entries) sync* {
    final occurrences = <String, int>{};
    for (final entry in entries) {
      final occurrence = occurrences.update(
        entry.path,
        (count) => count + 1,
        ifAbsent: () => 0,
      );
      yield _RowKey(entry.path, occurrence);
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

  /// The visible listing: dotfiles are hidden by default (02 §2.5; the
  /// toggle and the §2.4 precedence chain land with the view-options
  /// slice), then the §2.3 core comparator orders the snapshot — default
  /// name key, ascending, directories first, with natural digit runs and
  /// Unicode simple folding. `sortFileEntries` returns an unmodifiable
  /// copy over new row order, so the VFS-returned list is never mutated.
  List<RemoteFileEntry> _visibleSorted(List<RemoteFileEntry> listed) {
    final visible = listed
        .where((entry) => !entry.name.startsWith('.'))
        .toList(growable: false);
    return sortFileEntries(visible);
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
