import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/server_appearance.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_kit.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/test_panes.dart';

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
  late int addCalls;
  late List<ServerConfig> edits;
  late List<ServerConfig> duplicates;
  late List<ServerConfig> deletes;

  Future<SidebarController> pump(
    WidgetTester tester, {
    bool withCatalog = true,
    bool withOpen = true,
    bool withManage = true,
    WorkspaceController? workspace,
  }) async {
    tester.view.physicalSize = const Size(600, 1000);
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
        theme: buildPoltergeistTheme(
          Brightness.light,
          platform: TargetPlatform.linux,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: SidebarView(
                controller: controller,
                onOpenFavorite: (_, _) {},
                catalog: withCatalog ? catalog : null,
                catalogListenable: source,
                workspace: workspace,
                onOpenCatalogServer: withOpen
                    ? (server, action) => opens.add((server, action))
                    : null,
                onAddCatalogServer: withManage ? () => addCalls++ : null,
                onEditCatalogServer: withManage
                    ? (server) => edits.add(server)
                    : null,
                onDuplicateCatalogServer: withManage
                    ? (server) => duplicates.add(server)
                    : null,
                onDeleteCatalogServer: withManage
                    ? (server) => deletes.add(server)
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Finder row(String id) => find.byKey(ValueKey('sidebar.catalog.row.$id'));

  setUp(() {
    store = FakeBookmarkStore();
    catalog = SeanceServerCatalog();
    source = _CatalogSource();
    opens = [];
    addCalls = 0;
    edits = [];
    duplicates = [];
    deletes = [];
  });

  testWidgets('no catalog and no saved server renders the empty SERVERS', (
    tester,
  ) async {
    await pump(tester, withCatalog: false);
    expect(find.text('SERVERS'), findsOneWidget);
    expect(find.textContaining('No servers yet'), findsOneWidget);
    // The retired section title never renders.
    expect(find.text('Séance servers'), findsNothing);
  });

  testWidgets('catalog servers join SERVERS, grouped by the Séance rules', (
    tester,
  ) async {
    catalog.replace([
      _server('z1', label: 'zeta'),
      _server('a1', label: 'alpha', group: 'Prod'),
      _server('a2', label: 'beta', group: 'Prod', iconEmoji: '🚀'),
      _server('m1', label: 'mid', group: 'Dev', customColor: '#AA3366'),
    ]);
    await pump(tester);

    // Loose rows first, then the groups alphabetically (the rail's one
    // order, shared with FAVORITES).
    final zeta = tester.getTopLeft(row('z1')).dy;
    final dev = tester.getTopLeft(find.text('Dev')).dy;
    final prod = tester.getTopLeft(find.text('Prod')).dy;
    expect(zeta, lessThan(dev));
    expect(dev, lessThan(prod));
    expect(find.text('beta'), findsOneWidget);
    // The endpoint is the tooltip now (one-line rows, 10 §5).
    expect(find.text('deploy@z1.example.com:22'), findsNothing);
    expect(find.byTooltip('deploy@z1.example.com:22'), findsOneWidget);
    // A coloured or emoji server keeps its Séance badge.
    expect(
      find.descendant(of: row('m1'), matching: find.byType(ServerBadge)),
      findsOneWidget,
    );
  });

  testWidgets('a saved server and a catalog server share one group row', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 10, 1);
    store.bookmarks = [
      Bookmark(
        id: 'b1',
        kind: BookmarkKind.remotePath,
        label: 'saved-web',
        group: 'Prod',
        server: BookmarkServerRef(
          identity: EmbeddedHostIdentity(
            host: 'web.example.com',
            port: 22,
            username: 'deploy',
            authMethod: AuthMethod.agent,
          ),
        ),
        sortKey: 'mm',
        createdAt: now,
        updatedAt: now,
      ),
    ];
    catalog.replace([_server('a1', label: 'alpha', group: 'prod')]);
    await pump(tester);

    expect(find.text('Prod'), findsOneWidget);
    expect(find.text('saved-web'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
  });

  testWidgets('the section and its groups collapse under srv: keys', (
    tester,
  ) async {
    catalog.replace([
      _server('a1', group: 'Prod'),
      _server('b1', group: 'Prod'),
      _server('c1'),
    ]);
    final controller = await pump(tester);

    await tester.tap(find.text('Prod'));
    await tester.pumpAndSettle();
    expect(find.text('label-a1'), findsNothing);
    expect(find.text('label-c1'), findsOneWidget);
    expect(controller.isCollapsed('srv:prod'), isTrue);

    await tester.tap(find.text('Prod'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SERVERS'));
    await tester.pumpAndSettle();
    expect(find.text('label-c1'), findsNothing);
    expect(controller.isCollapsed('sec:servers'), isTrue);
  });

  testWidgets('tap opens with the modifier vocabulary', (tester) async {
    catalog.replace([_server('s1')]);
    await pump(tester);

    await tester.tap(find.text('label-s1'));
    await tester.pumpAndSettle();
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

    await tester.tap(row('s1'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Open in New Tab'), findsOneWidget);
    expect(find.text('Open in Other Pane'), findsOneWidget);

    await tester.tap(find.text('Open in Other Pane'));
    await tester.pumpAndSettle();
    expect(opens.single.$2, SidebarOpenAction.oppositePane);
  });

  testWidgets('the filter field appears at eight servers and filters', (
    tester,
  ) async {
    catalog.replace([
      _server('a1', label: 'alpha'),
      _server('a2', label: 'alpine'),
      for (final id in ['b1', 'c1', 'd1', 'e1', 'f1']) _server(id),
    ]);
    await pump(tester);
    // Seven: still chrome (10 §5's threshold is eight).
    expect(find.byType(TextField), findsNothing);

    catalog.replace([...catalog.servers, _server('g1')]);
    source.pulse();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'alp');
    await tester.pumpAndSettle();
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('alpine'), findsOneWidget);
    expect(find.text('label-b1'), findsNothing);
    expect(find.text('2 of 8'), findsOneWidget);

    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(opens.single.$1.label, 'alpha');
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

  testWidgets('a catalog server bound in a pane paints its live dot', (
    tester,
  ) async {
    final lanes = controller_test.FakePaneLanes();
    final left = PaneController(paneTabId: 'pane.left.tab1', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right.tab1', lanes: lanes);
    final workspace = WorkspaceController(
      left: testPaneStrip(left),
      right: testPaneStrip(right),
    );
    addTearDown(workspace.dispose);
    catalog.replace([_server('s1')]);
    await pump(tester, workspace: workspace);

    SidebarRow sidebarRow() => tester.widget<SidebarRow>(
      find.descendant(of: row('s1'), matching: find.byType(SidebarRow)),
    );
    expect(sidebarRow().statusColor, isNull);

    final now = DateTime.utc(2026, 10, 1);
    await left.connectRemote(
      Bookmark(
        id: 's1',
        kind: BookmarkKind.remotePath,
        label: 'label-s1',
        server: const BookmarkServerRef(serverConfigId: 's1'),
        sortKey: '',
        createdAt: now,
        updatedAt: now,
      ),
      resolvedConfig: catalog.byId('s1'),
    );
    await tester.pumpAndSettle();
    expect(sidebarRow().statusColor, isNotNull);
    expect(sidebarRow().selected, isTrue);
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

  testWidgets('the SERVERS + is New Server when the editor exists', (
    tester,
  ) async {
    catalog.replace([_server('s1')]);
    await pump(tester);
    final add = find.byKey(const ValueKey('sidebar.servers.add'));
    // Hidden until the header is hovered (10 §5): inert until then.
    await tester.tap(add, warnIfMissed: false);
    expect(addCalls, 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey('sidebar.section.sec:servers')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(add);
    expect(addCalls, 1);
  });

  testWidgets('the row menu offers and fires the management verbs', (
    tester,
  ) async {
    catalog.replace([_server('s1'), _server('s2', label: 'other')]);
    await pump(tester);

    await tester.tap(row('s2'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Duplicate'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(edits.single.id, 's2');

    await tester.tap(row('s1'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    expect(duplicates.single.id, 's1');

    await tester.tap(row('s1'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deletes.single.id, 's1');
  });

  testWidgets('null manage callbacks render the catalog read-only', (
    tester,
  ) async {
    catalog.replace([_server('s1')]);
    await pump(tester, withManage: false);

    // No add affordance: no editor and no Quick Connect seam.
    expect(find.byKey(const ValueKey('sidebar.servers.add')), findsNothing);

    await tester.tap(row('s1'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Open in New Tab'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Duplicate'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });
}
