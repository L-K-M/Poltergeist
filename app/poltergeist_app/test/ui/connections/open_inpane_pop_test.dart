import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/connection_status_controller.dart';
import 'package:poltergeist_app/ui/connections/connections_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_bookmark_store.dart';
import '../../support/fake_connection_state_bridge.dart';

// Observed-behavior tests for the open-in-pane row action's pop/open
// ordering: rapid double-tap and pop-race semantics against the real
// Navigator, including vetoed pops and stale callbacks under another route.
void main() {
  late FakeBookmarkStore store;
  late FakeConnectionStateBridge bridge;

  setUp(() {
    store = FakeBookmarkStore();
    bridge = FakeConnectionStateBridge();
  });

  tearDown(() async {
    await bridge.close();
  });

  Bookmark server(String id) {
    return Bookmark(
      id: id,
      kind: BookmarkKind.remotePath,
      label: 'web',
      server: BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: 'web.example.com',
          port: 2222,
          username: 'deploy',
          authMethod: AuthMethod.password,
        ),
      ),
      remotePath: '/',
      sortKey: id,
      createdAt: DateTime.utc(2026, 9, 10),
      updatedAt: DateTime.utc(2026, 9, 10),
    );
  }

  Future<void> pumpRoute(
    WidgetTester tester,
    List<String> opened, {
    Widget Function(Widget)? wrapRoute,
  }) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    store.bookmarks = [server('a')];
    final controller = ConnectionStatusController(
      bookmarks: store,
      bridge: bridge,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const ValueKey('shell.marker'),
                onPressed: () {
                  Navigator.of(context, rootNavigator: true).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) {
                        final view = ConnectionsView(
                          controller,
                          onOpenInPane: (server) => opened.add(server.serverId),
                        );
                        return wrapRoute?.call(view) ?? view;
                      },
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await controller.loadServers();
    await tester.pumpAndSettle();
  }

  testWidgets('a rapid double-tap opens the pane once and pops one route',
      (tester) async {
    final opened = <String>[];
    await pumpRoute(tester, opened);

    final button = find.byKey(const ValueKey('connection.open.a'));
    expect(button, findsOneWidget);

    // Two taps inside the exit animation window.
    await tester.tap(button, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(button, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(opened, ['a'],
        reason: 'the second tap must not re-fire the open');
    // The shell marker route underneath must survive both taps.
    expect(find.byKey(const ValueKey('shell.marker')), findsOneWidget);
  });

  testWidgets('a second tap mid-animation cannot mis-pop', (tester) async {
    final opened = <String>[];
    await pumpRoute(tester, opened);

    final button = find.byKey(const ValueKey('connection.open.a'));
    await tester.tap(button, warnIfMissed: false);
    // Mid exit-animation (material transition runs ~300ms): if the
    // popping route's subtree is still hit-testable, this tap reaches
    // the handler again — the observed-behavior probe.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(button, warnIfMissed: false);
    await tester.pumpAndSettle();

    // Strengthened: the first tap must have fired (the sibling test
    // proves the same setup connects) and the second must not re-fire.
    expect(opened, ['a']);
    // And the shell route underneath must survive both taps.
    expect(find.byKey(const ValueKey('shell.marker')), findsOneWidget);
  });

  testWidgets('a vetoed pop does not open a pane behind Connections', (tester) async {
    final opened = <String>[];
    await pumpRoute(
      tester,
      opened,
      wrapRoute: (child) => PopScope(canPop: false, child: child),
    );
    await tester.tap(find.byKey(const ValueKey('connection.open.a')));
    await tester.pumpAndSettle();
    expect(find.text('web'), findsOneWidget);
    expect(opened, isEmpty);
  });

  testWidgets('a stale row callback cannot pop a covering route', (tester) async {
    final opened = <String>[];
    await pumpRoute(tester, opened);
    final button = find.byKey(const ValueKey('connection.open.a'));
    final callback = tester.widget<IconButton>(button).onPressed!;
    final navigator = Navigator.of(tester.element(button));
    navigator.push<void>(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('covering route')),
    ));
    await tester.pumpAndSettle();
    callback();
    await tester.pumpAndSettle();
    expect(find.text('covering route'), findsOneWidget);
    expect(opened, isEmpty);
  });

  testWidgets('a single tap pops the connections route and opens the pane',
      (tester) async {
    final opened = <String>[];
    await pumpRoute(tester, opened);

    await tester.tap(find.byKey(const ValueKey('connection.open.a')));
    await tester.pumpAndSettle();

    expect(opened, ['a']);
    expect(find.byKey(const ValueKey('shell.marker')), findsOneWidget);
    expect(find.text('web'), findsNothing,
        reason: 'the connections route is gone');
  });
}
