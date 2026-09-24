import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';

RemoteFileEntry _entry(
  String dir,
  String name, {
  RemoteFileType type = RemoteFileType.file,
}) => RemoteFileEntry(path: '$dir/$name', name: name, type: type, size: 10);

/// D32 §6 in the real shell: the first press on the INACTIVE pane both
/// activates it and arms the double-click, so a double-click that
/// starts there opens the row like one in the active pane does.
void main() {
  late session_test.FakeAppEngine engine;
  late session_test.FakeAppBrowseChannel right;

  setUp(() {
    engine = session_test.FakeAppEngine();
    right = session_test.FakeAppBrowseChannel(homePath: '/home/tester')
      ..listings['/home/tester'] = [
        _entry('/home/tester', 'docs', type: RemoteFileType.directory),
        _entry('/home/tester', 'right.txt'),
      ]
      ..listings['/home/tester/docs'] = [
        _entry('/home/tester/docs', 'inside.txt'),
      ];
    engine.localChannels.addAll([
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [_entry('/home/tester', 'left.txt')],
      right,
    ]);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(engine.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-dblclick-');
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

  Future<void> click(WidgetTester tester, Offset at) async {
    final gesture = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
  }

  Future<void> doubleClickDocs(WidgetTester tester) async {
    final docs = tester.getCenter(find.text('docs'));
    await click(tester, docs);
    await tester.pump(const Duration(milliseconds: 60));
    await click(tester, docs);
    await tester.pumpAndSettle();
  }

  testWidgets('a double-click that starts in the inactive pane opens', (
    tester,
  ) async {
    await pumpApp(tester);

    // Activate the LEFT pane first, so the right one is inactive.
    await click(tester, tester.getCenter(find.text('left.txt')));
    await tester.pumpAndSettle();

    await doubleClickDocs(tester);

    expect(right.listCalls, contains('/home/tester/docs'));
    expect(find.text('inside.txt'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('a double-click opens even while a text field held focus', (
    tester,
  ) async {
    await pumpApp(tester);

    // The header filter field has focus (as a Quick Connect or save
    // field would): the first press must still arm the double-click.
    await tester.tap(find.byKey(const ValueKey('header.filter')));
    await tester.pumpAndSettle();

    await doubleClickDocs(tester);

    expect(right.listCalls, contains('/home/tester/docs'));
    expect(find.text('inside.txt'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
