import 'package:flutter/foundation.dart';

import 'pane_controller.dart';
import 'pane_tabs_controller.dart';

/// 03 §6's per-window workspace state, foundation slice: the pane pair and
/// the active pane (which pane keyboard pane-scoped commands act on).
/// Each pane owns its tab strip (02 §3); the pane toggle and layout
/// ratios join with their own slices (ratios already persist through the
/// M1 shell's splitter).
class WorkspaceController extends ChangeNotifier {
  WorkspaceController({required this.left, required this.right})
    : assert(
        !identical(left, right),
        'Workspace panes must be distinct PaneTabsController instances.',
      ),
      _activePane = left;

  /// The two panes (02 §1's pane A/pane B) — each a tab strip owning its
  /// tab controllers. Owned by the shell, which disposes them with the
  /// workspace.
  final PaneTabsController left;
  final PaneTabsController right;

  PaneTabsController _activePane;

  /// The pane that pane-scoped commands and focus chords resolve against;
  /// focus follows the active pane (02 §8.2's one FocusScope per pane).
  /// Set only through [setActivePane] so every change notifies.
  PaneTabsController get activePane => _activePane;

  /// The active pane's active tab controller — the browsing surface the
  /// registered pane commands act on; null while the pane sits on the
  /// launcher (no tab open).
  PaneController? get activeTabController => _activePane.activeTab?.controller;

  /// Marks [pane] active (a pane gained focus or was activated by
  /// command). Idempotent.
  void setActivePane(PaneTabsController pane) {
    assert(
      identical(pane, left) || identical(pane, right),
      'Active pane must be one of this workspace\'s panes.',
    );
    if (identical(_activePane, pane)) return;
    _activePane = pane;
    notifyListeners();
  }

  /// Whether any tab OTHER than [excluding]'s still binds [serverId] —
  /// scanned across BOTH panes' tab sets. The shell routes this into each
  /// strip's sibling seam so a remote tab's close/banner-cancel drops the
  /// pooled server reference only when it was the last binding (03 §3.2).
  bool serverStillBound(String serverId, {required PaneController excluding}) {
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

  /// `pane.swapFocus` (Tab inside a listing): activates and returns the
  /// other pane — the shell moves keyboard focus to it.
  PaneTabsController swapFocus() {
    final target = identical(_activePane, left) ? right : left;
    setActivePane(target);
    return target;
  }

  @override
  void dispose() {
    left.dispose();
    right.dispose();
    super.dispose();
  }
}
