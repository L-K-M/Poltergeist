import 'package:flutter/foundation.dart';

import 'pane_controller.dart';
import 'pane_tabs_controller.dart';
import 'sync_browsing_controller.dart';
import 'workspace_state.dart';

/// 03 §6's per-window workspace state, foundation slice: the pane pair,
/// the active pane (which pane keyboard pane-scoped commands act on),
/// the second pane's visibility (02 §3's toggle), and the Sync Browsing
/// link (02 §7). Each pane owns its tab strip (02 §3); layout ratios
/// already persist through the M1 shell's splitter.
/// The D32 inspector's tabs (10 §3): item facts, work in flight, and
/// things that need the user.
enum InspectorTab { info, transfers, alerts }

class WorkspaceController extends ChangeNotifier {
  WorkspaceController({
    required this.left,
    required this.right,
    bool inspectorHidden = false,
  }) : assert(
         !identical(left, right),
         'Workspace panes must be distinct PaneTabsController instances.',
       ),
       // Named parameters cannot be private.
       // ignore: prefer_initializing_formals
       _inspectorHidden = inspectorHidden,
       _activePane = left {
    syncBrowsing = SyncBrowsingController(workspace: this);
    _shownTab = activeTabController;
    left.addListener(_followActiveTab);
    right.addListener(_followActiveTab);
  }

  /// The two panes (02 §1's pane A/pane B) — each a tab strip owning its
  /// tab controllers. Owned by the shell, which disposes them with the
  /// workspace.
  final PaneTabsController left;
  final PaneTabsController right;

  /// The workspace's Sync Browsing link (02 §7): the anchored tab pair,
  /// the replay/suspend/resume state machine, and the anchor flags the
  /// tab close guard probes. Reads the strips and [secondPaneShown];
  /// created eagerly so a shell can never forget to wire it.
  late final SyncBrowsingController syncBrowsing;

  PaneTabsController _activePane;
  bool _disposed = false;
  // One guarded replacement at a time: a second open (or an Undo racing
  // an open still mid-confirm) fails closed rather than interleaving
  // confirms and closes across the two runs.
  bool _applyingWorkspace = false;

  /// The pane that pane-scoped commands and focus chords resolve against;
  /// focus follows the active pane (02 §8.2's one FocusScope per pane).
  /// Set only through [setActivePane] so every change notifies.
  PaneTabsController get activePane => _activePane;

  /// The active pane's active tab controller — the browsing surface the
  /// registered pane commands act on; null while the pane sits on the
  /// launcher (no tab open). A change notifies whichever way it came —
  /// a pane change, or a tab switch, ⌘T, or ⌘W inside the active pane —
  /// so surfaces bound to it (Info, the header filter) never stay on a
  /// hidden or disposed tab.
  PaneController? get activeTabController => _activePane.activeTab?.controller;

  /// The [activeTabController] the last notify described.
  PaneController? _shownTab;

  /// The strips notify on their own tab changes and forward every tab's
  /// state; only an identity change of the active tab is the
  /// workspace's news.
  void _followActiveTab() {
    if (!identical(activeTabController, _shownTab)) notifyListeners();
  }

  @override
  void notifyListeners() {
    _shownTab = activeTabController;
    super.notifyListeners();
  }

  /// `view.toggleSecondPane`'s user intent (02 §3): hiding pane B keeps
  /// its strip and every tab's state whole — the layout unmounts the
  /// surface while the workspace's tab objects live on, so re-showing
  /// restores it exactly.
  bool _secondPaneHidden = false;

  /// Whether the second pane is hidden by user intent — the toggle's
  /// own state, written only through [setSecondPaneHidden] so the
  /// layout's stage-2 auto-hide cannot latch it (02 §3: a transient
  /// auto-hide restores on regrow; only the explicit command persists).
  bool get secondPaneHidden => _secondPaneHidden;

  /// The shell-reported effective visibility of pane B — the layout's
  /// answer after user intent AND stage (02 §1's stage-2 auto-hide runs
  /// through the same mechanism). Sync Browsing suspends on
  /// [secondPaneShown] going false whichever path hid the pane (02 §7).
  bool _secondPaneLayoutShown = true;

  /// The D32 inspector column's visibility (10 §3): default-shown on the
  /// desktop, default-hidden on touch (the constructor's seed: a phone or
  /// a tablet has no width to spare for it until asked), and written
  /// only through [setInspectorHidden] / [showInspector] so every flip
  /// notifies — the session document persists it. The responsive overlay
  /// collapse is layout-only and never lands here.
  bool _inspectorHidden;
  InspectorTab _inspectorTab = InspectorTab.info;

  bool get inspectorHidden => _inspectorHidden;

  /// The tab the inspector shows (or will show when re-opened).
  InspectorTab get inspectorTab => _inspectorTab;

  void setInspectorHidden(bool hidden) {
    if (hidden == _inspectorHidden) return;
    final infoWasShown = !previewPanelHidden;
    _inspectorHidden = hidden;
    _endInfoWorkIfLeft(infoWasShown);
    notifyListeners();
  }

  void toggleInspector() => setInspectorHidden(!_inspectorHidden);

  /// Shows the inspector on [tab] — `file.getInfo`, `view.showTransfers`,
  /// the alert badge, and D16's new-work edge all land here.
  void showInspector(InspectorTab tab) {
    if (!_inspectorHidden && _inspectorTab == tab) return;
    final infoWasShown = !previewPanelHidden;
    _inspectorHidden = false;
    _inspectorTab = tab;
    _endInfoWorkIfLeft(infoWasShown);
    notifyListeners();
  }

  /// Selects [tab] without changing visibility (the inspector's own tab
  /// switcher; a hidden inspector re-opens on it).
  void selectInspectorTab(InspectorTab tab) {
    if (_inspectorTab == tab) return;
    final infoWasShown = !previewPanelHidden;
    _inspectorTab = tab;
    _endInfoWorkIfLeft(infoWasShown);
    notifyListeners();
  }

  /// The Info tab is the only consumer of a tab's folder-size walk and
  /// enclosed-apply operation (02 §2.6, D28), so the moment the user
  /// takes it off the screen — the inspector hidden, another tab
  /// selected — every pane tab's in-flight Info work ends: a walk left
  /// running would hold the tab close guard for nothing, and an apply's
  /// confirmation would be orphaned. D16's new-work edge is not the
  /// user leaving Info ([setActivityPanelHidden] skips this). The
  /// retired per-pane Get Info overlay did this on its close; the
  /// inspector column owns the edge now. Callers notify afterwards; the
  /// cancels notify their own panes.
  void _endInfoWorkIfLeft(bool infoWasShown) {
    if (!infoWasShown || !previewPanelHidden) return;
    for (final strip in [left, right]) {
      for (final tab in strip.tabs) {
        final pane = tab.controller;
        if (pane.folderSizeInFlight) pane.cancelFolderSize();
        if (pane.applyToEnclosedInFlight) pane.cancelEnclosedApply();
      }
    }
  }

  /// The tab-scoped toggle behind `view.toggleActivityPanel` and
  /// `view.togglePreview`: showing [tab] when the inspector is hidden or
  /// on another tab, hiding it when it already shows [tab].
  void toggleInspectorTab(InspectorTab tab) {
    if (!_inspectorHidden && _inspectorTab == tab) {
      setInspectorHidden(true);
    } else {
      showInspector(tab);
    }
  }

  /// D16's activity surface, now the inspector's Transfers tab (D32):
  /// "hidden" means the Transfers tab is not on screen. Kept as the
  /// seam the activity auto-show, the queue boot seed, and the session
  /// document's legacy flag already speak.
  bool get activityPanelHidden =>
      _inspectorHidden || _inspectorTab != InspectorTab.transfers;

  /// Showing here is D16's new-work edge, never a user's choice to
  /// leave Info: an unrelated transfer starting must not cut a running
  /// folder-size walk or a confirmed recursive chmod short, so the
  /// reveal skips [_endInfoWorkIfLeft] and that work runs on into the
  /// terminal snapshot Info shows on return.
  void setActivityPanelHidden(bool hidden) {
    if (!hidden) {
      if (!activityPanelHidden) return;
      _inspectorHidden = false;
      _inspectorTab = InspectorTab.transfers;
      notifyListeners();
    } else if (!activityPanelHidden) {
      setInspectorHidden(true);
    }
  }

  void toggleActivityPanel() => toggleInspectorTab(InspectorTab.transfers);

  /// `view.toggleSidebar`'s user intent (02 §1): the global sidebar is
  /// default-shown; only the explicit toggle writes this flag — the
  /// stage-1 auto-collapse recomputes per window width and never latches
  /// it (a user who hid the region keeps it hidden on regrow, and vice
  /// versa).
  bool _sidebarHidden = false;

  /// Whether the user intent hides the sidebar. Written only through
  /// [setSidebarHidden] so every flip notifies.
  bool get sidebarHidden => _sidebarHidden;

  void setSidebarHidden(bool hidden) {
    if (hidden == _sidebarHidden) return;
    _sidebarHidden = hidden;
    notifyListeners();
  }

  void toggleSidebar() => setSidebarHidden(!_sidebarHidden);

  /// 06 §5.2's preview surface, now the inspector's Info tab (D32): the
  /// preview renders at the top of Info, so "hidden" means the Info tab
  /// is not on screen. The preview session reads this to decide whether
  /// a selection change evaluates a preview.
  bool get previewPanelHidden =>
      _inspectorHidden || _inspectorTab != InspectorTab.info;

  void setPreviewPanelHidden(bool hidden) {
    if (!hidden) {
      showInspector(InspectorTab.info);
    } else if (!previewPanelHidden) {
      setInspectorHidden(true);
    }
  }

  void togglePreviewPanel() => toggleInspectorTab(InspectorTab.info);

  /// Whether pane B is on screen: not user-hidden and not layout-hidden.
  bool get secondPaneShown => !_secondPaneHidden && _secondPaneLayoutShown;

  /// Sets the user intent — `view.toggleSecondPane`'s seam. The shell
  /// folds it into the AdaptiveShell's `secondPaneIntent`.
  void setSecondPaneHidden(bool hidden) {
    if (hidden == _secondPaneHidden) return;
    _secondPaneHidden = hidden;
    _keepActivePaneVisible();
    notifyListeners();
  }

  void toggleSecondPane() => setSecondPaneHidden(!_secondPaneHidden);

  /// The shell reports the allocation's effective answer here — covering
  /// a stage-2 responsive hide the intent flag cannot see (02 §3's
  /// "auto-hide uses the same mechanism").
  void setSecondPaneLayoutShown(bool shown) {
    if (shown == _secondPaneLayoutShown) return;
    _secondPaneLayoutShown = shown;
    _keepActivePaneVisible();
    notifyListeners();
  }

  /// 02 §3's rule that a hidden pane's tabs take no commands, applied to
  /// the workspace's own pointer: the moment pane B leaves the screen —
  /// user toggle or stage-2 auto-hide, one mechanism — an active right
  /// pane would leave every pane-scoped command and the focus chords
  /// aimed at a strip nothing renders. The active pane falls to the
  /// survivor; re-showing never moves it back on its own (the remembered
  /// pane is state, not focus).
  void _keepActivePaneVisible() {
    if (!secondPaneShown && identical(_activePane, right)) {
      _activePane = left;
    }
  }

  /// Marks [pane] active (a pane gained focus or was activated by
  /// command). Idempotent; refuses the hidden pane (02 §3) — a focus
  /// event racing the unmount must not park pane commands on a strip
  /// nothing renders.
  void setActivePane(PaneTabsController pane) {
    assert(
      identical(pane, left) || identical(pane, right),
      'Active pane must be one of this workspace\'s panes.',
    );
    if (identical(pane, right) && !secondPaneShown) return;
    if (identical(_activePane, pane)) return;
    _activePane = pane;
    notifyListeners();
  }

  /// Whether any tab OTHER than [excluding]'s still binds [serverId] —
  /// scanned across BOTH panes' tab sets. The shell routes this into each
  /// strip's sibling seam so a remote tab's close/banner-cancel drops the
  /// pooled server reference only when it was the last binding (03 §3.2).
  /// Positional [excluding] matches the strips' `serverStillShared`
  /// typedef, so a tear-off wires the seam without an adapter.
  bool serverStillBound(String serverId, PaneController excluding) =>
      _bindsServer(serverId, excluding: excluding);

  /// Whether any tab in this workspace binds [serverId] live: another
  /// window's half of the last-binding check (00 D38).
  bool bindsServer(String serverId) => _bindsServer(serverId);

  bool _bindsServer(String serverId, {PaneController? excluding}) {
    for (final pane in [left, right]) {
      for (final tab in pane.tabs) {
        final controller = tab.controller;
        // A session-restored tab keeps the bookmark for its badge and
        // reconnect but holds no pool reference — only live bindings
        // count toward last-binding close semantics (02 §3, 03 §3.2).
        if (!identical(controller, excluding) &&
            controller.hasLiveRemoteBinding &&
            controller.remoteBookmark?.id == serverId) {
          return true;
        }
      }
    }
    return false;
  }

  /// 02 §3's "drag tabs between panes": moves [tab] — object identity
  /// and all — from the other pane's strip into [target] at [index]
  /// (null appends). The move is not a close: the close guard does not
  /// run, no ghost is pushed, and the tab's PaneController — its SFTP
  /// browse channel (keyed to the tab's stable paneTabId, 03 §3.2), an
  /// in-flight navigation or rename, selection, the transient lenses,
  /// and history — crosses untouched. A source pane that loses its last
  /// tab lands on the launcher (02 §2.7); the dropped tab activates and
  /// its pane becomes the active one.
  ///
  /// An anchored tab that lands on the other pane takes the Sync
  /// Browsing link down through the strips' notifies — 02 §7's rule
  /// that both anchors must never share one pane.
  ///
  /// Returns false for a no-op drop: the tab is not on the sibling
  /// strip (a same-strip drop is the cancelled case — there is no
  /// within-strip reorder), or pane B is hidden — a hidden pane's tabs
  /// take no drops and start no drags (02 §3).
  bool moveTabToPane(PaneTab tab, PaneTabsController target, {int? index}) {
    // The identity guard is runtime, not an assert: a foreign strip as
    // target would misread the sibling lookup as `left` and detach the
    // tab into another workspace, and asserts strip out in release.
    if (!identical(target, left) && !identical(target, right)) {
      return false;
    }
    if (!secondPaneShown) return false;
    final source = identical(target, left) ? right : left;
    if (!source.tabs.contains(tab)) return false;
    source.detachTabForMove(tab);
    if (!target.adoptMovedTab(tab, index: index)) {
      // Adoption was refused (e.g. a disposed target in a release build):
      // re-home the tab on its source strip rather than orphan a live
      // PaneController between strips. The source just detached it, so
      // refusal here would itself be a bug — the assert pins that. The
      // call stays outside the assert so release still re-homes.
      final rehomed = source.adoptMovedTab(tab);
      assert(rehomed, 'source strip refused to re-home a detached tab');
      return false;
    }
    setActivePane(target);
    return true;
  }

  /// The workspace snapshot `workspace.save` persists (02 §3): both
  /// panes' tab sets, active tabs, and per-tab view state — each strip's
  /// [PaneTabsController.captureWorkspacePane] half.
  WorkspaceSnapshot captureWorkspace() => WorkspaceSnapshot(
    left: left.captureWorkspacePane(),
    right: right.captureWorkspacePane(),
  );

  /// THE workspace-open operation (02 §3): replaces BOTH panes' tab
  /// sets with [next]'s, and returns the displaced snapshot for the
  /// caller's `Workspace "X" opened` toast's Undo action.
  ///
  /// Both panes' replacement routes through the same tab-scoped-state
  /// guard ⌘W uses — the strips' shared close-trigger registry and
  /// presenter — asked for EVERY existing tab BEFORE the first close,
  /// so a declined confirmation anywhere leaves the whole workspace
  /// untouched. Once confirmed, each strip swaps through
  /// [PaneTabsController.replaceTabs], the same teardown the guarded
  /// single close ends in.
  ///
  /// The returned snapshot powers Undo: it restores the prior tab sets
  /// but can never restore in-flight state — a navigation answer, an
  /// open rename edit, a running folder-size walk are gone the moment
  /// their tab closed. That is exactly why the guard runs first
  /// (02 §3): the user authorizes each loss explicitly before the
  /// workspace replaces anything. Undo itself routes through this same
  /// guarded operation — a workspace tab that has since gone in-flight
  /// is confirmed again rather than dropped silently.
  ///
  /// Transfers are unaffected by construction: the queue sits above the
  /// panes and nothing here touches an engine channel beyond the pane
  /// seams' own close/release calls.
  ///
  /// Returns null when a guard declined, no presenter was wired, or the
  /// workspace disposed mid-confirm — in every case nothing (or only
  /// user-approved closes) was applied.
  Future<WorkspaceSnapshot?> requestApplyWorkspace(
    WorkspaceSnapshot next,
  ) async {
    if (_disposed || _applyingWorkspace) return null;
    _applyingWorkspace = true;
    try {
      // Phase 1 — the batch guard across BOTH panes before the first
      // close anywhere. Confirming left fully then right keeps the
      // decline rule intact: a right-pane "don't close" after left's
      // confirms still leaves every tab standing (nothing closed yet).
      final leftPermit = await left.confirmTabReplacement();
      if (leftPermit == null || _disposed) return null;
      final rightPermit = await right.confirmTabReplacement();
      if (rightPermit == null || _disposed) return null;
      // Capture AFTER the confirms: Undo restores the arrangement as it
      // stood the instant before replacement — including anything that
      // settled while the dialogs were up.
      final prior = captureWorkspace();
      await left.replaceTabs(next.left, leftPermit);
      if (_disposed) return null;
      await right.replaceTabs(next.right, rightPermit);
      return _disposed ? null : prior;
    } finally {
      _applyingWorkspace = false;
    }
  }

  /// `pane.swapFocus` (Tab inside a listing): activates and returns the
  /// other pane — the shell moves keyboard focus to it. With pane B
  /// hidden there is nothing to swap to (02 §3): the visible pane
  /// answers, so the caller still lands focus on a shown strip.
  PaneTabsController swapFocus() {
    if (!secondPaneShown) return _activePane;
    final target = identical(_activePane, left) ? right : left;
    setActivePane(target);
    return target;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // The link dies first so its anchor flags clear on live controllers
    // and its strip listeners detach before the strips go.
    syncBrowsing.dispose();
    left.removeListener(_followActiveTab);
    right.removeListener(_followActiveTab);
    left.dispose();
    right.dispose();
    super.dispose();
  }
}
