import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_app/ui/server_state_indicator.dart';
import 'package:poltergeist_app/ui/shell/header_toolbar.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';

RemoteFileEntry _entry(String parent, String name) => RemoteFileEntry(
  path: '$parent/$name',
  name: name,
  type: RemoteFileType.file,
  size: 10,
);

Bookmark _server() => Bookmark(
  id: 'srv-web',
  kind: BookmarkKind.remotePath,
  label: 'web',
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: 'web.example.com',
      port: 22,
      username: 'deploy',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/srv/www',
  sortKey: 'srv-web',
  createdAt: DateTime.utc(2026, 9, 12),
  updatedAt: DateTime.utc(2026, 9, 12),
);

/// D32 §4's header title: the active location's folder name with the
/// server dot, a `user@host` subtitle for remotes only, and the full
/// path in a tooltip rather than a second line (10 §2).
void main() {
  late session_test.FakeAppEngine engine;

  setUp(() {
    engine = session_test.FakeAppEngine();
    engine.localChannels.addAll([
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [_entry('/home/tester', 'alpha.txt')],
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [_entry('/home/tester', 'right.txt')],
    ]);
    engine.channel = session_test.FakeAppBrowseChannel(homePath: '/srv/www')
      ..listings['/srv/www'] = [_entry('/srv/www', 'index.html')];
  });

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(engine.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-title-');
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

  Finder inHeader(Finder matching) =>
      find.descendant(of: find.byType(HeaderToolbar), matching: matching);

  Finder tooltip(String message) => inHeader(
    find.byWidgetPredicate((w) => w is Tooltip && w.message == message),
  );

  PaneController activePane(WidgetTester tester) => tester
      .widget<PaneTabsView>(find.byType(PaneTabsView).first)
      .workspace
      .activeTabController!;

  testWidgets('a local folder: its name, no second line, the path in a '
      'tooltip', (tester) async {
    await pumpApp(tester);
    final title = find.byKey(const ValueKey('header.title'));
    expect(tester.widget<Text>(title).data, 'tester');
    expect(inHeader(find.text('/home/tester')), findsNothing);
    expect(tooltip('/home/tester'), findsOneWidget);
    expect(inHeader(find.byType(ServerStateGlyph)), findsNothing);
  });

  testWidgets('a remote folder: its name, the server dot, and user@host '
      'under it', (tester) async {
    await pumpApp(tester);
    await activePane(tester).connectRemote(_server());
    await tester.pumpAndSettle();

    final title = find.byKey(const ValueKey('header.title'));
    expect(tester.widget<Text>(title).data, 'www');
    expect(inHeader(find.byType(ServerStateGlyph)), findsOneWidget);
    expect(inHeader(find.text('deploy@web.example.com')), findsOneWidget);
    expect(inHeader(find.textContaining('/srv/www')), findsNothing);
    expect(tooltip('deploy@web.example.com:/srv/www'), findsOneWidget);
  });
}
