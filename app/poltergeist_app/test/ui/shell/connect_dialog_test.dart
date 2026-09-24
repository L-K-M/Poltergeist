import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/shell_commands.dart';

RemoteFileEntry _entry(String dir, String name) => RemoteFileEntry(
  path: '$dir/$name',
  name: name,
  type: RemoteFileType.file,
  size: 10,
);

/// D32 §4's Connect verb (⌘K): the header's Connect button opens the
/// quick-connect form as a dialog and binds the address on a fresh tab
/// in the active pane.
void main() {
  late session_test.FakeAppEngine engine;

  setUp(() {
    engine = session_test.FakeAppEngine();
    engine.localChannels.addAll([
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [_entry('/home/tester', 'left.txt')],
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [_entry('/home/tester', 'right.txt')],
    ]);
    engine.channel = session_test.FakeAppBrowseChannel(homePath: '/home/demo')
      ..listings['/home/demo'] = [_entry('/home/demo', 'remote.txt')];
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(engine.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-connect-');
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

  testWidgets('submitting an address connects it and closes cleanly', (
    tester,
  ) async {
    await pumpApp(tester);

    await runShellCommand(tester, 'connect.quickConnect');
    expect(find.byKey(const ValueKey('connect.dialog')), findsOneWidget);

    // The field takes focus on open: typing needs no click first.
    final field = find.byKey(const ValueKey('quickConnect.field'));
    final editable = tester.widget<TextField>(field);
    expect(editable.focusNode!.hasFocus, isTrue);

    await tester.enterText(field, 'demo@example.com');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    // The dialog's exit transition keeps the field mounted after the
    // route pops — the frames that would use a disposed focus node.
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('connect.dialog')), findsNothing);
    expect(engine.openCalls, hasLength(1));
    expect(engine.openCalls.single.config.host, 'example.com');
    expect(engine.openCalls.single.config.username, 'demo');
    expect(find.text('remote.txt'), findsOneWidget);
  });

  testWidgets('Cancel via Esc leaves the panes as they were', (tester) async {
    await pumpApp(tester);

    await runShellCommand(tester, 'connect.quickConnect');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('connect.dialog')), findsNothing);
    expect(engine.openCalls, isEmpty);
  });
}
