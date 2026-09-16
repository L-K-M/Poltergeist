import 'package:flutter/foundation.dart';

import 'pane_controller.dart';
import 'pane_tabs_controller.dart';
import 'sync_browsing_controller.dart';

/// 03 §6's per-window workspace state, foundation slice: the pane pair,
/// the active pane (which pane keyboard pane-scoped commands act on),
/// the second pane's visibility (02 §3's toggle), and the Sync Browsing
/// link (02 §7). Each pane owns its tab strip (02 §3); layout ratios
/// already persist through the M1 shell's splitter.
class WorkspaceController extends ChangeNotifier {
  WorkspaceController({required this.left, required this.right})
    : assert(
        !identical(left, right),
        'Workspace panes must be distinct PaneTabsController instances.',
      ),
      _activePane = left {
    syncBrowsing = SyncBrowsingController(workspace: this);
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

  /// The pane that pane-scoped commands and focus chords resolve against;
  /// focus follows the active pane (02 §8.2's one FocusScope per pane).
  /// Set only through [setActivePane] so every change notifies.
  PaneTabsController get activePane => _activePane;

  /// The active pane's active tab controller — the browsing surface the
  /// registered pane commands act on; null while the pane sits on the
  /// launcher (no tab open).
  PaneController? get activeTabController => _activePane.activeTab?.controller;

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
  bool serverStillBound(String serverId, PaneController excluding) {
    for (final pane in [left, right]) {
      for (final tab in pane.tabs) {
        final controller = tab.controller;
        if (!identical(controller, excluding) &&
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
    // The link dies first so its anchor flags clear on live controllers
    // and its strip listeners detach before the strips go.
    syncBrowsing.dispose();
    left.dispose();
    right.dispose();
    super.dispose();
  }
}
