import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';

import '../../services/pane_controller_test.dart';
import '../../support/test_panes.dart';

Future<void> _pumpPane(
  WidgetTester tester,
  PaneTabsController strip,
  WorkspaceController workspace,
  FocusNode focusNode,
) {
  return tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: PaneTabsView(
          tabs: strip,
          workspace: workspace,
          focusNode: focusNode,
          onSwapFocus: () {},
          onCancelRecovery: () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('closing the last tab returns focus to the launcher', (
    tester,
  ) async {
    final lanes = FakePaneLanes();
    final leftStrip = testPaneStrip(
      PaneController(paneTabId: 'pane.left', lanes: lanes),
    );
    final rightStrip = testPaneStrip(
      PaneController(paneTabId: 'pane.right', lanes: lanes),
    );
    final workspace = WorkspaceController(
      left: leftStrip,
      right: rightStrip,
    );
    addTearDown(workspace.dispose);
    final focusNode = FocusNode(debugLabel: 'pane.left.listing');
    addTearDown(focusNode.dispose);

    await _pumpPane(tester, leftStrip, workspace, focusNode);
    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);

    // The last tab's unmount detaches the node's Focus — the launcher
    // must reclaim it so the pane's own keys (Tab swap) stay live.
    await leftStrip.requestCloseTab(leftStrip.activeTab!);
    await tester.pump();
    await tester.pump();

    expect(leftStrip.tabs, isEmpty);
    expect(focusNode.hasFocus, isTrue);
  });

  testWidgets('an inactive pane\'s launcher does not steal focus', (
    tester,
  ) async {
    final lanes = FakePaneLanes();
    final leftStrip = testPaneStrip(
      PaneController(paneTabId: 'pane.left', lanes: lanes),
    );
    final rightStrip = testPaneStrip(
      PaneController(paneTabId: 'pane.right', lanes: lanes),
    );
    final workspace = WorkspaceController(
      left: leftStrip,
      right: rightStrip,
    );
    addTearDown(workspace.dispose);
    final leftFocus = FocusNode(debugLabel: 'pane.left.listing');
    final rightFocus = FocusNode(debugLabel: 'pane.right.listing');
    addTearDown(leftFocus.dispose);
    addTearDown(rightFocus.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: PaneTabsView(
                  tabs: leftStrip,
                  workspace: workspace,
                  focusNode: leftFocus,
                  onSwapFocus: () {},
                  onCancelRecovery: () {},
                ),
              ),
              Expanded(
                child: PaneTabsView(
                  tabs: rightStrip,
                  workspace: workspace,
                  focusNode: rightFocus,
                  onSwapFocus: () {},
                  onCancelRecovery: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    leftFocus.requestFocus();
    await tester.pump();
    expect(leftFocus.hasFocus, isTrue);

    // Middle-click can close the INACTIVE right pane's last tab; its
    // launcher mounts without grabbing focus from the left pane.
    workspace.setActivePane(leftStrip);
    await rightStrip.requestCloseTab(rightStrip.activeTab!);
    await tester.pump();
    await tester.pump();

    expect(rightStrip.tabs, isEmpty);
    expect(leftFocus.hasFocus, isTrue);
    expect(rightFocus.hasFocus, isFalse);
  });

  testWidgets('activating an offscreen chip scrolls it into view', (
    tester,
  ) async {
    final strip = PaneTabsController(
      paneId: PaneTabsController.leftPaneId,
    );
    addTearDown(strip.dispose);
    // Fifteen launcher tabs overflow the 800px test surface: each chip
    // is at least 72px wide.
    for (var i = 0; i < 15; i++) {
      strip.newTab(target: NewTabTarget.launcher);
    }
    final otherStrip = PaneTabsController(
      paneId: PaneTabsController.rightPaneId,
    );
    addTearDown(otherStrip.dispose);
    final workspace = WorkspaceController(left: strip, right: otherStrip);
    addTearDown(workspace.dispose);
    final focusNode = FocusNode(debugLabel: 'pane.left.listing');
    addTearDown(focusNode.dispose);

    await _pumpPane(tester, strip, workspace, focusNode);
    await tester.pump();
    await tester.pump();

    // Chips share their ValueKey with the tab's PaneView — scope the
    // finder to the strip's scrollable.
    Finder chip(String id) => find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.byKey(ValueKey(id)),
    );
    final lastChip = chip('pane.left.tab15');
    expect(lastChip, findsOneWidget);
    final stripRect = tester.getRect(
      find.ancestor(
        of: lastChip,
        matching: find.byType(SingleChildScrollView),
      ),
    );
    // The last tab activated on open — its chip is scrolled into view.
    expect(
      stripRect.overlaps(tester.getRect(lastChip)),
      isTrue,
      reason: 'the freshly activated chip must be visible',
    );

    strip.activateTab(strip.tabs.first);
    await tester.pump();
    await tester.pump();

    expect(
      stripRect.overlaps(tester.getRect(chip('pane.left.tab1'))),
      isTrue,
      reason: 'cycling back must scroll the first chip into view',
    );

    // An already-visible activation must not scroll: ensureVisible's
    // explicit alignment would re-center the chip on every ⌃⇥.
    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(Scrollable),
      ),
    );
    final atRest = scrollable.position.pixels;
    strip.activateTab(strip.tabs[1]);
    await tester.pump();
    await tester.pump();
    expect(
      scrollable.position.pixels,
      atRest,
      reason: 'an onscreen chip activation keeps the strip at rest',
    );
  });
}
