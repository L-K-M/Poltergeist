import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

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

  testWidgets('returning to a tab restores its Quick Select query text '
      'and preview', (tester) async {
    final lanes = FakePaneLanes();
    lanes.nextLocalChannel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [
        RemoteFileEntry(
          path: '/home/tester/report.txt',
          name: 'report.txt',
          type: RemoteFileType.file,
          size: 8,
        ),
        RemoteFileEntry(
          path: '/home/tester/notes.md',
          name: 'notes.md',
          type: RemoteFileType.file,
          size: 8,
        ),
      ];
    final controllerA = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controllerA.openLocalHome();
    final strip = testPaneStrip(controllerA, lanes: lanes);
    final tabB = strip.newTab(target: NewTabTarget.launcher);
    final workspace = WorkspaceController(
      left: strip,
      right: testPaneStrip(
        PaneController(paneTabId: 'pane.right', lanes: lanes),
      ),
    );
    addTearDown(workspace.dispose);
    final focusNode = FocusNode(debugLabel: 'pane.left.listing');
    addTearDown(focusNode.dispose);

    await _pumpPane(tester, strip, workspace, focusNode);
    await tester.pump();
    await tester.pump();

    // newTab activates the new launcher tab — go back to A first.
    strip.activateTab(strip.tabs.first);
    await tester.pump();
    await tester.pump();

    controllerA.openQuickSelect();
    await tester.pump();
    final field = find.byKey(const ValueKey('pane.left.quickSelect.field'));
    expect(field, findsOneWidget);

    // Type the query through the field: the preview selects live.
    await tester.enterText(field, '*.txt');
    await tester.pump();
    bool selected(String name) => controllerA.isRowSelected(
      controllerA.entries.indexWhere((entry) => entry.name == name),
    );
    expect(selected('report.txt'), isTrue);
    expect(selected('notes.md'), isFalse);

    // Visiting the other tab unmounts the field; returning remounts it.
    strip.activateTab(tabB);
    await tester.pump();
    await tester.pump();
    expect(field, findsNothing);

    strip.activateTab(strip.tabs.first);
    await tester.pump();
    await tester.pump();
    expect(field, findsOneWidget);
    expect(
      tester.widget<TextField>(field).controller!.text,
      '*.txt',
      reason: 'the remounted field shows the retained session query',
    );
    expect(selected('report.txt'), isTrue);
    expect(selected('notes.md'), isFalse);

    // The restored text drives Add/Remove and Enter — not an invisible
    // retained query behind a blank field.
    await tester.tap(find.text('Remove'));
    await tester.pump();
    expect(selected('report.txt'), isFalse);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(field, findsNothing);
    expect(controllerA.quickSelectActive, isFalse);
    expect(selected('report.txt'), isFalse);
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
    // Full containment with the same 0.5px tolerance the widget's
    // visibility guard uses — a one-pixel overlap is not "in view".
    bool fullyVisible(Finder chipFinder) {
      final r = tester.getRect(chipFinder);
      return r.left >= stripRect.left - 0.5 &&
          r.right <= stripRect.right + 0.5;
    }

    // The last tab activated on open — its chip is scrolled into view.
    expect(
      fullyVisible(lastChip),
      isTrue,
      reason: 'the freshly activated chip must be fully visible',
    );

    strip.activateTab(strip.tabs.first);
    await tester.pump();
    await tester.pump();

    expect(
      fullyVisible(chip('pane.left.tab1')),
      isTrue,
      reason: 'cycling back must scroll the first chip fully into view',
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

  group('tab strip (D32 §6)', () {
    late FakePaneLanes lanes;
    late PaneTabsController leftStrip;
    late PaneTabsController rightStrip;
    late WorkspaceController workspace;
    late FocusNode leftNode;
    late FocusNode rightNode;

    setUp(() {
      lanes = FakePaneLanes();
      leftStrip = PaneTabsController(
        paneId: PaneTabsController.leftPaneId,
        lanes: lanes,
      );
      rightStrip = PaneTabsController(
        paneId: PaneTabsController.rightPaneId,
        lanes: lanes,
      );
      workspace = WorkspaceController(left: leftStrip, right: rightStrip);
      leftNode = FocusNode();
      rightNode = FocusNode();
    });

    tearDown(() {
      workspace.dispose();
      leftNode.dispose();
      rightNode.dispose();
    });

    Future<void> pumpBoth(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: PaneTabsView(
                    tabs: leftStrip,
                    workspace: workspace,
                    focusNode: leftNode,
                    onSwapFocus: () {},
                    onCancelRecovery: () {},
                  ),
                ),
                Expanded(
                  child: PaneTabsView(
                    tabs: rightStrip,
                    workspace: workspace,
                    focusNode: rightNode,
                    onSwapFocus: () {},
                    onCancelRecovery: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> openLocalTab(PaneTabsController strip, String path) async {
      final channel = FakePaneChannel(path);
      channel.listings[path] = const [];
      lanes.nextLocalChannel = channel;
      final tab = strip.newTab(target: NewTabTarget.launcher);
      await tab.controller.openLocalAt(path);
    }

    testWidgets('only the ACTIVE pane carries the 2 px accent line', (
      tester,
    ) async {
      await openLocalTab(leftStrip, '/home/a');
      await openLocalTab(rightStrip, '/home/b');
      await pumpBoth(tester);

      final chrome = PoltergeistChrome.of(
        tester.element(find.byType(Scaffold)),
      );
      Container line(String key) =>
          tester.widget<Container>(find.byKey(ValueKey(key)));
      expect(workspace.activePane, leftStrip);
      expect(find.byKey(const ValueKey('pane.left.activeIndicator')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('pane.right.inactiveSeparator')),
          findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('pane.left.activeIndicator')))
            .height,
        2,
      );
      expect(
        line('pane.left.activeIndicator').color,
        chrome.activePaneIndicator,
      );

      workspace.setActivePane(rightStrip);
      await tester.pump();
      expect(find.byKey(const ValueKey('pane.right.activeIndicator')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('pane.left.inactiveSeparator')),
          findsOneWidget);
    });

    testWidgets('the ✕ shows on the active tab and on hover only', (
      tester,
    ) async {
      await openLocalTab(leftStrip, '/home/a');
      await openLocalTab(leftStrip, '/home/b');
      leftStrip.activateTab(leftStrip.tabs.last);
      await pumpBoth(tester);

      bool closeVisible(PaneTab tab) => tester
          .widget<Visibility>(
            find.ancestor(
              of: find.byKey(ValueKey('${tab.id}.close')),
              matching: find.byType(Visibility),
            ),
          )
          .visible;
      final first = leftStrip.tabs.first;
      final second = leftStrip.tabs.last;
      expect(closeVisible(second), isTrue);
      expect(closeVisible(first), isFalse);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('a')));
      await tester.pump();
      expect(closeVisible(first), isTrue);
    });

    testWidgets('right-click opens the tab menu: Close Others, Duplicate, '
        'Move to Other Pane, Copy Path', (tester) async {
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await openLocalTab(leftStrip, '/home/a');
      await openLocalTab(leftStrip, '/home/b');
      await openLocalTab(rightStrip, '/home/r');
      await pumpBoth(tester);
      final a = leftStrip.tabs.first;

      Future<void> openMenuOn(String title) async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.text(title)),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await openMenuOn('a');
      await tester.tap(find.byKey(ValueKey('${a.id}.menu.copyPath')));
      await tester.pumpAndSettle();
      expect(clipboard, ['/home/a']);

      // Duplicate opens a new tab on the same folder.
      lanes.nextLocalChannel = FakePaneChannel('/home/a')
        ..listings['/home/a'] = const [];
      await openMenuOn('a');
      await tester.tap(find.byKey(ValueKey('${a.id}.menu.duplicate')));
      await tester.pumpAndSettle();
      expect(leftStrip.tabs, hasLength(3));
      expect(leftStrip.activeTab?.controller.location?.path, '/home/a');

      // Move to Other Pane hands the tab to the right strip.
      await openMenuOn('b');
      final b = leftStrip.tabs[1];
      await tester.tap(find.byKey(ValueKey('${b.id}.menu.moveToOtherPane')));
      await tester.pumpAndSettle();
      expect(rightStrip.tabs, contains(b));
      expect(leftStrip.tabs, isNot(contains(b)));

      // Close Others keeps only the menu's tab.
      await openMenuOn('r');
      final r = rightStrip.tabs.first;
      await tester.tap(find.byKey(ValueKey('${r.id}.menu.closeOthers')));
      await tester.pumpAndSettle();
      expect(rightStrip.tabs, [r]);
      // Let the "Path copied" notice's auto-hide timer run out.
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
