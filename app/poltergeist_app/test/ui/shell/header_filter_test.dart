import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
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

/// A channel whose next listing waits on [hold] — a re-list the test
/// keeps in flight.
class _HeldChannel extends session_test.FakeAppBrowseChannel {
  _HeldChannel() : super(homePath: '/home/tester');

  Completer<void>? hold;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    final gate = hold;
    hold = null;
    if (gate != null) await gate.future;
    return super.listDirectory(path);
  }
}

/// D32 §4's header filter field: it filters the ACTIVE pane's listing
/// (the pane's own strip no longer opens for ⌘F), counts `n of total`
/// while a query is active, follows the active pane, and Esc clears it.
void main() {
  late session_test.FakeAppEngine engine;

  setUp(() {
    engine = session_test.FakeAppEngine();
    engine.localChannels.addAll([
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [
          _entry('alpha.txt'),
          _entry('beta.txt'),
        ],
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [_entry('right.txt')],
      // A ⌘T tab in pane A.
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [
          _entry('gamma.txt'),
          _entry('delta.txt'),
        ],
    ]);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(engine.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-filter-');
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

  final field = find.byKey(const ValueKey('header.filter'));

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(field).controller!.text;

  testWidgets('typing filters the active pane and counts the matches', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('alpha.txt'), findsOneWidget);
    expect(find.text('beta.txt'), findsOneWidget);

    await tester.enterText(field, 'alp');
    await tester.pumpAndSettle();
    expect(find.text('alpha.txt'), findsOneWidget);
    expect(find.text('beta.txt'), findsNothing);
    // Only the active pane filters.
    expect(find.text('right.txt'), findsOneWidget);
    expect(
      find.descendant(of: field, matching: find.text('1 of 2')),
      findsOneWidget,
    );

    // Esc clears the query back to the whole listing.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(fieldText(tester), isEmpty);
    expect(find.text('beta.txt'), findsOneWidget);
  });

  testWidgets('the field follows the active pane\'s query', (tester) async {
    await pumpApp(tester);
    await tester.enterText(field, 'alp');
    await tester.pumpAndSettle();

    await runShellCommand(tester, kPaneFocusRightCommandId);
    expect(fieldText(tester), isEmpty);
    // Pane A keeps its filter while pane B is active.
    expect(find.text('beta.txt'), findsNothing);

    await runShellCommand(tester, kPaneFocusLeftCommandId);
    expect(fieldText(tester), 'alp');
  });

  testWidgets('the field follows a tab change inside the active pane', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.enterText(field, 'alp');
    await tester.pumpAndSettle();

    // A new tab in the same pane: the query goes to the tab on screen,
    // not to the hidden one it replaced.
    await runShellCommand(tester, kTabNewCommandId);
    expect(fieldText(tester), isEmpty);
    await tester.enterText(field, 'gam');
    await tester.pumpAndSettle();
    expect(find.text('gamma.txt'), findsOneWidget);
    expect(find.text('delta.txt'), findsNothing);

    await runShellCommand(tester, kTabPreviousCommandId);
    expect(fieldText(tester), 'alp');
  });

  testWidgets('a re-list neither disables the field nor takes its '
      'focus, and keeps what was typed', (tester) async {
    final channel = _HeldChannel()
      ..listings['/home/tester'] = [_entry('alpha.txt'), _entry('beta.txt')];
    engine.localChannels[0] = channel;
    await pumpApp(tester);
    await tester.enterText(field, 'a');
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'header.filter');

    // A watch or post-transfer refresh: the listing re-lists in place.
    final pane = tester
        .widget<PaneTabsView>(find.byType(PaneTabsView).first)
        .workspace
        .activeTabController!;
    final held = Completer<void>();
    channel.hold = held;
    pane.refresh();
    await tester.pump();
    expect(pane.loading, isTrue);
    expect(tester.widget<TextField>(field).enabled, isTrue);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'header.filter');

    // Typing on mid-re-list lands, and the landed listing honors it.
    tester.testTextInput.enterText('alp');
    await tester.pump();
    expect(pane.filterQuery, 'alp');
    held.complete();
    await tester.pumpAndSettle();
    expect(find.text('alpha.txt'), findsOneWidget);
    expect(find.text('beta.txt'), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'header.filter');
  });

  testWidgets('Ctrl+F (view.filter) focuses the header field', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await pumpApp(tester);
      // The listing holds focus, as after browsing with the keyboard.
      await runShellCommand(tester, kPaneFocusLeftCommandId);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'pane.left.listing',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'header.filter',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
