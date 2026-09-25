import 'dart:io';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/update_check_controller.dart';
import 'package:poltergeist_app/ui/menus/app_menu_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';

/// 10 §8's platform rows as the shell actually registers them: Check for
/// Updates… only on macOS (its application menu), Quit only on Linux
/// and Windows (their File menu; macOS keeps AppKit's own Quit).
void main() {
  Future<List<String>> registeredIds(
    WidgetTester tester,
    TargetPlatform platform,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    final engine = session_test.FakeAppEngine();
    engine.localChannels.addAll([
      session_test.FakeAppBrowseChannel(homePath: '/home/tester'),
      session_test.FakeAppBrowseChannel(homePath: '/home/tester'),
    ]);
    addTearDown(engine.close);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-rows-');
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
        updateCheck: UpdateCheckController(enabled: false),
      ),
    );
    await tester.pumpAndSettle();
    final ids = [
      for (final command
          in tester
              .widget<CommandChordScope>(find.byType(CommandChordScope))
              .commands)
        command.id,
    ];
    // Restored inside the body: the binding checks its debug variables
    // before any tear-down runs.
    debugDefaultTargetPlatformOverride = null;
    return ids;
  }

  testWidgets('macOS registers Check for Updates… and no Quit row', (
    tester,
  ) async {
    final ids = await registeredIds(tester, TargetPlatform.macOS);
    expect(ids, contains(kAppCheckForUpdatesCommandId));
    expect(ids, isNot(contains(kAppQuitCommandId)));
  });

  for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
    testWidgets('${platform.name} registers Quit and no update row', (
      tester,
    ) async {
      final ids = await registeredIds(tester, platform);
      expect(ids, contains(kAppQuitCommandId));
      expect(ids, isNot(contains(kAppCheckForUpdatesCommandId)));
    });
  }

  testWidgets('a phone registers neither', (tester) async {
    final ids = await registeredIds(tester, TargetPlatform.android);
    expect(ids, isNot(contains(kAppQuitCommandId)));
    expect(ids, isNot(contains(kAppCheckForUpdatesCommandId)));
  });
}
