import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/ssh_config_import_setup.dart';
import 'package:poltergeist_app/services/uuid.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/fake_ssh_config_source.dart';

/// Real-font captures of the registry-rendered menu bar (02 §9 / 07
/// §3.4): the closed strip, the File menu (tab block, Open, import), the
/// Edit menu showing the registered shortcut hints, and the View menu
/// (Refresh + the interim Connections entry). The widget-test
/// default font renders hollow boxes, so the capture loads a real face
/// when the host provides one — set POLTERGEIST_CAPTURE_FONT_DIR or rely
/// on the DejaVu fallback. The PNGs land in tasks/run3-task40/ at the
/// repo root (or POLTERGEIST_CAPTURE_DIR when set), and
/// POLTERGEIST_CAPTURE=1 gates every artifact write so an ordinary suite
/// run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task40';

Future<ByteData> _fontBytes(String path) async {
  // sublistView, not ByteData.view: correct even if the read ever
  // returns a sublist view into a pooled buffer (offset ≠ 0).
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

RemoteFileEntry _entry(String name) => RemoteFileEntry(
  path: '/home/tester/$name',
  name: name,
  type: RemoteFileType.file,
  size: 10,
);

void main() {
  testWidgets('captures the closed menu bar and the open File, Edit, '
      'and View menus', (tester) async {
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
    addTearDown(engine.close);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-menus-');
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

    final base = buildPoltergeistTheme(Brightness.dark);
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme: base.primaryTextTheme.apply(
        fontFamily: 'DejaVu Sans',
      ),
    );
    await tester.pumpWidget(
      // The boundary wraps the app, not the shell: a submenu popup
      // renders on the Navigator's overlay — a SIBLING of `home` — so a
      // boundary inside the app would capture no popup.
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
            sshConfigImport: SshConfigImportSetup(
              service: SshConfigImportService(
                homeDirectory: '/home/tester',
                source: FakeSshConfigSource(const {}),
                mintId: uuidV4,
              ),
              bookmarks: bookmarks,
              configPath: '/home/tester/.ssh/config',
            ),
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
          final data = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          return data!.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      }))!;
      outDir.createSync(recursive: true);
      final file = File('${outDir.path}/$name.png');
      // The default dir is relative to the test runner's CWD; print
      // where the PNG actually landed so a run launched from another
      // directory is obvious instead of silently writing elsewhere.
      // ignore: avoid_print
      print('capture: ${file.absolute.path}');
      file.writeAsBytesSync(bytes);
    }

    final l10n = AppLocalizations.of(
      tester.element(find.byType(MenuBar)),
    );

    // The closed strip: File, Edit, View, Go, Window — the menus with
    // registered commands today.
    expect(find.byType(MenuBar), findsOneWidget);
    await capture('menubar');

    await tester.tap(find.text(l10n.menuFile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The popup actually opened — a closed-bar capture is not
    // evidence the menu renders.
    expect(find.byType(MenuItemButton), findsWidgets);
    await capture('menu-file');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.tap(find.text(l10n.menuEdit));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The popup actually opened — a closed-bar capture is not
    // evidence the menu renders.
    expect(find.byType(MenuItemButton), findsWidgets);
    await capture('menu-edit');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.tap(find.text(l10n.menuView));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The popup actually opened — a closed-bar capture is not
    // evidence the menu renders.
    expect(find.byType(MenuItemButton), findsWidgets);
    await capture('menu-view');
  });
}
