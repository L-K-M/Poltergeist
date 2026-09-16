import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_app/services/workspace_library.dart';
import 'package:poltergeist_app/services/workspace_list_store.dart';
import 'package:poltergeist_app/services/workspace_state.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';

/// Real-font captures of the workspace surface (02 §3's final slice):
/// the Commands menu's "Workspaces" submenu listing the saved
/// workspaces newest-first, and the `Workspace "X" opened` toast with
/// its Undo action. Follows the menu-bar capture's convention — a real
/// face when the host provides one (POLTERGEIST_CAPTURE_FONT_DIR or the
/// DejaVu fallback), PNGs under tasks/run3-task58/ (or
/// POLTERGEIST_CAPTURE_DIR), POLTERGEIST_CAPTURE=1 gating every write.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task58';

Future<ByteData> _fontBytes(String path) async {
  final bytes = File(path).readAsBytesSync();
  return ByteData.sublistView(bytes);
}

Future<void> _loadRealFonts() async {
  final home = Platform.environment['HOME'];
  final dir =
      Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
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
  final loader = FontLoader('DejaVu Sans')..addFont(_fontBytes(sans.path));
  if (sansBold.existsSync()) loader.addFont(_fontBytes(sansBold.path));
  await loader.load();
  if (mono.existsSync()) {
    final monoLoader = FontLoader('DejaVu Sans Mono')
      ..addFont(_fontBytes(mono.path));
    await monoLoader.load();
  }
}

RemoteFileEntry _entry(String name) => RemoteFileEntry(
  path: '/home/tester/$name',
  name: name,
  type: RemoteFileType.file,
  size: 10,
);

WorkspacePaneState _pane(String paneId, List<String> paths) =>
    WorkspacePaneState(
      paneId: paneId,
      activeTab: paths.isEmpty ? -1 : 0,
      tabs: [
        for (final path in paths)
          WorkspaceTabState(
            session: SessionTabState.local(path: path),
            filterQuery: '',
            filterFieldOpen: false,
            showHidden: false,
            viewMode: PaneViewMode.details,
          ),
      ],
    );

void main() {
  testWidgets('captures the Workspaces submenu and the opened toast '
      'with Undo', (tester) async {
    await tester.runAsync(_loadRealFonts);

    final engine = session_test.FakeAppEngine();
    for (final names in [
      ['left.txt', 'docs'],
      ['right.txt'],
    ]) {
      engine.localChannels.add(
        session_test.FakeAppBrowseChannel(homePath: '/home/tester')
          ..listings['/home/tester'] = [for (final n in names) _entry(n)],
      );
    }
    // The opened workspace's own targets — each restored tab mints its
    // own channel, so the open needs one scripted channel per pane.
    for (final path in ['/home/tester/work', '/srv/archive']) {
      engine.localChannels.add(
        session_test.FakeAppBrowseChannel(homePath: '/home/tester')
          ..listings[path] = [
            path == '/home/tester/work'
                ? _entry('main.dart')
                : _entry('old.tar'),
          ],
      );
    }
    addTearDown(engine.close);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-ws-cap-');
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

    // The saved-workspace list, pre-seeded so the submenu has rows:
    // two records prove the newest-first order renders. The store stack
    // is built INSIDE the real-async zone — its `Future.value()` write
    // seeds never deliver to the fake zone's microtask queue, so a
    // fake-zone-built store could never complete a write here.
    late final WorkspaceLibrary library;
    await tester.runAsync(() async {
      library = WorkspaceLibrary(
        store: WorkspaceListStore(
          store: SettingsStore(path: p.join(supportDir.path, 'settings.json')),
        ),
      );
      await library.load();
      await library.save(
        label: 'Archive',
        snapshot: WorkspaceSnapshot(
          left: _pane(sessionLeftPaneId, ['/srv/archive']),
          right: _pane(sessionRightPaneId, const []),
        ),
      );
      await library.save(
        label: 'Client X',
        snapshot: WorkspaceSnapshot(
          left: _pane(sessionLeftPaneId, ['/home/tester/work']),
          right: _pane(sessionRightPaneId, ['/srv/archive']),
        ),
      );
    });
    addTearDown(library.dispose);

    final base = buildPoltergeistTheme(Brightness.dark);
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'DejaVu Sans'),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture.shell'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          navigatorKey: navigatorKey,
          home: WorkspaceShell(
            bookmarks: bookmarks,
            engineSession: session,
            workspaces: library,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.shell')),
    );
    final captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
    final outDir = Directory(_captureDir);

    Future<void> capture(String name) async {
      if (!captureOn) return;
      final bytes = (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          return data!.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      }))!;
      outDir.createSync(recursive: true);
      final file = File('${outDir.path}/$name.png');
      // ignore: avoid_print
      print('capture: ${file.absolute.path}');
      file.writeAsBytesSync(bytes);
    }

    final l10n = AppLocalizations.of(tester.element(find.byType(MenuBar)));

    // Open the Commands menu, then expand the Workspaces submenu row.
    expect(find.byType(MenuBar), findsOneWidget);
    await tester.tap(find.text(l10n.menuCommands));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Save Workspace…'), findsWidgets);

    await tester.tap(find.text(l10n.menuWorkspaces));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The submenu actually opened — both saved rows render.
    expect(find.text('Client X'), findsWidgets);
    expect(find.text('Archive'), findsWidgets);
    await capture('workspaces-submenu');

    // Open the top row: the guarded replace runs, then the toast lands.
    // runAsync because the open's markOpened write is real I/O.
    await tester.runAsync(() async {
      // The submenu row and the open popup leaf both carry the name —
      // tap the leaf's button.
      await tester.tap(find.widgetWithText(MenuItemButton, 'Client X'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // The command's markOpened write is real I/O — poll the real
      // event loop until the toast lands rather than betting on a fixed
      // delay (a fixed sleep flakes when the suite runs under load).
      for (var i = 0; i < 40; i++) {
        await tester.pump();
        if (find
            .text('Workspace "Client X" opened')
            .evaluate()
            .isNotEmpty) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await tester.pump();
    });
    await tester.pump();
    expect(find.text('Workspace "Client X" opened'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    // Run the toast's entrance animation out before the capture — a
    // single pump would freeze it at opacity ~0.
    await tester.pump(const Duration(milliseconds: 300));
    await capture('workspace-toast');
  });
}
