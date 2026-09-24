import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart' show AppLocalizations;
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/recent_locations.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/ssh_config_import_setup.dart';
import 'package:poltergeist_app/services/uuid.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../services/engine_session_test.dart' as session_test;
import '../support/fake_bookmark_store.dart';
import '../support/fake_ssh_config_source.dart';
import '../support/shell_menus.dart';

/// Real-font captures of the M9 surfaces (02 §8.4 / D22): the Quick
/// Open palette over the live registry — all three sections, shortcut
/// gutter, disabled reason — and the ssh_config import preview reached
/// through the launcher's adoption offer. The PNGs land in
/// tasks/run3-task93/ at the repo root (or POLTERGEIST_CAPTURE_DIR),
/// gated on POLTERGEIST_CAPTURE=1 like the menu captures.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task93';

// The same real-font loader the menu captures use (private there).
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
    // The import dialog styles cells with the generic 'monospace'
    // alias — register the same face under it so captures show text.
    final aliasLoader = FontLoader('monospace')
      ..addFont(_fontBytes(mono.path));
    await aliasLoader.load();
  }
}

const _home = '/home/tester';
const _configPath = '$_home/.ssh/config';
final _fixedNow = DateTime.utc(2026, 9, 22, 12);

const _sampleConfig = '''
Host web
  HostName web.example.com
  Port 2222
  User deploy
  IdentityFile ~/.ssh/id_ed25519

Host other
  HostName other.example.com
  User root
''';

Bookmark _favorite(String id, String label) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: label,
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: '$label.example.com',
      port: 22,
      username: 'deploy',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/srv/$label',
  sortKey: 'f-$label',
  createdAt: _fixedNow,
  updatedAt: _fixedNow,
);

void main() {
  testWidgets('captures the Quick Open palette and the ssh_config '
      'import preview', (tester) async {
    await tester.runAsync(_loadRealFonts);

    final engine = session_test.FakeAppEngine();
    for (final names in [
      ['left.txt', 'docs'],
      ['right.txt'],
    ]) {
      engine.localChannels.add(
        session_test.FakeAppBrowseChannel(homePath: '/home/tester')
          ..listings['/home/tester'] = [
            for (final name in names)
              RemoteFileEntry(
                path: '/home/tester/$name',
                name: name,
                type: RemoteFileType.file,
                size: 10,
              ),
          ],
      );
    }
    addTearDown(engine.close);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-m9-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final bookmarks = FakeBookmarkStore([
      _favorite('fav-web', 'web'),
      _favorite('fav-logs', 'logs'),
    ]);
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
      bookmarks: bookmarks,
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    addTearDown(session!.shutdown);

    // One remote + one local recent so all three palette sections
    // render in the capture.
    final recents = RecentLocationsStore(
      store: SettingsStore(
        path: '${supportDir.path}/settings.json',
        atomicWriter: (target, contents) async =>
            target.writeAsString(contents),
      ),
    );
    addTearDown(recents.dispose);
    recents.recordLocation(
      const LocalPaneLocation('/home/tester/docs'),
    );
    recents.recordLocation(
      const RemotePaneLocation('fav-web', '/srv/web'),
      remoteBookmark: _favorite('fav-web', 'web'),
    );

    final base = buildPoltergeistTheme(Brightness.dark);
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme: base.primaryTextTheme.apply(
        fontFamily: 'DejaVu Sans',
      ),
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
            recentLocations: recents,
            sshConfigImport: SshConfigImportSetup(
              service: SshConfigImportService(
                homeDirectory: _home,
                source: FakeSshConfigSource(
                  const {_configPath: _sampleConfig},
                ),
                mintId: uuidV4,
              ),
              bookmarks: bookmarks,
              configPath: _configPath,
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
      // ignore: avoid_print
      print('capture: ${file.absolute.path}');
      file.writeAsBytesSync(bytes);
    }

    // The palette via its registered chord (Ctrl+Shift+P — the test
    // platform is Linux). Assertions prove the dialog is up before the
    // capture, the same posture the menu captures take.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quickOpen.field')),
      findsOneWidget,
    );
    await capture('quick-open');

    // A filtered view: one query over commands + favorites + recents.
    await tester.enterText(
      find.byKey(const ValueKey('quickOpen.field')),
      'web',
    );
    await tester.pumpAndSettle();
    await capture('quick-open-filtered');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quickOpen.field')), findsNothing);

    // The import preview via the Server menu command (D22; D32 moved
    // it from File) — the launcher offer is covered in
    // quick_connect_test; the capture only needs the dialog itself.
    final l10n = AppLocalizations.of(
      tester.element(find.byType(WorkspaceShell)),
    );
    await openShellMenu(tester, AppMenuId.server);
    await tester.tap(
      find.ancestor(
        of: find.text(l10n.sshImportCommandLabel),
        matching: find.byType(MenuItemButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Import servers from ssh config'),
      findsOneWidget,
    );
    await capture('ssh-import-preview');
  });
}
