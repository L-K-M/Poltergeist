import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'engine_session.dart';
import 'listing_filter.dart';
import 'pane_engine_lanes.dart';
import 'pane_location.dart';
import 'pane_path_input.dart';
import 'quick_select_state.dart';
import 'selection_state.dart';
import 'unicode_diacritic_fold.dart';
import 'view_preferences.dart';

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
/// snapshot shares it without copying. [listing] is the full accepted
/// listing (pre-hidden-policy, pre-filter): the filter and the hidden
/// override are lenses on whatever listing is current, so the restore
/// re-applies the lenses that are active NOW.
class _QuiescentSnapshot {
  const _QuiescentSnapshot(
    this.location,
    this.listing,
    this.error,
    this.selection,
  );

  final PaneLocation? location;
  final List<RemoteFileEntry> listing;
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
enum PaneFault {
  connectionOpen,
  localOpen,
  listFolder,

  /// The path field's submission has no navigable shape under this
  /// pane's location model (02 §2.1) — rejected client-side, so no
  /// listing was ever requested.
  invalidPath,
}

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

  /// The accepted listing after the §2.3 sort, BEFORE the hidden-file
  /// policy — the tab-local [showHidden] override re-derives the visible
  /// listing from this without a re-list, and the quiescent snapshot
  /// shares it so a cancelled navigation restores the pre-policy listing
  /// too (the policy then re-applies on restore).
  List<RemoteFileEntry> _sortedListing = const [];

  /// [_sortedListing] after the hidden-file policy, BEFORE the §2.5
  /// name filter — [_entries] is this list seen through the active
  /// filter. Keeping the pre-filter listing is what lets clearing or
  /// widening a query re-show rows without a re-list.
  /// Written only through [_setListing], which rebuilds the lowercased
  /// basename cache in lockstep.
  List<RemoteFileEntry> _listing = const [];

  /// Lowercased basenames parallel to [_listing] — the §2.5 filter scans
  /// cached strings instead of re-lowercasing every name per keystroke,
  /// the same per-keystroke allocation rationale as [_foldedNames].
  /// Plain `toLowerCase`, NOT `typeAheadFold` (no diacritic stripping).
  List<String> _loweredNames = const [];
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

  /// The open Quick Select session (02 §2.5); null while the field is
  /// closed. The pane owns the field's visibility and its invalidation:
  /// every listing/selection replacement ends the session before the new
  /// rows prune the restored baseline — a stale session never restores
  /// into a listing it did not open on.
  QuickSelectState<_RowKey>? _quickSelect;

  /// 02 §2.5's type-ahead buffer: printable keys accumulate over the
  /// focused pane and 1 s of inactivity resets it. The pane view's key
  /// dispatch owns the printable/Space filter and the field-focus
  /// suppression; the controller owns the buffer, its reset timer, and
  /// the prefix jump.
  String _typeAheadBuffer = '';
  Timer? _typeAheadReset;

  /// 02 §2.5's Filter (`view.filter`): a case-insensitive substring lens
  /// over the current listing. Per-tab and transient BY CONSTRUCTION —
  /// it never reaches a persistence surface (not ViewPreferences, not §3
  /// workspace snapshots or session restore: a forgotten filter reads as
  /// data loss, which is why the plan forbids persisting it). The query
  /// survives navigation and refresh within the binding — §8.2's Esc
  /// order requires a filter to outlive an in-flight navigation — but a
  /// replaced binding or a detach drops it: a stale query silently
  /// hiding rows on a freshly connected server is the same data-loss
  /// read.
  String _filterQuery = '';

  /// Whether the filter strip is open for editing. The strip stays
  /// mounted while a query is active even after the field yields focus —
  /// its `12 of 348` helper text is the only surface showing the lens is
  /// on.
  bool _filterFieldOpen = false;

  /// Bumped by every `view.filter` invocation: the view re-focuses the
  /// field on a change, so ⌘F re-opens editing over a live filter
  /// instead of no-oping against the already-mounted strip.
  int _filterFocusGeneration = 0;

  /// The tab-local hidden-file override (02 §2.5's transient toggle):
  /// while false, dotfiles stay out of the visible listing. The §2.4
  /// precedence chain's persisted levels land with the view-options
  /// slice; this is the chain's per-tab slot, which ghost-tab reopen
  /// restores — it never persists (a forgotten hidden-file view reads
  /// as missing rows, the same data-loss argument as the filter).
  bool _showHidden = false;

  /// The tab's view mode slot in the §2.4 chain. The view-mode commands
  /// land with their own slice; tabs carry the field now so ghost-tab
  /// reopen restores it.
  PaneViewMode _viewMode = PaneViewMode.details;

  /// Whether this tab's inline-rename session is open — written by the
  /// row-interactions slice's rename flow; the tab close guard's
  /// inlineRename probe already reads it, so a rename can never be
  /// closed out from under the user once it exists.
  bool _inlineRenameActive = false;

  /// The tab's navigation trail (02 §2.1): every location the user
  /// navigated to, recorded at issue time — committed, in-flight, and
  /// erred entries alike — with [_historyIndex] naming the entry the
  /// pane stands on. Classic branch-truncation semantics: a new
  /// user-driven navigation drops every entry above the index; Back and
  /// Forward walk the index without recording. Per-tab and transient
  /// by construction — the trail lives on the per-tab controller and
  /// never reaches a persistence surface (ghost-tab reopen deliberately
  /// starts an empty trail, the same data-loss rule as the filter).
  final List<PaneLocation> _history = <PaneLocation>[];
  int _historyIndex = -1;

  /// 02 §2.1's path-field session (`go.editPath`/`go.toFolder`): the
  /// flag the view swaps the segment bar for the editable field on, the
  /// seed text of the current open, and the invocation counter — every
  /// open bumps it so the view re-seeds and re-focuses an already-open
  /// field instead of no-oping.
  bool _pathFieldOpen = false;
  String _pathFieldSeed = '';
  int _pathFieldGeneration = 0;

  /// Folded basenames per accepted listing, built once at apply time —
  /// type-ahead scans cached strings instead of re-folding every name
  /// per keystroke (a large listing would otherwise allocate O(rows)
  /// buffers per key). Null marks a flagged (U+FFFD) name excluded
  /// from matching.
  List<String?> _foldedNames = const [];

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
  /// hidden by default, and filtered by the active §2.5 filter — an
  /// unmodifiable copy written only when a listing is accepted, the
  /// filter changes, or Esc restores a snapshot.
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
    _sortedListing = snapshot?.listing ?? const [];
    _setListing(_hiddenFiltered(_sortedListing));
    _applyEntries(_filteredListing());
    // Reconcile the trail with the restored location: the index was
    // moved at issue time, so it names the just-cancelled target. The
    // restored location was recorded when the user navigated to it —
    // the nearest matching entry below the index (a cancelled push) or
    // above it (a cancelled traversal) becomes current. A cancelled
    // user navigation thereby survives as forward history: Esc then
    // Forward re-attempts it, like a browser's stop-then-forward.
    final restored = _location;
    if (restored != null && _history.isNotEmpty) {
      final origin = _historyIndex.clamp(0, _history.length - 1);
      for (var delta = 0; delta < _history.length; delta++) {
        final below = origin - delta;
        if (below >= 0 && _history[below] == restored) {
          _historyIndex = below;
          break;
        }
        final above = origin + delta;
        if (above != below &&
            above < _history.length &&
            _history[above] == restored) {
          _historyIndex = above;
          break;
        }
      }
    }
    _issuedGeneration++;
    _answeredGeneration = _issuedGeneration;
    _snapshot = null;
    notifyListeners();
  }

  /// Whether Back can walk the trail — false on the oldest entry and
  /// whenever no live channel could carry the navigation. Command
  /// enablement reads this, so Back greys at the start (02 §2.1).
  bool get canGoBack =>
      _channel != null && !connectionLost && _historyIndex > 0;

  /// Whether Forward can walk the trail — false on the newest entry.
  bool get canGoForward =>
      _channel != null &&
      !connectionLost &&
      _historyIndex < _history.length - 1;

  /// 02 §2.1's Back (Alt+Left / ⌘[): reissues the previous trail entry
  /// through the SAME navigation seam a typed path takes — generation
  /// bump, stale-answer drop, optimistic location — after walking the
  /// index so a later Forward still names where the user was heading.
  void goBack() {
    if (_disposed || !canGoBack) return;
    _historyIndex--;
    _issueNavigation(
      _history[_historyIndex],
      _history[_historyIndex].path,
      _channel!,
      historyTraversal: true,
    );
  }

  /// Forward (Alt+Right / ⌘]): [goBack]'s mirror.
  void goForward() {
    if (_disposed || !canGoForward) return;
    _historyIndex++;
    _issueNavigation(
      _history[_historyIndex],
      _history[_historyIndex].path,
      _channel!,
      historyTraversal: true,
    );
  }

  /// Whether the path field can open: a bound pane with a live channel.
  /// Unbound, mid-open, and connection-lost surfaces have no location
  /// model to edit against.
  bool get acceptsPathInput =>
      _phase == PanePhase.browsing && _channel != null && !connectionLost;

  /// Whether the path bar is swapped for its editable field (02 §2.1).
  bool get pathFieldOpen => _pathFieldOpen;

  /// The seed the field shows for the current open: the pane's location
  /// path for `go.editPath`, empty for `go.toFolder`.
  String get pathFieldSeed => _pathFieldSeed;

  /// The open-invocation counter: each `go.editPath`/`go.toFolder`
  /// bumps it, so the view re-seeds and re-focuses an already-open
  /// field instead of no-oping.
  int get pathFieldGeneration => _pathFieldGeneration;

  /// `go.editPath` (02 §2.1, ⌘L/Ctrl+L): swaps the path bar for the
  /// editable field seeded with the current location, selected whole.
  void editPath() => _openPathField(_location?.path ?? '');

  /// `go.toFolder` (⇧⌘G / Ctrl+Shift+G per §8.3): the same editor
  /// seeded empty — the path-only Go to Folder.
  void goToFolder() => _openPathField('');

  void _openPathField(String seed) {
    if (_disposed || !acceptsPathInput) return;
    // An open Quick Select session ends first: two text fields never
    // compete for the pane's keys (02 §8.2's field-first rule).
    _endQuickSelectSession();
    _pathFieldOpen = true;
    _pathFieldSeed = seed;
    _pathFieldGeneration++;
    notifyListeners();
  }

  /// Esc in the field — the highest Esc tier (02 §8.2): closes the
  /// editor, restores the segment bar, and navigates nothing.
  void closePathField() {
    if (_disposed || !_pathFieldOpen) return;
    _pathFieldOpen = false;
    notifyListeners();
  }

  /// Enter in the field: closes the editor and navigates the resolved
  /// target through the same seam every navigation takes — generation
  /// counter, stale-answer drop, and history record all apply
  /// unchanged. A blank submission just closes (there is nothing to
  /// navigate); an unresolvable shape surfaces the pane's inline error
  /// affordance (02 §2.1's no-dialog rule) — never an engine call for
  /// input that cannot name a location.
  void submitPathField(String raw) {
    if (_disposed || !_pathFieldOpen) return;
    _pathFieldOpen = false;
    final input = raw.trim();
    if (input.isEmpty) {
      notifyListeners();
      return;
    }
    final channel = _channel;
    final resolved = channel == null
        ? null
        : resolvePanePathInput(
            raw: input,
            remote: _pendingRemote != null,
            currentPath: _location?.path,
            homePath: channel.homePath,
          );
    if (resolved == null) {
      _error = PaneFaultException(PaneFault.invalidPath, operation: 'list');
      notifyListeners();
      return;
    }
    notifyListeners();
    navigate(resolved);
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
      await _openLocal(_pendingLocalRoot);
      return;
    }
    // A bound pane can hold an error with no committed location — the
    // path field's invalid-input fault, or a first listing that never
    // landed. Its channel is live, so retry opens the channel home
    // rather than dead-ending.
    if (_location == null && _error != null && _channel != null) {
      navigate(_channel!.homePath);
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

  /// Whether the Quick Select field is open (02 §2.5). The controller
  /// owns its visibility: the view renders the field on this flag, and
  /// every navigation or listing replacement ends the session first.
  bool get quickSelectActive => _quickSelect != null;

  /// The session's Add/Remove mode; [QuickSelectMode.add] while closed.
  QuickSelectMode get quickSelectMode =>
      _quickSelect?.mode ?? QuickSelectMode.add;

  /// The active filter's raw query (02 §2.5); empty while no filter
  /// applies. The field edits it live through [changeFilterQuery].
  String get filterQuery => _filterQuery;

  /// Whether a query currently prunes the visible listing — drives the
  /// strip's `visible of total` helper, the filtered-to-nothing empty
  /// state (02 §2.7), and the below-navigation Esc tier (02 §8.2).
  bool get filterActive => _filterQuery.isNotEmpty;

  /// Whether the filter strip is mounted for editing. The view also
  /// keeps it up while [filterActive] holds after the field yields
  /// focus — a hidden strip would leave the lens invisible.
  bool get filterFieldOpen => _filterFieldOpen;

  /// The `view.filter` focus-request counter: each invocation bumps it
  /// so the view re-focuses the field even when the strip is already
  /// mounted.
  int get filterFocusGeneration => _filterFocusGeneration;

  /// The tab-local hidden-file override (02 §2.5's transient toggle);
  /// the view slice's keyboard command writes it. Toggling re-derives
  /// the visible listing from the pre-policy one and re-applies the
  /// active filter — the same path a fresh listing accept takes, so
  /// selection pruning and Quick Select invalidation behave identically.
  bool get showHidden => _showHidden;

  set showHidden(bool value) {
    if (_disposed || value == _showHidden) return;
    _showHidden = value;
    _setListing(_hiddenFiltered(_sortedListing));
    _applyEntries(_filteredListing());
    notifyListeners();
  }

  /// The tab's view mode (02 §2.4's tab-local slot); the view-mode
  /// commands write it when their slice lands.
  PaneViewMode get viewMode => _viewMode;

  set viewMode(PaneViewMode value) {
    if (_disposed || value == _viewMode) return;
    _viewMode = value;
    notifyListeners();
  }

  /// Whether an inline rename is open on this tab — the tab close
  /// guard's trigger probe; the row-interactions slice owns the session.
  bool get inlineRenameActive => _inlineRenameActive;

  set inlineRenameActive(bool value) {
    if (_disposed || value == _inlineRenameActive) return;
    _inlineRenameActive = value;
    notifyListeners();
  }

  /// Restores the transient per-tab lenses a closed tab's ghost captured
  /// (02 §3's ⇧⌘T): filter, hidden override, view mode. Deliberately
  /// bypasses [changeFilterQuery]'s field-open gate — the ghost replays
  /// the state it froze, not the keystrokes that produced it.
  void restoreTransientState({
    // All four lenses are required: a partial restore must fail at
    // compile time rather than silently wiping the lenses it omitted.
    required String filterQuery,
    required bool filterFieldOpen,
    required bool showHidden,
    required PaneViewMode viewMode,
  }) {
    if (_disposed) return;
    _filterQuery = filterQuery;
    _filterFieldOpen = filterFieldOpen;
    _showHidden = showHidden;
    _viewMode = viewMode;
    _setListing(_hiddenFiltered(_sortedListing));
    _applyEntries(_filteredListing());
    notifyListeners();
  }

  /// The pre-filter listing size — the "of N" half of the strip's
  /// `12 of 348` helper ([entries] carries the visible half).
  int get unfilteredCount => _listing.length;

  /// `view.filter` (02 §2.5, ⌘F/Ctrl+F): opens the filter strip over the
  /// current listing and asks the view to focus its field — including
  /// re-invocations over an already-open strip, which bump the focus
  /// generation instead of no-oping.
  void openFilter() {
    if (_disposed || !verbsEnabled) return;
    // One text surface at a time (02 §8.2's field-first rule): an open
    // path field yields to the filter field taking focus.
    _pathFieldOpen = false;
    _filterFieldOpen = true;
    _filterFocusGeneration++;
    notifyListeners();
  }

  /// The field's live query: every change re-filters the accepted
  /// listing in place (02 §2.5). A replacement listing of rows ends any
  /// open Quick Select session BEFORE the restored baseline prunes
  /// against the filtered rows — the same invalidation seam a navigation
  /// or refresh uses (02 §2.5); a pending type-ahead buffer drops with
  /// the rows it matched.
  void changeFilterQuery(String query) {
    if (_disposed || !_filterFieldOpen || query == _filterQuery) return;
    _filterQuery = query;
    _applyEntries(_filteredListing());
    notifyListeners();
  }

  /// Clears the query AND closes the strip — the field tier's Esc while
  /// the field is focused, the below-navigation tier's Esc once the
  /// filter outlives focus, and the strip's Clear affordance all land
  /// here (02 §8.2's two slots are the same "filter off" act).
  void clearFilter() {
    if (_disposed || (!_filterFieldOpen && _filterQuery.isEmpty)) return;
    _filterFieldOpen = false;
    if (_filterQuery.isNotEmpty) {
      _filterQuery = '';
      _applyEntries(_filteredListing());
    }
    notifyListeners();
  }

  /// 02 §2.5's accumulated type-ahead buffer — the transient badge's
  /// content while typing. Empty while inactive.
  String get typeAheadBuffer => _typeAheadBuffer;

  /// Whether a type-ahead buffer is pending (drives the badge and the
  /// buffer-clearing Esc tier, 02 §8.2).
  bool get typeAheadActive => _typeAheadBuffer.isNotEmpty;

  /// Accumulates one printable character into the buffer and jumps the
  /// cursor to the first row whose decoded basename matches the buffer
  /// as a case- and diacritic-insensitive prefix (02 §2.5); the pane
  /// view scrolls it visible. No match leaves the cursor where it is —
  /// the plan is silent on no-match, so the no-op is the tested
  /// behavior. The matcher is deliberately NOT Quick Select's: that one
  /// applies §2.3's simple case fold with no diacritic stripping, while
  /// type-ahead strips marks — two specified semantics, two matchers.
  ///
  /// Flagged names (02 §13) are excluded from matching only — they stay
  /// selectable through cursor/click paths; the caller-side U+FFFD
  /// stand-in mirrors openQuickSelect until STATUS item 13 lands real
  /// flag metadata. Hidden files never reach the matcher: the hidden
  /// policy already ran when the listing was accepted.
  void typeAhead(String character) {
    if (_disposed || _entries.isEmpty || character.isEmpty) return;
    _typeAheadBuffer += character;
    _armTypeAheadReset();
    final prefix = typeAheadFold(_typeAheadBuffer);
    // A buffer of combining marks alone (a lone dead-key press) folds
    // to the empty string and every name startsWith('') — keep the
    // badge, skip the jump.
    if (prefix.isNotEmpty) {
      for (var i = 0; i < _foldedNames.length; i++) {
        final folded = _foldedNames[i];
        if (folded != null && folded.startsWith(prefix)) {
          setCursorIndex(i);
          break;
        }
      }
    }
    notifyListeners();
  }

  /// Clears a pending buffer — the §8.2 Esc tier below navigation-cancel
  /// and above deselect, and the timer's expiry path.
  void clearTypeAhead() {
    _typeAheadReset?.cancel();
    _typeAheadReset = null;
    if (_typeAheadBuffer.isEmpty) return;
    _typeAheadBuffer = '';
    notifyListeners();
  }

  /// 1 s of inactivity resets the buffer (02 §2.5); every keystroke
  /// re-arms.
  void _armTypeAheadReset() {
    _typeAheadReset?.cancel();
    _typeAheadReset = Timer(const Duration(seconds: 1), () {
      _typeAheadReset = null;
      if (_disposed) return;
      clearTypeAhead();
    });
  }

  /// `selection.quickSelect` (02 §2.5, ⌘E/Ctrl+E): opens the field over
  /// the CURRENT listing — the hidden-policy filter already ran when the
  /// entries were accepted, so only visible rows reach the matcher.
  /// Flagged names (02 §13) are ineligible for by-name matching: until
  /// STATUS item 13 lands real flag metadata, a decoded name carrying
  /// U+FFFD is the caller-side signal — excluding it covers the flagged
  /// row AND the ambiguous valid-name collision §13 describes. Excluded
  /// rows still survive in the baseline selection under both modes.
  void openQuickSelect() {
    if (_disposed || !verbsEnabled || _quickSelect != null) return;
    // Same one-field rule: an open path field yields to Quick Select.
    _pathFieldOpen = false;
    final names = <_RowKey, String>{};
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (entry.name.contains('\uFFFD')) continue;
      names[_rowKeys[i]] = entry.name;
    }
    _quickSelect = QuickSelectState<_RowKey>.begin(
      namesByKey: names,
      selectedKeys: _selection.selectedKeys,
    );
    notifyListeners();
  }

  /// The field's live query: every change recomputes the preview from the
  /// selection captured when the field opened, so narrowing undoes
  /// earlier previews (02 §2.5).
  void changeQuickSelectQuery(String query) {
    _updateQuickSelect((session) => session.changeQuery(query));
  }

  /// The segmented Add/Remove toggle; recomputes from the baseline too.
  void changeQuickSelectMode(QuickSelectMode mode) {
    _updateQuickSelect((session) => session.changeMode(mode));
  }

  /// Enter: keeps the preview as the selection and closes the field.
  void confirmQuickSelect() {
    final session = _quickSelect;
    if (_disposed || session == null) return;
    _quickSelect = null;
    _selection = _selection.withSelectedKeys(
      session.confirm().selectedKeys,
    );
    notifyListeners();
  }

  /// Esc: restores the selection captured when the field opened and
  /// closes it.
  void cancelQuickSelect() {
    if (_disposed || _quickSelect == null) return;
    _endQuickSelectSession();
    notifyListeners();
  }

  void _updateQuickSelect(
    QuickSelectState<_RowKey> Function(QuickSelectState<_RowKey>) change,
  ) {
    final session = _quickSelect;
    if (_disposed || session == null) return;
    final next = change(session);
    if (identical(next, session)) return;
    _quickSelect = next;
    _selection = _selection.withSelectedKeys(next.selectedKeys);
    notifyListeners();
  }

  /// Ends an open session with Esc semantics: the opening selection is
  /// restored against the rows it was captured on, THEN the caller's row
  /// replacement prunes it — never a restore into a new listing (02 §2.5).
  void _endQuickSelectSession() {
    final session = _quickSelect;
    if (session == null) return;
    _quickSelect = null;
    _selection = _selection.withSelectedKeys(session.cancel().selectedKeys);
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
  ///
  /// Omitting [serverStillUnshared] drops the server reference
  /// unconditionally — safe only where no sibling pane can bind the
  /// same server during the detach await.
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
    _history.clear();
    _historyIndex = -1;
    _pathFieldOpen = false;
    _sortedListing = const [];
    // The transient lenses die with the session like the listing and
    // filter do — an unbound pane shows hidden files and a non-default
    // view mode only while the browsing session that set them lives.
    _showHidden = false;
    _viewMode = PaneViewMode.details;
    _setListing(const []);
    _filterQuery = '';
    _filterFieldOpen = false;
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
    _quickSelect = null;
    _typeAheadReset?.cancel();
    _typeAheadReset = null;
    _typeAheadBuffer = '';
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
      // The trail and any open path edit are scoped to the binding —
      // a new binding starts a fresh trail.
      _history.clear();
      _historyIndex = -1;
      _pathFieldOpen = false;
      _sortedListing = const [];
      // A replaced binding drops the transient lenses with its listing —
      // the filter, the hidden override, and the view mode are all
      // scoped to the browsing session they were set in (02 §2.5).
      _showHidden = false;
      _viewMode = PaneViewMode.details;
      _setListing(const []);
      _filterQuery = '';
      _filterFieldOpen = false;
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

  /// The root the in-flight or last-failed local open targeted — [retry]
  /// re-opens THAT root, never silently '~' over a failed openLocalAt.
  String _pendingLocalRoot = '~';

  /// Opens a local channel rooted at the user's home and browses it.
  Future<void> openLocalHome() => _openLocal('~');

  /// Opens a local channel rooted at [path] and browses it — the root is
  /// the channel's initial home, not a sandbox (the engine canonicalizes
  /// it, 03 §2.2); `tab.new`'s Duplicate and Home targets land here.
  Future<void> openLocalAt(String path) => _openLocal(path);

  Future<void> _openLocal(String rootPath) async {
    _pendingRemote = null;
    _pendingRemotePath = null;
    _pendingLocalRoot = rootPath;
    await _bind(
      connectingPhase: PanePhase.openingLocal,
      operation: 'open',
      fault: PaneFault.localOpen,
      connect: (lanes, attempt) async {
        // '~' expands to the user's home inside the engine (03 §2.2);
        // the channel answers the canonicalized home path.
        final channel = await lanes.openLocalChannel(rootPath: rootPath);
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
    AppBrowseChannel channel, {
    bool historyTraversal = false,
  }) {
    // Quick Select ends BEFORE the navigation snapshot and the selection
    // reset: the restored baseline is what a later Esc-cancel restores,
    // and the new listing prunes it (02 §2.5).
    _endQuickSelectSession();
    if (!historyTraversal && target != _location) {
      // 02 §2.1's branch semantics: a user-driven navigation to a new
      // location truncates the forward entries and records the target
      // at issue time — an interrupted or failed navigation stays in
      // the trail too (the failure IS a location the user tried to
      // visit), matching browser history. A same-location re-list
      // (refresh, recovery re-list) records nothing; Back/Forward set
      // the index before issuing and arrive flagged, so they record
      // nothing either.
      if (_historyIndex < _history.length - 1) {
        _history.removeRange(_historyIndex + 1, _history.length);
      }
      if (_history.isEmpty || _history.last != target) {
        _history.add(target);
      }
      _historyIndex = _history.length - 1;
    }
    if (!_loadingActive()) {
      _snapshot =
          _QuiescentSnapshot(_location, _sortedListing, _error, _selection);
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
      _sortedListing = sortFileEntries(listed);
      _setListing(_hiddenFiltered(_sortedListing));
      _applyEntries(_filteredListing());
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

  /// Adopts [entries] as the pane's VISIBLE rows (already through the
  /// §2.5 filter where one is active) and prunes the selection against
  /// the new row identities: surviving keys keep their selection,
  /// cursor, and anchor; missing keys drop out instead of re-targeting
  /// a moved index.
  void _applyEntries(List<RemoteFileEntry> entries) {
    // Any row-set replacement — refresh accept, snapshot restore, bind
    // reset, detach, or a filter edit — ends an open Quick Select
    // session before pruning: the baseline is restored against the OLD
    // row identities, then withRows drops what the new listing no
    // longer has.
    _endQuickSelectSession();
    // A replaced listing also drops a pending type-ahead buffer — the
    // accumulated prefix was matched against rows that no longer stand.
    clearTypeAhead();
    _entries = entries;
    _foldedNames = List.generate(entries.length, (i) {
      final name = entries[i].name;
      return name.contains('\uFFFD') ? null : typeAheadFold(name);
    });
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

  /// The hidden-file policy over the sorted listing (02 §2.5): dotfiles
  /// stay out unless the tab-local [showHidden] override is on — the
  /// §2.4 precedence chain lands with the view-options slice. Pure over
  /// its input so the override re-derives the visible listing without a
  /// re-list; the §2.3 core comparator orders the snapshot first —
  /// default name key, ascending, directories first, with natural digit
  /// runs and Unicode simple folding — and `sortFileEntries` returns an
  /// unmodifiable copy over new row order, so the VFS-returned list is
  /// never mutated.
  List<RemoteFileEntry> _hiddenFiltered(List<RemoteFileEntry> sorted) {
    if (_showHidden) return sorted;
    // unmodifiable, not just non-growable: [entries]' §2.3 contract is
    // that mutating the accepted listing throws.
    return List.unmodifiable(
      sorted.where((entry) => !entry.name.startsWith('.')),
    );
  }

  /// Assigns the accepted listing and rebuilds the lowercased-name cache
  /// in lockstep — the filter's per-keystroke scan never re-lowercases
  /// rows.
  void _setListing(List<RemoteFileEntry> listing) {
    _listing = listing;
    _loweredNames = List.generate(
      listing.length,
      (i) => listing[i].name.toLowerCase(),
    );
  }

  /// The accepted listing seen through the §2.5 filter: an empty query
  /// passes [_listing] through unchanged; an active one keeps only
  /// case-insensitive substring matches, as an unmodifiable copy so
  /// [entries] keeps its immutable contract. Matching scans the cached
  /// [_loweredNames] — no per-row allocation per keystroke.
  List<RemoteFileEntry> _filteredListing() {
    // The invariant guards every read, not just filtered ones — a
    // desynced cache is wrong even when no query is active.
    assert(
      _loweredNames.length == _listing.length,
      '_loweredNames out of sync with _listing — assign via _setListing',
    );
    if (_filterQuery.isEmpty) return _listing;
    final folded = ListingFilter(_filterQuery).foldedQuery;
    return List.unmodifiable([
      for (var i = 0; i < _listing.length; i++)
        if (_loweredNames[i].contains(folded)) _listing[i],
    ]);
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
