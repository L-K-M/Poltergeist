import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_bookmark_store.dart';

const _nowMs = 1780000000000;

ServerConfig _server(
  String id, {
  String? label,
  String? group,
  ServerColor? color,
  String? customColor,
  ServerIcon? icon,
  String? iconEmoji,
  String host = 'example.com',
  int port = 22,
  String username = 'deploy',
}) => ServerConfig(
  id: id,
  label: label ?? 'label-$id',
  host: '$id.$host',
  port: port,
  username: username,
  authMethod: AuthMethod.agent,
  group: group,
  color: color,
  customColor: customColor,
  icon: icon,
  iconEmoji: iconEmoji,
  createdAt: _nowMs,
  updatedAt: _nowMs,
);

/// The service pulse the view merges into its repaint listenable — the
/// catalog mutates in place, so a round's landing is this notification.
final class _CatalogSource extends ChangeNotifier {
  void pulse() => notifyListeners();
}

void main() {
  late FakeBookmarkStore store;
  late SeanceServerCatalog catalog;
  late _CatalogSource source;
  late List<(ServerConfig, SidebarOpenAction)> opens;
  late int syncCalls;
  var syncing = false;
  String? syncError;

  Future<SidebarController> pump(
    WidgetTester tester, {
    bool withCatalog = true,
    bool withOpen = true,
    bool withSync = true,
    bool settle = true,
  }) async {
    tester.view.physicalSize = const Size(300, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = SidebarController(
      store: store,
      onCollapsedChanged: (_) {},
    );
    addTearDown(controller.dispose);
    unawaited(controller.reload());

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: SidebarView(
              controller: controller,
              onOpenFavorite: (_, _) {},
              catalog: withCatalog ? catalog : null,
              catalogListenable: source,
              catalogSyncing: syncing,
              catalogSyncError: syncError,
              onSyncNow: withSync ? () => syncCalls++ : null,
              onOpenCatalogServer: withOpen
                  ? (server, action) => opens.add((server, action))
                  : null,
            ),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // A syncing round paints an animating spinner — pumpAndSettle
      // would wait on it forever.
      await tester.pump();
    }
    return controller;
  }

  setUp(() {
    store = FakeBookmarkStore();
    catalog = SeanceServerCatalog();
    source = _CatalogSource();
    opens = [];
    syncCalls = 0;
    syncing = false;
    syncError = null;
  });

  testWidgets('no catalog renders no section', (tester) async {
    await pump(tester, withCatalog: false);
    expect(find.text('Séance servers'), findsNothing);
  });

  testWidgets('empty catalog renders the section with empty copy', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Séance servers'), findsOneWidget);
    expect(
      find.textContaining('No servers on this account yet'),
      findsOneWidget,
    );
  });

  testWidgets('servers render in Séance grouping order with marks', (
    tester,
  ) async {
    catalog.replace([
      _server('z1', label: 'zeta'),
      _server('a1', label: 'alpha', group: 'Prod'),
      _server('a2', label: 'beta', group: 'Prod', iconEmoji: '🚀'),
      _server('m1', label: 'mid', group: 'Dev', customColor: '#AA3366'),
    ]);
    await pump(tester);

    // Group headers alphabetical, ungrouped last — Séance's order.
    expect(find.text('Dev'), findsOneWidget);
    expect(find.text('Prod'), findsOneWidget);
    expect(find.text('Ungrouped'), findsOneWidget);
    expect(find.text('zeta'), findsOneWidget);
    // The emoji mark paints rather than rendering as text (appearance
    // coverage lives in server_appearance_test); the row it marks is
    // what matters here.
    expect(find.text('beta'), findsOneWidget);
    // Endpoint subtitle matches the pulled config.
    expect(find.text('deploy@z1.example.com:22'), findsOneWidget);
  });

  testWidgets('outer section collapses; inner group collapses too', (
    tester,
  ) async {
    catalog.replace([
      _server('a1', group: 'Prod'),
      _server('b1', group: 'Prod'),
      _server('c1'),
    ]);
    await pump(tester);

    // Collapse the inner Prod group: its rows leave, others stay.
    await tester.tap(find.text('Prod'));
    await tester.pumpAndSettle();
    expect(find.text('label-a1'), findsNothing);
    expect(find.text('label-c1'), findsOneWidget);

    // Expand again, then collapse the outer section: everything leaves.
    await tester.tap(find.text('Prod'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Séance servers'));
    await tester.pumpAndSettle();
    expect(find.text('label-c1'), findsNothing);
  });

  testWidgets('tap opens with the modifier vocabulary', (tester) async {
    catalog.replace([_server('s1')]);
    await pump(tester);

    await tester.tap(find.text('label-s1'));
    await tester.pumpAndSettle();
    expect(opens, hasLength(1));
    expect(opens.single.$1.id, 's1');
    expect(opens.single.$2, SidebarOpenAction.plain);

    // ⌘/Ctrl = new tab.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('label-s1'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(opens.last.$2, SidebarOpenAction.newTab);
  });

  testWidgets('context menu offers the three open verbs', (tester) async {
    catalog.replace([_server('s1')]);
    await pump(tester);

    await tester.tap(
      find.byKey(const ValueKey('sidebar.catalog.row.s1')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Open in New Tab'), findsOneWidget);
    expect(find.text('Open in Other Pane'), findsOneWidget);

    await tester.tap(find.text('Open in Other Pane'));
    await tester.pumpAndSettle();
    expect(opens.single.$2, SidebarOpenAction.oppositePane);
  });

  testWidgets('filter field appears at five servers and filters', (
    tester,
  ) async {
    catalog.replace([
      _server('a1', label: 'alpha'),
      _server('a2', label: 'alpine'),
      _server('b1', label: 'beta'),
      _server('c1', label: 'gamma'),
      _server('d1', label: 'delta'),
    ]);
    await pump(tester);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'alp');
    await tester.pumpAndSettle();
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('alpine'), findsOneWidget);
    expect(find.text('beta'), findsNothing);
    // The helper names the Enter-opens-first affordance.
    expect(find.textContaining('opens the first'), findsOneWidget);

    // Enter opens the first match.
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(opens.single.$1.label, 'alpha');
  });

  testWidgets('below the threshold no filter field renders', (
    tester,
  ) async {
    catalog.replace([_server('a1'), _server('b1')]);
    await pump(tester);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a sync round repaints the section via the listenable', (
    tester,
  ) async {
    catalog.replace([_server('one', label: 'first')]);
    await pump(tester);
    expect(find.text('first'), findsOneWidget);

    catalog.replace([
      _server('one', label: 'first'),
      _server('two', label: 'second', group: 'New'),
    ]);
    source.pulse();
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
    expect(find.text('New'), findsOneWidget);
  });

  testWidgets('sync button drives the round and shows busy/error', (
    tester,
  ) async {
    catalog.replace([_server('s1')]);
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('sidebar.catalog.syncNow')));
    expect(syncCalls, 1);

    // Sync state is a constructor field — a status change re-pumps the
    // view, same as the service's own notify in the shell.
    syncing = true;
    await pump(tester, settle: false);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    syncing = false;

    syncError = 'Connection refused';
    await pump(tester);
    expect(find.byIcon(Icons.sync_problem), findsOneWidget);
  });

  testWidgets('null open callback renders non-activatable rows', (
    tester,
  ) async {
    catalog.replace([_server('s1')]);
    await pump(tester, withOpen: false);
    await tester.tap(find.text('label-s1'));
    await tester.pumpAndSettle();
    expect(opens, isEmpty);
  });
}
