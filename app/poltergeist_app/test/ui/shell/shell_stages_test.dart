import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';

import '../compact/compact_harness.dart';

/// D32 §3.2's responsive stages through the real shell with its sidebar:
/// exactly one region changes per threshold, the inspector folds first,
/// then the sidebar, and the panes are the last to give way.
void main() {
  final sidebarRegion = find.byKey(const ValueKey('sidebar.region'));
  final inspectorRegion = find.byKey(const ValueKey('inspector.region'));
  final inspectorOverlay = find.byKey(const ValueKey('inspector.overlay'));
  final panes = find.byType(PaneTabsView);

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
}
