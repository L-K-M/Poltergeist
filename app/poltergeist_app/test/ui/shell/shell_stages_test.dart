import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';

import '../../support/shell_commands.dart';
import '../compact/compact_harness.dart';

/// D32 §3.2's responsive stages through the real shell with its sidebar:
/// exactly one region changes per threshold, the inspector folds first,
/// then the sidebar, and the panes are the last to give way.
void main() {
  final sidebarRegion = find.byKey(const ValueKey('sidebar.region'));
  final inspectorRegion = find.byKey(const ValueKey('inspector.region'));
  final inspectorOverlay = find.byKey(const ValueKey('inspector.overlay'));
  final panes = find.byType(PaneTabsView);
  final sidebarSplitter = find.byKey(const ValueKey('sidebar.splitter'));
  final inspectorSplitter = find.byKey(const ValueKey('inspector.splitter'));

  WorkspaceController workspaceOf(WidgetTester tester) =>
      tester.widget<PaneTabsView>(panes.first).workspace;

  /// A real mouse drag: many small moves, as a pointer delivers them,
  /// never the one large move `tester.drag` sends.
  Future<void> mouseDrag(
    WidgetTester tester,
    Finder splitter,
    double dx, {
    double step = 4,
  }) async {
    final gesture = await tester.startGesture(
      tester.getCenter(splitter),
      kind: PointerDeviceKind.mouse,
    );
    for (var moved = 0.0; moved < dx.abs(); moved += step) {
      await gesture.moveBy(Offset(dx.sign * step, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('the inspector folds first, then the sidebar; both panes '
      'stay on screen', (tester) async {
    final harness = CompactHarness();
    await harness.pump(tester, size: const Size(1400, 900));

    // Defaults: sidebar 232, inspector 280, two 260 px panes, and the
    // three 7 px splitters — everything inline from 1053 px.
    for (final (width, sidebar, inspectorInline) in [
      (1400.0, true, true),
      (1100.0, true, true),
      (1053.0, true, true),
      (1052.0, true, false),
      (900.0, true, false),
      (766.0, true, false),
      (765.0, false, false),
      (720.0, false, false),
    ]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      final reason = '$width px';
      expect(panes, findsNWidgets(2), reason: reason);
      expect(sidebarRegion, sidebar ? findsOneWidget : findsNothing,
          reason: reason);
      expect(inspectorRegion, inspectorInline ? findsOneWidget : findsNothing,
          reason: reason);
      expect(inspectorOverlay, inspectorInline ? findsNothing : findsOneWidget,
          reason: reason);
    }
  });

  testWidgets('a gradual drag well past the minimum hides the sidebar '
      'and the inspector (10 §3.1)', (tester) async {
    final harness = CompactHarness();
    await harness.pump(tester, size: const Size(1400, 900));

    // 232 → 120 px left in 4 px moves: 112 px, past 180 − 48.
    await mouseDrag(tester, sidebarSplitter, -120);
    expect(sidebarRegion, findsNothing);
    expect(workspaceOf(tester).sidebarHidden, isTrue);

    // 280 → 160 px right: 120 px, past 240 − 48.
    await mouseDrag(tester, inspectorSplitter, 160);
    expect(inspectorRegion, findsNothing);
    expect(workspaceOf(tester).inspectorHidden, isTrue);
  });

  testWidgets('a drag short of the overshoot stops at the minimum', (
    tester,
  ) async {
    final harness = CompactHarness();
    await harness.pump(tester, size: const Size(1400, 900));

    await mouseDrag(tester, sidebarSplitter, -80);
    expect(tester.getSize(sidebarRegion).width, 180);
    expect(workspaceOf(tester).sidebarHidden, isFalse);
  });

  testWidgets('widening a region stops where the panes need the room, so '
      'it never flips to the drawer or overlay mid-drag', (tester) async {
    final harness = CompactHarness();
    await harness.pump(tester, size: const Size(1100, 900));

    // 1100 − (232 + 7) − 7 − 527: the inspector's inline room.
    await mouseDrag(tester, inspectorSplitter, -200, step: 8);
    expect(inspectorOverlay, findsNothing);
    expect(tester.getSize(inspectorRegion).width, 327);
    expect(panes, findsNWidgets(2));

    // 1100 − (327 + 7) − 7 − 527: what is left for the sidebar.
    await mouseDrag(tester, sidebarSplitter, 200, step: 8);
    expect(sidebarRegion, findsOneWidget);
    expect(tester.getSize(sidebarRegion).width, 232);
    expect(inspectorRegion, findsOneWidget);
  });

  testWidgets('a hidden sidebar comes back inline from the toggle', (
    tester,
  ) async {
    final harness = CompactHarness();
    await harness.pump(tester, size: const Size(1400, 900));

    await runShellCommand(tester, kViewToggleSidebarCommandId);
    expect(sidebarRegion, findsNothing);
    await runShellCommand(tester, kViewToggleSidebarCommandId);
    expect(sidebarRegion, findsOneWidget);
    expect(workspaceOf(tester).sidebarHidden, isFalse);
  });
}
