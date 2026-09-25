import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/info_panel.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/shell_commands.dart';

RemoteFileEntry _entry(String name) => RemoteFileEntry(
  path: '/home/tester/$name',
  name: name,
  type: RemoteFileType.file,
  size: 10,
);

/// D32's Info tab follows the ACTIVE pane's ACTIVE tab (10 §3): a tab
/// switch, a new tab, or a close inside the active pane retargets it,
/// not only a pane change.
void main() {
  late session_test.FakeAppEngine engine;

  setUp(() {
    engine = session_test.FakeAppEngine();
    engine.localChannels.addAll([
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [_entry('alpha.txt')],
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [_entry('right.txt')],
      // The ⌘T tab in pane A.
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [_entry('gamma.txt')],
    ]);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(engine.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-inspector-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
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
      ),
    );
    await tester.pumpAndSettle();
  }

  WorkspaceController workspaceOf(WidgetTester tester) =>
      tester.widget<PaneTabsView>(find.byType(PaneTabsView).first).workspace;

  Finder inInfo(String text) =>
      find.descendant(of: find.byType(InfoPanel), matching: find.text(text));

  testWidgets('a new tab, a tab switch, and a close in the active pane '
      'retarget Info', (tester) async {
    await pumpApp(tester);
    final strip = workspaceOf(tester).left;
    strip.activeTabController!.setCursorIndex(0);
    await tester.pumpAndSettle();
    expect(inInfo('alpha.txt'), findsOneWidget);

    await runShellCommand(tester, kTabNewCommandId);
    strip.activeTabController!.setCursorIndex(0);
    await tester.pumpAndSettle();
    expect(inInfo('gamma.txt'), findsOneWidget);
    expect(inInfo('alpha.txt'), findsNothing);

    strip.activateTab(strip.tabs.first);
    await tester.pumpAndSettle();
    expect(inInfo('alpha.txt'), findsOneWidget);
    expect(inInfo('gamma.txt'), findsNothing);

    // Closing the shown tab lands Info on the survivor, never on the
    // disposed controller.
    strip.activateTab(strip.tabs.last);
    await tester.pumpAndSettle();
    await runShellCommand(tester, kTabCloseCommandId);
    expect(strip.tabs, hasLength(1));
    expect(inInfo('alpha.txt'), findsOneWidget);
    expect(inInfo('gamma.txt'), findsNothing);
  });
}
