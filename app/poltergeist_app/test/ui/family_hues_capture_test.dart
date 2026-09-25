import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/local_volumes.dart';
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../services/engine_session_test.dart' as session_test;
import '../support/fake_app_transfer_queue.dart';
import '../support/fake_bookmark_store.dart';
import '../support/sync_harness.dart';

/// Real-font captures of the whole window for D34's colour vocabulary:
/// the header toolbar's verbs, the sidebar's place tiles, the listing's
/// kind glyphs, and the inspector's tabs, in both themes. Follows the
/// other captures' convention: a real face when the host provides one
/// (POLTERGEIST_CAPTURE_FONT_DIR, or DejaVu under ~/.local/share/fonts
/// or /usr/share/fonts), PNGs under tasks/d34-colour/captures/ (or
/// POLTERGEIST_CAPTURE_DIR), POLTERGEIST_CAPTURE=1 gating every write,
/// and names each PNG with POLTERGEIST_CAPTURE_PREFIX, so one run on
/// the old code and one on the new make a before/after pair.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/d34-colour/captures';
final _prefix = Platform.environment['POLTERGEIST_CAPTURE_PREFIX'] ?? '';

const _home = '/home/tester';
final _modified = DateTime(2026, 9, 21, 14, 5);

Future<ByteData> _fontBytes(String path) async =>
    ByteData.sublistView(File(path).readAsBytesSync());

Future<void> _loadRealFonts() async {
  final home = Platform.environment['HOME'];
  final candidates = [
    ?Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'],
    if (home != null) '$home/.local/share/fonts',
    '/usr/share/fonts/truetype/dejavu',
  ];
  final dir = candidates.firstWhere(
    (dir) => File('$dir/DejaVuSans.ttf').existsSync(),
    orElse: () => '',
  );
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(_fontBytes(icons.path)))
        .load();
  }
  if (dir.isEmpty) return; // boxes are still a usable capture
  final sans = FontLoader('DejaVu Sans')
    ..addFont(_fontBytes('$dir/DejaVuSans.ttf'));
  if (File('$dir/DejaVuSans-Bold.ttf').existsSync()) {
    sans.addFont(_fontBytes('$dir/DejaVuSans-Bold.ttf'));
  }
  await sans.load();
  if (File('$dir/DejaVuSansMono.ttf').existsSync()) {
    await (FontLoader('DejaVu Sans Mono')
          ..addFont(_fontBytes('$dir/DejaVuSansMono.ttf')))
        .load();
  }
}

RemoteFileEntry _folder(String name) => RemoteFileEntry(
  path: '$_home/$name',
  name: name,
  type: RemoteFileType.directory,
  modifiedAt: _modified,
);

RemoteFileEntry _file(String name, int size) => RemoteFileEntry(
  path: '$_home/$name',
  name: name,
  type: RemoteFileType.file,
  size: size,
  modifiedAt: _modified,
);

/// A home folder with one of every kind the listing tints.
final _left = [
  for (final name in [
    'Desktop',
    'Documents',
    'Downloads',
    'Music',
    'Pictures',
    'Projects',
  ])
    _folder(name),
  _file('backup-2026-09.tar.gz', 734003200),
  _file('beach.jpg', 3355443),
  _file('deploy.sh', 1843),
  _file('docker-compose.yml', 2211),
  _file('invoice-0921.pdf', 88210),
  _file('keynote.mov', 214958080),
  _file('main.dart', 9120),
  _file('notes.md', 4410),
  _file('podcast.mp3', 48234496),
  _file('report.docx', 60211),
  _file('screenshot.png', 1048576),
  _file('vault.bin', 65536),
  RemoteFileEntry(
    path: '$_home/latest',
    name: 'latest',
    type: RemoteFileType.symbolicLink,
    modifiedAt: _modified,
  ),
];

final _right = [
  for (final name in ['assets', 'src', 'dist']) _folder(name),
  _file('favicon.ico', 15086),
  _file('index.html', 2113),
  _file('package.json', 1432),
  _file('README.md', 3120),
  _file('site.zip', 4718592),
  _file('style.css', 8841),
];

Bookmark _favorite(String id, String path, {String? label}) => Bookmark(
  id: id,
  kind: BookmarkKind.localFolder,
  label: label ?? path.split('/').last,
  localPath: path,
  sortKey: id,
  createdAt: _modified,
  updatedAt: _modified,
);

List<Bookmark> _bookmarks() => [
  _favorite('a', '$_home/Desktop'),
  _favorite('b', '$_home/Documents'),
  _favorite('c', '$_home/Downloads'),
  _favorite('d', '$_home/Pictures'),
  _favorite('e', '$_home/Projects'),
  Bookmark(
    id: 'f',
    kind: BookmarkKind.workspace,
    label: 'Client X',
    sortKey: 'f',
    createdAt: _modified,
    updatedAt: _modified,
  ),
  Bookmark(
    id: 'g',
    kind: BookmarkKind.savedSync,
    label: 'Mirror site',
    sync: SavedSyncSpec(
      source: const BookmarkLocation(path: '$_home/Projects/site'),
      destination: const BookmarkLocation(path: '/srv/www'),
    ),
    sortKey: 'g',
    createdAt: _modified,
    updatedAt: _modified,
  ),
];

/// Scripted DEVICES, never the capturing host's mounts.
final class _Volumes implements LocalVolumeSource {
  @override
  Future<List<LocalVolume>> list() async => const [
    LocalVolume(path: _home, name: 'tester', kind: LocalVolumeKind.home),
    LocalVolume(path: '/', name: 'Macintosh HD', kind: LocalVolumeKind.root),
    LocalVolume(
      path: '/Volumes/STICK',
      name: 'STICK',
      kind: LocalVolumeKind.removable,
    ),
    LocalVolume(path: '/mnt/backup', name: 'Backup', kind: LocalVolumeKind.fixed),
  ];

  @override
  Future<int?> freeBytes(LocalVolume volume) async => 35433480192;

  @override
  Future<List<String>> standardFolders() async => const [];

  @override
  String? get homeDirectory => _home;

  @override
  Future<bool> isDirectory(String path) async => true;

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Future<bool> eject(LocalVolume volume) async => false;
}

void main() {
  const scenes = [
    (Brightness.dark, SidebarDensity.compact),
    (Brightness.dark, SidebarDensity.comfortable),
    (Brightness.light, SidebarDensity.compact),
  ];
  for (final (brightness, density) in scenes) {
    final scene = '${brightness.name}-${density.name}';
    testWidgets('captures the $scene window', (tester) async {
      await tester.runAsync(_loadRealFonts);

      final engine = session_test.FakeAppEngine();
      for (final listing in [_left, _right]) {
        engine.localChannels.add(
          session_test.FakeAppBrowseChannel(homePath: _home)
            ..listings[_home] = listing,
        );
      }
      addTearDown(engine.close);

      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final navigatorKey = GlobalKey<NavigatorState>();
      final supportDir = Directory.systemTemp.createTempSync('pg-hue-cap-');
      addTearDown(() => supportDir.deleteSync(recursive: true));
      final bookmarks = FakeBookmarkStore()..bookmarks = _bookmarks();
      final session = await startEngineSession(
        supportDirectoryPath: supportDir.path,
        bookmarks: bookmarks,
        navigatorKey: navigatorKey,
        pinStore: InMemoryHostKeyStore(),
        incidentStore: InMemoryIncidentStore(),
        spawn: (config) async => engine,
      );
      addTearDown(session!.shutdown);

      // The desktop window (the variant below sets the platform):
      // flutter_test's host platform is Android, whose touch rows would
      // stand in for the 22 px listing.
      final base = buildPoltergeistTheme(
        brightness,
        platform: TargetPlatform.linux,
      );
      final theme = base.copyWith(
        textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
        primaryTextTheme: base.primaryTextTheme.apply(
          fontFamily: 'DejaVu Sans',
        ),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture.window'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            navigatorKey: navigatorKey,
            home: WorkspaceShell(
              bookmarks: bookmarks,
              engineSession: session,
              localVolumes: _Volumes(),
              transferQueue: FakeAppTransferQueue(),
              initialSidebarDensity: density,
              syncEnvironment: testSyncEnvironment(supportDir),
              syncTasks: SyncQueueTasks(),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      // Both panes' scripted listings arrived.
      expect(find.text('invoice-0921.pdf'), findsOneWidget);
      expect(find.text('style.css'), findsOneWidget);

      // A selection lights the selection verbs (Trash red, Duplicate and
      // Copy cyan) and puts the item under its kind glyph in Info.
      await tester.tap(find.text('keynote.mov'));
      await tester.pumpAndSettle();

      if (Platform.environment['POLTERGEIST_CAPTURE'] != '1') return;
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('capture.window')),
      );
      final bytes = (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          return data!.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      }))!;
      final dir = Directory(_captureDir)..createSync(recursive: true);
      final file = File('${dir.path}/${_prefix}window-$scene.png');
      // ignore: avoid_print
      print('capture: ${file.absolute.path}');
      file.writeAsBytesSync(bytes);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  }
}
