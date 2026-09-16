import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/adaptive_shell.dart';
import 'package:poltergeist_app/ui/panes/quick_connect_view.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';

/// 02 §3's launch restoration inside the production shell: the persisted
/// document rebuilds both strips (remote tabs land as inert cached
/// presentations under a localized Reconnect bar, local tabs rebind
/// live), the hidden second pane stays hidden, and an empty session
/// opens nothing. The Reconnect-bar capture loads a real font when the
/// host provides one — POLTERGEIST_CAPTURE=1 gates every artifact
/// write; PNGs land in tasks/run3-task57/captures/ at the repo root (or
/// POLTERGEIST_CAPTURE_DIR when set).
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task57/captures';

final _now = DateTime.utc(2026, 9, 12);

Future<ByteData> _fontBytes(String path) async {
  final bytes = File(path).readAsBytesSync();
  return ByteData.sublistView(bytes);
}

Future<void> _loadRealFonts() async {
  final home = Platform.environment['HOME'];
  final dir = Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      (home == null ? '' : '$home/.local/share/fonts');
  final sans = File('$dir/DejaVuSans.ttf');
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  final mono = File('$dir/DejaVuSansMono.ttf');
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final iconsLoader = FontLoader('MaterialIcons')
      ..addFont(_fontBytes(icons.path));
    await iconsLoader.load();
  }
  if (!sans.existsSync()) return; // boxes are still a usable capture
  final loader = FontLoader('DejaVu Sans')
    ..addFont(_fontBytes(sans.path));
  if (sansBold.existsSync()) loader.addFont(_fontBytes(sansBold.path));
  await loader.load();
  if (mono.existsSync()) {
    final monoLoader = FontLoader('DejaVu Sans Mono')
      ..addFont(_fontBytes(mono.path));
    await monoLoader.load();
  }
}

Bookmark _bookmark(String id) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: 'web.example.com',
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: 'web.example.com',
      port: 22,
      username: 'tester',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/srv',
  sortKey: id,
  createdAt: _now,
  updatedAt: _now,
);

RemoteFileEntry _row(String path, String name) => RemoteFileEntry(
  path: '$path/$name',
  name: name,
  type: RemoteFileType.file,
  size: 10,
);

/// The multi-tab document under test: pane A holds a restored remote
/// tab (active) and a local tab; the hidden pane B holds a local tab.
SessionState _sessionDoc() => SessionState(
  activePaneId: PaneTabsController.leftPaneId,
  secondPaneHidden: true,
  panes: [
    SessionPaneState(
      paneId: PaneTabsController.leftPaneId,
      activeTab: 0,
      nextTabOrdinal: 3,
      tabs: [
        SessionTabState.remote(
          serverId: 'b1',
          path: '/srv/www',
          bookmark: _bookmark('b1'),
          listing: [
            _row('/srv/www', 'cached-a.txt'),
            _row('/srv/www', 'cached-b.txt'),
          ],
        ),
        const SessionTabState.local(path: '/home/tester/docs'),
      ],
    ),
    SessionPaneState(
      paneId: PaneTabsController.rightPaneId,
      activeTab: 0,
      nextTabOrdinal: 2,
      tabs: const [SessionTabState.local(path: '/home/tester/pics')],
    ),
  ],
);

void main() {
  late session_test.FakeAppEngine engine;
  late FakeBookmarkStore bookmarks;
  late EngineSession? session;
  late Directory supportDir;

  setUp(() async {
    engine = session_test.FakeAppEngine();
    bookmarks = FakeBookmarkStore();
    supportDir = Directory.systemTemp.createTempSync('pg-restore-');
    session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
      bookmarks: bookmarks,
      navigatorKey: GlobalKey<NavigatorState>(),
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
  });

  tearDown(() async {
    await session?.shutdown();
    engine.close();
    supportDir.deleteSync(recursive: true);
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    SessionState? restored,
    bool reconnectRestoredTabs = true,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final base = buildPoltergeistTheme(Brightness.dark);
    final captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
    final theme = captureOn
        ? base.copyWith(
            textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
            primaryTextTheme: base.primaryTextTheme.apply(
              fontFamily: 'DejaVu Sans',
            ),
          )
        : base;
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture.shell'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WorkspaceShell(
            bookmarks: bookmarks,
            engineSession: session,
            restoredSession: restored,
            reconnectRestoredTabs: reconnectRestoredTabs,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (Platform.environment['POLTERGEIST_CAPTURE'] != '1') return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.shell')),
    );
    final bytes = (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final data = await image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        return data!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    }))!;
    final outDir = Directory(_captureDir)..createSync(recursive: true);
    final file = File('${outDir.path}/$name.png');
    // The default dir is relative to the test runner's CWD; print where
    // the PNG actually landed.
    // ignore: avoid_print
    print('capture: ${file.absolute.path}');
    file.writeAsBytesSync(bytes);
  }

  testWidgets(
    'restores tabs, hidden pane, and live bindings (reconnect ON)',
    (tester) async {
      // The remote tab's live listing and the two local opens (pane A's
      // inactive tab does NOT resume — only the active tab per pane).
      engine.channel = session_test.FakeAppBrowseChannel(homePath: '/srv')
        ..listings['/srv/www'] = [_row('/srv/www', 'live.txt')];
      engine.localChannels.addAll([
        session_test.FakeAppBrowseChannel(homePath: '/home/tester')
          ..listings['/home/tester/pics'] = [
            _row('/home/tester/pics', 'photo.jpg'),
          ],
      ]);

      await pumpShell(tester, restored: _sessionDoc());

      // Pane A: the remote tab reconnected on its persisted path.
      expect(engine.openCalls, hasLength(1));
      expect(engine.openCalls.single.serverId, 'b1');
      expect(engine.openCalls.single.paneTabId, 'pane.left.tab1');
      expect(find.text('live.txt'), findsOneWidget);
      // Both persisted tabs exist — chips title by the location's last
      // segment, the remote one active on its restored path.
      expect(find.text('www'), findsWidgets);
      expect(find.text('docs'), findsWidgets);

      // Pane B restored hidden — nothing of it is mounted, but its
      // local tab already rebound live (the active tab of a restored
      // pane rebinds regardless of visibility).
      expect(find.byKey(AdaptiveShell.secondaryPaneKey), findsNothing);
      expect(engine.localChannelRoots, ['~']);
      expect(find.text('photo.jpg'), findsNothing);

      // Re-showing pane B presents the already-live listing.
      await tester.tap(
        find.byKey(const ValueKey('command.view.toggleSecondPane')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(AdaptiveShell.secondaryPaneKey), findsOneWidget);
      expect(find.text('photo.jpg'), findsOneWidget);
    },
  );

  testWidgets(
    'reconnect OFF: cached rows under the bar until the button',
    (tester) async {
      if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
        await tester.runAsync(_loadRealFonts);
      }
      engine.channel = session_test.FakeAppBrowseChannel(homePath: '/srv')
        ..listings['/srv/www'] = [_row('/srv/www', 'live.txt')];
      engine.localChannels.addAll([
        session_test.FakeAppBrowseChannel(homePath: '/home/tester')
          ..listings['/home/tester/pics'] = [
            _row('/home/tester/pics', 'photo.jpg'),
          ],
      ]);

      await pumpShell(
        tester,
        restored: _sessionDoc(),
        reconnectRestoredTabs: false,
      );

      // Activation alone never reconnects: no browse open, the cached
      // snapshot rows render under the localized bar instead.
      expect(engine.openCalls, isEmpty);
      expect(find.text('cached-a.txt'), findsOneWidget);
      expect(find.text('cached-b.txt'), findsOneWidget);
      expect(
        find.text('Session restored — web.example.com is offline.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('pane.reconnectBar.reconnect')),
        findsOneWidget,
      );
      await capture(tester, 'session-restore-reconnect-bar');

      // The explicit gesture is what connects.
      await tester.tap(
        find.byKey(const ValueKey('pane.reconnectBar.reconnect')),
      );
      await tester.pumpAndSettle();
      expect(engine.openCalls, hasLength(1));
      expect(engine.openCalls.single.serverId, 'b1');
      expect(find.text('live.txt'), findsOneWidget);
      expect(find.text('cached-a.txt'), findsNothing);
    },
  );

  testWidgets('a restored local tab rebinds live on activation', (
    tester,
  ) async {
    engine.channel = session_test.FakeAppBrowseChannel(homePath: '/srv')
      ..listings['/srv/www'] = [];
    engine.localChannels.addAll([
      // Pane B's active local tab rebinds first.
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester/pics'] = [
          _row('/home/tester/pics', 'photo.jpg'),
        ],
      // Pane A's local tab, rebound on activation.
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester/docs'] = [
          _row('/home/tester/docs', 'doc.md'),
        ],
    ]);

    await pumpShell(tester, restored: _sessionDoc());
    expect(engine.localChannelRoots, ['~']);

    // Activating pane A's second (local) tab binds it live on its
    // persisted path.
    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    expect(engine.localChannelRoots, ['~', '~']);
    expect(find.text('doc.md'), findsOneWidget);
    expect(engine.localChannels[1].listCalls, ['/home/tester/docs']);
  });

  testWidgets('an empty session restores to the launcher — no tabs '
      'auto-opened', (tester) async {
    await pumpShell(
      tester,
      restored: const SessionState(
        activePaneId: PaneTabsController.leftPaneId,
        secondPaneHidden: false,
        panes: [
          SessionPaneState(
            paneId: PaneTabsController.leftPaneId,
            activeTab: -1,
            nextTabOrdinal: 1,
            tabs: [],
          ),
          SessionPaneState(
            paneId: PaneTabsController.rightPaneId,
            activeTab: -1,
            nextTabOrdinal: 1,
            tabs: [],
          ),
        ],
      ),
    );

    // Both panes sit on the launcher; nothing connected and nothing
    // was minted to fill the void.
    expect(find.byType(QuickConnectView), findsNWidgets(2));
    expect(engine.openCalls, isEmpty);
    expect(engine.localChannelRoots, isEmpty);
  });

  testWidgets('a session restored with pane B visible shows both strips',
      (tester) async {
    engine.localChannels.addAll([
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester/pics'] = [
          _row('/home/tester/pics', 'photo.jpg'),
        ],
    ]);
    final doc = _sessionDoc();

    await pumpShell(
      tester,
      restored: SessionState(
        activePaneId: doc.activePaneId,
        secondPaneHidden: false,
        panes: doc.panes,
      ),
      reconnectRestoredTabs: false,
    );

    expect(find.byKey(AdaptiveShell.secondaryPaneKey), findsOneWidget);
    expect(find.text('photo.jpg'), findsOneWidget);
    // Pane A still shows the cached snapshot — pane B's visibility does
    // not imply a reconnect.
    expect(find.text('cached-a.txt'), findsOneWidget);
    expect(engine.openCalls, isEmpty);
  });
}
