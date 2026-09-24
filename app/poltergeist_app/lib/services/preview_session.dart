import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller.dart';
import 'pane_location.dart';
import 'pane_tabs_controller.dart';
import 'quick_look_channel.dart';
import 'workspace_controller.dart';

// The session's constructor params keep PUBLIC names (`workspace`,
// `cache`, …) that map onto private fields — initializing formals
// would expose `_workspace` as the named parameter, unusable outside
// this library.
// ignore_for_file: prefer_initializing_formals

/// 06 §5.2's per-focused-item panel states — the pane's Space/Esc
/// dispatch and the preview panel's cards both key off this enum.
enum PreviewPhase {
  /// The panel is open with nothing to preview (empty selection,
  /// launcher tab, or an unbound pane).
  idle,

  /// A remote file of a previewable kind is focused but not yet in the
  /// cache: the metadata card with "Press Space to download a preview"
  /// (§5.3's explicit-action rule — selection alone never downloads).
  prompt,

  /// A known-size production sits over the large-download threshold:
  /// the `Download <size> to preview "<name>"?` card waits on the user.
  /// Space is a no-op here (§5.2).
  confirm,

  /// A production is in flight — progress card with Cancel; Space is a
  /// no-op and Esc cancels the download without closing the panel.
  producing,

  /// An unknown-size stream parked at the threshold (§5.3's gate):
  /// `Cancel` / `Keep downloading` — Space is a no-op, Esc answers the
  /// card's Cancel (the confirmation dismisses, the panel stays open).
  gateConfirm,

  /// Content rendered (text/image/PDF) or a promptless card answered
  /// (metadata, refusal, error): Space or Esc closes the panel.
  rendered,
}

/// Why a focused item's card refuses or fails to render — the card's
/// copy selector. `none` means the phase carries its own meaning.
enum PreviewRefusal {
  none,

  /// Known remote size exceeds the preview-cache cap — the prompt never
  /// offers a download the cache cannot hold (§5.3).
  overCacheCap,

  /// Known size exceeds the kind's cap (64 MiB image/PDF decode guard,
  /// applied from metadata before anything downloads).
  overKindCap,

  /// The produced/local bytes refused the text window — binary content
  /// or non-UTF-8 (the §1 refusal strings carry the detail).
  notText,

  /// Production failed — the card keeps the prompt so Space retries
  /// (§5.2's failed/cancelled → prompt rule).
  failed,

  /// The user cancelled the production — same prompt-card return, with
  /// the honest "cancelled" line rather than a failure one.
  cancelled,

  /// The focused file vanished between selection and render.
  missing,
}

/// One in-flight remote production, keyed by the cache key it will
/// commit to. Kept in a map so re-focusing the item (or Quick Look
/// arrow-stepping back to it) attaches to the same work instead of
/// queueing a duplicate (06 §5.2/§5.3's dedupe rule).
final class _Production {
  _Production({
    required this.ticket,
    required this.slot,
    required this.generation,
    required this.entry,
    required this.serverId,
  });

  final PreviewProduceTicket ticket;
  final PreviewCacheSlot slot;
  final int generation;
  final RemoteFileEntry entry;
  final String serverId;

  /// The unknown-size stream's threshold gate (null when the size was
  /// known) — a re-attaching focus lands on gateConfirm when this is
  /// parked.
  PreviewByteGate? gate;
  int transferred = 0;
  int? total;
}

/// The preview verb's surface answer for one invocation: where Space
/// routed the request. Exposed for the pane's key dispatch (and tests)
/// — the card/panel rendering keys off [phase] instead.
enum PreviewSurface { none, panel, quickLook }

/// 06 §5's preview driver: the per-window owner of the Space/Esc state
/// machine (§5.2), the macOS Quick Look surface (§5.1), and every
/// remote production through the §5.3 cache.
///
/// The session listens to the workspace's focus chain (active pane →
/// active tab → selection) and re-evaluates on every identity change of
/// the FOCUSED item — cursor identity, never index snapshots, so a
/// listing refresh keeps the same target. Production state lives keyed
/// to the cache key, not the focused item: a download for an item the
/// user left keeps running to fill the cache (§5.2), and only the
/// queue row's Cancel or a re-focused Esc cancels it — never the focus
/// change itself.
final class PreviewSession extends ChangeNotifier {
  PreviewSession({
    required WorkspaceController workspace,
    required PreviewCache cache,
    required this.largeDownloadThresholdBytes,
    PreviewProducer? producer,
    QuickLookChannel? quickLook,
    TargetPlatform? platform,
  }) : _workspace = workspace,
       _cache = cache,
       _producer = producer,
       _quickLook = quickLook ?? const NoopQuickLookChannel(),
       _platform = platform ?? defaultTargetPlatform {
    _workspace.addListener(_onFocusChainChanged);
    _onFocusChainChanged();
  }

  final WorkspaceController _workspace;
  final PreviewCache _cache;
  final PreviewProducer? _producer;
  final QuickLookChannel _quickLook;
  final TargetPlatform _platform;

  /// The live large-download threshold (06 §8's shared setting, read at
  /// every gate decision so a settings change applies to the next
  /// production, never retroactively).
  final int Function() largeDownloadThresholdBytes;

  /// Whether a [PreviewProducer] is wired — the prompt card's Download
  /// button greys out without one (a queue-less boot still previews
  /// local files; remote rows keep their honest prompt).
  bool get canProduce => _producer != null;

  // -- State the panel renders ----------------------------------------

  PreviewPhase _phase = PreviewPhase.idle;

  /// The §5.2 state machine's current phase (meaningful only while the
  /// panel is visible — see [WorkspaceController.previewPanelHidden]).
  PreviewPhase get phase => _phase;

  /// The focused item the current phase belongs to; null in [idle].
  RemoteFileEntry? _entry;
  RemoteFileEntry? get entry => _entry;

  /// The pane [entry] came from — the card's Open/Open With verbs route
  /// back through it so a preview never launches a `preview-cache/`
  /// path (§5.3's open-boundary rule).
  PaneController? _pane;
  PaneController? get pane => _pane;

  PreviewKind _kind = PreviewKind.metadata;
  PreviewKind get kind => _kind;

  PreviewRefusal _refusal = PreviewRefusal.none;
  PreviewRefusal get refusal => _refusal;

  /// The rendered file once produced/local — text reads through [text],
  /// images and PDFs decode straight off [file].
  File? _file;
  File? get file => _file;

  PreviewTextContent? _text;
  PreviewTextContent? get text => _text;

  /// Byte progress for [producing]/[gateConfirm]; null totals render an
  /// indeterminate bar (unknown-size streams, §5.3).
  int _transferred = 0;
  int? _totalBytes;
  int get transferred => _transferred;
  int? get totalBytes => _totalBytes;

  /// The gate mid-park — the gateConfirm card's `Keep downloading`
  /// releases it.
  PreviewByteGate? _gate;

  /// The pending confirmation's byte size ([confirm] card copy).
  int _confirmBytes = 0;
  int get confirmBytes => _confirmBytes;

  /// Multi-selection header facts (§5.2): count, the summed size of the
  /// size-known entries, and whether any entry's size is unknown — the
  /// header reads `3 items · 142 MB · 1 size unknown`, never a silently
  /// incomplete total.
  int _selectionCount = 0;
  int _selectionBytes = 0;
  int _selectionUnknownSizes = 0;
  int get selectionCount => _selectionCount;
  int get selectionBytes => _selectionBytes;
  int get selectionUnknownSizes => _selectionUnknownSizes;

  /// Whether the macOS Quick Look surface currently owns Space — true
  /// from a successful show until the panel closes by any route.
  bool _quickLookActive = false;
  bool get quickLookActive => _quickLookActive;

  /// Whether the Quick Look leg asked for the native surface — true
  /// from the first remote Space (production still in flight, panel not
  /// yet shown) through close. A completed production delivers via
  /// `showPreview` when the panel never opened, `updatePreview` once it
  /// has — without this the first remote Space would produce the file
  /// and surface nothing.
  bool _quickLookRequested = false;

  /// Whether a Quick Look production card is showing — the window
  /// overlay (§5.1: the native panel cannot host Flutter content, so
  /// progress/confirm render as a non-blocking card over the owning
  /// pane's edge of the window).
  bool get quickLookCardVisible =>
      _quickLookCard != QuickLookCardKind.none;
  QuickLookCardKind _quickLookCard = QuickLookCardKind.none;
  QuickLookCardKind get quickLookCard => _quickLookCard;

  // -- Focus chain -----------------------------------------------------

  PaneTabsController? _boundStrip;
  PaneController? _boundTab;
  StreamSubscription<void>? _quickLookCloseSub;

  /// Identity of the focused item the current phase was evaluated for:
  /// (pane identity, cache-key-shaped string). A notify storm that
  /// leaves both intact is a no-op — the §5.2 phase survives.
  PaneController? _focusedPane;
  String? _focusedKey;

  /// §5.1's selection generation: every focused-item change bumps it;
  /// productions and confirmation cards tag themselves with the
  /// generation that requested them so a stale completion updates
  /// nothing (its file simply lands in the cache).
  int _generation = 0;

  /// In-flight productions by cache key — the dedupe map and the
  /// re-focused Esc's cancel target.
  final _productions = <String, _Production>{};

  /// Keys whose `_startProduction` sits inside `cache.prepare` — no
  /// ticket exists to cancel yet, so Esc flags [_startCancels] instead
  /// and the start aborts the slot as soon as it lands.
  final _pendingStarts = <String>{};
  final _startCancels = <String>{};

  /// Temp slots handed out but not yet committed or aborted — disposal
  /// sweeps them so a dying session leaves no `.part` behind.
  final _openSlots = <PreviewCacheSlot>{};

  /// 09 §3's disposed guard: the shell can tear the session down while
  /// a production/lookup/commit is still in flight, and a completion
  /// that then called [notifyListeners] would throw inside an
  /// unawaited future. Every async continuation and sync callback
  /// (progress, gate, close edge) early-returns on this.
  bool _disposed = false;

  void _onFocusChainChanged() {
    final strip = _workspace.activePane;
    if (!identical(strip, _boundStrip)) {
      _boundStrip?.removeListener(_onFocusChainChanged);
      strip.addListener(_onFocusChainChanged);
      _boundStrip = strip;
    }
    final tab = strip.activeTab?.controller;
    if (!identical(tab, _boundTab)) {
      _boundTab?.removeListener(_onFocusChainChanged);
      tab?.addListener(_onFocusChainChanged);
      _boundTab = tab;
    }
    _selectionChanged();
  }

  /// The focused item's identity key: the §5.3 cache key for remote
  /// rows (mtime+size self-invalidation included), the path for local.
  String _identityFor(PaneController pane, RemoteFileEntry entry) {
    final location = pane.location;
    if (location is RemotePaneLocation) {
      return previewCacheKey(
        location.serverId,
        entry.path,
        entry.modifiedAt,
        entry.size,
      );
    }
    return 'local:${entry.path}';
  }

  void _selectionChanged() {
    final pane = _boundTab;
    RemoteFileEntry? entry;
    if (pane != null && pane.verbsEnabled && !pane.staleRows) {
      final cursor = pane.cursorIndex;
      if (cursor != null && cursor >= 0 && cursor < pane.entries.length) {
        entry = pane.entries[cursor];
      }
      // No cursor but rows selected: the selection's primary stands in,
      // mirroring the inspector's target rule (02 §2.6).
      entry ??= pane.infoTarget;
    }
    final key = pane == null || entry == null
        ? null
        : _identityFor(pane, entry);
    final sameTarget =
        identical(pane, _focusedPane) && key != null && key == _focusedKey;
    _focusedPane = entry == null ? null : pane;
    _focusedKey = key;
    if (sameTarget) {
      _syncSelectionHeader(pane!);
      return;
    }
    _generation++;
    _entry = entry;
    _pane = entry == null ? null : pane;
    _syncSelectionHeader(pane);
    if (_quickLookActive) {
      _quickLookFollow();
      return;
    }
    if (_workspace.previewPanelHidden) return;
    _evaluate();
  }

  void _syncSelectionHeader(PaneController? pane) {
    final selected = pane?.selectedEntries ?? const <RemoteFileEntry>[];
    _selectionCount = selected.length;
    var bytes = 0;
    var unknown = 0;
    for (final item in selected) {
      if (item.size == null) {
        unknown++;
      } else {
        bytes += item.size!;
      }
    }
    _selectionBytes = bytes;
    _selectionUnknownSizes = unknown;
  }

  // -- The Space verb --------------------------------------------------

  /// `file.preview` (02 §8.3's Space, sel scope): Quick Look on macOS —
  /// always, since D32 moved the in-app preview into the inspector's
  /// Info tab, a passive well that follows the selection rather than a
  /// surface competing for Space — and the Info tab elsewhere. Returns
  /// false when nothing is previewable — the pane then lets the key
  /// fall through to ancestors.
  bool previewFocused() {
    final pane = _boundTab;
    if (pane == null || !pane.verbsEnabled) return false;
    final cursor = pane.cursorIndex;
    if (cursor == null || cursor < 0 || cursor >= pane.entries.length) {
      return false;
    }
    // The workspace's selection bookkeeping runs first so the verb
    // always acts on the row the type-ahead landed on (02 §8.2's
    // precedence rule).
    _selectionChanged();
    if (_platform == TargetPlatform.macOS) {
      return _quickLookVerb(pane);
    }
    return _panelVerb(pane);
  }

  bool get _panelHidden => _workspace.previewPanelHidden;

  /// The panel's Space leg (§5.2's state machine): open-and-evaluate
  /// when hidden; from the prompt card, start the download; rendered or
  /// promptless → close; confirmation and in-flight are no-ops.
  bool _panelVerb(PaneController pane) {
    if (_panelHidden) {
      _workspace.setPreviewPanelHidden(false);
      _evaluate();
      return true;
    }
    switch (_phase) {
      case PreviewPhase.prompt:
        unawaited(_startProduction(generation: _generation));
        return true;
      case PreviewPhase.confirm:
      case PreviewPhase.gateConfirm:
      case PreviewPhase.producing:
        return true;
      case PreviewPhase.idle:
      case PreviewPhase.rendered:
        closePanel();
        return true;
    }
  }

  /// The Quick Look leg (§5.1): Space toggles the native panel — local
  /// multi-selections send every selected path with the focused index;
  /// remote selections produce the focused item first. A mid-flight
  /// production or a showing overlay card makes Space a no-op (§5.2's
  /// in-flight/confirmation-pending rule applies to this surface too).
  bool _quickLookVerb(PaneController pane) {
    if (_quickLookActive) {
      _hideQuickLook();
      return true;
    }
    if (_quickLookRequested ||
        _quickLookCard != QuickLookCardKind.none) {
      return true;
    }
    unawaited(_quickLookOpen(pane));
    return true;
  }

  // -- Esc tier ---------------------------------------------------------

  /// The pane's Esc-tier slot (02 §8.2's total order: preview sits above
  /// the field surfaces). One press fires one tier — the card's answer,
  /// the production's cancel, or the surface's close — and true marks
  /// the press consumed. Quick Look's native panel owns its own Esc;
  /// this only ever sees the in-app states.
  bool escape() {
    if (_quickLookActive || _quickLookCard != QuickLookCardKind.none) {
      // A parked gate card or in-flight production under Quick Look:
      // Esc answers it — the native panel stays up (its own Esc closes
      // it and cancels via the close edge).
      switch (_quickLookCard) {
        case QuickLookCardKind.confirm:
          _quickLookCard = QuickLookCardKind.none;
          // Answering a Quick Look card retracts the pending request
          // unless the surface itself is still open — otherwise a late
          // completion would deliver into showPreview the user just
          // declined, and a never-opened request would wedge Space
          // into a permanent no-op.
          _quickLookRequested = _quickLookActive;
          notifyListeners();
          return true;
        case QuickLookCardKind.gateConfirm:
          _gate?.deny();
          _quickLookCard = QuickLookCardKind.none;
          _quickLookRequested = _quickLookActive;
          notifyListeners();
          return true;
        case QuickLookCardKind.producing:
          _quickLookRequested = _quickLookActive;
          _cancelProduction();
          return true;
        case QuickLookCardKind.refused:
          // The metadata refusal card dismisses under Quick Look like
          // the panel's promptless cards — the native surface stays up.
          _quickLookCard = QuickLookCardKind.none;
          _quickLookRequested = _quickLookActive;
          notifyListeners();
          return true;
        case QuickLookCardKind.none:
          _hideQuickLook();
          return true;
      }
    }
    if (_panelHidden) return false;
    switch (_phase) {
      case PreviewPhase.confirm:
        // Esc answers the card's Cancel — the panel stays open on the
        // prompt state it arrived from (§5.2).
        denyDownload();
        return true;
      case PreviewPhase.gateConfirm:
        _gate?.deny();
        _phase = PreviewPhase.producing;
        notifyListeners();
        return true;
      case PreviewPhase.producing:
        _cancelProduction();
        return true;
      case PreviewPhase.idle:
      case PreviewPhase.prompt:
      case PreviewPhase.rendered:
        // D32: the preview lives in the inspector column, which is
        // persistent chrome — Esc never closes it (10 §2's "nothing
        // blocks the view"): the press falls through to lower tiers.
        return false;
    }
  }

  // -- Panel verbs ------------------------------------------------------

  /// `view.togglePreview` (⌥⌘P / Ctrl+Alt+P): opens the docked panel —
  /// which on macOS suppresses Quick Look's claim on Space — or closes
  /// it, running the surface-close cache sweep either way (§5.3).
  void togglePanel() {
    if (_panelHidden) {
      _workspace.setPreviewPanelHidden(false);
      _evaluate();
      return;
    }
    closePanel();
  }

  /// The ✕ affordance and the state machine's close: production keeps
  /// running silently into the cache (§5.1/§5.2), and the close sweep
  /// retries any unlink an open handle blocked.
  void closePanel() {
    if (_panelHidden) return;
    _workspace.setPreviewPanelHidden(true);
    _phase = PreviewPhase.idle;
    _refusal = PreviewRefusal.none;
    _file = null;
    _text = null;
    _gate = null;
    notifyListeners();
    unawaited(_cache.sweepTemps());
  }

  /// The prompt/confirm card's Download and the gate card's "Keep
  /// downloading" — phase-scoped so a stale card never releases the
  /// wrong gate.
  void confirmDownload() {
    switch (_phase) {
      case PreviewPhase.confirm:
        unawaited(_startProduction(generation: _generation));
      case PreviewPhase.gateConfirm:
        _gate?.confirm();
        _phase = PreviewPhase.producing;
        notifyListeners();
      case PreviewPhase.prompt:
        unawaited(_startProduction(generation: _generation));
      default:
        break;
    }
  }

  /// The confirm card's Cancel — and the gate card's (§5.3's `Cancel` /
  /// `Keep downloading`): a declined up-front confirmation returns to
  /// the prompt card; a denied gate aborts the stream, whose failure
  /// path then lands the same prompt card (§5.2's failed/cancelled
  /// rule).
  void denyDownload() {
    if (_phase == PreviewPhase.gateConfirm) {
      _gate?.deny();
      _phase = PreviewPhase.producing;
      notifyListeners();
      return;
    }
    if (_phase != PreviewPhase.confirm) return;
    _phase = PreviewPhase.prompt;
    notifyListeners();
  }

  /// The progress card's Cancel — and a re-focused Esc's: trips the
  /// produce task's queue-level cancel (the row's Cancel verb and this
  /// are the same machinery, §5.2).
  void cancelProduction() => _cancelProduction();

  void _cancelProduction() {
    final key = _focusedKey;
    final production = key == null ? null : _productions[key];
    if (production != null) {
      _producer?.cancel(production.ticket.taskId);
      return;
    }
    // Esc inside the slot-prepare window: the produce task does not
    // exist yet, so flag the start — it aborts the moment the temp
    // lands rather than launching work the user already cancelled.
    if (key != null && _pendingStarts.contains(key)) {
      _startCancels.add(key);
      if (_quickLookCard != QuickLookCardKind.none) {
        _quickLookCard = QuickLookCardKind.none;
        notifyListeners();
      } else {
        _refusal = PreviewRefusal.cancelled;
        _setPhase(PreviewPhase.prompt);
      }
      return;
    }
    // The Quick Look surface's in-flight production.
    for (final production in _productions.values) {
      _producer?.cancel(production.ticket.taskId);
    }
  }

  // -- Evaluation -------------------------------------------------------

  /// Re-derives the panel's phase for the current focused item — the
  /// §5.2 focus-change rule: cached or local renders immediately, an
  /// uncached previewable remote shows the prompt, refused-from-
  /// metadata kinds show the promptless card.
  void _evaluate() {
    final pane = _pane;
    final entry = _entry;
    if (pane == null || entry == null) {
      _setPhase(PreviewPhase.idle);
      return;
    }
    _syncSelectionHeader(pane);
    final location = pane.location;
    _refusal = PreviewRefusal.none;
    _file = null;
    _text = null;
    _gate = null;
    _transferred = 0;
    _totalBytes = null;

    if (location is! RemotePaneLocation) {
      _evaluateLocal(entry);
      return;
    }
    _evaluateRemote(entry, location.serverId);
  }

  void _evaluateLocal(RemoteFileEntry entry) {
    if (entry.isDirectory) {
      _kind = PreviewKind.metadata;
      _setPhase(PreviewPhase.rendered);
      return;
    }
    final kind = previewKindForName(entry.name);
    _kind = kind;
    final file = File(entry.path);
    switch (kind) {
      case PreviewKind.text:
        _loadText(file, _generation);
      case PreviewKind.image || PreviewKind.pdf:
        _renderFile(file, kind, _generation);
      case _:
        // Extensionless/unknown local names get the unknown-but-UTF-8
        // re-check (§5.3): bytes are local and free to read.
        _sniffLocal(file, _generation);
    }
  }

  void _evaluateRemote(RemoteFileEntry entry, String serverId) {
    if (entry.isDirectory) {
      _kind = PreviewKind.metadata;
      _setPhase(PreviewPhase.rendered);
      return;
    }
    final kind = previewKindForName(entry.name);
    _kind = kind;
    if (kind == PreviewKind.metadata || !previewKindIsRenderable(kind)) {
      // The Everything-else card row never prompts (§5.3): metadata is
      // all a remote row has before a download, and the unknown-but-
      // UTF-8 case is the accepted v1 gap.
      _setPhase(PreviewPhase.rendered);
      return;
    }
    // Metadata refusals run before any download is queued (§5.3): the
    // cache cap first, then the kind's own decode cap.
    final size = entry.size;
    if (size != null && !_cache.canAccommodate(size)) {
      _refusal = PreviewRefusal.overCacheCap;
      _setPhase(PreviewPhase.rendered);
      return;
    }
    final kindCap = previewKindCapBytes(kind);
    if (size != null && kindCap != null && size > kindCap) {
      _refusal = PreviewRefusal.overKindCap;
      _setPhase(PreviewPhase.rendered);
      return;
    }
    final key = _focusedKey!;
    unawaited(
      _cache.lookup(key).then((file) {
        if (_disposed) return;
        if (!identical(_focusedPane, pane) || _focusedKey != key) return;
        if (file == null) {
          // An in-flight production for this key re-attaches — rapid
          // paging back to the item shows live progress, never a second
          // task (§5.3's dedupe).
          final production = _productions[key];
          if (production != null) {
            _transferred = production.transferred;
            _totalBytes = production.total;
            _gate = production.gate;
            _setPhase(
              production.gate != null &&
                      production.gate!.isAwaitingConfirmation
                  ? PreviewPhase.gateConfirm
                  : PreviewPhase.producing,
            );
            return;
          }
          _setPhase(PreviewPhase.prompt);
          return;
        }
        if (kind == PreviewKind.text) {
          unawaited(_loadText(file, _generation));
        } else {
          unawaited(_renderFile(file, kind, _generation));
        }
      }).catchError((Object error) {
        // A cache read failure is not a production failure — fall back
        // to the prompt so a retry still exists.
        if (_disposed) return;
        if (_focusedKey == key) {
          _refusal = PreviewRefusal.failed;
          _setPhase(PreviewPhase.prompt);
        }
      }),
    );
  }

  Future<void> _sniffLocal(File file, int generation) async {
    try {
      if (await fileLooksLikeUtf8Text(file)) {
        if (_disposed) return;
        _kind = PreviewKind.text;
        await _loadText(file, generation);
        return;
      }
    } on FileSystemException {
      if (_disposed || _generation != generation) return;
      _refusal = PreviewRefusal.missing;
      _setPhase(PreviewPhase.rendered);
      return;
    }
    if (_disposed || _generation != generation) return;
    _setPhase(PreviewPhase.rendered);
  }

  Future<void> _loadText(File file, int generation) async {
    try {
      final content = await loadPreviewText(file);
      if (_disposed || _generation != generation) return;
      _text = content;
      _file = file;
      _setPhase(PreviewPhase.rendered);
    } on BuiltInEditorException {
      if (_disposed || _generation != generation) return;
      _refusal = PreviewRefusal.notText;
      _file = file;
      _setPhase(PreviewPhase.rendered);
    } on FileSystemException {
      if (_disposed || _generation != generation) return;
      _refusal = PreviewRefusal.missing;
      _setPhase(PreviewPhase.rendered);
    }
  }

  /// The image/PDF render step: file-size guards run against the LOCAL
  /// produced file too — a cap lowered mid-flight can land bytes the
  /// listing's size never predicted.
  Future<void> _renderFile(File file, PreviewKind kind, int generation) async {
    try {
      final length = await file.length();
      if (_disposed || _generation != generation) return;
      final kindCap = previewKindCapBytes(kind);
      if (kindCap != null && length > kindCap) {
        _refusal = PreviewRefusal.overKindCap;
        _setPhase(PreviewPhase.rendered);
        return;
      }
      _file = file;
      _setPhase(PreviewPhase.rendered);
    } on FileSystemException {
      if (_disposed || _generation != generation) return;
      _refusal = PreviewRefusal.missing;
      _setPhase(PreviewPhase.rendered);
    }
  }

  void _setPhase(PreviewPhase next) {
    _phase = next;
    notifyListeners();
  }

  // -- Production --------------------------------------------------------

  /// Starts (or attaches to) the focused item's remote production —
  /// the §5.3 prompt card's Space/button and the §8 threshold confirm's
  /// Download share this. Over-threshold known sizes land on the
  /// confirm card first; unknown sizes run under the mid-stream gate.
  Future<void> _startProduction({required int generation}) async {
    final producer = _producer;
    final pane = _pane;
    final entry = _entry;
    final key = _focusedKey;
    final location = pane?.location;
    if (producer == null ||
        pane == null ||
        entry == null ||
        key == null ||
        location is! RemotePaneLocation) {
      return;
    }
    // The §8 up-front gate: a KNOWN size over the threshold confirms
    // before any bytes move (the unknown-size case rides the stream
    // gate instead — it cannot be decided up front).
    final size = entry.size;
    final threshold = largeDownloadThresholdBytes();
    if (_phase == PreviewPhase.prompt &&
        size != null &&
        size > threshold) {
      _confirmBytes = size;
      _setPhase(PreviewPhase.confirm);
      return;
    }
    if (_productions.containsKey(key)) {
      _setPhase(PreviewPhase.producing);
      return;
    }
    _pendingStarts.add(key);
    final PreviewCacheSlot slot;
    try {
      slot = await _cache.prepare(
        key,
        extension: previewRawExtension(entry.name),
        expectedBytes: size,
      );
    } on Object {
      _pendingStarts.remove(key);
      _startCancels.remove(key);
      if (_disposed) return;
      _refusal = PreviewRefusal.failed;
      _setPhase(PreviewPhase.prompt);
      return;
    }
    _pendingStarts.remove(key);
    if (_disposed || _startCancels.remove(key)) {
      // Esc landed while the temp was being prepared — drop the slot,
      // never the task (§5.2's cancel-before-bytes rule). A disposed
      // session aborts it the same way: the slot is ours alone and a
      // late prepare must not leak a live temp past dispose's sweep.
      await slot.abort();
      return;
    }
    _openSlots.add(slot);

    // Unknown-size streams carry the kind cap where one exists (image/
    // PDF) and the preview-cache cap otherwise, plus the mid-stream
    // threshold gate (§5.3).
    final kindCap = previewKindCapBytes(_kind);
    final maximumBytes = size == null
        ? (kindCap ?? _cache.capacityBytes)
        : null;
    final PreviewByteGate? gate = size == null
        ? PreviewByteGate(
            thresholdBytes: threshold,
            onThresholdReached: (transferred) {
              if (_disposed) return;
              _transferred = transferred;
              if (_generation == generation &&
                  _phase == PreviewPhase.producing) {
                _setPhase(PreviewPhase.gateConfirm);
              } else if (_quickLookCard == QuickLookCardKind.producing) {
                _quickLookCard = QuickLookCardKind.gateConfirm;
                notifyListeners();
              }
            },
          )
        : null;
    _gate = gate;
    final ticket = producer.start(
      PreviewProduceSpec(
        serverId: location.serverId,
        remotePath: entry.path,
        destinationPath: slot.tempFile.path,
        expectedSize: size,
        maximumBytes: maximumBytes,
        gate: gate,
        onProgress: (transferred, total) {
          if (_disposed) return;
          final production = _productions[key];
          if (production != null) {
            production.transferred = transferred;
            production.total = total;
          }
          if (_focusedKey == key && _phase == PreviewPhase.producing) {
            _transferred = transferred;
            _totalBytes = total;
            notifyListeners();
          }
          if (_quickLookCard == QuickLookCardKind.producing) {
            _transferred = transferred;
            _totalBytes = total;
            notifyListeners();
          }
        },
      ),
    );
    final production = _Production(
      ticket: ticket,
      slot: slot,
      generation: generation,
      entry: entry,
      serverId: location.serverId,
    )..gate = gate;
    _productions[key] = production;
    if (_phase != PreviewPhase.gateConfirm) {
      _setPhase(PreviewPhase.producing);
    }
    try {
      await ticket.result;
      if (_disposed) return; // dispose() already aborted the slot
      _openSlots.remove(slot);
      // Commit always runs — a stale generation's file lands in the
      // cache for a later preview (§5.1/§5.2's close rule).
      final file = await slot.commit();
      if (_disposed) return;
      _productions.remove(key);
      if (!await file.exists()) {
        // The commit's own enforce pass evicted the just-committed
        // bytes — they alone exceeded the cap. That is the §5.3
        // over-cap refusal, not a vanished file.
        _gate = null;
        _refusal = PreviewRefusal.overCacheCap;
        if (_quickLookCard != QuickLookCardKind.none) {
          _quickLookCard = QuickLookCardKind.refused;
          notifyListeners();
        } else if (_generation == generation && !_panelHidden) {
          _setPhase(PreviewPhase.rendered);
        }
        return;
      }
      if (_generation == generation) {
        _gate = null;
        if (_kind == PreviewKind.text) {
          unawaited(_loadText(file, generation));
        } else {
          unawaited(_renderFile(file, _kind, generation));
        }
      }
      if (_quickLookRequested || _quickLookActive) {
        unawaited(_quickLookDeliver(production, file));
      }
    } on Object catch (error) {
      _openSlots.remove(slot);
      _productions.remove(key);
      await slot.abort();
      _gate = null;
      if (_disposed) return;
      // The unknown-size stream cap arrives typed (the produce seam's
      // suffix-pin): render the §5.3 over-cap refusal, never a
      // retryable failure — Space on a prompt would re-download the
      // same bytes into the same cap forever.
      final overCap =
          error is CheckoutLimitException && maximumBytes != null;
      final capRefusal = maximumBytes == kindCap
          ? PreviewRefusal.overKindCap
          : PreviewRefusal.overCacheCap;
      if (_quickLookCard != QuickLookCardKind.none) {
        // A cancelled/failed Quick Look production leaves the native
        // panel on its previous item — the card clears, the surface
        // stays (§5.1's "keeps the current item visible"); a refused
        // one shows the refusal card instead, which reads _refusal —
        // the docked panel stays hidden under Quick Look, so set it
        // here rather than inside the panel-hidden guard below.
        if (overCap) _refusal = capRefusal;
        _quickLookCard =
            overCap ? QuickLookCardKind.refused : QuickLookCardKind.none;
        notifyListeners();
      }
      if (_generation == generation && !_panelHidden) {
        // Failed or cancelled → the prompt card returns so Space
        // retries (§5.2); a cap refusal renders the promptless card.
        _refusal = overCap
            ? capRefusal
            : error is RemoteFileException &&
                  error.kind == RemoteFileErrorKind.cancelled
            ? PreviewRefusal.cancelled
            : PreviewRefusal.failed;
        _setPhase(overCap ? PreviewPhase.rendered : PreviewPhase.prompt);
      }
    }
  }

  // -- Quick Look --------------------------------------------------------

  Future<void> _quickLookOpen(PaneController pane) async {
    if (!await _quickLook.isAvailable()) {
      if (_disposed) return;
      // Channel absent on a non-macOS host or a headless test — the
      // panel is the honest fallback surface.
      _workspace.setPreviewPanelHidden(false);
      _evaluate();
      return;
    }
    if (_disposed) return;
    final location = pane.location;
    final cursor = pane.cursorIndex!;
    if (location is RemotePaneLocation) {
      // §5.1: remote selections preview the FOCUSED item only in v1.
      _quickLookRequested = true;
      await _quickLookProduce(pane, pane.entries[cursor]);
      return;
    }
    final selected = pane.selectedEntries;
    final items = selected.isEmpty ? [pane.entries[cursor]] : selected;
    final paths = [for (final item in items) item.path];
    final index = items.indexWhere(
      (item) => item.path == pane.entries[cursor].path,
    );
    await _quickLook.showPreview(paths, index < 0 ? 0 : index);
    if (_disposed) return;
    _quickLookRequested = true;
    _quickLookActive = true;
    _quickLookListenClose();
    notifyListeners();
  }

  /// §5.1's selection-follow while the native panel is open: local
  /// items update immediately; a remote item not yet cached keeps the
  /// current item visible while its production runs — gated by §8's
  /// confirmation card (the non-blocking overlay) — and only a
  /// current-generation completion ever calls `updatePreview`.
  void _quickLookFollow() {
    final pane = _boundTab;
    if (pane == null || !pane.verbsEnabled) {
      _hideQuickLook();
      return;
    }
    final cursor = pane.cursorIndex;
    if (cursor == null || cursor >= pane.entries.length) {
      _hideQuickLook();
      return;
    }
    final location = pane.location;
    if (location is RemotePaneLocation) {
      _quickLookRequested = true;
      unawaited(_quickLookProduce(pane, pane.entries[cursor]));
      return;
    }
    final selected = pane.selectedEntries;
    final items = selected.isEmpty ? [pane.entries[cursor]] : selected;
    final paths = [for (final item in items) item.path];
    final index = items.indexWhere(
      (item) => item.path == pane.entries[cursor].path,
    );
    unawaited(_quickLook.updatePreview(paths, index < 0 ? 0 : index));
  }

  /// Produces the remote focused item for Quick Look (§5.1): cached
  /// hits deliver immediately; misses run the production under the
  /// overlay card (progress, then the threshold card when the gate
  /// parks) — the previous item stays visible in the panel meanwhile.
  Future<void> _quickLookProduce(
    PaneController pane,
    RemoteFileEntry entry,
  ) async {
    final location = pane.location as RemotePaneLocation;
    // A remote directory has no producible bytes — the native panel
    // keeps its current item (§5.1's keep-visible rule) rather than
    // queuing a download that cannot run. The request flag collapses
    // back to whether the surface is actually up, so a declined or
    // never-opened request can't make a later completion pop the
    // panel (or wedge Space into a permanent no-op).
    if (entry.isDirectory) {
      _quickLookRequested = _quickLookActive;
      return;
    }
    final key = previewCacheKey(
      location.serverId,
      entry.path,
      entry.modifiedAt,
      entry.size,
    );
    final generation = _generation;
    final size = entry.size;
    // The metadata refusals apply to Quick Look productions too — the
    // overlay card carries them (QL renders kinds the panel cannot, so
    // only the cache cap gates here; §5.3).
    if (size != null && !_cache.canAccommodate(size)) {
      _quickLookCard = QuickLookCardKind.refused;
      _refusal = PreviewRefusal.overCacheCap;
      _entry = entry;
      _pane = pane;
      _kind = previewKindForName(entry.name);
      notifyListeners();
      return;
    }
    final cached = await _cache.lookup(key);
    if (_disposed) return;
    if (cached != null) {
      if (_quickLookActive) {
        await _quickLook.updatePreview([cached.path], 0);
      } else {
        await _quickLook.showPreview([cached.path], 0);
        if (_disposed) return;
        _quickLookActive = true;
        _quickLookListenClose();
      }
      return;
    }
    // Up-front §8 gate on a known size; the mid-stream gate covers the
    // unknown-size case inside _startProduction.
    if (size != null && size > largeDownloadThresholdBytes()) {
      _quickLookCard = QuickLookCardKind.confirm;
      _confirmBytes = size;
      _entry = entry;
      _pane = pane;
      _kind = previewKindForName(entry.name);
      notifyListeners();
      return;
    }
    _quickLookCard = QuickLookCardKind.producing;
    _transferred = 0;
    _totalBytes = size;
    _entry = entry;
    _pane = pane;
    _kind = previewKindForName(entry.name);
    notifyListeners();
    await _startProduction(generation: generation);
  }

  /// Delivers a completed Quick Look production to the native panel —
  /// gated on the surface still being requested AND the production's
  /// generation still being live (§5.1's stale-completion rule). The
  /// first remote Space opens the panel here; a mid-session completion
  /// updates it.
  Future<void> _quickLookDeliver(_Production production, File file) async {
    if (_disposed ||
        !_quickLookRequested ||
        production.generation != _generation) {
      return;
    }
    if (_quickLookActive) {
      await _quickLook.updatePreview([file.path], 0);
    } else {
      await _quickLook.showPreview([file.path], 0);
    }
    if (_disposed) return;
    if (!_quickLookActive) {
      _quickLookActive = true;
      _quickLookListenClose();
    }
    _quickLookCard = QuickLookCardKind.none;
    notifyListeners();
  }

  void _quickLookListenClose() {
    _quickLookCloseSub ??= _quickLook.onClosed.listen((_) {
      if (_disposed) return;
      _quickLookActive = false;
      _quickLookRequested = false;
      _quickLookCard = QuickLookCardKind.none;
      notifyListeners();
      // The surface-close sweep (§5.3): released handles unblock the
      // evictions a previous pass tolerated.
      unawaited(_cache.sweepTemps());
    });
  }

  void _hideQuickLook() {
    _quickLookActive = false;
    _quickLookRequested = false;
    _quickLookCard = QuickLookCardKind.none;
    unawaited(_quickLook.hidePreview());
    unawaited(_cache.sweepTemps());
    notifyListeners();
  }

  /// The overlay card's Download answer (Quick Look surface): starts
  /// the production the card gated.
  void quickLookConfirm() {
    if (_quickLookCard != QuickLookCardKind.confirm) return;
    _quickLookCard = QuickLookCardKind.producing;
    notifyListeners();
    unawaited(_startProduction(generation: _generation));
  }

  /// The overlay card's Cancel: drops the pending production — the
  /// native panel keeps showing the previous item (§5.1).
  void quickLookDeny() {
    if (_quickLookCard == QuickLookCardKind.gateConfirm) {
      _gate?.deny();
    }
    _quickLookCard = QuickLookCardKind.none;
    // The decline retracts the pending request — collapse the flag to
    // whether the surface is actually up, else a same-generation
    // production could still deliver into showPreview (and a
    // never-opened request would wedge Space into a no-op).
    _quickLookRequested = _quickLookActive;
    notifyListeners();
  }

  /// The gate card's "Keep downloading" on the Quick Look surface.
  void quickLookKeepDownloading() {
    if (_quickLookCard != QuickLookCardKind.gateConfirm) return;
    _gate?.confirm();
    _quickLookCard = QuickLookCardKind.producing;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _workspace.removeListener(_onFocusChainChanged);
    _boundStrip?.removeListener(_onFocusChainChanged);
    _boundTab?.removeListener(_onFocusChainChanged);
    unawaited(_quickLookCloseSub?.cancel());
    for (final slot in _openSlots) {
      unawaited(slot.abort());
    }
    _openSlots.clear();
    _productions.clear();
    super.dispose();
  }
}

/// The Quick Look surface's overlay-card kinds (§5.1): confirmation for
/// a known-size over-threshold production, the parked-gate card for an
/// unknown-size one, progress while bytes move, and the metadata
/// refusal.
enum QuickLookCardKind { none, confirm, gateConfirm, producing, refused }
