import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'double_click_action.dart';
import 'engine_session.dart';
import 'listing_filter.dart';
import 'pane_engine_lanes.dart';
import 'pane_location.dart';
import 'pane_path_input.dart';
import 'pane_rename.dart';
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
    this.committedLocation,
  );

  final PaneLocation? location;
  final List<RemoteFileEntry> listing;
  final RemoteFileException? error;
  final SelectionState<_RowKey> selection;

  /// The committed-location marker at snapshot time: an Esc-cancelled
  /// navigation (or an abandoned server change) restores it, so Sync
  /// Browsing's commit-gated drop never fires off a location the pane
  /// only visited optimistically (02 §7).
  final PaneLocation? committedLocation;
}

/// The prior binding a `replace` rebind keeps alive until its candidate
/// answers its first listing (02 §2.8's Esc-cancelled server change,
/// 02 §7's commit-gated link drop): the still-open channel, the remote
/// identity, and the full browsing presentation — wider than
/// [_QuiescentSnapshot] because the restore crosses a binding boundary
/// (channel, history, and the transient lenses come back too). Captured
/// only for a pane with a live channel; a genuinely fresh pane has
/// nothing to restore and keeps its detach-to-launcher semantics.
///
/// Invariant the record relies on: [_sortedListing] is only ever
/// REASSIGNED (never mutated in place) and [SelectionState] is
/// immutable — the captured references stay honest for the whole
/// candidate window. [_history] is the one live-mutated list, so it is
/// defensively copied at capture.
class _BindingRollback {
  const _BindingRollback({
    required this.channel,
    required this.remote,
    required this.remotePath,
    required this.location,
    required this.committedLocation,
    required this.sortedListing,
    required this.error,
    required this.selection,
    required this.history,
    required this.historyIndex,
    required this.filterQuery,
    required this.filterFieldOpen,
    required this.showHidden,
    required this.viewMode,
    required this.connectionStatus,
    required this.recovery,
  });

  /// Kept open for the whole candidate window: closing it early is what
  /// used to make the candidate's first navigation snapshot an empty
  /// state and left Esc with nothing to restore.
  final AppBrowseChannel channel;
  final Bookmark? remote;
  final String? remotePath;
  final PaneLocation? location;
  final PaneLocation? committedLocation;
  final List<RemoteFileEntry> sortedListing;
  final RemoteFileException? error;
  final SelectionState<_RowKey> selection;
  final List<PaneLocation> history;
  final int historyIndex;
  final String filterQuery;
  final bool filterFieldOpen;
  final bool showHidden;
  final PaneViewMode viewMode;
  final ServerStatus? connectionStatus;
  final _RecoveryPhase recovery;
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

/// One open inline-rename session (02 §2.6): the row under edit, kept as
/// an identity so a same-location refresh that drops the row can report
/// its loss instead of renaming a re-targeted index. [error] is the
/// last failed commit — a client-side validation fault or the channel's
/// typed refusal — shown inside the field until the next submission;
/// [attempted] keeps the refused draft so the re-opened field re-seeds
/// with what the user typed, not the pre-rename name.
class _RenameSession {
  _RenameSession({required this.entry, required this.rowKey});

  final RemoteFileEntry entry;
  final _RowKey rowKey;
  RemoteFileException? error;
  String? attempted;
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

  /// The inline-rename field's typed name was blank or all whitespace
  /// (02 §2.6) — rejected client-side, so no rename was ever requested.
  renameNameEmpty,

  /// The typed name contains the listing's `/` separator — a rename
  /// moves nothing across directories, so this is always invalid.
  renameNameSeparator,

  /// The typed name contains a character the pane's filesystem family
  /// forbids (a local pane on Windows rejects the NTFS set; remote
  /// panes stay POSIX-permissive and never hit this fault).
  renameNameInvalid,

  /// The row under edit left the listing mid-session — a refresh,
  /// another client's delete, or a filter edit removed it — so there
  /// is nothing left to rename.
  renameTargetGone,

  /// The file Open's launch failed with an untyped (non-VFS) error —
  /// the engine's answer was not a [RemoteFileException] at all, so the
  /// pane shows its own authored line instead of an opaque message.
  openFile,
}

/// A non-VFS fault surfacing on the pane: the taxonomy message is a
/// machine sentinel (never rendered); [fault] carries the renderable
/// identity for the view's localized diagnostic line.
class PaneFaultException extends RemoteFileException {
  PaneFaultException(this.fault, {required super.operation})
    : super(kind: RemoteFileErrorKind.other, message: 'fault:${fault.name}');

  final PaneFault fault;
}

/// A failed file Open's retry handle: the failed launch's error,
/// carrying the entry to re-open. The concrete type stays intact — a
/// typed engine error renders its message line, an authored fault
/// renders its ARB sentence — while the pane's Retry re-runs the
/// launch for THIS error, not a re-list. Snapshot/restore preserves it
/// like any other pane error (02 §2.8), so the retry identity survives
/// an Esc-cancel round trip without parallel bookkeeping. The view
/// reads the marker too: an open failure is a FILE problem, not the
/// kind taxonomy's folder sentence.
abstract interface class OpenEntryError implements Exception {
  /// The row the failed open targeted — [PaneController.retry]'s
  /// re-open payload.
  RemoteFileEntry get entry;
}

/// A typed launcher refusal carrying its retry entry.
final class _OpenEntryException extends RemoteFileException
    implements OpenEntryError {
  _OpenEntryException(this.entry, RemoteFileException error)
    : super(
        kind: error.kind,
        operation: error.operation,
        path: error.path,
        message: error.message,
        cause: error.cause,
      );

  @override
  final RemoteFileEntry entry;
}

/// An opaque launcher failure's authored fault carrying its retry
/// entry — still a [PaneFaultException], so the overlay renders the
/// fault's ARB line rather than a wrapper's synthetic message.
final class _OpenEntryFaultException extends PaneFaultException
    implements OpenEntryError {
  _OpenEntryFaultException(super.fault, this.entry, {required super.operation});

  @override
  final RemoteFileEntry entry;
}

/// A transient pane notice (02 §10's notice family): the honest
/// "not yet" for a registered-but-deferred action — never an error,
/// so it renders as a dismissible strip, not the error overlay. The
/// view maps each value to its ARB-authored sentence (D20 — the
/// controller never authors user copy).
enum PaneNotice {
  /// A remote file's Open: the managed-checkout pipeline is 06's —
  /// nothing runs, and the notice says so.
  openRemoteUnavailable,

  /// "Double-click action: Edit in Poltergeist" was chosen; the
  /// editor is 06's.
  editLater,

  /// "Double-click action: Transfer to other pane" was chosen; the
  /// transfer queue is M4's.
  transferLater,
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

  /// Bumped each time a navigation issue changes the location VALUE —
  /// the browsing-session half of a rename operation's ownership token:
  /// an away-and-back round trip lands on an equal path but is a
  /// different session, which location equality alone cannot tell.
  int _locationRevision = 0;

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

  /// The prior binding held open while a `replace` candidate is in
  /// flight (02 §2.8/§7): non-null from the rebind's `_beginBinding`
  /// until the candidate answers its first listing, fails, or is
  /// cancelled back to the prior binding. While it is pending the pane
  /// is BETWEEN bindings — [_channel] is null or the candidate, never
  /// the rolled-back channel.
  _BindingRollback? _rollback;
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

  /// Whether the rendered rows are presentation cache for a location
  /// the pane has already left (02 §2.8's grace is presentation-only):
  /// set the moment a location-changing navigation resets the selection
  /// while the old listing stays rendered for the anti-flash grace, and
  /// cleared only when a listing is accepted or a quiescent
  /// snapshot/rollback/binding state is restored — never by a
  /// mid-flight lens edit, which re-derives rows from the same disowned
  /// listing. Row interaction (cursor, selection, type-ahead,
  /// activation) is inert while this holds: the rows are cached data,
  /// not selectable rows.
  bool _staleRows = false;

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

  /// The open inline-rename session (02 §2.6); null while the row's
  /// field is closed. The pane owns its invalidation: a location change
  /// ends it at navigation-issue time, every row-set replacement ends it
  /// before pruning (re-attaching a `renameTargetGone` fault when the
  /// edited row left the listing), and a binding replace or detach ends
  /// it with the session it edited.
  _RenameSession? _renameSession;

  /// An awaited `channel.rename` — the field closes at submit time, but
  /// the tab-close guard must still quantify the in-flight rename.
  bool _renameInFlight = false;

  /// The rename target a just-issued refresh should re-select: the
  /// rename changes the row's key, so without this the listing accept
  /// would prune the cursor off the renamed row (02 §2.5's identity
  /// convention). Consumed by the next accepted listing; cleared by any
  /// newer navigation issue.
  String? _pendingRenameSelectPath;

  /// Whether this tab anchors the workspace's Sync Browsing pair
  /// (02 §7): the workspace's sync controller writes it on enable and
  /// drop; the tab close guard's syncAnchor probe reads it so closing
  /// an anchored tab quantifies the link loss through the same guarded
  /// operation every other trigger uses.
  bool _syncAnchorActive = false;

  /// The last location whose listing was actually accepted — 02 §2.8's
  /// committed answer. [location] moves optimistically at issue time
  /// and STAYS on a failed target (the error overlay rides it), so it
  /// cannot name where the pane verifiably stands; this marker only
  /// ever names a directory the channel listed. Null while a rebind is
  /// in flight and until its first listing lands. Sync Browsing (02 §7)
  /// keys anchors, replay, and the server-change drop on it, so a
  /// failed or Esc-cancelled navigation never drags the mirror.
  PaneLocation? _committedLocation;

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

  /// The "Double-click action" preference's live value (02 §2.6): read
  /// at every FILE activation in [openEntry]. The owning strip stamps
  /// it; the spec default is Open. Folders never consult it — they
  /// always navigate.
  DoubleClickAction doubleClickAction = DoubleClickAction.open;

  /// The active transient notice (02 §10's notice family): set when an
  /// activation resolves to a registered-but-deferred action, cleared
  /// by [dismissNotice], by the next activation (a notice never stacks
  /// on a notice), by the auto-hide timer, and by binding teardown.
  PaneNotice? get notice => _notice;
  PaneNotice? _notice;
  Timer? _noticeTimer;

  /// How long a notice lingers before auto-dismiss (02 §10's "transient
  /// or dismiss" contract — this notice is both). Public so tests pin a
  /// short life.
  Duration noticeLifetime = const Duration(seconds: 4);

  /// Dismisses the current notice (the strip's ✕ routes here); a no-op
  /// when none is showing.
  void dismissNotice() {
    _noticeTimer?.cancel();
    _noticeTimer = null;
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  void _postNotice(PaneNotice value) {
    _noticeTimer?.cancel();
    _notice = value;
    _noticeTimer = Timer(noticeLifetime, dismissNotice);
    notifyListeners();
  }

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

  /// Whether the rendered rows are a disowned cached listing — inert
  /// from the moment a location-changing navigation issues, not from
  /// the dim's appearance (02 §2.8). The view reads this to block
  /// pointer/keyboard/semantics dispatch before the grace elapses; the
  /// controller enforces the same boundary on every row-interaction
  /// entry point so no caller can select or activate a stale row.
  bool get staleRows => _staleRows;

  /// Whether row interaction is permitted: the controller is live, its
  /// rows are owned (not disowned cache), and a listing is present.
  /// Every row-interaction entry point gates on this so the stale
  /// boundary cannot drift as new entry points appear.
  bool get _rowsInteractive =>
      !_disposed && !_staleRows && _entries.isNotEmpty;

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

    // The binding being replaced, captured before [_pendingRemote]
    // moves to the candidate — the rollback record needs the PRIOR
    // identity, not the new one.
    final priorRemote = _pendingRemote;
    final priorRemotePath = _pendingRemotePath;
    // Preserve retries, but never carry one bookmark's path into another.
    if (bookmark.id != _pendingRemote?.id) _pendingRemotePath = null;
    _pendingRemote = bookmark;
    _pendingRemotePath = initialPath ?? _pendingRemotePath;
    await _bind(
      connectingPhase: PanePhase.connectingRemote,
      operation: 'connect',
      fault: PaneFault.connectionOpen,
      presentation: presentation,
      priorRemote: priorRemote,
      priorRemotePath: priorRemotePath,
      connect: (lanes, attempt) async {
        // Subscribe before connecting: a connect that raises state (or
        // a prompt the coordinator answers) must find this pane
        // listening.
        _statusWatch = _watchServerFor(lanes, bookmark, attempt);
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

  /// Activates one row (02 §2.6's Open — double-click, ⌘↓/⌘O on macOS,
  /// Enter on Windows/Linux): only entries the listing itself types as
  /// directories navigate, under every gesture and regardless of the
  /// preference (a symlink is not a directory from listing metadata
  /// alone — 02 §2.3 classifies without a target round trip — so it
  /// routes as a file). A file runs the "Double-click action" live
  /// value: Open launches a local file in the OS default application
  /// through the engine's seam (D8 — the UI never spawns the launcher)
  /// and posts the unavailable notice for a remote one (managed
  /// checkout is 06's); the registered-but-deferred Edit and Transfer
  /// values post their honest not-yet notices; Do nothing is inert.
  /// Any fresh activation clears a lingering notice first.
  Future<void> openEntry(RemoteFileEntry entry) async {
    // A stale row activation is fully inert — not even a notice clear:
    // the row is disowned presentation, and navigating into it would
    // supersede the pending navigation with the old directory's data.
    if (_disposed || _staleRows) return;
    dismissNotice();
    if (entry.type == RemoteFileType.directory) {
      navigate(entry.path);
      return;
    }
    switch (doubleClickAction) {
      case DoubleClickAction.nothing:
        return;
      case DoubleClickAction.edit:
        _postNotice(PaneNotice.editLater);
        return;
      case DoubleClickAction.transfer:
        _postNotice(PaneNotice.transferLater);
        return;
      case DoubleClickAction.open:
        // The BINDING names remote-ness (navigate's rule): a cancelled
        // first listing leaves the location null under a live remote
        // channel, and a null location must never mint a local open.
        if (_pendingRemote != null) {
          _postNotice(PaneNotice.openRemoteUnavailable);
          return;
        }
        await _openLocalEntry(entry);
    }
  }

  /// The local-file Open: hands the row's path to the engine's
  /// shell-open seam and maps the launch outcome onto the pane's ONE
  /// inline error affordance (02 §2.8) — typed engine errors surface
  /// verbatim, an untyped failure surfaces as the authored
  /// [PaneFault.openFile] line, and either way the pane's Retry re-runs
  /// the open for THIS entry (the error carries it).
  Future<void> _openLocalEntry(RemoteFileEntry entry) async {
    final channel = _channel;
    if (channel == null) return;
    try {
      await channel.openInDefaultApp(entry.path);
      // A rebind during the in-flight launch makes this answer stale —
      // same drop rule as a superseded listing generation.
      if (_disposed || !identical(_channel, channel)) return;
      // A successful (re)launch retires an open failure's inline error
      // — never an unrelated listing error that arrived in between.
      if (_error is OpenEntryError) {
        _error = null;
        notifyListeners();
      }
    } on RemoteFileException catch (error) {
      if (_disposed || !identical(_channel, channel)) return;
      _error = _OpenEntryException(entry, error);
      notifyListeners();
    } on Object catch (error, stackTrace) {
      // The opaque failure is real regardless of staleness — it still
      // reports; only the pane-state write drops after a rebind.
      _report(error, stackTrace);
      if (_disposed || !identical(_channel, channel)) return;
      _error = _OpenEntryFaultException(
        PaneFault.openFile,
        entry,
        operation: 'open',
      );
      notifyListeners();
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
    if (_disposed) return;

    // Esc during a pending replacement's first listing restores the
    // prior binding, not the cleared-state snapshot the candidate's
    // issue would have captured (02 §2.8's cancelled server change).
    // Checked before the loss/loading guards: the CANDIDATE's status
    // lane can raise connectionLost or set _error mid-window, which
    // would otherwise dead-end Esc on the failing candidate.
    if (_rollback != null) {
      _rollbackCandidateBind();
      return;
    }

    if (connectionLost || !_loadingActive()) return;

    final snapshot = _snapshot;
    _location = snapshot?.location;
    _committedLocation = snapshot?.committedLocation;
    _error = snapshot?.error;
    _selection =
        snapshot?.selection ?? SelectionState<_RowKey>.begin(rows: const []);
    _sortedListing = snapshot?.listing ?? const [];
    _setListing(_hiddenFiltered(_sortedListing));
    _applyEntries(_filteredListing());
    // The restored snapshot owns its rows again.
    _staleRows = false;
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
    // Open text surfaces yield first: Quick Select and the filter
    // field close so two fields never compete for the pane's keys
    // (02 §8.2's field-first rule). The filter QUERY survives — only
    // its strip unmounts.
    _endQuickSelectSession();
    _filterFieldOpen = false;
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
      // A failed file Open retries the LAUNCH for its recorded entry —
      // re-listing the directory would not re-attempt the open (02 §2.6).
      if (_error case OpenEntryError(:final entry)) {
        await _openLocalEntry(entry);
        return;
      }
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
    if (!_rowsInteractive) return;
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
    if (!_rowsInteractive) return;
    final before = _selection;
    _selection = _selection.selectAll();
    if (identical(before, _selection)) return;
    notifyListeners();
  }

  /// `edit.invertSelection` (02 §2.5): replaces the selection with its
  /// complement among the visible rows; cursor and anchor keep their
  /// positions.
  void invertSelection() {
    if (!_rowsInteractive) return;
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

  /// Whether an inline rename is open or committing on this tab — the
  /// tab close guard's trigger probe (02 §3). True while the field is
  /// mounted AND while its submitted rename is still in flight, so a
  /// close can never cut under either half.
  bool get inlineRenameActive =>
      _renameSession != null || _renameInFlight;

  /// The row under inline edit; null while no session is open.
  RemoteFileEntry? get renameTarget => _renameSession?.entry;

  /// The session row's index into [entries] — the overlay's anchor;
  /// null while closed or when the row left the listing (the
  /// `renameTargetGone` fault surface).
  int? get renameIndex =>
      _renameSession == null ? null : _rowKeyIndex[_renameSession!.rowKey];

  /// The session's last failed commit — a validation fault or the
  /// channel's typed refusal — rendered inside the field.
  RemoteFileException? get renameError => _renameSession?.error;

  /// The text the field opens with: the refused draft after a failed
  /// commit, the row's current name on a fresh open.
  String get renameSeed =>
      _renameSession?.attempted ?? _renameSession?.entry.name ?? '';

  /// `file.rename` (02 §2.6): opens the inline editor on the cursor row.
  /// Inert off the verb surface (unbound, loading, errored, or lost
  /// connection), while a session is open, and while a commit is in
  /// flight — one rename at a time per tab.
  void startRename() {
    if (_disposed ||
        !verbsEnabled ||
        _renameSession != null ||
        _renameInFlight) {
      return;
    }
    final cursor = cursorIndex;
    // The cursor is kept in-range by the listing prune, but the session
    // owns its own precondition rather than borrowing that invariant.
    if (cursor == null || cursor < 0 || cursor >= _entries.length) return;
    _renameSession = _RenameSession(
      entry: _entries[cursor],
      rowKey: _rowKeys[cursor],
    );
    notifyListeners();
  }

  /// Esc / focus-loss cancel (02 §8.2's field-first tier): closes the
  /// editor without a request. Inert while a commit is in flight — the
  /// session field is already null then, and the in-flight guard holds
  /// the close guard regardless.
  void cancelRename() {
    if (_disposed || _renameSession == null) return;
    _renameSession = null;
    notifyListeners();
  }

  /// Enter commit (02 §2.6): validates the typed name against the pane's
  /// filesystem family, closes the field, renames through the channel,
  /// then refreshes so the listing re-sorts around the new name. The
  /// field closes BEFORE the request — a failure re-opens it with the
  /// typed error; a vanish mid-commit drops it. Submitting the
  /// unchanged name is a silent no-op (no request, no refresh).
  Future<void> submitRename(String raw) async {
    final session = _renameSession;
    final channel = _channel;
    if (_disposed || session == null || channel == null || _renameInFlight) {
      return;
    }

    // A session whose row left the listing is diagnostic-only (the
    // `renameTargetGone` fault): it must never reach the channel — the
    // old path may now name a hidden file or a REPLACEMENT file that
    // arrived after the row vanished. Enter dismisses the stranded
    // editor; a new edit needs a fresh session on a live row.
    if (!_rowKeyIndex.containsKey(session.rowKey)) {
      // The canonical teardown (no notify by contract) plus this
      // path's own notify — the dismissal IS the transition here.
      _endRenameSession();
      notifyListeners();
      return;
    }

    final location = _location;
    final nameError = renameNameError(
      raw,
      remote: location is RemotePaneLocation,
      platform: defaultTargetPlatform,
    );
    if (nameError != null) {
      session.error = PaneFaultException(
        switch (nameError) {
          RenameNameError.empty => PaneFault.renameNameEmpty,
          RenameNameError.separator => PaneFault.renameNameSeparator,
          RenameNameError.invalid => PaneFault.renameNameInvalid,
        },
        operation: 'rename',
      );
      notifyListeners();
      return;
    }

    final entry = session.entry;
    if (raw == entry.name) {
      _renameSession = null;
      notifyListeners();
      return;
    }

    // The parent prefix keeps the entry path's own separators — never a
    // synthesized join — so the re-anchored path matches the refreshed
    // listing's normalization. The grammar comes from the path itself:
    // a remote or POSIX local path separates on '/' only, so a '\' in
    // a name is a filename byte, never a separator. The exact basename
    // is removed BEFORE any separator trimming — a POSIX name may end
    // in '\' and trimming it first would leave a path that no longer
    // ends with its name — and the prefix counts only when the cut
    // lands on a separator boundary. The last-separator split is the
    // fallback for a path that does not end with its name, the
    // location join the last resort.
    final separator = paneSeparator(entry.path);
    var parent = '';
    if (entry.path.endsWith(entry.name)) {
      final prefix = entry.path.substring(
        0,
        entry.path.length - entry.name.length,
      );
      if (prefix.isEmpty || prefix.endsWith(separator)) {
        parent = prefix;
      }
    }
    if (parent.isEmpty && entry.path != entry.name) {
      var trimmed = entry.path;
      while (trimmed.length > 1 && trimmed.endsWith(separator)) {
        trimmed = trimmed.substring(0, trimmed.length - 1);
      }
      if (trimmed.endsWith(entry.name)) {
        final prefix = trimmed.substring(
          0,
          trimmed.length - entry.name.length,
        );
        if (prefix.endsWith(separator)) parent = prefix;
      }
      if (parent.isEmpty) {
        final lastSep = trimmed.lastIndexOf(separator);
        if (lastSep >= 0) parent = trimmed.substring(0, lastSep + 1);
      }
    }
    if (parent.isEmpty) {
      // The last resort still respects the base's own terminator — a
      // root location ('/', 'C:\', a UNC root) already ends with its
      // separator, and doubling it would synthesize a spelling the
      // refreshed listing never matches.
      final base = location?.path ?? '';
      final baseSeparator = paneSeparator(base);
      parent = base.endsWith(baseSeparator) ? base : '$base$baseSeparator';
    }
    final newPath = '$parent$raw';

    // The field closes at submit: the in-flight flag alone holds the
    // tab-close guard until the request settles. The typed draft stays
    // on the session so a refusal can re-open the field with it.
    session.attempted = raw;
    _renameSession = null;
    _renameInFlight = true;
    notifyListeners();

    // The operation's ownership token: channel identity, bind attempt,
    // and the browsing-session revision at submit time. A rebind — even
    // one landing on the same path spelling — or an away-and-back
    // navigation retires the token, so a late answer can never mutate
    // a binding or session the operation no longer owns.
    final attempt = _bindAttempt;
    final revision = _locationRevision;
    bool ownsPresentation() =>
        identical(channel, _channel) &&
        attempt == _bindAttempt &&
        revision == _locationRevision &&
        location == _location;

    try {
      await channel.rename(entry.path, newPath);
    } on RemoteFileException catch (error, stackTrace) {
      // Only the owning operation clears the guard: a retired commit's
      // late settle must not release a newer commit's flag.
      if (_disposed || ownsPresentation()) _renameInFlight = false;
      if (_disposed) return;
      if (ownsPresentation()) {
        // Re-open the field with the refusal inside while the pane
        // still browses the session's location. A row that left the
        // listing renders detached (renameIndex null) but the refusal
        // still surfaces — a typed VFS error is never swallowed
        // silently.
        session.error = error;
        _renameSession = session;
      } else {
        // A stale operation's refusal belongs to the retired session,
        // not to whatever the pane browses now: it reports through the
        // pane's error path rather than reopening a stale editor or
        // dropping silently.
        _report(error, stackTrace);
      }
      notifyListeners();
      return;
    } on Object catch (error, stackTrace) {
      if (_disposed || ownsPresentation()) _renameInFlight = false;
      if (_disposed) return;
      // An untyped failure is not a name refusal — it reports on the
      // pane's error surface, and the field stays closed.
      _report(error, stackTrace);
      return;
    }

    if (_disposed || ownsPresentation()) _renameInFlight = false;
    if (_disposed) return;
    if (!ownsPresentation()) {
      // The rename applied on the old binding; the pane's current
      // listing belongs to a newer operation and is left untouched —
      // the retired session's editor and reselect stay off. The settle
      // itself still notifies: anything tracking the in-flight
      // operation learns it finished even though its state write is
      // suppressed. An away-and-back round trip (or a rebind landing on
      // the same path spelling) can leave the pane browsing the
      // renamed directory on the SAME channel: the listing it accepted
      // can predate the commit, so it is re-fetched.
      notifyListeners();
      if (identical(channel, _channel) && location == _location) {
        refresh();
      }
      return;
    }
    refresh();
    // Set AFTER refresh() issues: a navigation issue clears the pending
    // select, and the refresh's own accept is what consumes it.
    _pendingRenameSelectPath = newPath;
  }

  /// Ends the open session without a notify — every invalidation funnel
  /// (navigation issue, row-set replacement, binding reset) calls this
  /// inside a flow that notifies once for the whole transition.
  void _endRenameSession() {
    _renameSession = null;
  }

  /// Whether this tab anchors the Sync Browsing pair — the tab close
  /// guard's syncAnchor trigger probe (02 §7); the workspace's sync
  /// controller owns the writes.
  bool get syncAnchorActive => _syncAnchorActive;

  set syncAnchorActive(bool value) {
    if (_disposed || value == _syncAnchorActive) return;
    _syncAnchorActive = value;
    notifyListeners();
  }

  /// The last directory this pane's channel verifiably listed — null
  /// while a rebind is in flight and until its first listing lands.
  /// Sync Browsing (02 §7) keys on it: only a commit moves a pane, so a
  /// failed or cancelled navigation can neither replay nor drop the link.
  PaneLocation? get committedLocation => _committedLocation;

  /// Whether [path] lists on the live channel right now — the Sync
  /// Browsing mirror probe (02 §7): the link checks existence on the
  /// other pane BEFORE navigating it, so a missing mirror suspends the
  /// link instead of optimistically erroring that pane onto a
  /// nonexistent location. Typed VFS errors answer false; a transport
  /// fault reports and answers false (a pane that cannot answer cannot
  /// mirror).
  Future<bool> directoryExists(String path) async {
    final channel = _channel;
    if (_disposed || channel == null || connectionLost) return false;
    try {
      await channel.listDirectory(path);
      return true;
    } on RemoteFileException {
      return false;
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace);
      return false;
    }
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
    if (!_rowsInteractive || character.isEmpty) {
      return;
    }
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
    await cancelPendingBind();
    if (_disposed || _bindAttempt != detachedAttempt) return;
    if (serverStillUnshared != null && !serverStillUnshared()) return;
    try {
      await lanes.disconnectServer(serverId);
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace);
    }
  }

  /// The Esc/banner cancel route's entry point while a bind is in
  /// flight: a parked rollback means the pending bind was a REPLACEMENT,
  /// so cancel restores the prior binding and retires only the
  /// candidate; otherwise it is a plain detach. The branch lives here
  /// (not inside [detachRemote]) so detach keeps exactly one meaning —
  /// a future explicit disconnect affordance must not inherit the
  /// rollback fork.
  Future<void> cancelPendingBind() async {
    if (_disposed) return;
    if (_rollback != null) {
      _rollbackCandidateBind();
      return;
    }
    await detachRemote();
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
    // The detached binding's pending rename is retired by the attempt
    // bump — release its in-flight guard with the rest of the state.
    _renameInFlight = false;
    _phase = PanePhase.unbound;
    _location = null;
    _committedLocation = null;
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
    _staleRows = false;
    _error = null;
    _snapshot = null;
    _connectionStatus = null;
    _recovery = _RecoveryPhase.none;
    _pendingRemote = null;
    _pendingRemotePath = null;
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _notice = null;
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
    _renameSession = null;
    _pendingRenameSelectPath = null;
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _notice = null;
    _typeAheadReset?.cancel();
    _typeAheadReset = null;
    _typeAheadBuffer = '';
    unawaited(_statusWatch?.cancel());
    _statusWatch = null;
    _retireRollback();
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
    Bookmark? priorRemote,
    String? priorRemotePath,
    required Future<void> Function(PaneEngineLanes lanes, int attempt) connect,
  }) async {
    final lanes = _lanes;
    if (_disposed || lanes == null) return;

    final attempt = ++_bindAttempt;
    _phase = connectingPhase;
    _beginBinding(
      presentation,
      priorRemote: priorRemote,
      priorRemotePath: priorRemotePath,
    );
    notifyListeners();

    await _releaseBinding();
    if (_disposed || attempt != _bindAttempt) return;

    try {
      await connect(lanes, attempt);
    } on RemoteFileException catch (error) {
      if (_disposed || attempt != _bindAttempt) return;
      // A replace candidate's failure ends the transaction and retires
      // the parked prior binding. A retainCache recovery RETRY failing
      // is different: the rollback stays parked so Esc can still
      // restore the prior binding out of the failed reconnect.
      if (presentation == _BindingPresentation.replace) _retireRollback();
      _dropStatusWatch();
      if (presentation == _BindingPresentation.retainCache) {
        _recovery = _RecoveryPhase.failed;
      }
      _error = error;
      notifyListeners();
    } on Object catch (error, stackTrace) {
      if (_disposed || attempt != _bindAttempt) return;
      if (presentation == _BindingPresentation.replace) _retireRollback();
      _report(error, stackTrace);
      _dropStatusWatch();
      if (presentation == _BindingPresentation.retainCache) {
        _recovery = _RecoveryPhase.failed;
      }
      _error = PaneFaultException(fault, operation: operation);
      notifyListeners();
    }
  }

  /// The server-state subscription every remote binding owns: the
  /// connect path and a rollback restore share it. Events are captured
  /// under [attempt] so a superseded binding's statuses drop themselves
  /// (09 §3's stale-attempt idiom).
  StreamSubscription<ServerStatus> _watchServerFor(
    PaneEngineLanes lanes,
    Bookmark bookmark,
    int attempt,
  ) {
    return lanes
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
  ///
  /// [priorRemote]/[priorRemotePath] carry the binding being replaced —
  /// [_pendingRemote] already names the candidate by the time this runs.
  void _beginBinding(
    _BindingPresentation presentation, {
    Bookmark? priorRemote,
    String? priorRemotePath,
  }) {
    _cancelListing();
    // The attempt bump in _bind retires every pending rename's
    // ownership token; release the in-flight guard here so a stalled
    // request on the old binding cannot keep the new binding's rename
    // verb closed. The retiring operation's settle leaves the flag
    // untouched once it no longer owns it.
    _renameInFlight = false;
    // The notice dies with the browsing session it arose in — a rebind
    // never carries one pane-moment's "not yet" into the next binding.
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _notice = null;
    if (presentation == _BindingPresentation.replace) {
      // Transactional replacement (02 §2.8/§7): the prior binding moves
      // into the rollback record — channel still open — instead of
      // being discarded before the candidate commits. A stacked rebind
      // does NOT supersede a pending rollback: the last binding the
      // pane actually displayed remains the restore target while the
      // intermediate candidate's channel is released below like any
      // other.
      if (_rollback == null && _channel != null) {
        _rollback = _BindingRollback(
          channel: _channel!,
          remote: priorRemote,
          remotePath: priorRemotePath,
          location: _location,
          committedLocation: _committedLocation,
          sortedListing: _sortedListing,
          error: _error,
          selection: _selection,
          history: List.of(_history),
          historyIndex: _historyIndex,
          filterQuery: _filterQuery,
          filterFieldOpen: _filterFieldOpen,
          showHidden: _showHidden,
          viewMode: _viewMode,
          // Captured as displayed at replacement time: the parked
          // server's status events are dropped while the candidate owns
          // the watch, and the fresh subscription on restore corrects
          // both on its next event.
          connectionStatus: _connectionStatus,
          recovery: _recovery,
        );
        // The record owns the channel now; [_releaseBinding] must not
        // close it.
        _channel = null;
      }
      _location = null;
      // A rebind stands nowhere until its first listing commits — the
      // sync link's server-change drop keys on THAT commit, so an
      // abandoned rebind keeps the link (02 §7).
      _committedLocation = null;
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
      // No rows at all now — nothing stale is left to guard.
      _staleRows = false;
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
    // A cancelled listing can never consume a pending rename re-select.
    _pendingRenameSelectPath = null;
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
    final priorRemote = _pendingRemote;
    final priorRemotePath = _pendingRemotePath;
    _pendingRemote = null;
    _pendingRemotePath = null;
    _pendingLocalRoot = rootPath;
    await _bind(
      connectingPhase: PanePhase.openingLocal,
      operation: 'open',
      fault: PaneFault.localOpen,
      priorRemote: priorRemote,
      priorRemotePath: priorRemotePath,
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
    // A rename's refresh-select hint is consumed by the listing THIS
    // issue's answer accepts; any newer issue invalidates it.
    _pendingRenameSelectPath = null;
    if (_location != target) {
      // A location change ends an open rename at issue time — the field
      // edits against rows of the directory it opened on (02 §2.6), and
      // a same-location refresh instead lets the accepted listing's
      // row-presence check decide (02 §2.8's keep-rows-while-loading).
      _endRenameSession();
      _locationRevision++;
      // The revision bump retires a pending commit's ownership token —
      // release its in-flight guard so a stalled request cannot keep
      // this location's rename verb closed.
      _renameInFlight = false;
    }
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
    // While a replacement rollback is pending there is no quiescent
    // state in the CANDIDATE binding to capture — the rollback record
    // is the only honest restore target, and a cleared-state snapshot
    // would resurrect the empty pane this seam exists to prevent.
    if (!_loadingActive() && _rollback == null) {
      _snapshot =
          _QuiescentSnapshot(
        _location,
        _sortedListing,
        _error,
        _selection,
        _committedLocation,
      );
    }
    if (_location != target) {
      // The old entries stay visible (dimmed) during the load, but the
      // selection belongs to the old listing — the cursor convention.
      // The rows are disowned from THIS moment: the anti-flash grace
      // governs presentation only, never interaction eligibility.
      _staleRows = true;
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
      // The candidate answered — its binding is now the pane's, so the
      // prior binding's channel finally retires.
      _retireRollback();
      _sortedListing = sortFileEntries(listed);
      _setListing(_hiddenFiltered(_sortedListing));
      _applyEntries(_filteredListing());
      // The accepted listing owns its rows again.
      _staleRows = false;
      final renameSelect = _pendingRenameSelectPath;
      _pendingRenameSelectPath = null;
      if (renameSelect != null) {
        // The rename changed the row's key; re-anchor the cursor to the
        // renamed row's new index instead of letting the prune drop it.
        final index = _entries.indexWhere(
          (entry) => entry.path == renameSelect,
        );
        if (index >= 0) setCursorIndex(index);
      }
      _recovery = _RecoveryPhase.none;
      _answeredGeneration = generation;
      // The commit marker moves only here — an accepted answer. The
      // generation check above already pins `_location` to this
      // navigation's target.
      _committedLocation = _location;
      _error = null;
      notifyListeners();
    } on RemoteFileException catch (error) {
      if (_disposed ||
          generation != _issuedGeneration ||
          !identical(channel, _channel)) {
        return;
      }
      // Same retire rule as an accept: the candidate binding answered,
      // so the pane stays on it (with the error) rather than rolling
      // back — Esc next routes to Retry, not restore.
      _retireRollback();
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
      _retireRollback();
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
    // Any row-set replacement ends an open rename session (02 §2.6 —
    // the field edits against the listing it opened on). When the edited
    // row left the new listing while the pane still browses, the session
    // re-attaches carrying the `renameTargetGone` fault: the field stays
    // mounted to show why its target vanished instead of disappearing
    // silently.
    final rename = _renameSession;
    _renameSession = null;
    _entries = entries;
    _foldedNames = List.generate(entries.length, (i) {
      final name = entries[i].name;
      return name.contains('\uFFFD') ? null : typeAheadFold(name);
    });
    _rowKeys = List.unmodifiable(_keysFor(entries));
    _rowKeyIndex = {for (var i = 0; i < _rowKeys.length; i++) _rowKeys[i]: i};
    _selection = _selection.withRows(_rowKeys);
    if (rename != null &&
        _location != null &&
        !_rowKeyIndex.containsKey(rename.rowKey)) {
      rename.error = PaneFaultException(
        PaneFault.renameTargetGone,
        operation: 'rename',
      );
      _renameSession = rename;
    }
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
  ///
  /// A channel parked in [_rollback] is NOT this method's business —
  /// the record owns it until [_retireRollback] or
  /// [_rollbackCandidateBind] decides its fate.
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

  /// The candidate answered or failed — the pane stays on it, so the
  /// parked prior binding closes for real. Fire-and-forget like every
  /// other channel retire in this class (a hung close must not hold the
  /// answer path).
  void _retireRollback() {
    final rollback = _rollback;
    _rollback = null;
    if (rollback != null) unawaited(_closeChannel(rollback.channel));
  }

  /// Esc/cancel while a replacement candidate is still in flight: the
  /// CANDIDATE retires (channel close, pending markers dropped, status
  /// watch — [_releaseBinding] plus the generation bumps), and the
  /// prior binding comes back whole — channel still open, listing,
  /// selection, history, lenses, error, connection status — with its
  /// server watch re-subscribed under the current attempt so late
  /// statuses keep flowing to the pane that restored it.
  ///
  /// [_cancelListing] retires every in-flight candidate answer before
  /// the restore (09 §3's advance, never reuse — a late candidate
  /// listing answers stale and is swallowed), and the bind-attempt bump
  /// retires a still-pending candidate open the same way. The rollback
  /// channel's own late answers were already swallowed by the
  /// `identical(channel, _channel)` checks while it sat parked.
  void _rollbackCandidateBind() {
    final rollback = _rollback;
    _rollback = null;
    if (rollback == null) return;
    // Invalidate the candidate's bind attempt first: a late
    // openBrowseChannel/openLocalChannel completion must hit the
    // stale-attempt close, never be adopted into the restored binding.
    // (cancelRecovery also counts on this being exactly one bump.)
    final attempt = ++_bindAttempt;
    _cancelListing();
    unawaited(_releaseBinding());
    _pendingRemote = rollback.remote;
    _pendingRemotePath = rollback.remotePath;
    // [retry] reads the pending local root only under openingLocal —
    // restore the prior binding's root, or the harmless default.
    final priorLocal = rollback.location;
    _pendingLocalRoot =
        priorLocal is LocalPaneLocation ? priorLocal.path : '~';
    _location = rollback.location;
    _committedLocation = rollback.committedLocation;
    _error = rollback.error;
    // The lenses land before the listing is re-derived — the hidden and
    // filter projections both read them (same order as cancelNavigation's
    // snapshot restore).
    _viewMode = rollback.viewMode;
    _showHidden = rollback.showHidden;
    _filterQuery = rollback.filterQuery;
    _filterFieldOpen = rollback.filterFieldOpen;
    _sortedListing = rollback.sortedListing;
    _setListing(_hiddenFiltered(_sortedListing));
    _selection = rollback.selection;
    _applyEntries(_filteredListing());
    // The restored binding owns its rows again.
    _staleRows = false;
    _history
      ..clear()
      ..addAll(rollback.history);
    _historyIndex = rollback.historyIndex;
    _connectionStatus = rollback.connectionStatus;
    _recovery = rollback.recovery;
    _channel = rollback.channel;
    // No snapshot is carried: the restored state IS the quiescent
    // baseline, and the next _issueNavigation recaptures it before any
    // listing goes in flight — there is no restore-less window.
    _snapshot = null;
    _phase = PanePhase.browsing;
    final lanes = _lanes;
    final remote = _pendingRemote;
    if (lanes != null && remote != null) {
      _statusWatch = _watchServerFor(lanes, remote, attempt);
    }
    notifyListeners();
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
