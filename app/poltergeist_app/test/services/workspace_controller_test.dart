import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';

import '../support/test_panes.dart';
import 'pane_controller_test.dart' as controller_test;

/// 02 §3's one/two-pane toggle at the workspace layer: hiding pane B —
/// through `view.toggleSecondPane`'s intent flag or the shell's stage-2
/// layout report, which share [WorkspaceController.secondPaneShown] —
/// preserves the hidden strip whole and parks the workspace's active
/// pane on the survivor, so no pane-scoped command or focus chord can
/// ever resolve to an unmounted strip.
void main() {
  ({WorkspaceController workspace, PaneController left, PaneController right})
  build() {
    final lanes = controller_test.FakePaneLanes();
    final left = PaneController(paneTabId: 'pane.left.tab1', lanes: lanes);
    final right = PaneController(
      paneTabId: 'pane.right.tab1',
      lanes: lanes,
    );
    final workspace = WorkspaceController(
      left: testPaneStrip(left, lanes: lanes),
      right: testPaneStrip(right, lanes: lanes),
    );
    addTearDown(workspace.dispose);
    return (workspace: workspace, left: left, right: right);
  }

  group('a hidden pane takes no commands (02 §3)', () {
    test('hiding pane B while it is active retargets pane A', () {
      final rig = build();
      rig.workspace.setActivePane(rig.workspace.right);

      rig.workspace.toggleSecondPane();

      expect(rig.workspace.secondPaneHidden, isTrue);
      expect(rig.workspace.secondPaneShown, isFalse);
      expect(
        rig.workspace.activePane,
        rig.workspace.left,
        reason: 'pane-scoped commands resolve the ACTIVE pane — it must '
            'never be the unmounted one',
      );
      expect(identical(rig.workspace.activeTabController, rig.left), isTrue);
    });

    test('a late activation of the hidden pane is refused', () {
      final rig = build();
      rig.workspace.setSecondPaneHidden(true);

      // A focus event racing the unmount, or any other stray activation,
      // cannot park pane commands on a strip nothing renders.
      rig.workspace.setActivePane(rig.workspace.right);

      expect(rig.workspace.activePane, rig.workspace.left);
    });

    test('swapFocus cannot leave the visible pane', () {
      final rig = build();
      rig.workspace.setSecondPaneHidden(true);

      expect(rig.workspace.swapFocus(), rig.workspace.left);
      expect(rig.workspace.activePane, rig.workspace.left);
    });

    test('re-showing restores the strip whole; the active pane does not '
        'move back on its own', () {
      final rig = build();
      final rightStrip = rig.workspace.right;
      final rightTabs = rightStrip.tabs;
      rig.workspace.setActivePane(rightStrip);

      rig.workspace.setSecondPaneHidden(true);
      rig.workspace.setSecondPaneHidden(false);

      expect(rig.workspace.secondPaneShown, isTrue);
      // The remembered pane is state, not focus: the strip and every
      // tab object survive untouched while the active pane stays where
      // the hide parked it.
      expect(rightStrip.tabs, rightTabs);
      expect(identical(rightStrip.activeTab?.controller, rig.right), isTrue);
      expect(rig.workspace.activePane, rig.workspace.left);
    });
  });

  group('the stage-2 auto-hide runs the same seam (02 §1/§3)', () {
    test('the layout report hides pane B without touching user intent '
        'and retargets the active pane', () {
      final rig = build();
      rig.workspace.setActivePane(rig.workspace.right);

      rig.workspace.setSecondPaneLayoutShown(false);

      expect(rig.workspace.secondPaneShown, isFalse);
      expect(
        rig.workspace.secondPaneHidden,
        isFalse,
        reason: 'a transient auto-hide restores on regrow — only the '
            'explicit command persists (02 §1)',
      );
      expect(rig.workspace.activePane, rig.workspace.left);
      expect(rig.workspace.swapFocus(), rig.workspace.left);
      rig.workspace.setActivePane(rig.workspace.right);
      expect(rig.workspace.activePane, rig.workspace.left);

      // Regrowth restores the pane through the same flag; the active
      // pane never moves back on its own.
      rig.workspace.setSecondPaneLayoutShown(true);
      expect(rig.workspace.secondPaneShown, isTrue);
      expect(rig.workspace.activePane, rig.workspace.left);
    });

    test('an explicit hide survives a regrow report', () {
      final rig = build();
      rig.workspace.setSecondPaneHidden(true);

      rig.workspace.setSecondPaneLayoutShown(true);

      expect(rig.workspace.secondPaneShown, isFalse);
      expect(rig.workspace.secondPaneHidden, isTrue);
    });
  });
}
