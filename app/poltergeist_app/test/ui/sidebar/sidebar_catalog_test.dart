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
import '../../support/fake_stored_id_set.dart';
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
    // The one-line rail these tests describe (D33's compact density).
    SidebarDensity density = SidebarDensity.compact,
    Set<String> pinned = const {},
    PinnedServerWriter? onPinnedChanged,
  }) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = SidebarController(
      store: store,
      density: density,
      initiallyPinned: pinned,
      onPinnedChanged: onPinnedChanged,
      onCollapsedChanged: FakeStoredIdSet().collapse,
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

  testWidgets('no catalog renders SERVERS for live sessions only', (
    tester,
  ) async {
    await pump(tester, withCatalog: false);
    expect(find.text('SERVERS'), findsOneWidget);
    expect(
      find.textContaining('Quick Connect sessions show here'),
      findsOneWidget,
    );
    // The retired section title never renders.
    expect(find.text('Séance servers'), findsNothing);
  });

  testWidgets('an empty catalog says the account has no servers yet', (
    tester,
  ) async {
    await pump(tester);
    expect(
      find.text(
        'No servers on this account yet. Add one in Séance and sync to '
        'see it here.',
      ),
      findsOneWidget,
    );
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
    expect(
      find.byTooltip('deploy@z1.example.com:22\nFrom your Séance account'),
      findsOneWidget,
    );
    // A coloured or emoji server keeps its Séance badge.
    expect(
      find.descendant(of: row('m1'), matching: find.byType(ServerBadge)),
      findsOneWidget,
    );
  });

  testWidgets('a remote favorite files under FAVORITES, apart from the '
      'catalog group of the same name', (tester) async {
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
    final controller = await pump(tester);

    // Two groups: the bookmark's under FAVORITES, the account's under
    // SERVERS, each folding on its own namespaced key.
    expect(find.text('Prod'), findsOneWidget);
    expect(find.text('prod'), findsOneWidget);
    final servers = tester
        .getTopLeft(find.byKey(const ValueKey('sidebar.section.sec:servers')))
        .dy;
    expect(tester.getTopLeft(find.text('saved-web')).dy, lessThan(servers));
    expect(tester.getTopLeft(find.text('alpha')).dy, greaterThan(servers));

    await tester.tap(find.byKey(const ValueKey('sidebar.section.srv:prod')));
    await tester.pumpAndSettle();
    expect(controller.isCollapsed('srv:prod'), isTrue);
    expect(find.text('alpha'), findsNothing);
    expect(find.text('saved-web'), findsOneWidget);
  });

  group('PINNED', () {
    Finder header(String key) => find.byKey(ValueKey('sidebar.section.$key'));

    testWidgets('nothing pinned draws no PINNED section', (tester) async {
      catalog.replace([_server('a1', group: 'Prod')]);
      await pump(tester);
      expect(find.text('PINNED'), findsNothing);
      expect(header('sec:pinned'), findsNothing);
    });

    testWidgets('Pin to top moves a server above SERVERS, out of its group; '
        'Unpin files it back', (tester) async {
      catalog.replace([
        _server('a1', label: 'alpha', group: 'Prod'),
        _server('b1', label: 'beta', group: 'Prod'),
        _server('c1', label: 'gamma'),
      ]);
      final pins = FakeStoredIdSet();
      final writes = pins.writes;
      final controller = await pump(tester, onPinnedChanged: pins.pin);

      await tester.tap(row('a1'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin to top'));
      await tester.pumpAndSettle();

      expect(writes, [
        {'a1'},
      ]);
      expect(controller.isPinned('a1'), isTrue);
      // PINNED leads the rail (D33), above SERVERS.
      final pinnedY = tester.getTopLeft(header('sec:pinned')).dy;
      final serversY = tester.getTopLeft(header('sec:servers')).dy;
      final alphaY = tester.getTopLeft(row('a1')).dy;
      expect(pinnedY, lessThan(alphaY));
      expect(alphaY, lessThan(serversY));
      // One row, not two: the pinned server leaves Prod, whose count
      // follows; SERVERS counts what it still lists.
      expect(row('a1'), findsOneWidget);
      final prod = tester.widget<SidebarSectionHeader>(
        find.ancestor(
          of: header('srv:prod'),
          matching: find.byType(SidebarSectionHeader),
        ),
      );
      expect(prod.count, 1);
      final servers = tester.widget<SidebarSectionHeader>(
        find.ancestor(
          of: header('sec:servers'),
          matching: find.byType(SidebarSectionHeader),
        ),
      );
      expect(servers.count, 2);

      await tester.tap(row('a1'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unpin'));
      await tester.pumpAndSettle();

      expect(writes.last, isEmpty);
      expect(header('sec:pinned'), findsNothing);
      expect(tester.getTopLeft(row('a1')).dy, greaterThan(serversY - 1));
    });

    testWidgets('a pin for a server no longer listed draws nothing', (
      tester,
    ) async {
      catalog.replace([_server('a1')]);
      await pump(tester, pinned: {'gone'});
      expect(header('sec:pinned'), findsNothing);
    });

    testWidgets('with every server pinned, SERVERS does not call the '
        'account empty', (tester) async {
      catalog.replace([_server('a1', label: 'alpha')]);
      await pump(tester, pinned: {'a1'});
      expect(header('sec:pinned'), findsOneWidget);
      expect(row('a1'), findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar.servers.empty')), findsNothing);
    });

    testWidgets('the filter reads PINNED first and keeps it on its own', (
      tester,
    ) async {
      catalog.replace([
        _server('a1', label: 'alpha one'),
        _server('a2', label: 'alpha two'),
        _server('b1', label: 'beta'),
      ]);
      final controller = await pump(tester, pinned: {'a2'});
      controller.requestFilter();
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('sidebar.filter.field'));

      // Rail order: the pinned match is the first one Enter opens.
      await tester.enterText(field, 'alpha');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(opens.single.$1.id, 'a2');

      // Only a pinned server matches: PINNED stays, SERVERS goes.
      await tester.enterText(field, 'two');
      await tester.pumpAndSettle();
      expect(row('a2'), findsOneWidget);
      expect(header('sec:pinned'), findsOneWidget);
      expect(header('sec:servers'), findsNothing);
    });

    testWidgets('PINNED mixes account servers and remote favorites in one '
        'order, by label whatever the case', (tester) async {
      final now = DateTime.utc(2026, 10, 1);
      Bookmark favorite(String id, String label) => Bookmark(
        id: id,
        kind: BookmarkKind.remotePath,
        label: label,
        server: BookmarkServerRef(
          identity: EmbeddedHostIdentity(
            host: '$id.example.com',
            port: 22,
            username: 'deploy',
            authMethod: AuthMethod.agent,
          ),
        ),
        sortKey: 'mm',
        createdAt: now,
        updatedAt: now,
      );
      store.bookmarks = [favorite('b1', 'bravo'), favorite('c1', 'Charlie')];
      catalog.replace([
        _server('a1', label: 'alpha'),
        _server('d1', label: 'Delta'),
        _server('e1', label: 'echo'),
      ]);
      await pump(tester, pinned: {'a1', 'b1', 'c1', 'd1'});

      double y(Finder finder) => tester.getTopLeft(finder).dy;
      Finder favoriteRow(String id) =>
          find.byKey(ValueKey('sidebar.favorite.$id'));
      final ys = [
        y(header('sec:pinned')),
        y(row('a1')),
        y(favoriteRow('b1')),
        y(favoriteRow('c1')),
        y(row('d1')),
        y(header('sec:favorites')),
        y(header('sec:servers')),
        y(row('e1')),
      ];
      expect(ys, orderedEquals([...ys]..sort()));
      final pinned = tester.widget<SidebarSectionHeader>(
        find.ancestor(
          of: header('sec:pinned'),
          matching: find.byType(SidebarSectionHeader),
        ),
      );
      expect(pinned.count, 4);
    });

    testWidgets('PINNED folds under its own key', (tester) async {
      catalog.replace([_server('a1'), _server('b1')]);
      final controller = await pump(tester, pinned: {'a1'});

      await tester.tap(header('sec:pinned'));
      await tester.pumpAndSettle();
      expect(controller.isCollapsed('sec:pinned'), isTrue);
      expect(row('a1'), findsNothing);
      expect(row('b1'), findsOneWidget);
    });
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

  testWidgets('the filter field appears at five servers and filters', (
    tester,
  ) async {
    catalog.replace([
      _server('a1', label: 'alpha'),
      _server('a2', label: 'alpine'),
      for (final id in ['b1', 'c1']) _server(id),
    ]);
    await pump(tester);
    // Four: still chrome (the threshold is five again, D33).
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
    expect(find.text('2 of 5 · ↵ opens the first'), findsOneWidget);

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
    expect(sidebarRow().status, isNull);

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
    expect(sidebarRow().status, isNotNull);
    expect(sidebarRow().selected, isTrue);
  });

  testWidgets('a folded account group shows the live server it hides', (
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
    catalog.replace([_server('s1', group: 'Prod'), _server('s2')]);
    final controller = await pump(tester, workspace: workspace);
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
    SidebarSectionHeader header(String key) =>
        tester.widget<SidebarSectionHeader>(
          find.ancestor(
            of: find.byKey(ValueKey('sidebar.section.$key')),
            matching: find.byType(SidebarSectionHeader),
          ),
        );
    final row = tester.widget<SidebarRow>(
      find.descendant(
        of: find.byKey(const ValueKey('sidebar.catalog.row.s1')),
        matching: find.byType(SidebarRow),
      ),
    );
    expect(header('srv:prod').status, isNull);

    controller.toggleCollapsed('srv:prod');
    await tester.pumpAndSettle();
    expect(header('srv:prod').status, row.status);
    controller.toggleCollapsed('sec:servers');
    await tester.pumpAndSettle();
    expect(header('sec:servers').status, row.status);
  });

  testWidgets('an account server says it comes from the Séance account', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final now = DateTime.utc(2026, 10, 1);
    store.bookmarks = [
      Bookmark(
        id: 'b1',
        kind: BookmarkKind.remotePath,
        label: 'saved-web',
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
    catalog.replace([_server('s1', label: 'alpha')]);
    await pump(tester);
    SidebarRow sidebarRow(Finder finder) => tester.widget<SidebarRow>(
      find.descendant(of: finder, matching: find.byType(SidebarRow)),
    );

    final account = sidebarRow(row('s1'));
    expect(account.trailingIcon, Icons.cloud_outlined);
    expect(account.tooltip, contains('From your Séance account'));
    expect(
      find.bySemanticsLabel(
        'alpha, deploy@s1.example.com, From your Séance account',
      ),
      findsOneWidget,
    );
    // A bookmark of this device's own carries no such mark.
    final saved = sidebarRow(find.byKey(const ValueKey('sidebar.favorite.b1')));
    expect(saved.trailingIcon, isNull);
    expect(saved.tooltip, isNot(contains('Séance account')));
    semantics.dispose();
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

  // Moved here with the account's servers (D33): SERVERS' "+" header now
  // sits over catalog rows.
  testWidgets('the arrows and Tab get past the SERVERS header and its +', (
    tester,
  ) async {
    catalog.replace([_server('a1', label: 'a'), _server('b1', label: 'b')]);
    await pump(tester);
    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    await tester.tap(row('a1'));
    await tester.pumpAndSettle();
    opens.clear();

    // Up lands on the header (its "+" drawn for the keyboard); Down
    // comes straight back to the row rather than bouncing off the "+".
    await press(LogicalKeyboardKey.arrowUp);
    await press(LogicalKeyboardKey.arrowDown);
    await press(LogicalKeyboardKey.enter);
    expect(opens.single.$1.id, 'a1');
    opens.clear();

    // Tab takes the header's "+" as a stop of its own, then the row.
    await press(LogicalKeyboardKey.arrowUp);
    await press(LogicalKeyboardKey.tab);
    await press(LogicalKeyboardKey.enter);
    expect(addCalls, 1);
    await press(LogicalKeyboardKey.tab);
    await press(LogicalKeyboardKey.enter);
    expect(opens.single.$1.id, 'a1');
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
