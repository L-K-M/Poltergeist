import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/pane_controller.dart';
import '../../services/registered_command.dart';
import '../../services/selection_state.dart';
import '../../services/workspace_controller.dart';
import '../inspector/inspector_view.dart';
import '../panes/pane_commands.dart' show kFileGetInfoCommandId;
import '../panes/pane_context_menu.dart';
import 'compact_browser.dart';
import 'compact_home.dart';
import 'compact_inspector_sheet.dart';
import 'compact_listing.dart';
import 'compact_posture.dart';
import 'compact_progress_pill.dart';

/// What one system back does next, in D32 §9's order. An open field —
/// the filter, a Quick Select session — is a transient mode of the
/// browser like the sheet, so it closes after the sheet and before
/// folder history.
enum CompactBackStep {
  clearSelection,
  closeSheet,
  closeField,
  folderBack,
  home,
  leave,
}

/// The selection bar's height (without the gesture-bar inset) — the
/// progress pill floats above it.
const double _selectionBarHeight = 80;

/// Room the listing keeps below its last row while the pill floats there.
const double _pillClearance = 72;

/// Home's FAB (56 dp) plus its 16 dp margins, which the pill stays clear
/// of.
const double _fabClearance = 88;

/// D32 §9's compact posture: Home (the full-screen sidebar) with the
/// browser pushed over it, one pane at a time, the inspector as a
/// draggable bottom sheet, and a floating progress pill while transfers
/// run.
///
/// Navigation is a state flag with its own transition rather than a
/// nested Navigator — Séance's Android model (10 §10.6): every modal the
/// commands raise (dialogs, sheets) stays on the app's one navigator, so
/// it is always above this surface and always closes first on back, and
/// one [PopScope] walks the compact modes in order: clear the selection,
/// close the sheet, close the filter, go back in folder history, return
/// to Home, then leave the app. Home stays mounted under the browser, so
/// its scroll position and filter survive the round trip.
///
/// Both panes stay logically shown: the workspace hears that pane B is
/// on screen (the switcher flips between them), so Copy/Move to Other
/// Pane keep their implicit destination on a phone.
class CompactWorkspace extends StatefulWidget {
  const CompactWorkspace({
    super.key,
    required this.workspace,
    required this.commands,
    required this.onRunCommand,
    required this.inspector,
    required this.seams,
    this.home,
    this.clock = DateTime.now,
  });

  final WorkspaceController workspace;
  final List<RegisteredCommand> commands;
  final Future<void> Function(RegisteredCommand command) onRunCommand;

  /// The shell's inspector configuration, rendered as the bottom sheet.
  final InspectorView inspector;
  final CompactPaneSeams seams;

  /// Home's content (the sidebar's home presentation). Null when the
  /// shell has no sidebar: the browser is then the only screen.
  final Widget? home;
  final DateTime Function() clock;

  @override
  State<CompactWorkspace> createState() => CompactWorkspaceState();
}

class CompactWorkspaceState extends State<CompactWorkspace>
    with SingleTickerProviderStateMixin {
  /// 0 shows Home, 1 the browser.
  late final AnimationController _page = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 260),
    value: widget.home == null ? 1 : 0,
  );
  late final Animation<double> _pageCurve = CurvedAnimation(
    parent: _page,
    curve: Curves.easeInOutCubicEmphasized,
    reverseCurve: Curves.easeInOutCubicEmphasized.flipped,
  );

  late bool _browsing = widget.home == null;
  bool _selecting = false;
  PaneController? _selectionPane;
  bool _filterOpen = false;
  Listenable? _panes;

  /// The inspector visibility last seen — its hide edge releases a row
  /// Get Info held as the Info tab's subject.
  late bool _inspectorWasHidden = widget.workspace.inspectorHidden;

  /// Whether any transfer runs — tracked on its own edge, because the
  /// queue notifies on every progress tick and only the pill (which
  /// listens itself) needs those.
  bool _transfersLive = false;

  WorkspaceController get _workspace => widget.workspace;

  /// Whether the browser is (or is becoming) the shown screen.
  bool get browsing => _browsing;

  /// Whether a selection is in progress (the contextual bar is up).
  bool get selecting => _selecting;

  @override
  void initState() {
    super.initState();
    _bindPanes();
    widget.inspector.activity.addListener(_onActivityChanged);
    _transfersLive = compactTransferSummary(widget.inspector.activity).live > 0;
    // The browser layer leaves the tree once Home is fully back.
    _page.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _claimPosture());
  }

  void _onActivityChanged() {
    final live = compactTransferSummary(widget.inspector.activity).live > 0;
    if (live == _transfersLive || !mounted) return;
    setState(() => _transfersLive = live);
  }

  @override
  void didUpdateWidget(CompactWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspace, widget.workspace)) {
      _selecting = false;
      _selectionPane = null;
      _filterOpen = false;
      _bindPanes();
      WidgetsBinding.instance.addPostFrameCallback((_) => _claimPosture());
    }
    if (!identical(oldWidget.inspector.activity, widget.inspector.activity)) {
      oldWidget.inspector.activity.removeListener(_onActivityChanged);
      widget.inspector.activity.addListener(_onActivityChanged);
      _transfersLive =
          compactTransferSummary(widget.inspector.activity).live > 0;
    }
    if (widget.home == null && !_browsing) {
      _browsing = true;
      _page.value = 1;
    }
  }

  @override
  void dispose() {
    widget.inspector.activity.removeListener(_onActivityChanged);
    _panes?.removeListener(_onPanesChanged);
    _page.dispose();
    super.dispose();
  }

  void _bindPanes() {
    _panes?.removeListener(_onPanesChanged);
    final workspace = _workspace;
    _panes = Listenable.merge([workspace, workspace.left, workspace.right]);
    _panes!.addListener(_onPanesChanged);
  }

  /// The compact posture's two claims on the workspace, made once per
  /// mount: pane B counts as shown (it is one flip away, and the two-pane
  /// verbs need their destination), and the inspector starts closed —
  /// its desktop "shown" default would otherwise open the sheet over
  /// Home at launch.
  void _claimPosture() {
    if (!mounted) return;
    _workspace.setSecondPaneLayoutShown(true);
    if (!_workspace.inspectorHidden) _workspace.setInspectorHidden(true);
  }

  /// Strips forward every tab notification (location, listing, selection),
  /// so this one listener keeps the app bar, the breadcrumbs, and the
  /// selection mode current. A selection that emptied — the last row
  /// toggled off, a navigation pruned it, the pane or tab changed under
  /// it — ends selection mode.
  ///
  /// A bulk selection made through the registry (Select All, Invert,
  /// Quick Select) enters selection mode on its own: the contextual bar
  /// is where its verbs live. A single selected row outside the mode is
  /// a verb's subject (the row sheet, Get Info, a fresh rename) and stays
  /// out of it; closing the sheet releases Get Info's.
  void _onPanesChanged() {
    if (!mounted) return;
    final active = _listingPane;
    if (_selecting) {
      final pane = _selectionPane;
      if (pane == null || !identical(pane, active) || pane.selectedCount == 0) {
        _selecting = false;
        _selectionPane = null;
        if (pane != null && !identical(pane, active)) pane.clearSelection();
      }
    } else if (active != null &&
        active.selectedCount > 1 &&
        !active.quickSelectActive) {
      _selecting = true;
      _selectionPane = active;
    }
    final hidden = _workspace.inspectorHidden;
    if (hidden && !_inspectorWasHidden && !_selecting) {
      active?.clearSelection();
    }
    _inspectorWasHidden = hidden;
    setState(() {});
  }

  // ── Navigation ─────────────────────────────────────────────────────

  /// Pushes the browser over Home — every open from Home (a sidebar row,
  /// Quick Connect, a sync plan, a revealed transfer) lands here.
  void showBrowser() {
    if (_browsing) return;
    setState(() => _browsing = true);
    unawaited(_page.forward());
  }

  /// Returns to Home. A selection ends with the browser it lived in.
  void showHome() {
    if (widget.home == null || !_browsing) return;
    _endSelection();
    setState(() => _browsing = false);
    unawaited(_page.reverse());
  }

  /// `view.filter` in the compact posture: the browser's filter field.
  void openFilter() {
    showBrowser();
    if (_filterOpen) return;
    setState(() => _filterOpen = true);
  }

  /// The pane the browser shows as a listing (not a sync plan tab).
  PaneController? get _listingPane {
    final tab = _workspace.activePane.activeTab;
    if (tab == null || tab.syncSession != null) return null;
    return tab.controller;
  }

  bool get _filterVisible =>
      _filterOpen || (_listingPane?.filterActive ?? false);

  bool get _fieldOpen =>
      _filterVisible || (_listingPane?.quickSelectActive ?? false);

  /// The next step system back takes (D32 §9's order).
  CompactBackStep get nextBackStep {
    if (_selecting) return CompactBackStep.clearSelection;
    if (!_workspace.inspectorHidden) return CompactBackStep.closeSheet;
    if (!_browsing) return CompactBackStep.leave;
    if (_fieldOpen) return CompactBackStep.closeField;
    if (_listingPane?.canGoBack ?? false) return CompactBackStep.folderBack;
    if (widget.home != null) return CompactBackStep.home;
    return CompactBackStep.leave;
  }

  /// Runs one back step; false when nothing is left but leaving the app.
  bool back() {
    switch (nextBackStep) {
      case CompactBackStep.clearSelection:
        _endSelection();
      case CompactBackStep.closeSheet:
        _workspace.setInspectorHidden(true);
      case CompactBackStep.closeField:
        final pane = _listingPane;
        if (pane != null && pane.quickSelectActive) {
          pane.cancelQuickSelect();
        } else {
          _closeFilter();
        }
      case CompactBackStep.folderBack:
        _listingPane?.goBack();
      case CompactBackStep.home:
        showHome();
      case CompactBackStep.leave:
        return false;
    }
    return true;
  }

  void _closeFilter() {
    _listingPane?.clearFilter();
    if (_filterOpen) setState(() => _filterOpen = false);
  }

  // ── Panes and selection ────────────────────────────────────────────

  /// The A · B switcher: the other pane becomes the shown one. A pane B
  /// the user hid on a wide window un-hides — flipping to it is the
  /// explicit ask.
  void _switchPane() {
    final workspace = _workspace;
    _endSelection();
    _filterOpen = false;
    final target = identical(workspace.activePane, workspace.left)
        ? workspace.right
        : workspace.left;
    if (identical(target, workspace.right) && workspace.secondPaneHidden) {
      workspace.setSecondPaneHidden(false);
    }
    workspace.setActivePane(target);
  }

  void _endSelection() {
    final pane = _selectionPane;
    final wasSelecting = _selecting;
    _selecting = false;
    _selectionPane = null;
    pane?.clearSelection();
    if (wasSelecting && mounted) setState(() {});
  }

  /// Outside selection mode a tap opens (folders navigate, files take the
  /// open action) and leaves nothing selected; inside it a tap toggles.
  void _onRowTap(PaneController pane, int index) {
    if (_selecting) {
      pane.setCursorIndex(index, update: SelectionUpdate.toggle);
      return;
    }
    final entries = pane.entries;
    if (index < 0 || index >= entries.length) return;
    pane.clearSelection();
    unawaited(pane.openEntry(entries[index]));
  }

  /// A long-press starts the selection on the row (and toggles further
  /// rows once selecting).
  void _onRowLongPress(PaneController pane, int index) {
    if (_selecting) {
      pane.setCursorIndex(index, update: SelectionUpdate.toggle);
      return;
    }
    pane.setCursorIndex(index);
    if (pane.selectedCount == 0) return;
    setState(() {
      _selecting = true;
      _selectionPane = pane;
    });
  }

  /// The row's ⋮: the row becomes the verbs' subject and the registry's
  /// row menu opens as a sheet (D32 §6's context menu, touch rendering).
  /// The subject is released once the chosen verb has run — or at once
  /// when the sheet is dismissed — so no row stays an invisible target
  /// of a later verb. Get Info keeps it: the Info tab shows that row.
  Future<void> _onRowActions(PaneController pane, int index) async {
    final entries = pane.entries;
    if (index < 0 || index >= entries.length) return;
    final name = entries[index].name;
    pane.setCursorIndex(index);
    var chosen = false;
    await showPaneContextSheet(
      context,
      title: name,
      sections: resolvePaneContextSections(
        widget.commands,
        kPaneRowContextMenu,
      ),
      onRun: (command) async {
        chosen = true;
        await widget.onRunCommand(command);
        if (!mounted || _selecting) return;
        if (command.id != kFileGetInfoCommandId) pane.clearSelection();
      },
    );
    if (!chosen && mounted && !_selecting) pane.clearSelection();
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final workspace = _workspace;
    final inspector = widget.inspector;
    final padding = MediaQuery.paddingOf(context);
    final home = widget.home;
    return PopScope(
      canPop: nextBackStep == CompactBackStep.leave,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        back();
      },
      child: Stack(
        key: const ValueKey(CompactKey.workspace),
        fit: StackFit.expand,
        children: [
          if (home != null)
            _PageLayer(
              animation: _pageCurve,
              role: _PageRole.home,
              child: CompactHome(
                sidebar: home,
                commands: widget.commands,
                onRunCommand: widget.onRunCommand,
              ),
            ),
          if (_browsing || _page.value > 0)
            _PageLayer(
              animation: _pageCurve,
              role: _PageRole.browser,
              child: CompactBrowser(
                workspace: workspace,
                commands: widget.commands,
                onRunCommand: widget.onRunCommand,
                seams: widget.seams,
                selecting: _selecting,
                filterOpen: _filterVisible,
                rowCallbacks: CompactRowCallbacks(
                  onTap: _onRowTap,
                  onLongPress: _onRowLongPress,
                  onActions: (pane, index) =>
                      unawaited(_onRowActions(pane, index)),
                ),
                onBack: back,
                onSwitchPane: _switchPane,
                onEndSelection: _endSelection,
                onOpenFilter: openFilter,
                onCloseFilter: _closeFilter,
                listingBottomPadding: _transfersLive ? _pillClearance : 0,
                clock: widget.clock,
              ),
            ),
          PositionedDirectional(
            start: 16,
            // Home's "+" FAB owns the bottom end corner: the pill centres
            // in the room beside it, so the two never collide on a narrow
            // phone.
            end: _browsing ? 16 : _fabClearance,
            bottom:
                padding.bottom +
                16 +
                (_browsing && _selecting ? _selectionBarHeight : 0),
            child: Center(
              child: CompactProgressPill(
                activity: inspector.activity,
                hidden: !workspace.inspectorHidden,
                onPressed: () =>
                    workspace.showInspector(InspectorTab.transfers),
              ),
            ),
          ),
          Positioned.fill(child: CompactInspectorSheet(inspector: inspector)),
        ],
      ),
    );
  }
}

enum _PageRole { home, browser }

/// M3's shared-axis step between Home and the browser: the browser
/// slides in from the end edge as it fades up, Home drifts toward the
/// start and dims. Home leaves the tree's input and semantics (but stays
/// mounted) once the browser fully covers it.
class _PageLayer extends StatelessWidget {
  const _PageLayer({
    required this.animation,
    required this.role,
    required this.child,
  });

  final Animation<double> animation;
  final _PageRole role;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = animation.value;
        final width = MediaQuery.sizeOf(context).width;
        switch (role) {
          case _PageRole.home:
            final covered = t >= 1;
            return Offstage(
              offstage: covered,
              child: TickerMode(
                enabled: !covered,
                child: IgnorePointer(
                  ignoring: t > 0,
                  child: Transform.translate(
                    offset: Offset((rtl ? 1 : -1) * width * 0.08 * t, 0),
                    child: Opacity(
                      opacity: (1 - t * 1.4).clamp(0.0, 1.0),
                      child: child,
                    ),
                  ),
                ),
              ),
            );
          case _PageRole.browser:
            return IgnorePointer(
              ignoring: t < 1 && animation.status == AnimationStatus.reverse,
              child: Transform.translate(
                offset: Offset((rtl ? -1 : 1) * width * 0.18 * (1 - t), 0),
                child: Opacity(
                  opacity: Curves.easeOut.transform(t.clamp(0.0, 1.0)),
                  child: child,
                ),
              ),
            );
        }
      },
      child: child,
    );
  }
}
