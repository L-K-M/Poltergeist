import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';

/// Wraps a test-built browsing controller in a one-tab strip (02 §3):
/// pane-level tests keep constructing [PaneController]s directly while
/// the workspace shape carries a [PaneTabsController] per pane. The
/// adopted controller becomes the strip's single active tab.
PaneTabsController testPaneStrip(
  PaneController controller, {
  String paneId = 'pane.left',
  TabCloseConfirm? confirmClose,
}) {
  return PaneTabsController(paneId: paneId, confirmClose: confirmClose)
    ..addTab(controller);
}
