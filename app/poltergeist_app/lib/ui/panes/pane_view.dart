import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/pane_controller.dart';
import '../../services/pane_location.dart';
import '../../services/quick_select_state.dart';
import '../../services/selection_state.dart';
import '../../services/workspace_controller.dart';
import 'pane_format.dart';

/// 02 §2.8's anti-flash grace: no spinner, dim, footer swap, or cancel
/// affordance before this, so fast navigations never flash.
const _antiFlashGrace = Duration(milliseconds: 150);

/// Whether a remote bind is in flight for this pane — the single
/// definition shared by the Esc key path and the post-grace Cancel
/// action, so the two affordances can never drift apart.
bool _pendingRemoteConnect(PaneController controller) =>
    controller.phase == PanePhase.connectingRemote &&
    controller.remoteBookmark != null;

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

/// 02 §11's comfortable row density (28 px), scaled by the active text
/// scale so scaled text never clips (D20). Recomputed per build, which
/// preserves the fixed-extent virtualization. One definition, shared by
/// the row extent and the cursor-reveal scroll arithmetic.
const _comfortableRowExtent = 28.0;

/// Width of the leading cursor bar: the cursor row must stay
/// identifiable inside a multi-selection by shape, not tint alone —
/// M3's container tints are too close for that (02 §13's focus-visible
/// principle applied to the listing cursor). Every row reserves the
/// space so the cursor never shifts row content as it moves.
const _cursorBarWidth = 3.0;

double scaledPaneRowExtent(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(_comfortableRowExtent);

/// One pane's browsing surface (foundation slice): path bar with
/// clickable ancestor segments, fixed-extent listing rows (name, kind,
/// size, mtime), inline errors over cached entries, latency-honest
/// loading states, the connection-lost banner, and the keyboard-first
/// interactions (arrows, Enter, Esc, Tab, Home/End, Backspace — 02 §8.2
/// scoped to the pane's focus node).
///
/// The pane never blocks the UI isolate (D8): every byte of file data
/// crosses through the engine channel the controller drives.
class PaneView extends StatefulWidget {
  const PaneView({
    super.key,
    required this.controller,
    required this.workspace,
    required this.focusNode,
    required this.onSwapFocus,
    required this.onCancelRecovery,
    this.clock = _systemClock,
  });

  final PaneController controller;

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
  late Listenable _listenable = Listenable.merge([
    widget.controller,
    widget.workspace,
  ]);
  Timer? _graceTimer;
  bool _pastGrace = false;
  bool _disposed = false;
  bool _quickSelectWasActive = false;
  final _quickSelectFieldKey = GlobalKey();
  // The filter field's focus node lives here (not inside the strip's
  // state) so `view.filter` can re-focus an already-mounted strip — the
  // controller's focus-generation bump is the request signal.
  final _filterFocusNode = FocusNode();
  final _filterStripKey = GlobalKey();
  int _filterFocusSeen = 0;
  bool _filterStripWasVisible = false;
  String? _revealedLocationPath;
  List<RemoteFileEntry>? _revealedEntries;

  @override
  void didUpdateWidget(PaneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller) ||
        !identical(oldWidget.workspace, widget.workspace)) {
      _listenable = Listenable.merge([widget.controller, widget.workspace]);
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
      _filterFocusSeen = 0;
      _filterStripWasVisible = false;
      _revealedLocationPath = null;
      _revealedEntries = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _graceTimer?.cancel();
    _scrollController.dispose();
    _filterFocusNode.dispose();
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

  /// The filter strip's two focus chores. A `view.filter` invocation
  /// bumps the controller's focus generation — including over an
  /// already-mounted strip — so the field re-claims primary focus on a
  /// change. And when the strip unmounts under a still-focused field —
  /// a Clear click, a controller-side clear, a rebind — primary focus
  /// strands at the root; return it to the listing unless a deliberate
  /// target already claimed it (same rule as Quick Select's close).
  void _syncFilterFocus() {
    final controller = widget.controller;
    final stripVisible = controller.filterFieldOpen || controller.filterActive;
    final focusRequest = controller.filterFocusGeneration != _filterFocusSeen;
    _filterFocusSeen = controller.filterFocusGeneration;
    final justClosed = _filterStripWasVisible && !stripVisible;
    _filterStripWasVisible = stripVisible;
    if (!focusRequest && !justClosed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      if (focusRequest && stripVisible) {
        _filterFocusNode.requestFocus();
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

    // 02 §2.8: once the grace passes, the pane's OWN keys are inert —
    // the entries under the dim are stale; the connection-lost scrim
    // declares the same inertness (pointer and semantics are already
    // blocked there — the keyboard must not be the one live path onto
    // stale entries). Type-ahead input is inert for the same reason:
    // matching a stale listing would jump a cursor onto disowned rows.
    // Unowned keys fall through to ancestors (app shortcuts stay live
    // during slow loads); Esc and Tab reach the switch below and stay
    // live.
    final ownedKey =
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.space;
    if ((controller.connectionLost ||
            controller.error != null ||
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
        // (§8.3), and rename lands with the row-interactions slice.
        // Key repeats never re-open — holding Enter must not drill
        // through nested folders (and the owned key must not leak its
        // repeats to other handlers).
        if (event is KeyRepeatEvent) {
          return KeyEventResult.handled;
        }
        if (platform == TargetPlatform.windows ||
            platform == TargetPlatform.linux) {
          _openCursor();
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
      case LogicalKeyboardKey.escape:
        if (controller.loading) {
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
          // 02 §8.2's Esc order: an active-but-unfocused filter clears
          // below navigation-cancel (a filtered loading pane's first
          // Esc still cancels the load) and above the type-ahead
          // buffer. The field-focused Esc never reaches here — the
          // strip's own Focus handles it at the field tier.
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

  void _openCursor() {
    final controller = widget.controller;
    final cursor = controller.cursorIndex;
    if (cursor == null || cursor >= controller.entries.length) return;
    controller.openEntry(controller.entries[cursor]);
  }

  /// Resolves a row tap's selection gesture from the modifiers captured
  /// at POINTER-DOWN and the platform (02 §2.5): plain click singles,
  /// meta on macOS / control elsewhere toggles, shift extends the
  /// anchored range. Shift wins the modifier race on every platform so
  /// a ctrl/⌘+shift click keeps one predictable range meaning. The
  /// modifiers come from the row's pointer-down listener — a tap
  /// commits up to kDoubleTapTimeout later (onTap coexists with
  /// onDoubleTap), so reading HardwareKeyboard at commit time would
  /// miss a modifier released inside that window.
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        _syncGrace(_graceBusy());
        _syncReveal();
        _syncQuickSelectFocus();
        _syncFilterFocus();
        final active = identical(
          widget.workspace.activePane,
          widget.controller,
        );
        return Semantics(
          container: true,
          label: widget.controller.paneTabId == 'pane.left'
              ? l10n.paneAName
              : l10n.paneBName,
          child: Focus(
            focusNode: widget.focusNode,
            onKeyEvent: _handleKey,
            onFocusChange: (focused) {
              if (focused) widget.workspace.setActivePane(widget.controller);
            },
            child: Listener(
              // Clicking anywhere in the pane focuses its listing (and so
              // activates the pane) — the two-pane muscle-memory basic. A
              // raw pointer listener, not a gesture: a pane-level tap
              // recognizer would join the arena against the row InkWells
              // and both would lose.
              onPointerDown: (event) {
                // The pane's field strips keep their own clicks: a
                // pointer down inside the Quick Select or filter strip
                // must not bounce focus to the listing before the
                // field's own tap handler runs.
                for (final key in [_quickSelectFieldKey, _filterStripKey]) {
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
              child: _PaneSurface(
                controller: widget.controller,
                active: active,
                graceVisible: _pastGrace,
                scrollController: _scrollController,
                clock: widget.clock,
                onCancelNavigation: widget.controller.cancelNavigation,
                onRetry: () => unawaited(widget.controller.retry()),
                onCancelRecovery: widget.onCancelRecovery,
                onQuickSelectClosed: () => widget.focusNode.requestFocus(),
                quickSelectFieldKey: _quickSelectFieldKey,
                filterStripKey: _filterStripKey,
                filterFocusNode: _filterFocusNode,
                onFilterClosed: () => widget.focusNode.requestFocus(),
                onActivateRow: (index, modifiers) {
                  widget.controller.setCursorIndex(
                    index,
                    update: _selectionUpdateFor(
                      modifiers,
                      Theme.of(context).platform,
                    ),
                  );
                  widget.focusNode.requestFocus();
                },
                onOpenRow: (index) {
                  final entries = widget.controller.entries;
                  if (index < entries.length) {
                    widget.controller.openEntry(entries[index]);
                  }
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PaneSurface extends StatelessWidget {
  const _PaneSurface({
    required this.controller,
    required this.active,
    required this.graceVisible,
    required this.scrollController,
    required this.clock,
    required this.onCancelNavigation,
    required this.onRetry,
    required this.onCancelRecovery,
    required this.onQuickSelectClosed,
    required this.quickSelectFieldKey,
    required this.filterStripKey,
    required this.filterFocusNode,
    required this.onFilterClosed,
    required this.onActivateRow,
    required this.onOpenRow,
  });

  final PaneController controller;
  final bool active;
  final bool graceVisible;
  final ScrollController scrollController;
  final DateTime Function() clock;
  final VoidCallback onCancelNavigation;
  final VoidCallback onRetry;
  final VoidCallback onCancelRecovery;
  final VoidCallback onQuickSelectClosed;
  final GlobalKey quickSelectFieldKey;

  /// The filter strip's hit-test boundary for the pane's pointer-down
  /// listener (clicks inside it must not bounce focus to the listing).
  final GlobalKey filterStripKey;

  /// The filter field's focus node, owned by the pane state so a
  /// `view.filter` re-invocation can re-focus the mounted field.
  final FocusNode filterFocusNode;

  /// Returns focus to the listing after the field's own Enter/Esc.
  final VoidCallback onFilterClosed;
  final ValueChanged<int> onOpenRow;
  final void Function(int index, _PointerModifiers? modifiers) onActivateRow;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PathBar(
          controller: controller,
          active: active,
          loadingVisible: graceVisible && !controller.connectionLost,
          onCancel: onCancelNavigation,
        ),
        // 02 §2.5: the Quick Select field drops in below the path bar
        // while the controller reports an open session.
        if (controller.quickSelectActive)
          _QuickSelectField(
            key: quickSelectFieldKey,
            controller: controller,
            onClosed: onQuickSelectClosed,
          ),
        // The filter strip: open for editing on `view.filter`, and held
        // mounted while a query stays active after the field yields
        // focus — its helper text is the only visible proof the lens is
        // on (02 §2.5).
        if (controller.filterFieldOpen || controller.filterActive)
          _FilterField(
            key: filterStripKey,
            controller: controller,
            focusNode: filterFocusNode,
            onClosed: onFilterClosed,
          ),
        Expanded(child: _body(context, l10n)),
        _PaneFooter(
          controller: controller,
          graceVisible: graceVisible && !controller.connectionLost,
        ),
      ],
    );
  }

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
        // The inline error makes the stale listing's POINTERS inert as
        // well (the error card never covers the whole listing, and a
        // stray click on an uncovered stale row would change selection
        // over data the pane has disowned) — scoped to this subtree,
        // never a Stack sibling, so chrome added to this Stack later
        // stays clickable.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: controller.error != null && !controller.connectionLost,
            child: ExcludeSemantics(
              excluding:
                  controller.connectionLost ||
                  controller.error != null ||
                  (controller.loading && graceVisible),
              child: controller.connectionLost
                  ? _listing(context, l10n)
                  : switch (controller.phase) {
                      PanePhase.unbound => _Centered(l10n.paneNoLocation),
                      PanePhase.openingLocal || PanePhase.connectingRemote =>
                        _connectingBody(context, l10n),
                      PanePhase.browsing => _listing(context, l10n),
                    },
            ),
          ),
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
    if (!controller.connectionLost) return content;

    // Reserve banner space so even a short cached listing remains visible.
    return _LostConnectionBanner(
      label: controller.remoteBookmark?.label ?? '',
      onCancel: onCancelRecovery,
      onRetry: controller.canRetryRecovery ? onRetry : null,
      child: content,
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
    if (controller.entries.isEmpty) {
      // Never claim emptiness while a load is in flight (02 §2.8's
      // nothing-before-grace rule): the first listing of an empty
      // folder would otherwise flash "Empty folder" before arrival.
      if (controller.loading || controller.connectionLost) {
        return const SizedBox.shrink();
      }
      // 02 §2.7's filtered-to-nothing state: the dedicated message plus
      // the Clear affordance — never a blank pane.
      if (controller.filterActive) {
        return _FilteredEmpty(controller: controller);
      }
      return Center(child: Text(l10n.paneEmptyFolder));
    }

    final extent = scaledPaneRowExtent(context);

    return ListView.builder(
      controller: scrollController,
      itemExtent: extent,
      itemCount: controller.entries.length,
      itemBuilder: (context, index) => _PaneRow(
        entry: controller.entries[index],
        highlighted: controller.cursorIndex == index,
        selected: controller.isRowSelected(index),
        active: active,
        clock: clock,
        onTap: (modifiers) => onActivateRow(index, modifiers),
        onDoubleTap: () => onOpenRow(index),
      ),
    );
  }
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

/// The path bar (02 §2.1, foundation subset): one clickable segment per
/// ancestor, focused-pane accent, the 2 px progress line, and the cancel
/// affordance while a navigation is outstanding.
class _PathBar extends StatefulWidget {
  const _PathBar({
    required this.controller,
    required this.active,
    required this.loadingVisible,
    required this.onCancel,
  });

  final PaneController controller;
  final bool active;
  final bool loadingVisible;
  final VoidCallback onCancel;

  @override
  State<_PathBar> createState() => _PathBarState();
}

class _PathBarState extends State<_PathBar> {
  final _segmentScroll = ScrollController();
  String? _revealedPath;

  @override
  void initState() {
    super.initState();
    // First mount with a deep path: didUpdateWidget never fires for
    // it, so seed the reveal here too.
    final path = widget.controller.location?.path;
    _revealedPath = path;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_segmentScroll.hasClients) return;
      _segmentScroll.jumpTo(_segmentScroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _segmentScroll.dispose();
    super.dispose();
  }

  // Deep paths overflow the bar: the deepest segment — where the user
  // IS — must be the visible one, so reveal the tail on every location
  // change (02 §2.1's "where am I" is the bar's whole job).
  @override
  void didUpdateWidget(_PathBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final path = widget.controller.location?.path;
    if (path == _revealedPath) return;
    _revealedPath = path;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_segmentScroll.hasClients) return;
      _segmentScroll.jumpTo(_segmentScroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final location = controller.location;
    final segments = location == null
        ? <(String, String)>[]
        : _segmentsOf(location.path);

    // 02 §2.1: the focused pane's segments render in the accent color so
    // the transfer-deciding side is always visible.
    final segmentColor = widget.active
        ? colors.primary
        : colors.onSurfaceVariant;

    return Column(
      children: [
        Container(
          key: ValueKey('${controller.paneTabId}.path'),
          height: MediaQuery.textScalerOf(context).scale(34),
          color: colors.surfaceContainerLow,
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
          child: Row(
            children: [
              Icon(
                location is RemotePaneLocation
                    ? Icons.dns_outlined
                    : Icons.folder_outlined,
                size: 16,
                color: segmentColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: ListView(
                  controller: _segmentScroll,
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final (label, path) in segments)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 2),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(4),
                          onTap: () => controller.navigate(path),
                          child: Padding(
                            padding: const EdgeInsetsDirectional.symmetric(
                              horizontal: 6,
                              vertical: 8,
                            ),
                            child: Text(
                              label,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: segmentColor),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (controller.loading && widget.loadingVisible)
                IconButton(
                  key: ValueKey('${controller.paneTabId}.cancel'),
                  tooltip: l10n.paneCancelLoading,
                  onPressed: widget.onCancel,
                  icon: const Icon(Icons.close, size: 16),
                ),
            ],
          ),
        ),
        // 02 §2.8: a 2 px indeterminate progress line under the path bar
        // once the anti-flash grace has passed.
        if (controller.loading && widget.loadingVisible)
          SizedBox(
            key: ValueKey('${controller.paneTabId}.progress'),
            height: 2,
            child: const LinearProgressIndicator(),
          ),
      ],
    );
  }

  /// ('/', '/'), ('home', '/home'), ('tester', '/home/tester') — one
  /// clickable segment per ancestor, root first.
  List<(String, String)> _segmentsOf(String path) {
    final separator = path.startsWith('/') ? '/' : '\\';
    final segments = <(String, String)>[];
    var walking = path;
    while (true) {
      final parent = paneParentPath(walking);
      if (parent == walking) break;
      segments.add((
        walking.substring(parent.length).replaceAll(separator, ''),
        walking,
      ));
      walking = parent;
    }
    // Collected deepest-first; flip so children follow parents, with
    // the root leading (02 §2.1's ancestor order).
    final ordered = segments.reversed.toList();
    ordered.insert(0, (walking, walking)); // the root ('/' or 'C:\')
    return ordered;
  }
}

/// The pointer modifiers of one row tap, captured at POINTER-DOWN: a
/// tap commits up to kDoubleTapTimeout later (rows carry both onTap
/// and onDoubleTap), so reading HardwareKeyboard at commit time would
/// miss a modifier released inside that window and silently downgrade
/// a range or toggle gesture to a plain single-select.
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

class _PaneRow extends StatefulWidget {
  const _PaneRow({
    required this.entry,
    required this.highlighted,
    required this.selected,
    required this.active,
    required this.clock,
    required this.onTap,
    required this.onDoubleTap,
  });

  final RemoteFileEntry entry;

  /// Whether the cursor is on this row.
  final bool highlighted;

  /// Whether this row is in the selection (02 §2.5).
  final bool selected;

  final bool active;
  final DateTime Function() clock;
  final ValueChanged<_PointerModifiers?> onTap;
  final VoidCallback onDoubleTap;

  @override
  State<_PaneRow> createState() => _PaneRowState();
}

class _PaneRowState extends State<_PaneRow> {
  _PointerModifiers? _downModifiers;

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final platform = Theme.of(context).platform;

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

    // 02 §2.1: the unfocused pane's selection highlight drops to a
    // neutral tone. Selected rows keep a quieter tint than the cursor
    // row so the cursor stays identifiable inside a multi-selection
    // (02 §2.5's visible-selection rule).
    final Color? rowColor = widget.highlighted
        ? (widget.active
              ? colors.primaryContainer
              : colors.surfaceContainerHighest)
        : widget.selected
        ? (widget.active
              ? colors.secondaryContainer
              : colors.surfaceContainerHigh)
        : null;

    // 02 §13: the row's kind is part of the announced label
    // (Name-Kind-Size-Date order); the icon carries it only visually.
    final kind = switch (widget.entry.type) {
      RemoteFileType.file => l10n.paneRowKindFile,
      RemoteFileType.directory => l10n.paneRowKindDirectory,
      RemoteFileType.symbolicLink => l10n.paneRowKindSymbolicLink,
      RemoteFileType.other => l10n.paneRowKindOther,
    };

    return Semantics(
      label: l10n.paneRowSemantics(widget.entry.name, kind, size, modified),
      // The composed label replaces the child text's own semantics —
      // without this, screen readers announce the name twice. The
      // excluded child no longer provides the tap action either, so
      // activation is exposed here.
      excludeSemantics: true,
      // AT activation opens the row: a screen reader's activate gesture
      // is the row's primary verb here (the cursor-set single click is
      // a sighted-user convention; Enter covers it for keyboards).
      onTap: widget.onDoubleTap,
      // Announced membership follows the actual selection (02 §13),
      // never the cursor: a plain move single-selects its row, so the
      // cursor is announced selected except in the one state where it
      // is not selected — a toggled-off row.
      selected: widget.selected,
      child: Material(
        // The row owns its surface so ink feedback paints above the
        // row color (an opaque ColoredBox inside the InkWell would
        // cover the splash entirely).
        color: rowColor ?? colors.surface,
        child: Listener(
          // Capture the gesture's modifiers at pointer-down: the tap
          // callback commits after the double-tap window.
          onPointerDown: (event) {
            final keyboard = HardwareKeyboard.instance;
            _downModifiers = _PointerModifiers(
              shift: keyboard.isShiftPressed,
              meta: keyboard.isMetaPressed,
              control: keyboard.isControlPressed,
            );
          },
          child: InkWell(
            onTap: () => widget.onTap(_downModifiers),
            onDoubleTap: widget.onDoubleTap,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 8 + _cursorBarWidth,
                    end: 8,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        switch (widget.entry.type) {
                          RemoteFileType.directory => Icons.folder_outlined,
                          RemoteFileType.symbolicLink =>
                            Icons.shortcut_outlined,
                          _ => Icons.insert_drive_file_outlined,
                        },
                        size: 16,
                        color: colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          widget.entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: MediaQuery.textScalerOf(context).scale(64),
                        child: Text(
                          size,
                          textAlign: TextAlign.end,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: MediaQuery.textScalerOf(context).scale(120),
                        child: Text(
                          modified,
                          textAlign: TextAlign.end,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
                // The cursor's shape marker, on the row's leading edge in
                // both the active and the unfocused pane's tones.
                if (widget.highlighted)
                  PositionedDirectional(
                    start: 0,
                    top: 0,
                    bottom: 0,
                    width: _cursorBarWidth,
                    child: ColoredBox(
                      color: widget.active
                          ? colors.primary
                          : colors.onSurfaceVariant,
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

class _PaneFooter extends StatelessWidget {
  const _PaneFooter({required this.controller, required this.graceVisible});

  final PaneController controller;
  final bool graceVisible;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    // 02 §2.8/§2.9: the footer doubles as the loading line, behind the
    // same anti-flash grace as the dim.
    final String text = controller.loading && graceVisible
        ? l10n.paneLoadingFolder(paneLastSegment(controller.location?.path))
        : l10n.paneItemCount(controller.entries.length);

    return Container(
      key: const ValueKey('pane.footer'),
      height: MediaQuery.textScalerOf(context).scale(24),
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 10),
      color: colors.surfaceContainerLow,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
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
                        // engine's message rides below as the diagnostic line.
                        switch (error.kind) {
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
                          RemoteFileErrorKind.other => l10n.paneErrorOther,
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
                    PaneFaultException(:final fault) => switch (fault) {
                      PaneFault.connectionOpen => l10n.paneFaultConnectionOpen,
                      PaneFault.localOpen => l10n.paneFaultLocalOpen,
                      PaneFault.listFolder => l10n.paneFaultListFolder,
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

/// 02 §2.7's connection-lost banner: keyed on connection state, it owns
/// the pane's single dim layer while the transport reconnects.
class _LostConnectionBanner extends StatelessWidget {
  const _LostConnectionBanner({
    required this.label,
    required this.onCancel,
    required this.child,
    this.onRetry,
  });

  final String label;
  final VoidCallback onCancel;
  final Widget child;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        Container(
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
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onErrorContainer,
                    ),
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
        ),
        Expanded(
          // Absorb, not ignore: the stale listing under the scrim must
          // not take interactions while the transport is down (the
          // banner above the scrim stays reachable).
          child: Stack(
            children: [
              Positioned.fill(child: child),
              Positioned.fill(
                child: AbsorbPointer(
                  child: ColoredBox(
                    color: colors.surfaceContainerLowest.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 02 §2.5's Quick Select strip: a small field below the path bar with an
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
  final _query = TextEditingController();
  final _fieldFocus = FocusNode();

  @override
  void initState() {
    super.initState();
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
          border: Border(
            bottom: BorderSide(color: colors.outlineVariant),
          ),
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

/// 02 §2.5's Filter strip (`view.filter`): a small field below the path
/// bar that re-filters the visible listing live as a case-insensitive
/// substring, plus the `visible of total` helper while a query is active
/// and a Clear affordance. Esc is the field tier of §8.2's order —
/// clearing the filter and closing the strip; Enter keeps the filter
/// and returns focus to the listing.
class _FilterField extends StatefulWidget {
  const _FilterField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onClosed,
  });

  final PaneController controller;

  /// Owned by the pane state so `view.filter` re-invocations can
  /// re-focus the field while the strip stays mounted.
  final FocusNode focusNode;

  /// Returns focus to the listing after Enter commits or Esc clears.
  final VoidCallback onClosed;

  @override
  State<_FilterField> createState() => _FilterFieldState();
}

class _FilterFieldState extends State<_FilterField> {
  late final TextEditingController _query = TextEditingController(
    text: widget.controller.filterQuery,
  );

  @override
  void didUpdateWidget(_FilterField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The field is the query's only editor; if the controller's query
    // ever differs from the field's text (a controller-side change that
    // left the strip mounted), the controller wins.
    if (widget.controller.filterQuery != _query.text) {
      _query.text = widget.controller.filterQuery;
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _clear() {
    widget.controller.clearFilter();
    widget.onClosed();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final controller = widget.controller;
    return Focus(
      // Esc clears from anywhere inside the strip — the field tier of
      // §8.2's order. This node sits in the focus ancestry above the
      // field and sees only keys the focused child did not consume.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        _clear();
        return KeyEventResult.handled;
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(
            bottom: BorderSide(color: colors.outlineVariant),
          ),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 8, 6),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 6),
                child: Icon(
                  Icons.filter_list_outlined,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
              ),
              Expanded(
                // A floated label cannot fit this strip's height; the
                // field's accessible name rides Semantics instead and
                // the hint states the match shape (02 §2.5's plain
                // substring — no glob, no diacritic folding).
                child: Semantics(
                  label: l10n.paneFilterFieldLabel,
                  textField: true,
                  child: TextField(
                    key: ValueKey(
                      '${widget.controller.paneTabId}.filter.field',
                    ),
                    controller: _query,
                    focusNode: widget.focusNode,
                    autofocus: true,
                    style: Theme.of(context).textTheme.bodySmall,
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      hintText: l10n.paneFilterFieldHint,
                    ),
                    onChanged: controller.changeFilterQuery,
                    // Enter keeps the active filter and returns focus to
                    // the listing — the strip stays mounted while a
                    // query is live so the helper text remains visible.
                    onSubmitted: (_) => widget.onClosed(),
                  ),
                ),
              ),
              if (controller.filterActive) ...[
                const SizedBox(width: 8),
                Text(
                  // 02 §2.5's `12 of 348` helper: visible of total.
                  l10n.paneFilterCount(
                    controller.entries.length,
                    controller.unfilteredCount,
                  ),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(width: 4),
              IconButton(
                key: ValueKey(
                  '${widget.controller.paneTabId}.filter.clear',
                ),
                tooltip: l10n.paneFilterClear,
                onPressed: _clear,
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
            key: const ValueKey('pane.filter.emptyClear'),
            onPressed: controller.clearFilter,
            child: Text(l10n.paneFilterClear),
          ),
        ],
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
