import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_engine_lanes.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';

/// Wraps a test-built browsing controller in a one-tab strip (02 §3):
/// pane-level tests keep constructing [PaneController]s directly while
/// the workspace shape carries a [PaneTabsController] per pane. The
/// adopted controller becomes the strip's single active tab.
///
/// [paneId] defaults to the controller's tab-id prefix (`pane.left.tab1`
/// → `pane.left`), so a strip can never silently disagree with the
/// controller it wraps. Pass [lanes] when the test drives strip-level
/// operations that open channels (`newTab`, ghost reopen) or close
/// remote tabs (the last-binding disconnect check). Strips wrapping
/// into a WorkspaceController are disposed with it; the teardown here
/// covers strips that never join one (double-dispose is guarded).
PaneTabsController testPaneStrip(
  PaneController controller, {
  String? paneId,
  PaneEngineLanes? lanes,
  TabCloseConfirm? confirmClose,
  bool Function(String serverId, PaneController excluding)?
  serverStillShared,
}) {
  final strip = PaneTabsController(
    paneId: paneId ?? controller.paneTabId.split('.').take(2).join('.'),
    lanes: lanes,
    confirmClose: confirmClose,
    serverStillShared: serverStillShared,
  )..addTab(controller);
  addTearDown(strip.dispose);
  return strip;
}
