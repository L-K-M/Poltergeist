// D32 §9's Home: the sidebar in the kit's list layout on a phone. Each
// row is a 56 dp list item that spells on its second line what the rail
// leaves to a hover tooltip (touch has none), each row is one semantics
// node that says the same, the "+" sheet carries only the verbs that make
// sense without a folder in view, and an empty section says what it is
// for and offers the verbs that fill it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/application_error_reporter.dart';
import 'package:poltergeist_app/services/connection_status_controller.dart';
import 'package:poltergeist_app/services/local_volumes.dart';
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/middle_ellipsis_text.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_facts.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_kit.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_bookmark_store.dart';
import '../../support/fake_connection_state_bridge.dart';

final _now = DateTime.utc(2026, 10, 1);

Bookmark _server(
  String id, {
  String? label,
  int port = 22,
  String? group,
  String sortKey = 'mm',
}) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: label ?? 'label-$id',
  group: group,
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: '$id.example.com',
      port: port,
      username: 'deploy',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/',
  sortKey: sortKey,
  createdAt: _now,
  updatedAt: _now,
);

Bookmark _folder(String id, String path, {String? label}) => Bookmark(
  id: id,
  kind: BookmarkKind.localFolder,
  label: label ?? id,
  localPath: path,
  sortKey: 'mm',
  createdAt: _now,
  updatedAt: _now,
);

/// DEVICES for a phone: nothing listed unless a test says so, and the
/// app-storage home the local pane opens as `~`.
final class _Volumes implements LocalVolumeSource {
  List<LocalVolume> volumes = const [];
  List<String> standard = const [];

  @override
  String? get homeDirectory => '/home/deploy';

  @override
  Future<List<LocalVolume>> list() async => volumes;

  @override
  Future<int?> freeBytes(LocalVolume volume) async => volume.freeBytes;

  @override
  Future<List<String>> standardFolders() async => standard;

  @override
  Future<bool> isDirectory(String path) async => true;

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Future<bool> eject(LocalVolume volume) async => false;
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late FakeBookmarkStore store;
  late FakeConnectionStateBridge bridge;
  late _Volumes volumes;
  late List<String> calls;

  setUp(() {
    store = FakeBookmarkStore();
    bridge = FakeConnectionStateBridge();
    volumes = _Volumes();
    calls = [];
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    SidebarPresentation presentation = SidebarPresentation.home,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = SidebarController(store: store);
    addTearDown(controller.dispose);
    unawaited(controller.reload());
    final connections = ConnectionStatusController(
      bookmarks: store,
      bridge: bridge,
      errors: ApplicationErrorReporter(sink: (_, _) {}),
    );
    addTearDown(connections.dispose);
    unawaited(connections.loadServers());

    await tester.pumpWidget(
      MaterialApp(
        theme: buildPoltergeistTheme(
          Brightness.light,
          platform: TargetPlatform.android,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SidebarView(
            controller: controller,
            connections: connections,
            presentation: presentation,
            volumes: volumes,
            onOpenFavorite: (_, _) {},
            onQuickConnect: () => calls.add('quickConnect'),
            onImportSshConfig: () => calls.add('import'),
            onAddCatalogServer: () => calls.add('newServer'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SidebarRow rowOf(WidgetTester tester, String key) =>
      tester.widget<SidebarRow>(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(SidebarRow),
          matchRoot: true,
        ),
      );

  group('rows', () {
    testWidgets('are 56 dp list items: a 40 dp disc and a 16 sp title', (
      tester,
    ) async {
      store.bookmarks = [_server('demo')];
      await pumpHome(tester);

      final row = find.byKey(const ValueKey('sidebar.favorite.demo'));
      expect(tester.getSize(row).height, 56);
      final title = tester.widget<MiddleEllipsisText>(
        find.descendant(of: row, matching: find.byType(MiddleEllipsisText)),
      );
      expect(title.style?.fontSize, 16);
      final disc = find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).shape == BoxShape.circle,
        ),
      );
      expect(tester.getSize(disc.first), const Size(40, 40));
      // The verbs are one visible tap away, as on the browser's rows.
      expect(rowOf(tester, 'sidebar.favorite.demo').showMenuButton, isTrue);
    });

    testWidgets('a long name ellipsizes in the middle', (tester) async {
      const name = 'production-database-primary-eu-west-1.internal';
      store.bookmarks = [_server('db', label: name)];
      await pumpHome(tester);

      final title = find.byWidgetPredicate(
        (widget) => widget is MiddleEllipsisText && widget.text == name,
      );
      expect(title, findsOneWidget);
      // It fits its row rather than pushing the ⋮ off screen.
      expect(tester.getRect(title).right, lessThan(390 - 48));
    });

    testWidgets('section captions are Material list subheaders', (
      tester,
    ) async {
      store.bookmarks = [_server('demo')];
      await pumpHome(tester);

      final caption = tester.widget<Text>(find.text('Servers'));
      expect(caption.style?.fontSize, 14);
      expect(
        caption.style?.color,
        buildPoltergeistTheme(
          Brightness.light,
          platform: TargetPlatform.android,
        ).colorScheme.primary,
      );
      final header = find.byKey(
        ValueKey(
          'sidebar.section.${SidebarCollapseKeys.section(SidebarSection.servers)}',
        ),
      );
      expect(tester.getSize(header).height, 48);
      // Touch never hovers: the chevron stays drawn.
      expect(
        find.descendant(of: header, matching: find.byIcon(Icons.expand_more)),
        findsOneWidget,
      );
    });
  });

  group('subtitles', () {
    testWidgets('DEVICES spell free space, or the path without it', (
      tester,
    ) async {
      volumes.volumes = const [
        LocalVolume(
          path: '/home/deploy',
          name: 'deploy',
          kind: LocalVolumeKind.home,
          freeBytes: 23000000000,
        ),
        LocalVolume(
          path: '/media/deploy/STICK',
          name: 'STICK',
          kind: LocalVolumeKind.removable,
        ),
      ];
      await pumpHome(tester);

      final home = rowOf(tester, 'sidebar.device./home/deploy');
      expect(home.subtitle, '23 GB free');
      // Free space moved to the second line; nothing trails it twice.
      expect(home.trailingText, isNull);
      expect(home.semanticLabel, 'deploy, 23 GB available');
      expect(
        rowOf(tester, 'sidebar.device./media/deploy/STICK').subtitle,
        '/media/deploy/STICK',
      );
    });

    testWidgets('This device says what it opens', (tester) async {
      await pumpHome(tester);

      final row = rowOf(tester, 'sidebar.device.thisDevice');
      expect(row.subtitle, l10n.compactHomeThisDeviceSubtitle);
      expect(row.semanticLabel, 'This device, App storage');
    });

    testWidgets('FAVORITES spell the location, home-relative', (tester) async {
      store.bookmarks = [
        _folder('docs', '/home/deploy/Documents', label: 'Documents'),
        _folder('srv', '/srv/data', label: 'Data'),
        _server('demo', label: 'demo'),
        Bookmark(
          id: 'mirror',
          kind: BookmarkKind.savedSync,
          label: 'Mirror',
          sync: SavedSyncSpec(
            source: const BookmarkLocation(path: '/home/deploy/site'),
            destination: BookmarkLocation(
              server: _server('demo').server,
              path: '/srv/www',
            ),
          ),
          sortKey: 'mn',
          createdAt: _now,
          updatedAt: _now,
        ),
        Bookmark(
          id: 'pair',
          kind: BookmarkKind.workspace,
          label: 'Daily pair',
          sortKey: 'mo',
          createdAt: _now,
          updatedAt: _now,
        ),
      ];
      await pumpHome(tester);

      expect(rowOf(tester, 'sidebar.favorite.docs').subtitle, '~/Documents');
      expect(
        rowOf(tester, 'sidebar.favorite.docs').semanticLabel,
        'Documents, ~/Documents',
      );
      // Outside the home the path stays absolute.
      expect(rowOf(tester, 'sidebar.favorite.srv').subtitle, '/srv/data');
      // A remote side is the server's own name and the folder.
      expect(
        rowOf(tester, 'sidebar.favorite.mirror').subtitle,
        '~/site → demo · /srv/www',
      );
      expect(
        rowOf(tester, 'sidebar.favorite.pair').subtitle,
        l10n.sidebarKindWorkspace,
      );
    });

    testWidgets('SERVERS spell user@host, a non-default port, and the state '
        'in words while it needs them', (tester) async {
      store.bookmarks = [
        _server('alpha', sortKey: 'ma'),
        _server('beta', port: 2222, sortKey: 'mb'),
        _server('gamma', sortKey: 'mc'),
        _server('delta', sortKey: 'md'),
      ];
      await pumpHome(tester);

      bridge
        ..emitStatus(
          'alpha',
          const ServerStatus(ServerConnectionState.connected),
        )
        ..emitStatus(
          'gamma',
          const ServerStatus(ServerConnectionState.connecting),
        )
        ..emitStatus(
          'delta',
          const ServerStatus(
            ServerConnectionState.disconnected,
            detail: 'Connection refused',
          ),
        );
      await tester.pump();

      // Connected: the dot says it; the line keeps to the endpoint.
      expect(
        rowOf(tester, 'sidebar.favorite.alpha').subtitle,
        'deploy@alpha.example.com',
      );
      expect(
        rowOf(tester, 'sidebar.favorite.beta').subtitle,
        'deploy@beta.example.com:2222',
      );
      expect(
        rowOf(tester, 'sidebar.favorite.gamma').subtitle,
        '${l10n.connectionStateConnecting} · deploy@gamma.example.com',
      );
      expect(
        rowOf(tester, 'sidebar.favorite.delta').subtitle,
        '${l10n.connectionFailedTitle} · deploy@delta.example.com',
      );
    });

    testWidgets('the desktop rail keeps to one line', (tester) async {
      store.bookmarks = [
        _server('demo'),
        _folder('docs', '/home/deploy/Documents'),
      ];
      await pumpHome(tester, presentation: SidebarPresentation.rail);

      expect(rowOf(tester, 'sidebar.favorite.demo').subtitle, isNull);
      expect(rowOf(tester, 'sidebar.favorite.docs').subtitle, isNull);
      expect(rowOf(tester, 'sidebar.favorite.demo').showMenuButton, isFalse);
    });
  });

  group('semantics', () {
    testWidgets('each row is one node whose label carries its state', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      store.bookmarks = [_server('demo', label: 'demo')];
      await pumpHome(tester);
      bridge.emitStatus(
        'demo',
        const ServerStatus(
          ServerConnectionState.disconnected,
          detail: 'Connection refused',
        ),
      );
      await tester.pump();

      const label =
          'demo, Connection failed, deploy@demo.example.com, '
          'Connection refused';
      expect(find.bySemanticsLabel(label), findsOneWidget);
      final node = tester.getSemantics(find.bySemanticsLabel(label));
      expect(
        node,
        isSemantics(
          label: label,
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          hasLongPressAction: true,
        ),
      );
      // The title, the second line, and the ⋮ are pictures of the label:
      // nothing below the row announces on its own.
      expect(node.childrenCount, 0);
      semantics.dispose();
    });
  });

  group('the + sheet', () {
    testWidgets('offers only the verbs that make sense on Home', (
      tester,
    ) async {
      await pumpHome(tester);

      await tester.tap(find.byKey(const ValueKey('sidebar.home.add')));
      await tester.pumpAndSettle();

      final labels = [
        for (final tile in tester.widgetList<ListTile>(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(ListTile),
          ),
        ))
          (tile.title! as Text).data,
      ];
      expect(labels, [
        l10n.sidebarAddNewServer,
        l10n.sidebarAddQuickConnect,
        l10n.sidebarImportSshConfig,
        l10n.sidebarNewGroup,
      ]);
      expect(find.text(l10n.sidebarAddCurrentFolder), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(l10n.sidebarImportSshConfig),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, ['import']);
    });

    testWidgets('the FAVORITES header keeps no + on Home', (tester) async {
      store.bookmarks = [_folder('docs', '/home/deploy/Documents')];
      await pumpHome(tester);

      expect(find.byKey(const ValueKey('sidebar.favorites.add')), findsNothing);
      // SERVERS' + stays: a server is always one tap from being added.
      expect(find.byKey(const ValueKey('sidebar.servers.add')), findsOneWidget);
    });
  });

  group('empty states', () {
    testWidgets('no servers invites a connection: Quick Connect and Import', (
      tester,
    ) async {
      await pumpHome(tester);

      final empty = find.byKey(const ValueKey('sidebar.servers.empty'));
      expect(
        find.descendant(
          of: empty,
          matching: find.text(l10n.compactHomeServersEmptyTitle),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('sidebar.servers.quickConnect')),
      );
      await tester.tap(find.byKey(const ValueKey('sidebar.importSshConfig')));
      expect(calls, ['quickConnect', 'import']);
    });

    testWidgets('no favorites says where one comes from, and offers the '
        'standard folders where they exist', (tester) async {
      volumes.standard = ['/home/deploy/Documents', '/home/deploy/Downloads'];
      await pumpHome(tester);

      final empty = find.byKey(const ValueKey('sidebar.favorites.empty'));
      expect(
        find.descendant(
          of: empty,
          matching: find.text(l10n.compactHomeFavoritesEmptyBody),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('sidebar.favorites.addStandard')),
      );
      await tester.pumpAndSettle();
      expect([
        for (final b in store.bookmarks) b.localPath,
      ], containsAll(['/home/deploy/Documents', '/home/deploy/Downloads']));
    });

    testWidgets('a phone without the standard folders offers no button', (
      tester,
    ) async {
      await pumpHome(tester);

      expect(
        find.byKey(const ValueKey('sidebar.favorites.empty')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('sidebar.favorites.addStandard')),
        findsNothing,
      );
    });
  });

  group('location grammar', () {
    test('paths under the home read as ~', () {
      expect(sidebarHomeRelativePath('/home/me', '/home/me'), '~');
      expect(sidebarHomeRelativePath('/home/me/', '/home/me'), '~');
      expect(
        sidebarHomeRelativePath('/home/me/Documents/a', '/home/me/'),
        '~/Documents/a',
      );
      // A sibling that only shares the prefix is not inside the home.
      expect(sidebarHomeRelativePath('/home/meg', '/home/me'), '/home/meg');
      expect(sidebarHomeRelativePath('/srv', '/home/me'), '/srv');
      expect(sidebarHomeRelativePath('/srv', null), '/srv');
      // A home at the root would make everything "~".
      expect(sidebarHomeRelativePath('/srv', '/'), '/srv');
      expect(
        sidebarHomeRelativePath(r'C:\Users\me\Documents', r'C:\Users\me'),
        r'~\Documents',
      );
    });

    test('endpoints are user@host with only a non-default port', () {
      expect(
        sidebarEndpointText(username: 'deploy', host: 'a.example', port: 22),
        'deploy@a.example',
      );
      expect(
        sidebarEndpointText(username: 'deploy', host: 'a.example', port: 2222),
        'deploy@a.example:2222',
      );
      expect(
        sidebarEndpointText(username: '', host: 'a.example', port: 22),
        'a.example',
      );
      expect(
        sidebarEndpointText(username: 'root', host: 'fd00::1', port: 2222),
        'root@[fd00::1]:2222',
      );
    });
  });
}
