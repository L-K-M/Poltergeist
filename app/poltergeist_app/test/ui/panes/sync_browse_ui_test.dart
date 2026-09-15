import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/ssh_config_import_setup.dart';
import 'package:poltergeist_app/services/uuid.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_app/ui/panes/sync_browse_chip.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/fake_ssh_config_source.dart';
import '../../support/test_panes.dart';

/// 02 §7's UI surface: the link chips on both path bars and the status
/// bar, the `view.toggleSyncBrowsing`/`view.toggleSecondPane`
/// registrations, and the visibility-driven suspend/resume. The state
/// machine itself is covered by the service suite; here the chips,
/// chords, and shell wiring are exercised end to end.
void main() {
  RemoteFileEntry entry(
    String name, {
    String parent = '/x',
    RemoteFileType type = RemoteFileType.file,
  }) => RemoteFileEntry(
    path: '$parent/$name',
    name: name,
    type: type,
    size: 10,
  );

  /// Widget-test settle: the replay chain is commit → probe → mirrored
  /// list → commit across several microtask hops. Each pump drains the
  /// fake zone's microtask queue (pumpEventQueue relies on a real timer
  /// that never fires here).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump();
    }
  }

  /// Two panes bound local at their own roots — `/left/home` has a
  /// `leftOnly/` child the right lacks — inside a two-PaneView harness
  /// sharing the production widgets.
  Future<({PaneController left, PaneController right, WorkspaceController workspace})>
  pumpPanes(WidgetTester tester) async {
    final lanes = controller_test.FakePaneLanes();
    final leftChannel = controller_test.FakePaneChannel('/left/home')
      ..listings['/left/home'] = [
        entry('docs', parent: '/left/home', type: RemoteFileType.directory),
        entry('leftOnly', parent: '/left/home', type: RemoteFileType.directory),
      ]
      ..listings['/left/home/docs'] = [
        entry('inner.txt', parent: '/left/home/docs'),
      ]
      ..listings['/left/home/leftOnly'] = [
        entry('l.txt', parent: '/left/home/leftOnly'),
      ]
      ..listings['/left'] = [
        entry('home', parent: '/left', type: RemoteFileType.directory),
      ];
    final rightChannel = controller_test.FakePaneChannel('/right/home')
      ..listings['/right/home'] = [
        entry('docs', parent: '/right/home', type: RemoteFileType.directory),
      ]
      ..listings['/right/home/docs'] = [
        entry('inner.txt', parent: '/right/home/docs'),
      ];
    final left = PaneController(paneTabId: 'pane.left.tab1', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right.tab1', lanes: lanes);
    final leftStrip = testPaneStrip(left, lanes: lanes);
    final rightStrip = testPaneStrip(right, lanes: lanes);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);
    final leftNode = FocusNode();
    final rightNode = FocusNode();
    addTearDown(leftNode.dispose);
    addTearDown(rightNode.dispose);

    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();
    lanes.nextLocalChannel = rightChannel;
    await right.openLocalHome();
    await tester.pump();

    tester.view.physicalSize = const Size(1400, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // PaneTabsView, not a fixed PaneView: the production shell swaps the
    // mounted tab view on strip changes, which is exactly what the
    // anchored-tab switch test exercises.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPoltergeistTheme(Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: PaneTabsView(
                  tabs: leftStrip,
                  workspace: workspace,
                  focusNode: leftNode,
                  onSwapFocus: () => rightNode.requestFocus(),
                  onCancelRecovery: () {},
                ),
              ),
              Expanded(
                child: PaneTabsView(
                  tabs: rightStrip,
                  workspace: workspace,
                  focusNode: rightNode,
                  onSwapFocus: () => leftNode.requestFocus(),
                  onCancelRecovery: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    leftNode.requestFocus();
    await tester.pump();
    return (left: left, right: right, workspace: workspace);
  }

  group('link chips on the path bars (02 §7)', () {
    testWidgets('both anchored path bars carry the linked chip; toggling '
        'off removes it', (tester) async {
      final rig = await pumpPanes(tester);
      rig.workspace.syncBrowsing.toggle();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('pane.left.tab1.syncChip')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('pane.right.tab1.syncChip')),
        findsOneWidget,
      );
      expect(find.text('Sync browsing'), findsNWidgets(2));

      rig.workspace.syncBrowsing.toggle();
      await tester.pump();
      expect(find.byType(SyncBrowseChip), findsNothing);
    });

    testWidgets('the amber chip carries the escape cause on both bars',
        (tester) async {
      final rig = await pumpPanes(tester);
      rig.workspace.syncBrowsing.toggle();
      await tester.pump();

      rig.left.goUp(); // '/left/home' → '/left': escapes the anchor root.
      await settle(tester);

      expect(
        find.text('Sync browsing suspended — outside the anchor subtree'),
        findsNWidgets(2),
      );
      expect(rig.right.location?.path, '/right/home');
    });

    testWidgets('the amber chip names the missing mirror and the side '
        'it is missing on', (tester) async {
      final rig = await pumpPanes(tester);
      rig.workspace.syncBrowsing.toggle();
      await tester.pump();

      rig.left.navigate('/left/home/leftOnly');
      await settle(tester);

      expect(
        find.text('Sync browsing suspended — "leftOnly" missing on right'),
        findsNWidgets(2),
      );
    });

    testWidgets('switching to a non-anchored tab hides its chip and '
        'suspends; switching back resumes', (tester) async {
      final rig = await pumpPanes(tester);
      rig.workspace.syncBrowsing.toggle();
      await tester.pump();
      final leftStrip = rig.workspace.left;

      // A second tab activates itself — the anchored tab (and its
      // chip) leaves the visible pair.
      leftStrip.newTab(target: NewTabTarget.launcher);
      await tester.pump();
      await tester.pump();

      expect(leftStrip.tabs, hasLength(2));
      expect(rig.workspace.syncBrowsing.suspended, isTrue);
      // The right pane still shows the suspended chip; the left now
      // renders the UNanchored tab's bar, which carries none.
      expect(
        find.byKey(const ValueKey('pane.right.tab1.syncChip')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('pane.left.tab1.syncChip')),
        findsNothing,
      );

      leftStrip.activateTab(leftStrip.tabs.first);
      await tester.pump();
      expect(rig.workspace.syncBrowsing.suspended, isFalse);
      expect(
        find.byKey(const ValueKey('pane.left.tab1.syncChip')),
        findsOneWidget,
      );
    });
  });

  group('command registration (02 §8.3/§9)', () {
    testWidgets('view.toggleSyncBrowsing is app-scoped with the spec '
        'chords, the Go-menu slot, and commit-gated enablement', (
      tester,
    ) async {
      final rig = await pumpPanes(tester);
      final commands = buildPaneCommands(
        workspace: rig.workspace,
        focusLeft: () {},
        focusRight: () {},
        swapFocus: () {},
      );
      final command = commands.firstWhere(
        (c) => c.id == kViewToggleSyncBrowsingCommandId,
      );

      expect(command.scope, CommandScope.app);
      expect(
        command.activators!(TargetPlatform.macOS),
        [
          const SingleActivator(
            LogicalKeyboardKey.keyB,
            meta: true,
            alt: true,
          ),
        ],
      );
      expect(
        command.activators!(TargetPlatform.linux),
        [
          const SingleActivator(
            LogicalKeyboardKey.keyB,
            control: true,
            alt: true,
          ),
        ],
      );
      expect(
        command.activators!(TargetPlatform.windows),
        [
          const SingleActivator(
            LogicalKeyboardKey.keyB,
            control: true,
            alt: true,
          ),
        ],
      );
      expect(command.menuPlacement?.menu, AppMenuId.go);
      expect(command.menuPlacement?.order, 80);

      final context = tester.element(find.byType(Scaffold));
      expect(command.enabled(), isTrue);
      await command.run(context);
      expect(rig.workspace.syncBrowsing.enabled, isTrue);
      await command.run(context);
      expect(rig.workspace.syncBrowsing.enabled, isFalse);
    });

    testWidgets('view.toggleSyncBrowsing is disabled while a pane '
        'stands nowhere', (tester) async {
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
      final command = buildPaneCommands(
        workspace: workspace,
        focusLeft: () {},
        focusRight: () {},
        swapFocus: () {},
      ).firstWhere((c) => c.id == kViewToggleSyncBrowsingCommandId);
      // Neither pane has committed anywhere — nothing to anchor.
      expect(command.enabled(), isFalse);
    });

    testWidgets('view.toggleSecondPane carries the §8.3 chord, the View '
        'slot, and drives the workspace intent', (tester) async {
      final rig = await pumpPanes(tester);
      final command = buildPaneCommands(
        workspace: rig.workspace,
        focusLeft: () {},
        focusRight: () {},
        swapFocus: () {},
      ).firstWhere((c) => c.id == kViewToggleSecondPaneCommandId);

      expect(command.scope, CommandScope.app);
      expect(
        command.activators!(TargetPlatform.macOS),
        [
          const SingleActivator(
            LogicalKeyboardKey.keyD,
            meta: true,
            shift: true,
          ),
        ],
      );
      expect(
        command.activators!(TargetPlatform.linux),
        [
          const SingleActivator(
            LogicalKeyboardKey.keyD,
            control: true,
            shift: true,
          ),
        ],
      );
      expect(command.menuPlacement?.menu, AppMenuId.view);
      expect(command.menuPlacement?.order, 70);
      expect(command.enabled(), isTrue);

      final context = tester.element(find.byType(Scaffold));
      expect(rig.workspace.secondPaneHidden, isFalse);
      await command.run(context);
      expect(rig.workspace.secondPaneHidden, isTrue);
      await command.run(context);
      expect(rig.workspace.secondPaneHidden, isFalse);
    });
  });

  group('shell wiring (02 §7 → §3)', () {
    /// The production shell over a fake engine session — the panes bind
    /// their homes from the two scripted local channels.
    Future<session_test.FakeAppEngine> pumpShell(WidgetTester tester) async {
      final engine = session_test.FakeAppEngine();
      engine.localChannels.addAll([
        session_test.FakeAppBrowseChannel(homePath: '/home/tester')
          ..listings['/home/tester'] = [
            entry('docs', parent: '/home/tester', type: RemoteFileType.directory),
          ]
          ..listings['/home'] = [entry('h.txt', parent: '/home')],
        session_test.FakeAppBrowseChannel(homePath: '/srv/files')
          ..listings['/srv/files'] = [
            entry('docs', parent: '/srv/files', type: RemoteFileType.directory),
          ]
          ..listings['/home/tester/docs'] = [
            entry('inner.txt', parent: '/home/tester/docs'),
          ]
          ..listings['/srv/files/docs'] = [
            entry('inner.txt', parent: '/srv/files/docs'),
          ],
      ]);
      addTearDown(engine.close);

      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final navigatorKey = GlobalKey<NavigatorState>();
      final supportDir = Directory.systemTemp.createTempSync('pg-sync-');
      addTearDown(() {
        try {
          supportDir.deleteSync(recursive: true);
        } on FileSystemException {
          // Best-effort: a stuck engine handle must not mask the result.
        }
      });
      final bookmarks = FakeBookmarkStore();
      final session = await startEngineSession(
        supportDirectoryPath: supportDir.path,
        bookmarks: bookmarks,
        navigatorKey: navigatorKey,
        pinStore: InMemoryHostKeyStore(),
        incidentStore: InMemoryIncidentStore(),
        spawn: (config) async => engine,
      );
      addTearDown(session!.shutdown);

      await tester.pumpWidget(
        PoltergeistApp(
          bookmarks: bookmarks,
          engineSession: session,
          navigatorKey: navigatorKey,
          sshConfigImport: SshConfigImportSetup(
            service: SshConfigImportService(
              homeDirectory: '/home/tester',
              source: FakeSshConfigSource(const {}),
              mintId: uuidV4,
            ),
            bookmarks: bookmarks,
            configPath: '/home/tester/.ssh/config',
          ),
        ),
      );
      await tester.pump();
      await settle(tester);
      return engine;
    }

    testWidgets('the status bar carries the chip; the anchored tab\'s '
        'close is guarded and drops the link on confirm', (tester) async {
      await pumpShell(tester);

      // Arm the link through the toolbar — the same run path ⌥⌘B takes.
      await tester.tap(find.byKey(
        const ValueKey('command.view.toggleSyncBrowsing'),
      ));
      await settle(tester);

      expect(
        find.byKey(const ValueKey('statusbar.syncChip')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('pane.left.tab1.syncChip')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('pane.right.tab1.syncChip')),
        findsOneWidget,
      );

      // The anchored tab's close is guarded by the syncAnchor trigger —
      // declining keeps the tab and the link.
      await tester.tap(find.byKey(const ValueKey('pane.left.tab1.close')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('anchors a sync pair'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('statusbar.syncChip')),
        findsOneWidget,
      );

      // Confirming the same guarded close drops the link with the tab.
      await tester.tap(find.byKey(const ValueKey('pane.left.tab1.close')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('statusbar.syncChip')),
        findsNothing,
      );
    });

    testWidgets('hiding the second pane suspends the link with the '
        'amber chip; re-showing resumes it', (tester) async {
      final engine = await pumpShell(tester);
      await tester.tap(find.byKey(
        const ValueKey('command.view.toggleSyncBrowsing'),
      ));
      await settle(tester);

      // view.toggleSecondPane through the toolbar: pane B unmounts and
      // the link suspends — the amber chip lands on the status bar.
      await tester.tap(find.byKey(
        const ValueKey('command.view.toggleSecondPane'),
      ));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('secondary-pane')),
        findsNothing,
      );
      expect(
        find.text('Sync browsing suspended'),
        findsWidgets,
      );

      // While hidden, pane B's tabs take no commands (02 §3): the
      // refresh chord retargeted to the survivor lists pane A again and
      // never touches pane B's channel.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(engine.localChannels[0].listCalls, hasLength(2));
      expect(engine.localChannels[1].listCalls, hasLength(1));

      // Re-showing restores the strip whole and resumes the link — the
      // anchors never moved.
      await tester.tap(find.byKey(
        const ValueKey('command.view.toggleSecondPane'),
      ));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('secondary-pane')),
        findsOneWidget,
      );
      expect(find.text('Sync browsing'), findsWidgets);
      expect(find.text('Sync browsing suspended'), findsNothing);
    });
  });
}
