import 'package:flutter/foundation.dart';

import 'pane_controller.dart';

/// 03 §6's per-window workspace state, foundation slice: the pane pair and
/// the active pane (which pane keyboard pane-scoped commands act on).
/// Tabs per pane, the pane toggle, and layout ratios join with their own
/// slices (ratios already persist through the M1 shell's splitter).
class WorkspaceController extends ChangeNotifier {
  WorkspaceController({required this.left, required this.right})
    : assert(
        !identical(left, right),
        'Workspace panes must be distinct PaneController instances.',
      ),
      _activePane = left;

  /// The two panes (02 §1's pane A/pane B). Owned by the shell, which
  /// disposes them with the workspace.
  final PaneController left;
  final PaneController right;

  PaneController _activePane;

  /// The pane that pane-scoped commands and focus chords resolve against;
  /// focus follows the active pane (02 §8.2's one FocusScope per pane).
  /// Set only through [setActivePane] so every change notifies.
  PaneController get activePane => _activePane;

  /// Marks [pane] active (a pane gained focus or was activated by
  /// command). Idempotent.
  void setActivePane(PaneController pane) {
    assert(
      identical(pane, left) || identical(pane, right),
      'Active pane must be one of this workspace\'s panes.',
    );
    if (identical(_activePane, pane)) return;
    _activePane = pane;
    notifyListeners();
  }

  /// `pane.swapFocus` (Tab inside a listing): activates and returns the
  /// other pane — the shell moves keyboard focus to it.
  PaneController swapFocus() {
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
