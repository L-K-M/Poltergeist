import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerCancelEvent,
        kDoubleTapSlop,
        kDoubleTapTimeout,
        kPrimaryMouseButton,
        kSecondaryMouseButton,
        kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/checkout_session.dart';
import '../../services/drag_out_controller.dart';
import '../../services/pane_controller.dart';
import '../../services/pane_drop.dart';
import '../../services/pane_location.dart';
import '../../services/pane_permissions.dart' show nameIsFlagged;
import '../../services/pane_tabs_controller.dart';
import '../../services/preview_session.dart';
import '../../services/quick_connect_address.dart';
import '../../services/quick_select_state.dart';
import '../../services/registered_command.dart';
import '../../services/selection_state.dart';
import '../../services/sync_browsing_controller.dart';
import '../../services/view_preferences.dart' show PaneViewMode;
import '../../services/workspace_controller.dart';
import '../../theme/app_theme.dart';
import '../local_edits_review.dart';
import '../server_appearance.dart';
import 'pane_column_header.dart';
import 'pane_context_menu.dart';
import 'pane_drop_area.dart';
import 'pane_format.dart';
import 'save_favorite_bar.dart';
import 'sync_browse_chip.dart';

/// 02 §2.8's anti-flash grace: no spinner, dim, loading line, or cancel
/// affordance before this, so fast navigations never flash.
const _antiFlashGrace = Duration(milliseconds: 150);

/// Whether a remote bind is in flight for this pane — the single
/// definition shared by the Esc key path and the post-grace Cancel
/// action, so the two affordances can never drift apart.
bool _pendingRemoteConnect(PaneController controller) =>
    controller.phase == PanePhase.connectingRemote &&
    controller.remoteBookmark != null;

/// The adhoc bookmark qualifying for 02 §2.7's "Save as favorite…"
/// bar: a live adhoc session past a successful connect — null while
/// connecting, failed, local, or bound to a stored favorite.
Bookmark? _saveBarBookmark(PaneController controller) {
  final bookmark = controller.remoteBookmark;
  if (bookmark == null) return null;
  if (!bookmark.id.startsWith(quickConnectAdhocIdPrefix)) return null;
  if (controller.phase != PanePhase.browsing) return null;
  return bookmark;
}

/// 02 §2.5's type-ahead input filter: the pane's printable text for a
/// key event, or null when the key produces none. Space never
/// accumulates — it is reserved for file.preview (§2.6), so names
/// containing spaces match by their non-space prefix — and neither do
/// control characters (C0 range and DEL).
String? _typeAheadCharacter(KeyEvent event) {
  final character = event.character;
  if (character == null || character.isEmpty) return null;
  for (final rune in character.runes) {
    if (rune <= 0x20 || (rune >= 0x7f && rune <= 0x9f)) return null;
  }
  return character;
}

/// D32 §6's row extent — 22 px on desktop, 48 on touch
/// ([PoltergeistChrome.rowExtent]) — scaled by the active text scale so
/// scaled text never clips (D20). Recomputed per build, which preserves
/// the fixed-extent virtualization. One definition, shared by the row
/// extent, the drop zone's hit math, and the cursor-reveal scroll
/// arithmetic.
double scaledPaneRowExtent(BuildContext context) => MediaQuery.textScalerOf(
  context,
).scale(PoltergeistChrome.of(context).rowExtent);

/// Whether rows take touch gestures (D32 §9: a tap opens, a long-press
/// selects and opens the action sheet) rather than desktop pointer
/// gestures (select on pointer-down, double-click opens).
bool _touchRows(BuildContext context) =>
    !isDesktopPlatform(Theme.of(context).platform);

/// One pane's browsing surface (D32 §6's anatomy): the location header
/// (folder name with its ancestor menu, the item/selection summary, the
/// sync-browsing chip and loading affordances), one banner slot, the
/// sortable column header, and fixed-extent listing rows that select
/// on pointer-down — plus inline errors over cached entries,
/// latency-honest loading states, the registry-built context menu, and
/// the keyboard-first interactions (arrows, Enter, Esc, Tab, Home/End,
/// Backspace, Shift+F10 — 02 §8.2 scoped to the pane's focus node).
///
/// The pane never blocks the UI isolate (D8): every byte of file data
/// crosses through the engine channel the controller drives.
class PaneView extends StatefulWidget {
  const PaneView({
    super.key,
    required this.controller,
    required this.pane,
    required this.workspace,
    required this.focusNode,
    required this.onSwapFocus,
    required this.onCancelRecovery,
    this.bookmarks,
    this.dropDelegate,
    this.dragOut,
    this.supportsOsDrop,
    this.preview,
    this.checkoutSession,
    this.onReviewLocalEdits,
    this.commands,
    this.onRunCommand,
    this.clock = _systemClock,
  });

  final PaneController controller;

  /// The pane strip owning [controller]'s tab — pane identity, ordering,
  /// and activity live at the strip level (02 §3).
  final PaneTabsController pane;

  /// The workspace that owns pane activity: the active pane drives the
  /// accent path (02 §2.1) and receives pane-scoped commands.
  final WorkspaceController workspace;

  /// This pane's listing focus node (02 §8.2: one FocusScope per pane).
  final FocusNode focusNode;

  /// `pane.swapFocus`: activates the other pane and moves focus there —
  /// the shell owns both nodes, so it wires the pair.
  final VoidCallback onSwapFocus;

  /// The connection-lost banner's cancel, routed by the shell: with a
  /// sibling pane on the same server it detaches only this pane
  /// (disconnectServer would sever the shared transport); alone it
  /// drops the server reference so recovery stops.
  final VoidCallback onCancelRecovery;

  /// The bookmark persistence seam for the "Save as favorite…" bar
  /// (02 §2.7): null where no store is wired, and the bar's save then
  /// posts the honest not-yet notice instead of a fake write.
  final BookmarkStore? bookmarks;

  /// The drop enqueue seam (02 §5.1, D14): null leaves rows undraggable
  /// and both drop targets refusing — no queue means nowhere to land a
  /// task.
  final PaneDropDelegate? dropDelegate;

  /// OS drag-out (00 D14's 2026-09-25 amendment): a row drag whose
  /// pointer leaves the window is handed to this controller's native
  /// session, and a drop of that session coming back into the pane is
  /// routed with the in-app verb rules. Null keeps every drag in-app.
  final DragOutController? dragOut;

  /// Whether the OS drop-in `DropTarget` mounts — null defers to the
  /// platform default (desktop_drop serves Linux/macOS/Windows only).
  final bool? supportsOsDrop;

  /// The 06 §5 preview driver: this pane's Space dispatches to it and
  /// its Esc tier sits at the top of [_handleEscapeTier]. Null leaves
  /// Space falling through to ancestors — the same posture the pane
  /// held before a session existed.
  final PreviewSession? preview;

  /// The managed-checkout truth behind 06 §3.7's local-edits banner —
  /// null leaves the banner unmounted (a shell without a checkout
  /// session owns no edits to surface).
  final CheckoutSession? checkoutSession;

  /// The banner's `Review…`, resolved by the shell with the pane's
  /// bound server id — the shell owns the modal.
  final void Function(String serverId)? onReviewLocalEdits;

  /// The registry the context menu renders from (D32 §6, D21): the
  /// shell's command list. Null (or a null [onRunCommand]) mounts no
  /// context menu — a pane without a registry has no verbs to offer.
  final List<RegisteredCommand>? commands;

  /// Runs a context-menu row through the shell's runner, so enablement
  /// and error reporting match the menus and chords.
  final Future<void> Function(RegisteredCommand command)? onRunCommand;

  /// Injectable clock for deterministic relative-date rendering.
  final DateTime Function() clock;

  static DateTime _systemClock() => DateTime.now();

  @override
  State<PaneView> createState() => _PaneViewState();
}

class _PaneViewState extends State<PaneView> {
  final _scrollController = ScrollController();
  // Memoized: ListenableBuilder compares by identity, so a per-build
  // merge would churn both subscriptions on every cursor move. Refreshed
  // in didUpdateWidget — a session swap replaces the controllers under a
  // reused element.
  late Listenable _listenable = _merged();

  Listenable _merged() => Listenable.merge([
    widget.controller,
    widget.workspace,
    // 02 §7's link chip state — suspension transitions must repaint the
    // location header even when the pane's own controller did not
    // change.
    widget.workspace.syncBrowsing,
    // 06 §3.7's banner follows the checkout truth: a dirty edge takes
    // the banner slot, a clean upload frees it — neither comes through
    // the pane controller.
    ?widget.checkoutSession,
  ]);
  Timer? _graceTimer;
  bool _pastGrace = false;

  /// Whether the OTHER pane's location header shows a link chip right
  /// now: that pane is on screen and its visible tab is anchored.
  bool _otherPaneShowsSyncChip() {
    final workspace = widget.workspace;
    final isLeft = widget.pane.isLeftPane;
    if (isLeft && !workspace.secondPaneShown) return false;
    final other = isLeft ? workspace.right : workspace.left;
    return other.activeTab?.controller.syncAnchorActive ?? false;
  }
  bool _disposed = false;
  bool _quickSelectWasActive = false;
  final _quickSelectFieldKey = GlobalKey();
  // The path field's focus node and invocation bookkeeping, owned here
  // for the same reason as the filter's: `go.editPath`/`go.toFolder`
  // re-invocations must re-focus (and the view re-seeds) an
  // already-mounted field (02 §2.1).
  final _pathFieldFocusNode = FocusNode();
  final _pathFieldStripKey = GlobalKey();
  int _pathFieldSeen = -1;
  bool _pathFieldWasOpen = false;
  // The inline-rename editor's hit-test boundary (clicks inside it must
  // not bounce focus to the listing) and its close bookkeeping, both
  // mirroring the other field strips (02 §2.6).
  final _renameEditorKey = GlobalKey();
  bool _renameWasActive = false;
  String? _revealedLocationPath;
  List<RemoteFileEntry>? _revealedEntries;
  // D14's drop plumbing: the listing's ListView key (row hit-testing
  // resolves through its render box) and the folder row a live drag
  // hover targets, reported up from the drop zone so the row paints
  // the highlight (02 §5.1).
  final _listAreaKey = GlobalKey();
  int? _dropTargetRow;

  // D32 §6's context menu: one anchor over the whole pane surface,
  // opened at the pointer (or the cursor row for Shift+F10), with the
  // section list chosen by what the press landed on.
  final _contextMenu = MenuController();
  final _contextMenuAnchorKey = GlobalKey();
  final _contextMenuFirstItem = FocusNode();
  List<List<String>> _contextMenuSections = kPaneRowContextMenu;

  /// The pointer a row press already claimed — the listing-level
  /// handler under the rows sees the same press and must not open the
  /// empty-area menu over it.
  int? _rowClaimedPointer;

  /// The row a primary press armed for a double-click: the next press
  /// on the same row, within [kDoubleTapSlop] and [kDoubleTapTimeout] of
  /// it, opens instead of reselecting. The window is timed by us, so a
  /// single click selects immediately — nothing waits out a double-tap
  /// recognizer (D32 §6).
  ///
  /// The window is measured between the two presses' own timestamps:
  /// activating a pane rebuilds the header and the inspector, and on a
  /// slow frame a wall-clock timer could lapse before the already-queued
  /// second press dispatched, turning a real double-click into a
  /// reselect. [_armedClickTimer] only times synthetic pointers that
  /// carry no timestamp.
  ({int row, Offset position, Duration timeStamp})? _armedClick;
  Timer? _armedClickTimer;

  /// The drop zone's hovered-folder report — the row highlight is view
  /// state, so the zone never reaches into the listing directly.
  void _onDropHoverRow(int? row) {
    if (_dropTargetRow == row) return;
    setState(() => _dropTargetRow = row);
  }

  @override
  void didUpdateWidget(PaneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        !identical(oldWidget.workspace, widget.workspace) ||
        !identical(oldWidget.checkoutSession, widget.checkoutSession)) {
      _listenable = _merged();
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      // The old controller's grace/reveal bookkeeping must not leak
      // into the new one: a session swap mid-load would otherwise skip
      // the new session's first anti-flash grace (stale _pastGrace) and
      // suppress the first listing's scroll-to-top reveal.
      _graceTimer?.cancel();
      _graceTimer = null;
      _pastGrace = false;
      _quickSelectWasActive = false;
      // Adopt the incoming controller's generation without treating it
      // as a fresh focus request.
      _pathFieldSeen = widget.controller.pathFieldGeneration;
      _renameWasActive = false;
      _revealedLocationPath = null;
      _revealedEntries = null;
      // A pane that swaps controllers mid-drag keeps no hover row — the
      // index belongs to the old listing's geometry — and no armed
      // double-click either.
      _dropTargetRow = null;
      _disarmClick();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _graceTimer?.cancel();
    _armedClickTimer?.cancel();
    _scrollController.dispose();
    _pathFieldFocusNode.dispose();
    _contextMenuFirstItem.dispose();
    super.dispose();
  }

  /// A navigation that lands while the viewport keeps its old offset
  /// leaves the TOP of the new listing off-screen (key-event reveals
  /// cannot fix what the user has not touched). Scroll a genuinely new
  /// location to its top — but never a cancel-restore: the restored
  /// listing is the same unmodifiable instance, so it keeps the user's
  /// place.
  void _syncReveal() {
    final path = widget.controller.location?.path;
    final entries = widget.controller.entries;
    // Record the location only when its listing instance has actually
    // arrived: an optimistic navigation start (location set at issue)
    // must not consume the reveal before the entries replace. A
    // cancel-restore never gets here — its listing is the same
    // unmodifiable instance, so it keeps the user's place.
    if (identical(entries, _revealedEntries)) return;
    final pathChanged = path != _revealedLocationPath;
    _revealedLocationPath = path;
    _revealedEntries = entries;
    if (!pathChanged || path == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted || !_scrollController.hasClients) return;
      if (_scrollController.offset > 0) {
        _scrollController.jumpTo(0);
      }
    });
  }

  void _revealCursor() {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      if (!_scrollController.hasClients) return;
      final extent = _rowExtent();
      final rowTop = (widget.controller.cursorIndex ?? 0) * extent;
      final rowBottom = rowTop + extent;
      final viewportTop = _scrollController.position.pixels;
      final viewportBottom =
          viewportTop + _scrollController.position.viewportDimension;

      if (rowTop < viewportTop) {
        _scrollController.jumpTo(rowTop);
      } else if (rowBottom > viewportBottom) {
        _scrollController.jumpTo(
          rowBottom - _scrollController.position.viewportDimension,
        );
      }
    });
  }

  double _rowExtent() => scaledPaneRowExtent(context);

  /// When a Quick Select session ends from the controller side — a
  /// navigation or listing replacement (02 §2.5) rather than the field's
  /// own Enter/Esc — the field unmounts under focus and primary focus
  /// strands at the root. Return it to the listing, but only when focus
  /// really is stranded: a deliberate target (another field, a toolbar
  /// control) is never yanked back.
  void _syncQuickSelectFocus() {
    final active = widget.controller.quickSelectActive;
    final justClosed = _quickSelectWasActive && !active;
    _quickSelectWasActive = active;
    if (!justClosed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null ||
          primary.context == null ||
          identical(primary, FocusManager.instance.rootScope)) {
        widget.focusNode.requestFocus();
      }
    });
  }

  /// The path field's two focus chores. A
  /// `go.editPath`/`go.toFolder` invocation bumps the controller's
  /// generation — including over an already-mounted field — so the
  /// field re-claims primary focus on a change. And when the field
  /// unmounts under a still-focused node — a controller-side close (a
  /// rebind, a listing verb) rather than the field's own Enter/Esc —
  /// primary focus strands at the root; return it to the listing
  /// unless a deliberate target already claimed it.
  void _syncPathFieldFocus() {
    final controller = widget.controller;
    final focusRequest = controller.pathFieldGeneration != _pathFieldSeen;
    _pathFieldSeen = controller.pathFieldGeneration;
    final justClosed = _pathFieldWasOpen && !controller.pathFieldOpen;
    _pathFieldWasOpen = controller.pathFieldOpen;
    if (!focusRequest && !justClosed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      if (focusRequest && controller.pathFieldOpen) {
        _pathFieldFocusNode.requestFocus();
        return;
      }
      if (justClosed) {
        final primary = FocusManager.instance.primaryFocus;
        if (primary == null ||
            primary.context == null ||
            identical(primary, FocusManager.instance.rootScope)) {
          widget.focusNode.requestFocus();
        }
      }
    });
  }

  /// When an inline-rename session ends from the controller side — a
  /// submitted rename, a listing replacement, a location change — the
  /// field unmounts under focus and primary focus strands at the root.
  /// Return it to the listing, but only when focus really is stranded:
  /// a deliberate target is never yanked back (02 §8.2, same rule as
  /// the other field strips).
  void _syncRenameFocus() {
    final active = widget.controller.inlineRenameActive;
    final justClosed = _renameWasActive && !active;
    _renameWasActive = active;
    if (!justClosed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      // Stranded = no primary focus, a detached node (the unmounted
      // field's), or a bare focus scope — where the IME `done` unfocus
      // parks focus. A leaf node is a deliberate target and is never
      // yanked back (02 §8.2, same rule as the other field strips).
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null ||
          primary.context == null ||
          primary is FocusScopeNode) {
        widget.focusNode.requestFocus();
      }
    });
  }

  /// 02 §8.2's single-key table, scoped to this pane's focus node: these
  /// keys must never fire while any text field anywhere holds focus. The
  /// Quick Select field's focus node is a descendant of this pane's —
  /// the [FocusNode.hasPrimaryFocus] gate below keeps the listing's keys
  /// inert while it (or any other descendant) holds primary focus.
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // onKeyEvent fires for this node even when a descendant (path
    // segment, cancel button) holds primary focus — gate on primary
    // focus, so a focused descendant keeps its keys.
    if (!widget.focusNode.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    final controller = widget.controller;
    final platform = Theme.of(context).platform;
    final key = event.logicalKey;

    // A pointer-opened context menu leaves focus on the listing (no row
    // highlights until asked): Esc still dismisses it, and an arrow key
    // moves into it, as a native menu does.
    if (_contextMenu.isOpen) {
      if (key == LogicalKeyboardKey.escape) {
        _contextMenu.close();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowUp) {
        _contextMenuFirstItem.requestFocus();
        return KeyEventResult.handled;
      }
    }

    // 02 §2.5: shift + a cursor key extends the anchored selection
    // instead of single-selecting the target row.
    final cursorUpdate = HardwareKeyboard.instance.isShiftPressed
        ? SelectionUpdate.range
        : SelectionUpdate.single;

    // The pane's single keys are PLAIN keys: modified chords (Ctrl+Enter,
    // Alt+Backspace, …) belong to whoever binds them, not this table.
    final bool plainKey =
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isAltPressed;

    // 02 §2.8: the pane's OWN keys are inert the moment its rows are
    // disowned — a location-changing navigation stales them at issue,
    // not when the dim appears (the grace governs presentation, never
    // interaction eligibility); the connection-lost scrim declares the
    // same inertness (pointer and semantics are already blocked there —
    // the keyboard must not be the one live path onto stale entries).
    // Type-ahead input is inert for the same reason: matching a stale
    // listing would jump a cursor onto disowned rows. Unowned keys fall
    // through to ancestors (app shortcuts stay live during slow loads);
    // Esc and Tab reach the switch below and stay live.
    final ownedKey =
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.f2 ||
        key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.f10;
    if ((controller.connectionLost ||
            controller.error != null ||
            controller.inlineRenameActive ||
            controller.staleRows ||
            (_graceBusy() && _pastGrace)) &&
        (ownedKey || _typeAheadCharacter(event) != null) &&
        plainKey) {
      return KeyEventResult.handled;
    }
    // Modified chords (Ctrl+Enter, Alt+Home, …) belong to whoever binds
    // them, not this table — pass them through untouched.
    if (!plainKey) {
      return KeyEventResult.ignored;
    }

    switch (key) {
      case LogicalKeyboardKey.arrowDown:
        controller.moveCursorBy(1, update: cursorUpdate);
        _revealCursor();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        controller.moveCursorBy(-1, update: cursorUpdate);
        _revealCursor();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        if (controller.entries.isNotEmpty) {
          controller.setCursorIndex(0, update: cursorUpdate);
          _revealCursor();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        if (controller.entries.isNotEmpty) {
          controller.setCursorIndex(
            controller.entries.length - 1,
            update: cursorUpdate,
          );
          _revealCursor();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
        // Enter opens on Windows/Linux; on macOS Enter is the rename key
        // (02 §8.3). Key repeats never re-open or re-invoke — holding
        // Enter must not drill through nested folders (and the owned
        // key must not leak its repeats to other handlers).
        if (event is KeyRepeatEvent) {
          return KeyEventResult.handled;
        }
        if (platform == TargetPlatform.macOS) {
          controller.startRename();
        } else if (platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux) {
          _openCursor();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.f2:
        // F2 is the rename key on Windows/Linux (02 §8.3; macOS renames
        // through Return). Repeats are consumed, never re-invoked.
        if (platform == TargetPlatform.macOS) {
          return KeyEventResult.ignored;
        }
        if (event is! KeyRepeatEvent) {
          controller.startRename();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.backspace:
        // Parent-folder key on Windows/Linux (§8.3). Key repeats never
        // re-ascend — holding Backspace must not race up the tree
        // (mirrors the Enter repeat guard above). Unbound platforms
        // let the key fall through to ancestor handlers.
        if (platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux) {
          if (event is! KeyRepeatEvent) controller.goUp();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.space:
        // Space is `file.preview`'s universal trigger (06 §5): the pane
        // owns the key while its listing is live (the owned-key gate
        // already swallowed it on stale/error rows) and the session
        // decides the phase-appropriate action — open, toggle closed,
        // or a producing/confirm-phase no-op. Repeats are consumed: a
        // held Space must not toggle a surface open and shut.
        final preview = widget.preview;
        if (preview == null) return KeyEventResult.ignored;
        if (event is! KeyRepeatEvent) preview.previewFocused();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.contextMenu:
        // D32 §6's keyboard path onto the context menu: the Menu key
        // opens it over the cursor row. Repeats never re-open it.
        if (event is! KeyRepeatEvent) _openContextMenuFromKeyboard();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.f10:
        // Shift+F10 is the other platform-standard menu chord; plain
        // F10 belongs to whoever binds it.
        if (!HardwareKeyboard.instance.isShiftPressed) {
          return KeyEventResult.ignored;
        }
        if (event is! KeyRepeatEvent) _openContextMenuFromKeyboard();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        return _handleEscapeTier(event);
      case LogicalKeyboardKey.tab:
        // Only plain Tab swaps (02 §8.2). Shift+Tab keeps the standard
        // reverse traversal (ignored → traversal); repeats of the owned
        // key are consumed so holding Tab cannot oscillate focus.
        if (event is KeyRepeatEvent) {
          return KeyEventResult.handled;
        }
        if (HardwareKeyboard.instance.isShiftPressed) {
          return KeyEventResult.ignored;
        }
        widget.onSwapFocus();
        return KeyEventResult.handled;
      default:
        // 02 §2.5: any other printable key joins the type-ahead buffer —
        // the first case/diacritic-insensitive prefix match becomes the
        // cursor and scrolls visible. Space and control characters fall
        // through to ancestors (Space is reserved for file.preview, §2.6).
        final character = _typeAheadCharacter(event);
        if (character == null) return KeyEventResult.ignored;
        controller.typeAhead(character);
        _revealCursor();
        // Only consume what actually accumulated: an empty pane owns no
        // printable keys, so they still reach app-level handlers.
        return controller.typeAheadActive
            ? KeyEventResult.handled
            : KeyEventResult.ignored;
    }
  }

  /// 02 §8.2's Esc tiers in their total order, run from the listing's
  /// own key path (primary focus on the pane node). One press fires one
  /// tier.
  KeyEventResult _handleEscapeTier(KeyEvent event) {
    // One press fires one tier — a held Esc's repeats are consumed here
    // rather than cascading down to the next tier on each repeat.
    if (event is KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    // 02 §8.2's total order puts the preview tier first: an open Quick
    // Look or docked panel answers Esc before the pane's own rename,
    // navigation, filter, and type-ahead slots see it. The
    // session answers false while no preview surface is live, leaving
    // the tiers below untouched — one press still fires one tier.
    if (widget.preview?.escape() ?? false) {
      return KeyEventResult.handled;
    }
    final controller = widget.controller;
    if (controller.renameTarget != null) {
      // 02 §8.2's field-first order: an open rename session owns the
      // first Esc — a stranded field (its focus lost but the session
      // still mounted) cancels here too, so the key can never fall
      // through to navigation-cancel while an edit is open. An
      // in-flight commit has no field left to cancel; its Esc falls
      // through to the navigation tiers like any other.
      controller.cancelRename();
    } else if (controller.navigationInFlight) {
      // A directory watch's own re-list is not the user's to cancel:
      // Esc goes to the tiers below while one runs.
      controller.cancelNavigation();
    } else if (controller.error != null) {
      // The inline error's keyboard escape hatch: Esc retries the
      // failed operation (the overlay's Retry is otherwise
      // mouse-only in this keyboard-first surface).
      unawaited(controller.retry());
    } else if (_pendingRemoteConnect(controller)) {
      // A pending remote bind is not `loading` (no generation is
      // issued yet), so it cancels through the shell's
      // sibling-aware path — detach when a sibling still browses
      // the server, never a shared disconnect. A held key's
      // repeats must not cancel a replacement binding.
      if (event is KeyRepeatEvent) {
        return KeyEventResult.handled;
      }
      widget.onCancelRecovery();
    } else if (controller.filterActive || controller.filterFieldOpen) {
      // 02 §8.2's Esc order: an active filter clears below
      // navigation-cancel (a filtered loading pane's first Esc still
      // cancels the load) and above the type-ahead buffer. D32 moved
      // the field into the header, whose own Esc handles the
      // field-focused tier; this is the listing's tier. (The Get Info
      // overlay's tier left with the overlay — the inspector's Info
      // tab owns Get Info now.)
      controller.clearFilter();
    } else if (controller.typeAheadActive) {
      // 02 §8.2's Esc order: a pending type-ahead buffer clears
      // below navigation-cancel and above deselect.
      controller.clearTypeAhead();
    } else {
      // Idle: nothing to cancel here — let Esc reach ancestor
      // handlers (app shortcuts) instead of swallowing it.
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _openCursor() {
    final controller = widget.controller;
    final cursor = controller.cursorIndex;
    if (cursor == null || cursor >= controller.entries.length) return;
    controller.openEntry(controller.entries[cursor]);
  }

  /// Resolves a row press's selection gesture from the modifiers held
  /// at POINTER-DOWN and the platform (02 §2.5): plain click singles,
  /// meta on macOS / control elsewhere toggles, shift extends the
  /// anchored range. Shift wins the modifier race on every platform so
  /// a ctrl/⌘+shift click keeps one predictable range meaning.
  SelectionUpdate _selectionUpdateFor(
    _PointerModifiers? modifiers,
    TargetPlatform platform,
  ) {
    if (modifiers != null && modifiers.shift) return SelectionUpdate.range;
    final toggle = platform == TargetPlatform.macOS
        ? (modifiers?.meta ?? false)
        : (modifiers?.control ?? false);
    return toggle ? SelectionUpdate.toggle : SelectionUpdate.single;
  }

  void _syncGrace(bool loading) {
    if (!loading) {
      if (_pastGrace || _graceTimer != null) {
        _graceTimer?.cancel();
        _graceTimer = null;
        // Called from the controller-driven rebuild: this build already
        // re-renders with the grace cleared, so no setState is needed
        // (and one would throw mid-build).
        _pastGrace = false;
      }
      return;
    }
    if (_pastGrace || _graceTimer != null) return;
    _graceTimer = Timer(_antiFlashGrace, () {
      // Null the fired timer: a callback that early-returns must not
      // leave a dead timer blocking the next load's grace re-arm.
      _graceTimer = null;
      if (_disposed || !mounted || !_graceBusy()) return;
      setState(() => _pastGrace = true);
    });
  }

  /// The grace gates every busy surface (02 §2.8): an in-flight listing
  /// AND a mid-bind phase (the connecting spinner, which is not
  /// `loading` — no generation is outstanding yet).
  bool _graceBusy() =>
      widget.controller.loading ||
      widget.controller.phase == PanePhase.openingLocal ||
      widget.controller.phase == PanePhase.connectingRemote;

  void _disarmClick() {
    _armedClickTimer?.cancel();
    _armedClickTimer = null;
    _armedClick = null;
  }

  void _openRow(int index) {
    final entries = widget.controller.entries;
    if (index < entries.length) widget.controller.openEntry(entries[index]);
  }

  /// A plain press on a row inside a multi-selection: the single-select
  /// waits for pointer-up so a drag can still carry the whole selection
  /// (Finder's rule); movement past the touch slop cancels it.
  ({int pointer, int row, Offset position})? _deferredSelect;

  /// The press that started the current row gesture: the pointer the
  /// OS drag-out hand-off cancels once the native session runs.
  PointerDownEvent? _rowDown;

  /// Whether this row gesture already reached the window edge: the
  /// hand-off (or its hint) happens at most once per gesture.
  bool _dragOutDecided = false;

  /// The payload the current row drag's avatar carries, kept from the
  /// drag's start: rows are built by index, so a listing change under
  /// the drag rebuilds the dragged row with another row's payload.
  PaneEntryDrag? _rowDrag;

  void _onRowDragStarted(PaneEntryDrag drag) => _rowDrag = drag;

  /// D14's drag-out amendment: the row drag's pointer left the window.
  /// Only a position outside the view counts: every in-app target sits
  /// inside it, so in-app drags are untouched.
  void _onRowDragUpdate(DragUpdateDetails details) {
    final dragOut = widget.dragOut;
    final drag = _rowDrag;
    if (dragOut == null || drag == null || _dragOutDecided) return;
    final view = View.of(context);
    final bounds = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    if (bounds.contains(details.globalPosition)) return;
    _dragOutDecided = true;
    unawaited(
      _handOffRowDrag(
        dragOut,
        drag,
        details.globalPosition,
        view.devicePixelRatio,
      ),
    );
  }

  Future<void> _handOffRowDrag(
    DragOutController dragOut,
    PaneEntryDrag drag,
    Offset position,
    double devicePixelRatio,
  ) async {
    final down = _rowDown;
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final result = await dragOut.handOff(
      drag,
      position: position,
      style: DragOutImageStyle(
        palette: DragOutImagePalette(
          background: colors.surfaceContainerHighest,
          foreground: colors.onSurface,
          badge: colors.primary,
          onBadge: colors.onPrimary,
        ),
        devicePixelRatio: devicePixelRatio,
        itemCountLabel: l10n.dropItemCount,
      ),
    );
    if (!mounted) return;
    switch (result) {
      case DragOutHandOff.started:
        // The native session owns the drag now. Cancel the framework's
        // gesture so the in-app drag ends without landing a drop; the
        // native side resets the embedder's own button state.
        if (down != null) {
          GestureBinding.instance.handlePointerEvent(
            PointerCancelEvent(
              viewId: down.viewId,
              timeStamp: down.timeStamp,
              pointer: down.pointer,
              kind: down.kind,
              device: down.device,
              position: position,
            ),
          );
        }
      case DragOutHandOff.remoteUnsupported:
        widget.controller.noteDragOutRemoteUnavailable();
      case DragOutHandOff.unavailable || DragOutHandOff.notStarted:
      // The in-app drag simply continues.
    }
  }

  /// D32 §6: selection happens on pointer-DOWN. A primary press selects
  /// at once with its modifiers; a second plain press on the same row
  /// inside the double-click window opens it. A secondary press — or
  /// macOS's control-click — retargets an unselected row and opens the
  /// context menu at the pointer (a press inside the selection keeps it
  /// as the menu's subject).
  void _onRowPointerDown(int index, PointerDownEvent event) {
    final controller = widget.controller;
    if (index >= controller.entries.length) return;
    _rowClaimedPointer = event.pointer;
    _rowDown = event;
    _rowDrag = null;
    _dragOutDecided = false;
    _deferredSelect = null;
    final platform = Theme.of(context).platform;
    final keyboard = HardwareKeyboard.instance;
    final modifiers = _PointerModifiers(
      shift: keyboard.isShiftPressed,
      meta: keyboard.isMetaPressed,
      control: keyboard.isControlPressed,
    );
    final primary = event.buttons & kPrimaryMouseButton != 0;
    final secondary =
        event.buttons & kSecondaryMouseButton != 0 ||
        (primary && platform == TargetPlatform.macOS && modifiers.control);
    if (secondary) {
      _disarmClick();
      if (!controller.isRowSelected(index)) controller.setCursorIndex(index);
      widget.focusNode.requestFocus();
      _openContextMenu(kPaneRowContextMenu, event.position);
      return;
    }
    if (!primary) return;
    final plain = !modifiers.shift && !modifiers.meta && !modifiers.control;
    final armed = _armedClick;
    if (plain &&
        armed != null &&
        armed.row == index &&
        (event.position - armed.position).distance <= kDoubleTapSlop &&
        _withinDoubleClick(armed.timeStamp, event.timeStamp)) {
      _disarmClick();
      _openRow(index);
      return;
    }
    if (plain &&
        controller.isRowSelected(index) &&
        controller.selectedCount > 1) {
      _deferredSelect = (
        pointer: event.pointer,
        row: index,
        position: event.position,
      );
    } else {
      controller.setCursorIndex(
        index,
        update: _selectionUpdateFor(modifiers, platform),
      );
    }
    widget.focusNode.requestFocus();
    _armedClickTimer?.cancel();
    _armedClick = plain
        ? (row: index, position: event.position, timeStamp: event.timeStamp)
        : null;
    // Stamped presses carry their own clock; only a stampless synthetic
    // pointer falls back to wall-clock expiry.
    _armedClickTimer = plain && event.timeStamp == Duration.zero
        ? Timer(kDoubleTapTimeout, _disarmClick)
        : null;
  }

  /// Whether a second press at [second] completes a double-click begun
  /// at [first]: by the events' own timestamps when both carry one, else
  /// by the fallback timer, which disarms a stampless press on expiry.
  static bool _withinDoubleClick(Duration first, Duration second) {
    if (first == Duration.zero || second == Duration.zero) return true;
    final gap = second - first;
    return !gap.isNegative && gap <= kDoubleTapTimeout;
  }

  void _onRowPointerMove(PointerMoveEvent event) {
    final deferred = _deferredSelect;
    if (deferred == null || deferred.pointer != event.pointer) return;
    if ((event.position - deferred.position).distance > kTouchSlop) {
      _deferredSelect = null;
    }
  }

  void _onRowPointerUp(PointerUpEvent event) {
    final deferred = _deferredSelect;
    _deferredSelect = null;
    if (deferred == null || deferred.pointer != event.pointer) return;
    widget.controller.setCursorIndex(deferred.row);
  }

  /// D32 §9's touch rows: a tap opens (folders navigate, files take the
  /// double-click action) — there is no hover or double-click to wait
  /// for on a finger.
  void _onRowTap(int index) {
    widget.controller.setCursorIndex(index);
    widget.focusNode.requestFocus();
    _openRow(index);
  }

  /// A long-press selects the row and opens the action sheet.
  void _onRowLongPress(int index) {
    final controller = widget.controller;
    if (!controller.isRowSelected(index)) controller.setCursorIndex(index);
    widget.focusNode.requestFocus();
    _showContextSheet(kPaneRowContextMenu);
  }

  /// A secondary press that no row claimed: the empty area's menu.
  void _onListingPointerDown(PointerDownEvent event) {
    if (_rowClaimedPointer == event.pointer) return;
    // The inline editor floats over the listing; its presses are the
    // field's own (a right-click there is the text field's menu).
    final editor = _renameEditorKey.currentContext?.findRenderObject();
    if (editor is RenderBox &&
        editor.hasSize &&
        editor.size.contains(editor.globalToLocal(event.position))) {
      return;
    }
    final macControlClick =
        event.buttons & kPrimaryMouseButton != 0 &&
        Theme.of(context).platform == TargetPlatform.macOS &&
        HardwareKeyboard.instance.isControlPressed;
    if (event.buttons & kSecondaryMouseButton == 0 && !macControlClick) {
      return;
    }
    widget.focusNode.requestFocus();
    _openContextMenu(kPaneEmptyContextMenu, event.position);
  }

  List<List<RegisteredCommand>> _resolvedSections(List<List<String>> sections) {
    final commands = widget.commands;
    if (commands == null || widget.onRunCommand == null) return const [];
    return resolvePaneContextSections(commands, sections);
  }

  void _openContextMenu(List<List<String>> sections, Offset global) {
    if (_resolvedSections(sections).isEmpty) return;
    final anchor = _contextMenuAnchorKey.currentContext?.findRenderObject();
    if (anchor is! RenderBox || !anchor.hasSize) return;
    setState(() => _contextMenuSections = sections);
    _contextMenu.open(position: anchor.globalToLocal(global));
  }

  /// Shift+F10 / the Menu key (D32 §5's keyboard path): the menu opens
  /// under the cursor row — the empty-area menu when there is no cursor
  /// — and focus lands on its first row. Touch platforms get the sheet.
  void _openContextMenuFromKeyboard() {
    final cursor = widget.controller.cursorIndex;
    final sections = cursor == null
        ? kPaneEmptyContextMenu
        : kPaneRowContextMenu;
    if (_touchRows(context)) {
      _showContextSheet(sections);
      return;
    }
    final anchor = _contextMenuAnchorKey.currentContext?.findRenderObject();
    if (anchor is! RenderBox || !anchor.hasSize) return;
    final list = _listAreaKey.currentContext?.findRenderObject();
    var global = anchor.localToGlobal(const Offset(24, 24));
    if (list is RenderBox && list.hasSize) {
      final extent = _rowExtent();
      final scrolled = _scrollController.hasClients
          ? _scrollController.offset
          : 0.0;
      final y = cursor == null ? 0.0 : (cursor + 1) * extent - scrolled;
      global = list.localToGlobal(
        Offset(
          PaneColumnMetrics.startPadding + PaneColumnMetrics.glyphSize,
          y.clamp(0.0, list.size.height),
        ),
      );
    }
    _openContextMenu(sections, global);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted || !_contextMenu.isOpen) return;
      _contextMenuFirstItem.requestFocus();
    });
  }

  void _showContextSheet(List<List<String>> sections) {
    final run = widget.onRunCommand;
    final resolved = _resolvedSections(sections);
    if (run == null || resolved.isEmpty) return;
    final cursor = widget.controller.cursorIndex;
    final entries = widget.controller.entries;
    unawaited(
      showPaneContextSheet(
        context,
        title: cursor != null && cursor < entries.length
            ? entries[cursor].name
            : null,
        sections: resolved,
        onRun: run,
      ),
    );
  }

  List<Widget> _contextMenuChildren(BuildContext context) {
    final run = widget.onRunCommand;
    if (run == null) return const [];
    return buildPaneContextMenuItems(
      context: context,
      sections: _resolvedSections(_contextMenuSections),
      onRun: run,
      firstItemFocus: _contextMenuFirstItem,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        _syncGrace(_graceBusy());
        _syncReveal();
        _syncQuickSelectFocus();
        _syncPathFieldFocus();
        _syncRenameFocus();
        final active = identical(widget.workspace.activePane, widget.pane);
        final touch = _touchRows(context);
        return Semantics(
          container: true,
          label: widget.pane.isLeftPane ? l10n.paneAName : l10n.paneBName,
          child: Focus(
            focusNode: widget.focusNode,
            onKeyEvent: _handleKey,
            onFocusChange: (focused) {
              if (focused) widget.workspace.setActivePane(widget.pane);
            },
            child: Listener(
              // Clicking anywhere in the pane focuses its listing (and so
              // activates the pane) — the two-pane muscle-memory basic. A
              // raw pointer listener, not a gesture: a pane-level tap
              // recognizer would join the arena against the rows' own
              // gestures and both would lose.
              onPointerDown: (event) {
                // The pane's fields keep their own clicks: a pointer
                // down inside the Quick Select strip, the path field, or
                // the rename editor must not bounce focus to the listing
                // before the field's own tap handler runs.
                for (final key in [
                  _quickSelectFieldKey,
                  _pathFieldStripKey,
                  _renameEditorKey,
                ]) {
                  final fieldBox =
                      key.currentContext?.findRenderObject() as RenderBox?;
                  if (fieldBox != null &&
                      fieldBox.hasSize &&
                      fieldBox.size.contains(
                        fieldBox.globalToLocal(event.position),
                      )) {
                    return;
                  }
                }
                widget.focusNode.requestFocus();
              },
              child: MenuAnchor(
                controller: _contextMenu,
                // An outside click only dismisses the menu — it must not
                // also select a row or run a header button.
                consumeOutsideTap: true,
                menuChildren: _contextMenuChildren(context),
                child: KeyedSubtree(
                  key: _contextMenuAnchorKey,
                  child: _PaneSurface(
                    controller: widget.controller,
                    pane: widget.pane,
                    syncLink: widget.workspace.syncBrowsing,
                    announceSyncChip: syncChipAnnounces(
                      paneActive: active,
                      otherPaneShowsChip: _otherPaneShowsSyncChip(),
                    ),
                    active: active,
                    graceVisible: _pastGrace,
                    scrollController: _scrollController,
                    clock: widget.clock,
                    bookmarks: widget.bookmarks,
                    dropDelegate: widget.dropDelegate,
                    dragOut: widget.dragOut,
                    supportsOsDrop: widget.supportsOsDrop,
                    checkoutSession: widget.checkoutSession,
                    onReviewLocalEdits: widget.onReviewLocalEdits,
                    listAreaKey: _listAreaKey,
                    dropTargetRow: _dropTargetRow,
                    onDropHoverRow: _onDropHoverRow,
                    onCancelNavigation: widget.controller.cancelNavigation,
                    onRetry: () => unawaited(widget.controller.retry()),
                    onCancelRecovery: widget.onCancelRecovery,
                    onQuickSelectClosed: () => widget.focusNode.requestFocus(),
                    quickSelectFieldKey: _quickSelectFieldKey,
                    pathFieldStripKey: _pathFieldStripKey,
                    pathFieldFocusNode: _pathFieldFocusNode,
                    onPathFieldClosed: () => widget.focusNode.requestFocus(),
                    renameEditorKey: _renameEditorKey,
                    gestures: _RowGestures(
                      touch: touch,
                      onPointerDown: _onRowPointerDown,
                      onPointerMove: _onRowPointerMove,
                      onPointerUp: _onRowPointerUp,
                      onTap: _onRowTap,
                      onLongPress: _onRowLongPress,
                      onOpen: _openRow,
                      onRename: (index) {
                        widget.controller.setCursorIndex(index);
                        widget.focusNode.requestFocus();
                        widget.controller.startRename();
                      },
                      onListingPointerDown: _onListingPointerDown,
                      onDragStarted: widget.dragOut == null
                          ? null
                          : _onRowDragStarted,
                      onDragUpdate: widget.dragOut == null
                          ? null
                          : _onRowDragUpdate,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The row gesture callbacks the pane state owns (selection, the
/// double-click window, the context menu), handed down to the listing
/// in one bundle.
@immutable
class _RowGestures {
  const _RowGestures({
    required this.touch,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onTap,
    required this.onLongPress,
    required this.onOpen,
    required this.onRename,
    required this.onListingPointerDown,
    this.onDragStarted,
    this.onDragUpdate,
  });

  /// Touch rows (D32 §9) take tap/long-press; desktop rows take raw
  /// pointer presses.
  final bool touch;
  final void Function(int index, PointerDownEvent event) onPointerDown;
  final void Function(PointerMoveEvent event) onPointerMove;
  final void Function(PointerUpEvent event) onPointerUp;
  final void Function(int index) onTap;
  final void Function(int index) onLongPress;

  /// The row's primary verb for assistive tech (open).
  final void Function(int index) onOpen;

  /// §13's rename custom action: select the row, then open the editor.
  final void Function(int index) onRename;

  /// Presses on the listing no row claimed (the empty-area menu).
  final void Function(PointerDownEvent event) onListingPointerDown;

  /// A row drag began carrying this payload (the avatar's for the whole
  /// gesture); set together with [onDragUpdate].
  final void Function(PaneEntryDrag drag)? onDragStarted;

  /// A row drag's moves, for the OS drag-out hand-off at the window
  /// edge (D14's amendment); null leaves the row `Draggable` exactly as
  /// it was, in-app only.
  final void Function(DragUpdateDetails details)? onDragUpdate;
}

class _PaneSurface extends StatelessWidget {
  const _PaneSurface({
    required this.controller,
    required this.pane,
    required this.syncLink,
    required this.announceSyncChip,
    required this.active,
    required this.graceVisible,
    required this.scrollController,
    required this.clock,
    required this.bookmarks,
    required this.dropDelegate,
    required this.dragOut,
    required this.supportsOsDrop,
    required this.checkoutSession,
    required this.onReviewLocalEdits,
    required this.listAreaKey,
    required this.dropTargetRow,
    required this.onDropHoverRow,
    required this.onCancelNavigation,
    required this.onRetry,
    required this.onCancelRecovery,
    required this.onQuickSelectClosed,
    required this.quickSelectFieldKey,
    required this.pathFieldStripKey,
    required this.pathFieldFocusNode,
    required this.onPathFieldClosed,
    required this.renameEditorKey,
    required this.gestures,
  });

  final PaneController controller;

  /// The strip owning the tab.
  final PaneTabsController pane;

  /// The workspace's Sync Browsing link (02 §7) — the location
  /// header's link chip reads its state.
  final SyncBrowsingController syncLink;

  /// Whether this pane's link chip is the one screen-reader announcer
  /// (see [syncChipAnnounces]).
  final bool announceSyncChip;
  final bool active;
  final bool graceVisible;
  final ScrollController scrollController;
  final DateTime Function() clock;

  /// The bookmark persistence seam for the "Save as favorite…" bar
  /// (02 §2.7) — see [PaneView.bookmarks].
  final BookmarkStore? bookmarks;

  /// The drop enqueue seam (02 §5.1) — see [PaneView.dropDelegate].
  final PaneDropDelegate? dropDelegate;

  /// See [PaneView.dragOut]: the drop zone's own-drag echo routing.
  final DragOutController? dragOut;

  /// See [PaneView.supportsOsDrop].
  final bool? supportsOsDrop;

  /// See [PaneView.checkoutSession] — the §3.7 banner's truth source.
  final CheckoutSession? checkoutSession;

  /// See [PaneView.onReviewLocalEdits] — the banner's `Review…`.
  final void Function(String serverId)? onReviewLocalEdits;

  /// Keys the listing's `ListView` for drop hit-testing — see
  /// [PaneDropArea.listAreaKey].
  final GlobalKey listAreaKey;

  /// The folder row a live drag hover targets (02 §5.1's highlight);
  /// null for current-directory or no hover.
  final int? dropTargetRow;

  /// The drop zone's hovered-folder report — see [_PaneViewState].
  final ValueChanged<int?> onDropHoverRow;

  final VoidCallback onCancelNavigation;
  final VoidCallback onRetry;
  final VoidCallback onCancelRecovery;
  final VoidCallback onQuickSelectClosed;
  final GlobalKey quickSelectFieldKey;

  /// The path field's hit-test boundary for the pane's pointer-down
  /// listener (clicks inside the editing field must not bounce focus to
  /// the listing before the field's own tap runs).
  final GlobalKey pathFieldStripKey;

  /// The path field's focus node, owned by the pane state so a
  /// `go.editPath`/`go.toFolder` re-invocation re-focuses the mounted
  /// field (02 §2.1).
  final FocusNode pathFieldFocusNode;

  /// Returns focus to the listing after the field's own Enter/Esc.
  final VoidCallback onPathFieldClosed;

  /// The inline-rename editor's hit-test boundary for the pane's
  /// pointer-down listener (clicks inside it keep the field's focus).
  final GlobalKey renameEditorKey;

  /// The row and listing gestures the pane state owns.
  final _RowGestures gestures;

  /// Whether the listing (and so the column header) is on screen: a
  /// bound pane showing rows, cached or live.
  bool get _listingShown =>
      controller.hasEngine &&
      (controller.connectionLost ||
          controller.phase == PanePhase.browsing ||
          controller.phase == PanePhase.restored);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final loadingVisible = graceVisible && !controller.connectionLost;
    return ColoredBox(
      color: PoltergeistChrome.of(context).paneBackground,
      // One width measure for the column header and every row, so the
      // two can never disagree about which columns fit.
      child: LayoutBuilder(
        builder: (context, constraints) => PaneColumnMetricsScope(
          metrics: PaneColumnMetrics.forWidth(
            constraints.maxWidth,
            MediaQuery.textScalerOf(context),
            modifiedWidth: PaneColumnMetrics.modifiedWidthIn(context),
          ),
          // Below the scope, so the surface's own reads (the rename
          // editor's name-column bounds) see the width the rows use.
          child: Builder(
            builder: (context) =>
                _surfaceColumn(context, l10n, loadingVisible),
          ),
        ),
      ),
    );
  }

  Widget _surfaceColumn(
    BuildContext context,
    AppLocalizations l10n,
    bool loadingVisible,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LocationHeader(
          controller: controller,
          announceSyncChip: announceSyncChip,
          syncLink: syncLink,
          loadingVisible: loadingVisible,
          onCancel: onCancelNavigation,
          pathFieldKey: pathFieldStripKey,
          pathFieldFocusNode: pathFieldFocusNode,
          onPathFieldClosed: onPathFieldClosed,
        ),
        // 02 §2.5: the Quick Select field drops in below the header
        // while the controller reports an open session.
        if (controller.quickSelectActive)
          _QuickSelectField(
            key: quickSelectFieldKey,
            controller: controller,
            onClosed: onQuickSelectClosed,
          ),
        ..._bannerSlot(context),
        // D32 §6's column header: outside the listing's scroll view,
        // so the drop zone's list origin stays row 0.
        if (_listingShown && controller.viewMode == PaneViewMode.details)
          PaneColumnHeader(
            paneTabId: controller.paneTabId,
            sortKey: controller.sortKey,
            sortDirection: controller.sortDirection,
            onSort: controller.sortByColumn,
            enabled:
                !controller.connectionLost &&
                !controller.restoredPending &&
                !controller.staleRows,
          ),
        // D14's drop zone wraps the listing body only — the header,
        // banners, and column header stay outside it. The OS-drop gate
        // resolves per build: a busy or unbound pane advertises no
        // droppable bounds at all.
        Expanded(
          child: PaneDropArea(
            controller: controller,
            delegate: dropDelegate,
            scrollController: scrollController,
            listAreaKey: listAreaKey,
            rowExtent: scaledPaneRowExtent(context),
            onHoverFolderRow: onDropHoverRow,
            dragOut: dragOut,
            supportsOsDrop: supportsOsDrop ?? _isDesktopPlatform(),
            child: _body(context, l10n),
          ),
        ),
      ],
    );
  }

  /// D32 §6's one banner slot: only the highest-priority banner shows —
  /// lost connection > reconnect > local edits > notice > save as
  /// favorite. The save bar stays mounted (offstage) under a higher
  /// banner: it owns its typed name and its saved-for-good latch, which
  /// an unmount would reset.
  List<Widget> _bannerSlot(BuildContext context) {
    final bookmark = controller.remoteBookmark;
    Widget? banner;
    if (controller.connectionLost) {
      banner = _LostConnectionBanner(
        label: bookmark?.label ?? '',
        onCancel: onCancelRecovery,
        onRetry: controller.canRetryRecovery ? onRetry : null,
      );
    } else if (controller.phase == PanePhase.restored && bookmark != null) {
      // 02 §3's session-restored remote tab: its cached listing stays
      // inert behind the Reconnect bar. A restored LOCAL tab needs no
      // bar: activation rebinds it on the spot.
      banner = _SessionReconnectBar(
        label: bookmark.label,
        onReconnect: () => unawaited(controller.resumeRestored()),
      );
    } else if (checkoutSession != null &&
        bookmark != null &&
        LocalEditsBanner.localEditCount(checkoutSession!, bookmark.id) > 0) {
      // 06 §3.7's resume surface: while this pane's bound server has
      // checkouts holding dirty/missing local edits the banner holds
      // the slot until they're resolved. remoteBookmark is the pane's
      // server binding (it survives a connection-lost phase, where the
      // review dialog stays reachable).
      banner = LocalEditsBanner(
        session: checkoutSession!,
        serverId: bookmark.id,
        onReview: () => onReviewLocalEdits?.call(bookmark.id),
      );
    } else if (controller.notice != null) {
      // 02 §10's transient notice: the honest "not yet", or a copy
      // confirmation — informational, never the error overlay.
      banner = _NoticeStrip(controller: controller);
    }
    return [
      ?banner,
      // 02 §2.7's "Not saved" banner: a live adhoc session past a
      // successful connect, until a stored server carries its endpoint
      // or the user dismisses it in this tab.
      if (_saveBarBookmark(controller) case final adhoc?
          when !controller.unsavedBannerDismissed)
        Offstage(
          offstage: banner != null,
          child: SaveFavoriteBar(
            key: ValueKey('saveFavorite.${adhoc.id}'),
            bookmark: adhoc,
            currentPath: switch (controller.location) {
              RemotePaneLocation(path: final path) => path,
              _ => null,
            },
            store: bookmarks,
            onNoStore: controller.noteSaveFavoriteUnavailable,
            onDismiss: controller.dismissUnsavedBanner,
          ),
        ),
    ];
  }

  /// Whether pointer drags are this platform's gesture (02 §5.1):
  /// `desktop_drop` serves the desktop platforms only, and the in-app
  /// row drag's immediate recognizer would hijack touch scrolling on
  /// mobile — so both halves of D14 are desktop gestures.
  /// `defaultTargetPlatform` (not dart:io) so tests can drive the
  /// wiring. The [supportsOsDrop] override applies only to the OS
  /// `DropTarget`, never to in-app row drags.
  bool _isDesktopPlatform() =>
      // defaultTargetPlatform reports the HOST OS on web builds, where
      // desktop_drop's channels don't exist — exclude it explicitly.
      !kIsWeb &&
      switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => true,
    _ => false,
  };

  Widget _body(BuildContext context, AppLocalizations l10n) {
    if (!controller.hasEngine) {
      return _Centered(l10n.paneNoEngine);
    }

    final content = Stack(
      children: [
        // While the connection-lost banner owns the pane — or the
        // post-grace dim declares the listing inert — the stale listing
        // leaves the semantics tree too: a reachable-but-inert row
        // would read as broken (AT activation bypasses hit testing).
        // Disowned rows also leave it the moment a location-changing
        // navigation issues — the grace delays only the DIM, never the
        // inertness. The inline error makes the stale listing's
        // POINTERS inert as well (the error card never covers the whole
        // listing, and a stray click on an uncovered stale row would
        // change selection over data the pane has disowned) — scoped to
        // this subtree, never a Stack sibling, so chrome added to this
        // Stack later stays clickable.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: (controller.error != null || controller.staleRows) &&
                !controller.connectionLost,
            child: ExcludeSemantics(
              excluding:
                  controller.connectionLost ||
                  controller.error != null ||
                  controller.staleRows ||
                  (controller.loading && graceVisible),
              child: controller.connectionLost
                  ? _listing(context, l10n)
                  : switch (controller.phase) {
                      PanePhase.unbound => _Centered(l10n.paneNoLocation),
                      PanePhase.openingLocal || PanePhase.connectingRemote =>
                        _connectingBody(context, l10n),
                      PanePhase.browsing || PanePhase.restored =>
                        _listing(context, l10n),
                    },
            ),
          ),
        ),
        // WCAG 4.1.3: the rows leaving the semantics tree at issue must
        // not be silent — while they're disowned, a live region
        // announces the transition with the same string the header shows
        // once the grace dim lands. The node stays mounted permanently
        // and the label transitions '' → loading string at issue: live
        // regions announce label CHANGES on an existing node, while
        // mount-time announcements are dropped by some engines/AT. A
        // 1x1 empty box keeps the node in the semantics tree (zero-size
        // nodes are culled) while staying invisible.
        Semantics(
          label: controller.staleRows &&
                  !controller.connectionLost &&
                  controller.error == null &&
                  controller.phase != PanePhase.restored
              ? l10n.paneLoadingFolder(
                  paneLastSegment(controller.location?.path),
                )
              : '',
          liveRegion: true,
          container: true,
          child: const SizedBox(width: 1, height: 1),
        ),
        // 02 §2.8: the old listing stays visible, dimmed, past the grace —
        // and inert while the navigation it belongs to is still in flight.
        if (controller.loading && graceVisible && !controller.connectionLost)
          Positioned.fill(
            child: AbsorbPointer(
              child: ColoredBox(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerLowest.withValues(alpha: 0.6),
              ),
            ),
          ),
        if (controller.error != null && !controller.connectionLost)
          Positioned.fill(
            child: _ErrorOverlay(error: controller.error!, onRetry: onRetry),
          ),
        // 02 §2.5: the type-ahead badge floats over the listing for the
        // buffer's lifetime — transient by construction, it unmounts the
        // moment the 1 s reset clears the buffer.
        if (controller.typeAheadActive)
          PositionedDirectional(
            start: 0,
            end: 0,
            bottom: 8,
            child: Center(
              child: _TypeAheadBadge(buffer: controller.typeAheadBuffer),
            ),
          ),
      ],
    );
    // The banner slot's two binding banners (lost connection, the
    // restored tab's Reconnect) own the pane's single dim layer: the
    // cached listing stays visible under the scrim but inert — absorb,
    // not ignore, so a click cannot fall through onto stale rows.
    final scrimmed =
        controller.connectionLost ||
        (controller.phase == PanePhase.restored &&
            controller.remoteBookmark != null);
    if (!scrimmed) return content;
    return Stack(
      children: [
        Positioned.fill(child: content),
        Positioned.fill(
          child: AbsorbPointer(
            child: ColoredBox(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerLowest.withValues(alpha: 0.6),
            ),
          ),
        ),
      ],
    );
  }

  Widget _connectingBody(BuildContext context, AppLocalizations l10n) {
    // Nothing before the anti-flash grace (02 §2.8): a fast open must
    // not flash a spinner any more than a fast navigation does.
    if (controller.error != null || !graceVisible) {
      // The error overlay renders above; nothing else to show.
      return const SizedBox.shrink();
    }
    final label = controller.remoteBookmark?.label;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: 10),
          Text(
            label == null ? l10n.paneOpeningHome : l10n.paneConnectingTo(label),
          ),
          // Only a REMOTE connect offers cancel (the shell's
          // sibling-aware detach): a local home open has no shared
          // server reference to drop.
          if (_pendingRemoteConnect(controller)) ...[
            const SizedBox(height: 10),
            TextButton(
              key: const ValueKey('pane.connect.cancel'),
              onPressed: onCancelRecovery,
              child: Text(l10n.paneConnectCancel),
            ),
          ],
        ],
      ),
    );
  }

  Widget _listing(BuildContext context, AppLocalizations l10n) {
    // The listing's own presses: a secondary press no row claimed opens
    // the empty-area menu. Translucent, so the rows and the scroll view
    // underneath keep every press.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: gestures.onListingPointerDown,
      child: _listingBody(context, l10n),
    );
  }

  Widget _listingBody(BuildContext context, AppLocalizations l10n) {
    // The inline editor floats over the edited row's name cell: past
    // the leading padding and the kind glyph, up to the size/date
    // columns — the metrics the rows themselves lay out with.
    final metrics = PaneColumnMetrics.of(context);
    // The field's border and inset put its text exactly on the label's x.
    final renameStart = metrics.nameStart - _renameTextOffset;
    final renameEnd = metrics.trailingExtent;
    if (controller.entries.isEmpty) {
      // Never claim emptiness while a load is in flight (02 §2.8's
      // nothing-before-grace rule): the first listing of an empty
      // folder would otherwise flash "Empty folder" before arrival.
      if (controller.loading || controller.connectionLost) {
        return const SizedBox.shrink();
      }
      // 02 §2.7's filtered-to-nothing state: the dedicated message plus
      // the Clear affordance — never a blank pane.
      final Widget emptyState = controller.filterActive
          ? _FilteredEmpty(controller: controller)
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.paneEmptyFolder),
                  // §2.7's drop hint — only while a drop could actually
                  // land: no queue seam means no target, a busy or
                  // inert listing refuses them anyway, and mobile has
                  // no DnD surfaces at all.
                  if (dropDelegate != null &&
                      controller.verbsEnabled &&
                      _isDesktopPlatform())
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        controller.location is RemotePaneLocation
                            ? l10n.paneDropHintRemote
                            : l10n.paneDropHintLocal,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PoltergeistChrome.of(context).secondaryText,
                        ),
                      ),
                    ),
                ],
              ),
            );
      // A detached rename session (its row left the visible listing —
      // e.g. the last row vanished) has no row to anchor on: it floats
      // at the top of the empty state so the renameTargetGone
      // diagnostic and its dismissal stay reachable instead of hiding
      // behind "Empty folder" while the close guard still holds.
      if (controller.renameTarget != null) {
        final extent = scaledPaneRowExtent(context);
        return LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              Positioned.fill(child: emptyState),
              PositionedDirectional(
                start: renameStart,
                top: 0,
                child: _RenameEditor(
                  key: renameEditorKey,
                  controller: controller,
                  rowExtent: extent,
                  maxWidth: constraints.maxWidth - renameStart - renameEnd,
                ),
              ),
            ],
          ),
        );
      }
      return emptyState;
    }

    final extent = scaledPaneRowExtent(context);

    return LayoutBuilder(
      builder: (context, constraints) => Stack(
      children: [
        ListView.builder(
          // The drop zone's hit-testing anchor (D14): row extents are
          // fixed, so position math against this box's render size maps
          // a drop onto the rendered rows — never an unrendered index.
          // Zero padding keeps the box's origin coincident with row 0;
          // the default MediaQuery padding would shift every index by
          // padding/rowExtent.
          padding: EdgeInsets.zero,
          key: listAreaKey,
          controller: scrollController,
          itemExtent: extent,
          itemCount: controller.entries.length,
          itemBuilder: (context, index) => _buildRow(context, index),
        ),
        // 02 §2.6's inline editor: it floats over the edited row at the
        // row's scroll offset, so it rides the row through scrolling
        // and a validation error extends below the row (the listing
        // itself stays mounted underneath).
        if (controller.renameTarget != null)
          AnimatedBuilder(
            animation: scrollController,
            builder: (context, _) {
              final index = controller.renameIndex;
              final offset = scrollController.hasClients
                  ? scrollController.offset
                  : 0.0;
              return PositionedDirectional(
                start: renameStart,
                // No clamp: a row scrolled above the viewport carries
                // its editor off with it — the Stack clips the
                // overflow, and clipped pixels never hit-test. A
                // detached session (the row left the listing) anchors
                // at the top so its fault stays visible.
                top: index == null ? 0.0 : index * extent - offset,
                child: _RenameEditor(
                  key: renameEditorKey,
                  controller: controller,
                  rowExtent: extent,
                  maxWidth: constraints.maxWidth - renameStart - renameEnd,
                ),
              );
            },
          ),
      ],
      ),
    );
  }

  /// One listing row (D32 §6), plus the D14 drag wiring: while a queue
  /// seam exists and the pane's verbs are live, each row is a
  /// `Draggable` whose payload snapshots the selection at grab time —
  /// a grabbed row inside a multi-selection drags the whole selection
  /// (02 §5.1). `childWhenDragging` leaves the dimmed ghost in place —
  /// the move is not committed until a target accepts it.
  Widget _buildRow(BuildContext context, int index) {
    final highlighted = controller.cursorIndex == index;
    final selected = controller.isRowSelected(index);
    final row = _PaneRow(
      entry: controller.entries[index],
      highlighted: highlighted,
      // The cursor ring marks the cursor by SHAPE (02 §2.5): needed
      // wherever the tint alone cannot say which row it is — inside a
      // multi-selection, or on an unselected row. A lone selected
      // cursor row is its own marker.
      cursorRing: highlighted && !(selected && controller.selectedCount == 1),
      selected: selected,
      renaming: controller.renameIndex == index,
      dropTargeted: dropTargetRow == index,
      active: active,
      clock: clock,
      touch: gestures.touch,
      onPointerDown: (event) => gestures.onPointerDown(index, event),
      onPointerMove: gestures.onPointerMove,
      onPointerUp: gestures.onPointerUp,
      onTap: () => gestures.onTap(index),
      onLongPress: () => gestures.onLongPress(index),
      onOpen: () => gestures.onOpen(index),
      // 02 §13's row-level rename action: select the row (rename acts on
      // the cursor), then open the inline editor. Flagged names carry
      // no action — their reason is spelled out in the row's label.
      onRename:
          controller.verbsEnabled &&
              !nameIsFlagged(controller.entries[index].name)
          ? () => gestures.onRename(index)
          : null,
    );
    // Rows drag only where a pointer drag is the platform's gesture —
    // on touch platforms the immediate recognizer would steal the
    // listing's scroll. Drops still land via DragTarget on the zone.
    if (dropDelegate == null ||
        !controller.verbsEnabled ||
        !_isDesktopPlatform()) {
      return row;
    }
    final entry = controller.entries[index];
    // verbsEnabled does not promise a bound location — a stale listing
    // can outlive it; rows without one stay undraggable.
    final location = controller.location;
    if (location == null) return row;
    final grabbed =
        controller.isRowSelected(index) && controller.selectedCount > 1
        ? controller.selectedEntries
        : [entry];
    final drag = PaneEntryDrag(
      source: fsLocationForLocation(location),
      rootPaths: [for (final selected in grabbed) selected.path],
      entries: grabbed,
    );
    final onDragStarted = gestures.onDragStarted;
    return Draggable<PaneEntryDrag>(
      data: drag,
      // The pointer anchor keeps DragTargetDetails.offset equal to the
      // pointer — the drop zone's row math works on the pointer itself.
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: 1,
      // D14's drag-out amendment: the pane watches for the window edge.
      // The start reports this build's payload, the one the avatar
      // takes; a later build of this row may carry another.
      onDragStarted: onDragStarted == null ? null : () => onDragStarted(drag),
      onDragUpdate: gestures.onDragUpdate,
      feedback: PaneEntryDragAvatar(drag: drag),
      childWhenDragging: Opacity(opacity: 0.4, child: row),
      child: row,
    );
  }
}

/// 02 §2.6's inline-rename editor: the cursor row's name becomes a text
/// field seeded with the current name, its stem pre-selected (Finder's
/// convention — the extension survives a typed replacement). Enter
/// commits through [PaneController.submitRename]; Esc and focus loss
/// cancel through [PaneController.cancelRename] — the field tier of
/// §8.2's order. The controller owns the session and its invalidation;
/// a failed commit re-mounts this field carrying the typed error.
///
/// It sits exactly where the label does (Finder's in-place edit): the
/// text starts at the label's x, the field hugs the name plus a little
/// slack and grows as the user types up to the name column's width, it
/// is centered in the row at the row's own text size, and the row hides
/// its label meanwhile. A refusal renders under the row.
class _RenameEditor extends StatefulWidget {
  const _RenameEditor({
    super.key,
    required this.controller,
    required this.rowExtent,
    required this.maxWidth,
  });

  final PaneController controller;

  /// The edited row's height — the field centers in it.
  final double rowExtent;

  /// The name column's width: the field never grows past it.
  final double maxWidth;

  @override
  State<_RenameEditor> createState() => _RenameEditorState();
}

/// The field's border plus its text inset: the editor starts this far
/// before the label so the edited text lands on the label's x.
const double _renameBorder = 1;
const double _renameInset = 5;
const double _renameTextOffset = _renameBorder + _renameInset;

/// Room past the name so the caret and the next keystroke never scroll
/// the start of the name out of view.
const double _renameSlack = 14;

class _RenameEditorState extends State<_RenameEditor> {
  final _text = TextEditingController();
  final _fieldFocus = FocusNode();

  /// Set while a submit is in progress: the IME `done` action unfocuses
  /// the field right after `onSubmitted` returns, and that unfocus must
  /// not cancel a session validation just kept open (02 §2.6 — the
  /// field stays up with its error until the user fixes or Esc's).
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // The seed is the row's name on a fresh open and the refused draft
    // after a failed commit (02 §2.6 — the user edits what they typed,
    // not the pre-rename name).
    final name = widget.controller.renameSeed;
    // Pre-select the stem only: the last '.' of a dotted name keeps its
    // extension out of the selection, and dotfiles (a leading dot is
    // part of the stem, not an extension) select whole. The selection
    // runs backwards so its moving end (the caret the field keeps in
    // view) sits at the start: a name longer than the column shows its
    // beginning, not a tail scrolled in from the right.
    final dot = name.lastIndexOf('.');
    _text.value = TextEditingValue(
      text: name,
      selection: TextSelection(
        baseOffset: dot > 0 ? dot : name.length,
        extentOffset: 0,
      ),
    );
    _fieldFocus.addListener(_onFocusChange);
    // The field hugs the name, so every edit re-measures it.
    _text.addListener(_onTextChange);
    // autofocus alone cannot take focus from a listing that already
    // holds it — the field must claim primary focus explicitly on open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fieldFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _fieldFocus.removeListener(_onFocusChange);
    _text.removeListener(_onTextChange);
    _fieldFocus.dispose();
    _text.dispose();
    super.dispose();
  }

  String _measured = '';

  void _onTextChange() {
    if (_text.text == _measured) return;
    setState(() {});
  }

  /// Focus loss cancels the edit (02 §2.6's click-outside rule). Only a
  /// mounted session cancels — a committed or already-closed session
  /// makes this a no-op, and the listener detaches before dispose so an
  /// unmount never re-triggers it. The unfocus that the `done` action
  /// performs after `onSubmitted` is not a click-outside: [_submitting]
  /// tells the two apart.
  void _onFocusChange() {
    if (!_fieldFocus.hasFocus && !_submitting) {
      widget.controller.cancelRename();
    }
  }

  /// Enter commit: the IME action unfocuses the field right after this
  /// runs, so when the session survives (a refused name) the field
  /// re-claims focus instead of stranding unfocused-and-open.
  void _submit() {
    _submitting = true;
    unawaited(
      widget.controller.submitRename(_text.text).whenComplete(() {
        _submitting = false;
        if (mounted && widget.controller.renameTarget != null) {
          _fieldFocus.requestFocus();
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final error = widget.controller.renameError;
    // The row's own 13 px name style, on the field's surface colour.
    final style = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: colors.onSurface,
    );
    _measured = _text.text;
    final painter = TextPainter(
      text: TextSpan(text: _measured.isEmpty ? ' ' : _measured, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final textWidth = painter.width;
    final lineHeight = painter.height;
    painter.dispose();
    final maxWidth = widget.maxWidth < 0 ? 0.0 : widget.maxWidth;
    final boxWidth = (textWidth + 2 * _renameTextOffset + _renameSlack)
        .clamp(0.0, maxWidth);
    // As tall as the row allows (22 px on desktop) and centered in it;
    // a touch row's 48 dp leaves the box at text height plus a margin.
    final boxHeight = math.min(widget.rowExtent, lineHeight + 6);
    final errorText = error == null ? null : _errorText(l10n, error);

    return Focus(
      // Esc cancels from inside the field — the field tier of §8.2's
      // order, so an in-flight navigation underneath keeps loading.
      // This node sits in the focus ancestry above the field and sees
      // only keys the field itself did not consume.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        widget.controller.cancelRename();
        return KeyEventResult.handled;
      },
      child: Padding(
        padding: EdgeInsets.only(
          top: math.max(0, (widget.rowExtent - boxHeight) / 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              key: ValueKey('${widget.controller.paneTabId}.rename.box'),
              width: boxWidth,
              height: boxHeight,
              alignment: AlignmentDirectional.centerStart,
              decoration: BoxDecoration(
                // Opaque, so the accent row never shows through; the
                // border marks the edited extent.
                color: colors.surface,
                border: Border.all(
                  color: error == null ? colors.primary : colors.error,
                  width: _renameBorder,
                ),
                borderRadius: BorderRadius.circular(3),
              ),
              // Legible on the surface fill whatever the row paints
              // underneath (the accent selection included).
              child: TextSelectionTheme(
                data: TextSelectionThemeData(
                  cursorColor: colors.primary,
                  selectionColor: colors.primary.withValues(alpha: 0.3),
                  selectionHandleColor: colors.primary,
                ),
                // A floated label cannot fit the row's height; the
                // field's accessible name rides Semantics instead.
                child: Semantics(
                  label: l10n.paneRenameFieldLabel,
                  textField: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _renameInset,
                    ),
                    // No decorator: its baseline layout would push the
                    // text off-center in a box this short; the box
                    // above is the field's whole chrome.
                    child: TextField(
                      key: ValueKey(
                        '${widget.controller.paneTabId}.rename.field',
                      ),
                      controller: _text,
                      focusNode: _fieldFocus,
                      autofocus: true,
                      maxLines: 1,
                      style: style,
                      decoration: null,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                ),
              ),
            ),
            if (errorText != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: math.max(maxWidth, 0)),
                child: Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colors.errorContainer,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  // A live region: the refusal arrives while the field
                  // keeps focus, so it is announced where it appears.
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      errorText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onErrorContainer,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _errorText(AppLocalizations l10n, RemoteFileException error) =>
      switch (error) {
        PaneFaultException(:final fault) => switch (fault) {
          PaneFault.renameNameEmpty => l10n.paneFaultRenameNameEmpty,
          PaneFault.renameNameSeparator => l10n.paneFaultRenameNameSeparator,
          PaneFault.renameNameInvalid => l10n.paneFaultRenameNameInvalid,
          PaneFault.renameTargetGone => l10n.paneFaultRenameTargetGone,
          _ => error.message,
        },
        _ => error.message,
      };
}

/// 02 §2.5's transient typing badge: shows the accumulated prefix while
/// the buffer lives and announces it politely — a live region, so the
/// announcement is assertive-free and an AT joins the queue rather than
/// interrupting. The visible text stays out of the semantics tree: the
/// label already carries the whole announcement.
class _TypeAheadBadge extends StatelessWidget {
  const _TypeAheadBadge({required this.buffer});

  final String buffer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      key: const ValueKey('pane.typeAhead'),
      // A semantic boundary of its own: without the container the
      // announcement merges into the pane's label and no AT hears a
      // standalone live-region update.
      container: true,
      liveRegion: true,
      label: l10n.paneTypeAheadBadge(buffer),
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsetsDirectional.symmetric(
            horizontal: 10,
            vertical: 5,
          ),
          decoration: BoxDecoration(
            // The inverse pair is M3's tooltip contrast — ≥4.5:1 at any
            // theme seed (02 §13's contrast floor for a transient label).
            color: colors.inverseSurface,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            buffer,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colors.onInverseSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// The ancestors of [path], parent first and root last — Finder's title
/// menu order: ('/home', 'home'), ('/', '/') for `/home/tester`. Empty
/// at a root.
List<(String, String)> _ancestorsOf(String path) {
  final ancestors = <(String, String)>[];
  var walking = paneParentPath(path);
  var previous = path;
  while (walking != previous) {
    ancestors.add((paneLastSegment(walking), walking));
    previous = walking;
    walking = paneParentPath(walking);
  }
  return ancestors;
}

/// D32 §6's location header (44 px), replacing the segmented path bar:
/// the location glyph, the folder name in semibold with its ▾ ancestor
/// menu (Finder's title menu), and a second line with the item count or
/// the selection summary. Clicking the name — or `go.editPath` (⌘L) —
/// swaps in the editable path field in place. Trailing: the Sync
/// Browsing chip, and past the anti-flash grace a spinner with cancel.
class _LocationHeader extends StatelessWidget {
  const _LocationHeader({
    required this.controller,
    required this.announceSyncChip,
    required this.syncLink,
    required this.loadingVisible,
    required this.onCancel,
    required this.pathFieldKey,
    required this.pathFieldFocusNode,
    required this.onPathFieldClosed,
  });

  final PaneController controller;

  /// Whether this header's link chip is the screen-reader announcer —
  /// both anchored panes show a chip, and only one may announce a state
  /// change (see [syncChipAnnounces]).
  final bool announceSyncChip;

  /// The workspace's Sync Browsing link (02 §7): while enabled, both
  /// anchored headers carry the link chip.
  final SyncBrowsingController syncLink;

  /// Past the anti-flash grace (02 §2.8) and not under the lost-
  /// connection banner.
  final bool loadingVisible;
  final VoidCallback onCancel;

  /// The editable field's hit-test boundary for the pane's pointer-down
  /// listener — clicks inside the field keep its focus.
  final GlobalKey pathFieldKey;

  /// The field's focus node, owned by the pane state (open
  /// re-invocations re-focus the mounted field).
  final FocusNode pathFieldFocusNode;

  /// Returns focus to the listing after the field's own Enter/Esc.
  final VoidCallback onPathFieldClosed;

  @override
  Widget build(BuildContext context) {
    final chrome = PoltergeistChrome.of(context);
    final l10n = AppLocalizations.of(context);
    final loading = controller.loading && loadingVisible;
    return Container(
      key: ValueKey('${controller.paneTabId}.path'),
      constraints: BoxConstraints(
        minHeight: MediaQuery.textScalerOf(context).scale(44),
      ),
      color: chrome.paneBackground,
      padding: const EdgeInsetsDirectional.fromSTEB(10, 4, 6, 4),
      child: Row(
        children: [
          _LocationGlyph(controller: controller),
          const SizedBox(width: 8),
          Expanded(
            // The title keeps the larger share: a long suspended-link
            // cause ellipsizes inside its chip rather than squeezing the
            // folder name out.
            flex: 3,
            // `go.editPath`/`go.toFolder` swap the name for the editable
            // field in place (02 §2.1) — the glyph and the trailing
            // affordances stay put around it.
            child: controller.pathFieldOpen
                ? _PathEditorField(
                    key: pathFieldKey,
                    controller: controller,
                    focusNode: pathFieldFocusNode,
                    onClosed: onPathFieldClosed,
                  )
                : _LocationTitle(controller: controller, loading: loading),
          ),
          // 02 §7: the anchored tabs' headers carry the chip. A
          // non-anchored tab's header shows none: its navigation is not
          // the pair's.
          if (controller.syncAnchorActive) ...[
            const SizedBox(width: 6),
            Flexible(
              flex: 2,
              child: SyncBrowseChip(
                key: ValueKey('${controller.paneTabId}.syncChip'),
                link: syncLink,
                announce: announceSyncChip,
              ),
            ),
          ],
          if (loading) ...[
            const SizedBox(width: 8),
            // 02 §2.8's post-grace progress affordance.
            SizedBox(
              key: ValueKey('${controller.paneTabId}.progress'),
              width: 14,
              height: 14,
              child: const CircularProgressIndicator(strokeWidth: 2),
            ),
            IconButton(
              key: ValueKey('${controller.paneTabId}.cancel'),
              tooltip: l10n.paneCancelLoading,
              onPressed: onCancel,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 16),
            ),
          ],
        ],
      ),
    );
  }
}

/// The header's 20 px location glyph: the server's mark for a remote
/// binding, a volume at a root, a folder otherwise.
class _LocationGlyph extends StatelessWidget {
  const _LocationGlyph({required this.controller});

  final PaneController controller;

  @override
  Widget build(BuildContext context) {
    const size = 20.0;
    final bookmark = controller.remoteBookmark;
    if (bookmark != null) {
      return ServerBadge.glyph(
        tint: ServerTint(named: bookmark.color),
        icon: bookmark.icon,
        size: size,
      );
    }
    final path = controller.location?.path;
    final root = path != null && paneParentPath(path) == path;
    return ExcludeSemantics(
      child: Icon(
        root ? Icons.storage_outlined : Icons.folder,
        size: size,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

/// The header's two text lines: the clickable folder name with its ▾
/// ancestor menu, and the item or selection summary under it.
class _LocationTitle extends StatelessWidget {
  const _LocationTitle({required this.controller, required this.loading});

  final PaneController controller;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chrome = PoltergeistChrome.of(context);
    final theme = Theme.of(context);
    final location = controller.location;
    final path = location?.path;
    final name = path != null
        ? paneLastSegment(path)
        : controller.remoteBookmark?.label ?? '';
    final ancestors = path == null
        ? const <(String, String)>[]
        : _ancestorsOf(path);
    final editable = controller.acceptsPathInput;

    Widget title = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleSmall,
    );
    title = Semantics(
      button: editable,
      label: name,
      hint: editable ? l10n.goEditPathLabel : null,
      onTap: editable ? controller.editPath : null,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('${controller.paneTabId}.path.name'),
        borderRadius: BorderRadius.circular(4),
        hoverColor: chrome.hoverFill,
        onTap: editable ? controller.editPath : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: title,
        ),
      ),
    );
    // Paths are secondary facts (D32 §2): the full path rides the
    // tooltip, never a second line.
    if (path != null) title = Tooltip(message: path, child: title);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(child: title),
            if (ancestors.isNotEmpty)
              _AncestorMenu(controller: controller, ancestors: ancestors),
          ],
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 2),
          child: Text(
            _summary(context, l10n, name),
            key: ValueKey('${controller.paneTabId}.path.summary'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: chrome.secondaryText,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  /// `329 items`, or `3 of 329 selected · 42.1 MB` — bytes count files
  /// only (a folder's listed size is not its contents). Past the grace a
  /// navigation's loading line takes the slot (02 §2.8/§2.9).
  String _summary(BuildContext context, AppLocalizations l10n, String name) {
    if (loading) return l10n.paneLoadingFolder(name);
    if (controller.location == null) return '';
    final total = controller.entries.length;
    final selected = controller.selectedCount;
    if (selected == 0) return l10n.paneItemCount(total);
    var bytes = 0;
    var files = 0;
    for (final entry in controller.selectedEntries) {
      final size = entry.size;
      if (entry.type != RemoteFileType.file || size == null) continue;
      bytes += size;
      files++;
    }
    final summary = l10n.paneSelectionSummary(selected, total);
    if (files == 0) return summary;
    return l10n.paneSelectionSummaryWithSize(
      summary,
      formatPaneSize(bytes, platform: Theme.of(context).platform),
    );
  }
}

/// The ▾ beside the folder name: every enclosing folder, parent first
/// (Finder's title menu). Choosing one navigates there.
class _AncestorMenu extends StatelessWidget {
  const _AncestorMenu({required this.controller, required this.ancestors});

  final PaneController controller;
  final List<(String, String)> ancestors;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chrome = PoltergeistChrome.of(context);
    return MenuAnchor(
      menuChildren: [
        for (var i = 0; i < ancestors.length; i++)
          MenuItemButton(
            key: ValueKey('${controller.paneTabId}.path.ancestor.$i'),
            leadingIcon: Icon(
              i == ancestors.length - 1
                  ? Icons.storage_outlined
                  : Icons.folder_outlined,
              size: 16,
            ),
            onPressed: () => controller.navigate(ancestors[i].$2),
            child: Text(ancestors[i].$1),
          ),
      ],
      builder: (context, menu, _) => IconButton(
        key: ValueKey('${controller.paneTabId}.path.ancestors'),
        tooltip: l10n.paneAncestorMenuTooltip,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 22, height: 22),
        iconSize: 16,
        color: chrome.secondaryText,
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: const Icon(Icons.keyboard_arrow_down),
      ),
    );
  }
}

/// 02 §2.1's editable path field, mounted inside the bar in place of
/// the segments while `go.editPath`/`go.toFolder` hold it open. The
/// controller owns the session — the field is pure plumbing: the seed
/// arrives from the controller (current path selected whole for
/// `go.editPath`, empty for `go.toFolder`), Enter submits through
/// [PaneController.submitPathField], and Esc is the field tier of
/// §8.2's order. While this field holds focus the pane's single-key
/// table and type-ahead stay inert — the FocusNode.hasPrimaryFocus
/// gate on the pane's key handler covers it, since this node is not
/// the listing's.
class _PathEditorField extends StatefulWidget {
  const _PathEditorField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onClosed,
  });

  final PaneController controller;

  /// Owned by the pane state so a re-invoked `go.editPath`/`go.toFolder`
  /// can re-focus the already-mounted field.
  final FocusNode focusNode;

  /// Returns focus to the listing after Enter commits or Esc cancels.
  final VoidCallback onClosed;

  @override
  State<_PathEditorField> createState() => _PathEditorFieldState();
}

class _PathEditorFieldState extends State<_PathEditorField> {
  final _text = TextEditingController();

  /// The controller generation whose seed is currently in the field —
  /// a re-invocation while mounted re-seeds instead of no-oping.
  late int _appliedGeneration;

  /// The seed applies selected-whole: `go.editPath` opens with the
  /// current path highlighted so a keystroke replaces it (02 §2.1's
  /// prefilled-and-selected rule); an empty seed just places the caret.
  void _applySeed() {
    final seed = widget.controller.pathFieldSeed;
    _appliedGeneration = widget.controller.pathFieldGeneration;
    _text.value = TextEditingValue(
      text: seed,
      selection: seed.isEmpty
          ? const TextSelection.collapsed(offset: 0)
          : TextSelection(baseOffset: 0, extentOffset: seed.length),
    );
  }

  @override
  void initState() {
    super.initState();
    _applySeed();
    // autofocus alone cannot take focus from a listing that already
    // holds it — the field must claim primary focus explicitly on open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.focusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(_PathEditorField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller.pathFieldGeneration != _appliedGeneration) {
      _applySeed();
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    widget.controller.submitPathField(_text.text);
    widget.onClosed();
  }

  void _cancel() {
    widget.controller.closePathField();
    widget.onClosed();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Focus(
      // Esc cancels from inside the field — the field tier of §8.2's
      // order, so an in-flight navigation underneath keeps loading.
      // This node sits in the focus ancestry above the field and sees
      // only keys the field itself did not consume.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        _cancel();
        return KeyEventResult.handled;
      },
      child: Center(
        // A floated label cannot fit the bar's height; the field's
        // accessible name rides Semantics instead and the hint carries
        // the accepted shapes (02 §2.1).
        child: Semantics(
          label: l10n.panePathFieldLabel,
          textField: true,
          child: TextField(
            key: ValueKey('${widget.controller.paneTabId}.path.field'),
            controller: _text,
            focusNode: widget.focusNode,
            autofocus: true,
            style: Theme.of(context).textTheme.bodySmall,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 7,
              ),
              border: const OutlineInputBorder(),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: colors.outlineVariant),
              ),
              hintText: l10n.panePathFieldHint,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
      ),
    );
  }
}

/// The keyboard modifiers held at a row press's POINTER-DOWN — the
/// moment D32 §6 selects on.
@immutable
class _PointerModifiers {
  const _PointerModifiers({
    required this.shift,
    required this.meta,
    required this.control,
  });

  final bool shift;
  final bool meta;
  final bool control;
}

/// The kind glyph's icon and category tint (D32 §6). The tint is a
/// scheme role per family — never an ad-hoc hue — and the active
/// selection repaints every glyph on-accent.
(IconData, Color) _kindGlyph(
  PaneKindCategory category,
  ColorScheme colors,
  PoltergeistChrome chrome,
) => switch (category) {
  PaneKindCategory.folder => (Icons.folder, colors.primary),
  PaneKindCategory.link => (Icons.shortcut_outlined, chrome.secondaryText),
  PaneKindCategory.image => (Icons.image_outlined, colors.tertiary),
  PaneKindCategory.text => (Icons.description_outlined, chrome.secondaryText),
  PaneKindCategory.archive => (Icons.inventory_2_outlined, colors.secondary),
  PaneKindCategory.pdf => (Icons.picture_as_pdf_outlined, colors.error),
  PaneKindCategory.media => (Icons.play_circle_outline, colors.tertiary),
  PaneKindCategory.other => (
    Icons.insert_drive_file_outlined,
    chrome.secondaryText,
  ),
};

/// One dense listing row (D32 §6): kind glyph, 13 px name, and the size
/// and date columns in the secondary tone with tabular figures. The
/// ACTIVE pane's selection paints the accent fill with on-accent text;
/// the inactive pane's is neutral grey. Desktop rows select on
/// pointer-down (the pane state owns the double-click window); touch
/// rows open on tap and select on long-press.
class _PaneRow extends StatefulWidget {
  const _PaneRow({
    required this.entry,
    required this.highlighted,
    required this.cursorRing,
    required this.selected,
    this.renaming = false,
    required this.dropTargeted,
    required this.active,
    required this.clock,
    required this.touch,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onTap,
    required this.onLongPress,
    required this.onOpen,
    this.onRename,
  });

  final RemoteFileEntry entry;

  /// Whether the cursor is on this row.
  final bool highlighted;

  /// Whether the cursor's shape marker shows (a subtle ring) — the
  /// cursor must stay identifiable inside a multi-selection by shape,
  /// not tint alone (02 §2.5).
  final bool cursorRing;

  /// The inline editor is open over this row: the editor shows the name
  /// in place, so the label itself steps aside rather than peeking out
  /// past the field.
  final bool renaming;

  /// Whether this row is in the selection (02 §2.5).
  final bool selected;

  /// Whether a live drag hover names this folder row its destination
  /// (02 §5.1's target highlight) — a ring distinct from both cursor
  /// and selection.
  final bool dropTargeted;

  /// Whether this row's pane is the active one.
  final bool active;
  final DateTime Function() clock;
  final bool touch;
  final ValueChanged<PointerDownEvent> onPointerDown;
  final ValueChanged<PointerMoveEvent> onPointerMove;
  final ValueChanged<PointerUpEvent> onPointerUp;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// The row's primary verb for assistive tech: open.
  final VoidCallback onOpen;

  /// §13's rename affordance on the row's semantics node (keyboard/AT
  /// parity with Enter/F2). Null when rename is unavailable — verbs
  /// gated off or a flagged name.
  final VoidCallback? onRename;

  @override
  State<_PaneRow> createState() => _PaneRowState();
}

class _PaneRowState extends State<_PaneRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final chrome = PoltergeistChrome.of(context);
    final metrics = PaneColumnMetrics.of(context);
    final platform = theme.platform;

    final size = formatPaneSize(
      widget.entry.type == RemoteFileType.directory ? null : widget.entry.size,
      platform: platform,
    );
    final modified = formatPaneModified(
      widget.entry.modifiedAt,
      now: widget.clock(),
      localeName: Localizations.localeOf(context).toString(),
      today: l10n.paneDateToday,
      yesterday: l10n.paneDateYesterday,
    );

    // D32 §3: the accent selection belongs to the pane that decides
    // transfers; the other pane's selection drops to neutral grey.
    final accentSelected = widget.selected && widget.active;
    final Color? fill = accentSelected
        ? chrome.selectionFill
        : widget.selected
        ? chrome.inactiveSelectionFill
        : (widget.dropTargeted || _hovered)
        ? chrome.hoverFill
        : null;
    final foreground = accentSelected ? chrome.onSelection : colors.onSurface;
    final secondary = accentSelected
        ? chrome.onSelection
        : chrome.secondaryText;
    final captionStyle = theme.textTheme.bodySmall?.copyWith(
      color: secondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final (glyph, tint) = _kindGlyph(
      paneKindCategory(widget.entry),
      colors,
      chrome,
    );

    // 02 §5.1's folder-row target ring outranks the cursor ring; both
    // paint in the foreground so they never shift the row's layout.
    final Border? ring = widget.dropTargeted
        ? Border.all(color: colors.primary, width: 2)
        : widget.cursorRing
        ? Border.all(
            color: widget.active
                ? (accentSelected
                      ? chrome.onSelection.withValues(alpha: 0.7)
                      : chrome.activePaneIndicator)
                : chrome.secondaryText.withValues(alpha: 0.6),
          )
        : null;

    // 02 §13: the row's kind is part of the announced label
    // (Name-Kind-Size-Date order); the glyph carries it only visually.
    final kind = switch (widget.entry.type) {
      RemoteFileType.file => l10n.paneRowKindFile,
      RemoteFileType.directory => l10n.paneRowKindDirectory,
      RemoteFileType.symbolicLink => l10n.paneRowKindSymbolicLink,
      RemoteFileType.other => l10n.paneRowKindOther,
    };

    // 02 §13's flagged-name rule: a U+FFFD name is undecodable — the
    // row keeps a warning badge + tooltip visually and spells the
    // reason into the semantics label; rename is withheld above.
    final flagged = nameIsFlagged(widget.entry.name);

    Widget content = DecoratedBox(
      decoration: BoxDecoration(color: fill),
      position: DecorationPosition.background,
      child: DecoratedBox(
        decoration: BoxDecoration(border: ring),
        position: DecorationPosition.foreground,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            start: PaneColumnMetrics.startPadding,
            end: PaneColumnMetrics.endPadding,
          ),
          child: Row(
            children: [
              Icon(
                glyph,
                size: PaneColumnMetrics.glyphSize,
                color: accentSelected ? chrome.onSelection : tint,
              ),
              const SizedBox(width: PaneColumnMetrics.glyphGap),
              Expanded(
                child: widget.renaming
                    ? const SizedBox.shrink()
                    : Text(
                        widget.entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: foreground,
                        ),
                      ),
              ),
              // 02 §13's flagged-name marker: the name already shows
              // U+FFFD; the badge + tooltip say why.
              if (flagged)
                Tooltip(
                  message: l10n.paneFlaggedNameTooltip,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 4),
                    child: Icon(
                      Icons.warning_amber_outlined,
                      size: 14,
                      color: accentSelected ? chrome.onSelection : colors.error,
                    ),
                  ),
                ),
              if (metrics.showsSize) ...[
                const SizedBox(width: PaneColumnMetrics.columnGap),
                SizedBox(
                  width: metrics.sizeWidth,
                  child: Text(
                    size,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: captionStyle,
                  ),
                ),
              ],
              const SizedBox(width: PaneColumnMetrics.columnGap),
              SizedBox(
                width: metrics.modifiedWidth,
                child: Text(
                  modified,
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: captionStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    content = widget.touch
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: content,
          )
        : MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: Listener(
              // Raw presses, never a tap recognizer: the row selects the
              // moment the button goes down, and the pane state times the
              // double-click itself (D32 §6).
              behavior: HitTestBehavior.opaque,
              onPointerDown: widget.onPointerDown,
              onPointerMove: widget.onPointerMove,
              onPointerUp: widget.onPointerUp,
              child: content,
            ),
          );

    return Semantics(
      label: flagged
          ? l10n.paneRowSemanticsFlagged(
              widget.entry.name,
              kind,
              size,
              modified,
            )
          : l10n.paneRowSemantics(widget.entry.name, kind, size, modified),
      // The composed label replaces the child text's own semantics —
      // without this, screen readers announce the name twice. The
      // excluded child no longer provides the tap action either, so
      // activation is exposed here.
      excludeSemantics: true,
      // AT activation opens the row: a screen reader's activate gesture
      // is the row's primary verb here (the cursor-set single click is
      // a sighted-user convention; Enter covers it for keyboards).
      onTap: widget.onOpen,
      // Announced membership follows the actual selection (02 §13),
      // never the cursor: a plain move single-selects its row, so the
      // cursor is announced selected except in the one state where it
      // is not selected — a toggled-off row.
      selected: widget.selected,
      // §13's open/rename action pair: open rides onTap; rename is a
      // custom action, absent when the row cannot take one.
      customSemanticsActions: {
        if (widget.onRename != null)
          CustomSemanticsAction(label: l10n.fileRenameLabel):
              widget.onRename!,
      },
      child: content,
    );
  }
}

class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({required this.error, required this.onRetry});

  final RemoteFileException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;

    return Center(
      child: SingleChildScrollView(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Semantics(
            // The overlay replaces the listing — announce its arrival.
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.error_outline, size: 18, color: colors.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        // D20: the taxonomy sentence is ARB-authored; the
                        // engine's message rides below as the diagnostic
                        // line. A failed file Open is a FILE problem —
                        // the kind taxonomy's folder sentence would
                        // misname the failed verb.
                        switch (error) {
                          OpenEntryError() => l10n.paneFaultOpenFile,
                          _ => switch (error.kind) {
                            RemoteFileErrorKind.notFound =>
                              l10n.paneErrorNotFound,
                            RemoteFileErrorKind.permissionDenied =>
                              l10n.paneErrorPermissionDenied,
                            RemoteFileErrorKind.unsupported =>
                              l10n.paneErrorUnsupported,
                            RemoteFileErrorKind.disconnected =>
                              l10n.paneErrorDisconnected,
                            RemoteFileErrorKind.conflict =>
                              l10n.paneErrorConflict,
                            RemoteFileErrorKind.cancelled =>
                              l10n.paneErrorCancelled,
                            RemoteFileErrorKind.other =>
                              l10n.paneErrorOther,
                          },
                        },
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  // Non-VFS faults carry no engine-authored diagnostic —
                  // the view maps the typed fault to an ARB sentence (D20);
                  // every other error keeps the engine's message line.
                  switch (error) {
                    // The title already carries the openFile sentence —
                    // an authored fault has no diagnostic to repeat.
                    PaneFaultException(fault: PaneFault.openFile) => '',
                    PaneFaultException(:final fault) => switch (fault) {
                      PaneFault.connectionOpen => l10n.paneFaultConnectionOpen,
                      PaneFault.localOpen => l10n.paneFaultLocalOpen,
                      PaneFault.listFolder => l10n.paneFaultListFolder,
                      PaneFault.invalidPath => l10n.paneFaultInvalidPath,
                      PaneFault.renameNameEmpty =>
                        l10n.paneFaultRenameNameEmpty,
                      PaneFault.renameNameSeparator =>
                        l10n.paneFaultRenameNameSeparator,
                      PaneFault.renameNameInvalid =>
                        l10n.paneFaultRenameNameInvalid,
                      PaneFault.renameTargetGone =>
                        l10n.paneFaultRenameTargetGone,
                      PaneFault.openFile => l10n.paneFaultOpenFile,
                    },
                    _ => error.message,
                  },
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('pane.error.retry'),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: Text(l10n.connectionRetry),
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

/// 02 §3's Reconnect bar for a session-restored remote tab: the same
/// banner contract as the connection-lost banner — the persisted cached
/// listing stays visible behind the body's scrim, inert — but the
/// session's truth is "offline until asked", not "transport lost": a
/// neutral surface, one Reconnect action, no Cancel (there is nothing
/// to cancel — the binding was never opened).
class _SessionReconnectBar extends StatelessWidget {
  const _SessionReconnectBar({required this.label, required this.onReconnect});

  final String label;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;

    return Container(
      key: const ValueKey('pane.reconnectBar'),
      width: double.infinity,
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: 12,
        vertical: 8,
      ),
      color: colors.secondaryContainer,
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 16,
            color: colors.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            // Live region like the connection banner: the restored
            // rows under the scrim are excluded from semantics, so
            // the bar is the only announcement of the tab's state.
            child: Semantics(
              liveRegion: true,
              child: Text(
                l10n.paneRestoredOffline(label),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSecondaryContainer,
                ),
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('pane.reconnectBar.reconnect'),
            onPressed: onReconnect,
            style: TextButton.styleFrom(
              foregroundColor: colors.onSecondaryContainer,
            ),
            child: Text(l10n.paneReconnect),
          ),
        ],
      ),
    );
  }
}

/// 02 §2.7's connection-lost banner: keyed on connection state, it tops
/// the banner slot while the transport reconnects (the body owns the
/// matching dim layer).
class _LostConnectionBanner extends StatelessWidget {
  const _LostConnectionBanner({
    required this.label,
    required this.onCancel,
    this.onRetry,
  });

  final String label;
  final VoidCallback onCancel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;

    return Container(
      key: const ValueKey('pane.banner'),
      width: double.infinity,
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: 12,
        vertical: 8,
      ),
      color: colors.errorContainer,
      child: Row(
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 16,
            color: colors.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            // Live region: the banner's appearance is announced to
            // assistive tech (the scrim hides the stale content from
            // semantics, so the banner is the only signal).
            child: Semantics(
              liveRegion: true,
              child: Text(
                onRetry == null
                    ? l10n.paneConnectionLost(label)
                    : l10n.paneConnectionRecoveryFailed(label),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onErrorContainer),
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              key: const ValueKey('pane.banner.retry'),
              onPressed: onRetry,
              child: Text(l10n.connectionRetry),
            ),
          TextButton(
            key: const ValueKey('pane.banner.cancel'),
            onPressed: onCancel,
            style: TextButton.styleFrom(
              foregroundColor: colors.onErrorContainer,
            ),
            child: Text(l10n.paneConnectionLostCancel),
          ),
        ],
      ),
    );
  }
}

/// 02 §2.5's Quick Select strip: a small field below the header with an
/// Add/Remove segmented toggle. The controller owns the session — the
/// field is pure plumbing between keystrokes and the controller's
/// quick-select verbs, so every query or mode edit recomputes the live
/// preview from the session's opening selection (03 §2.5).
class _QuickSelectField extends StatefulWidget {
  const _QuickSelectField({
    super.key,
    required this.controller,
    required this.onClosed,
  });

  final PaneController controller;

  /// Returns focus to the listing after Enter/Esc close the session.
  final VoidCallback onClosed;

  @override
  State<_QuickSelectField> createState() => _QuickSelectFieldState();
}

class _QuickSelectFieldState extends State<_QuickSelectField> {
  late final TextEditingController _query;
  final _fieldFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The session outlives the field: a tab switch disposes this state
    // while the controller retains the query and its preview, so a
    // remount seeds from the session — a blank field over a live
    // preview would confirm an invisible query on Enter.
    _query = TextEditingController(
      text: widget.controller.quickSelectQuery,
    );
    // autofocus alone cannot take focus from a listing that already
    // holds it — the field must claim primary focus explicitly on open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fieldFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _fieldFocus.dispose();
    _query.dispose();
    super.dispose();
  }

  void _confirm() {
    widget.controller.confirmQuickSelect();
    widget.onClosed();
  }

  void _cancel() {
    widget.controller.cancelQuickSelect();
    widget.onClosed();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Focus(
      // Esc cancels from anywhere inside the strip — the field and the
      // toggle. This node sits in the focus ancestry above both, so it
      // sees only keys the focused child did not consume.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        _cancel();
        return KeyEventResult.handled;
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(bottom: BorderSide(color: colors.outlineVariant)),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 8, 6),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 6),
                child: Icon(
                  Icons.manage_search_outlined,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
              ),
              Expanded(
                // A floated label cannot fit this strip's height; the
                // field's accessible name rides Semantics instead and
                // the hint carries the two match shapes (02 §2.5).
                child: Semantics(
                  label: l10n.quickSelectFieldLabel,
                  textField: true,
                  child: TextField(
                    key: ValueKey(
                      '${widget.controller.paneTabId}.quickSelect.field',
                    ),
                    controller: _query,
                    focusNode: _fieldFocus,
                    autofocus: true,
                    style: Theme.of(context).textTheme.bodySmall,
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      hintText: l10n.quickSelectFieldHint,
                    ),
                    onChanged: widget.controller.changeQuickSelectQuery,
                    onSubmitted: (_) => _confirm(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SegmentedButton<QuickSelectMode>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: [
                  ButtonSegment(
                    value: QuickSelectMode.add,
                    label: Text(l10n.quickSelectAddLabel),
                  ),
                  ButtonSegment(
                    value: QuickSelectMode.remove,
                    label: Text(l10n.quickSelectRemoveLabel),
                  ),
                ],
                selected: {widget.controller.quickSelectMode},
                onSelectionChanged: (modes) =>
                    widget.controller.changeQuickSelectMode(modes.first),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 02 §2.7's filtered-to-nothing empty state: the dedicated
/// `No items match "q"` message with the Clear button — never a blank
/// pane while a filter hides every row.
class _FilteredEmpty extends StatelessWidget {
  const _FilteredEmpty({required this.controller});

  final PaneController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.paneFilterNoMatch(controller.filterQuery),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.tonal(
            key: ValueKey('${controller.paneTabId}.filter.emptyClear'),
            onPressed: controller.clearFilter,
            child: Text(l10n.paneFilterClear),
          ),
        ],
      ),
    );
  }
}

/// 02 §10's transient notice strip: the honest "not yet" for a
/// registered-but-deferred activation — a remote file's Open (managed
/// checkout is the editor milestone's), or the Double-click action's
/// Edit and Transfer values. Informational, never an error, so it
/// strips in under the pane chrome instead of taking the §2.8 error
/// overlay; the controller owns the value, the auto-hide timer, and
/// the binding-teardown drop. The ✕ dismisses early (02 §10's
/// "transient or dismiss" — this notice is both).
class _NoticeStrip extends StatelessWidget {
  const _NoticeStrip({required this.controller});

  final PaneController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      // A polite live-region announcement: the strip appears under the
      // user's own activation, so an assertive interrupt would over-say it.
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(bottom: BorderSide(color: colors.outlineVariant)),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 8, 6),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 6),
                // Decorative — the sentence alone is the announcement.
                child: ExcludeSemantics(
                  child: Icon(
                    Icons.info_outline,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  // D20: the view maps the typed notice to its
                  // ARB-authored sentence — the controller never
                  // authors user copy.
                  switch (controller.notice) {
                    PaneNotice.openRemoteUnavailable =>
                      l10n.paneNoticeOpenRemoteUnavailable,
                    PaneNotice.editLater => l10n.paneNoticeEditLater,
                    PaneNotice.transferLater => l10n.paneNoticeTransferLater,
                    PaneNotice.saveFavoriteLater =>
                      l10n.paneNoticeSaveFavoriteLater,
                    PaneNotice.pathCopied => l10n.paneNoticePathCopied,
                    PaneNotice.dragOutRemote => l10n.paneNoticeDragOutRemote,
                    PaneNotice.watchStopped => l10n.paneNoticeWatchStopped,
                    null => '',
                  },
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              IconButton(
                key: ValueKey('${controller.paneTabId}.notice.dismiss'),
                tooltip: l10n.paneNoticeDismiss,
                onPressed: controller.dismissNotice,
                icon: const Icon(Icons.close, size: 16),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
