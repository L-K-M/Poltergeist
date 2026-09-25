import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/local_volumes.dart';
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_bookmark_store.dart';

/// Real-font captures of the D32 sidebar (10 §5) for visual review:
/// DEVICES, FAVORITES, and grouped SERVERS over the shared kit, and a
/// row's context menu. The widget-test default font renders hollow boxes, so
/// the capture loads a real face when the host provides one — set
/// POLTERGEIST_CAPTURE_FONT_DIR or rely on the DejaVu fallback. The PNGs
/// land in tasks/run3-task76/captures/ at the repo root (or
/// POLTERGEIST_CAPTURE_DIR when set), and POLTERGEIST_CAPTURE=1 gates
/// every artifact write so an ordinary suite run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task76/captures';

final _now = DateTime.utc(2026, 10, 1);

Bookmark _remote(String id, {String? group, String sortKey = 'mm'}) =>
    Bookmark(
      id: id,
      kind: BookmarkKind.remotePath,
      label: 'label-$id',
      group: group,
      server: BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: '$id.example.com',
          port: 22,
          username: 'deploy',
          authMethod: AuthMethod.agent,
        ),
      ),
      remotePath: '/srv/$id',
      sortKey: sortKey,
      createdAt: _now,
      updatedAt: _now,
    );

Future<ByteData> _fontBytes(String path) async {
  final bytes = File(path).readAsBytesSync();
  return ByteData.view(
    bytes.buffer,
    bytes.offsetInBytes,
    bytes.lengthInBytes,
  );
}

/// Registers a readable face under the names the theme resolves: the
/// default family name for body text plus the mono fallback chain.
Future<void> _loadRealFonts() async {
  final dir = Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      '${Platform.environment['HOME']}/.local/share/fonts';
  final sans = File('$dir/DejaVuSans.ttf');
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  final mono = File('$dir/DejaVuSansMono.ttf');
  // Kind glyphs are MaterialIcons codepoints: without the icon font they
  // rasterize as tofu boxes. It ships inside the Flutter SDK, so it loads
  // even when the host has no DejaVu faces (text then falls back to
  // boxes, which is still a usable capture).
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

/// Scripted DEVICES for the capture — never the capturing host's mounts.
final class _CaptureVolumes implements LocalVolumeSource {
  @override
  Future<List<LocalVolume>> list() async => const [
    LocalVolume(
      path: '/home/deploy',
      name: 'deploy',
      kind: LocalVolumeKind.home,
      freeBytes: 69000000000,
    ),
    LocalVolume(
      path: '/',
      name: 'Macintosh HD',
      kind: LocalVolumeKind.root,
      freeBytes: 69000000000,
    ),
    LocalVolume(
      path: '/Volumes/STICK',
      name: 'STICK',
      kind: LocalVolumeKind.removable,
      freeBytes: 2000000000,
    ),
  ];

  @override
  Future<int?> freeBytes(LocalVolume volume) async => volume.freeBytes;

  @override
  Future<List<String>> standardFolders() async => const [];

  @override
  String? get homeDirectory => '/home/deploy';

  @override
  Future<bool> isDirectory(String path) async => false;

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Future<bool> eject(LocalVolume volume) async => false;
}

void main() {
  testWidgets('captures the grouped sidebar and a row context menu', (
    tester,
  ) async {
    await tester.runAsync(_loadRealFonts);

    final store = FakeBookmarkStore()
      ..bookmarks = [
        _remote('alpha', group: 'work', sortKey: 'ma'),
        _remote('beta', group: 'work', sortKey: 'mb'),
        _remote('gamma', group: 'home', sortKey: 'mc'),
        Bookmark(
          id: 'docs',
          kind: BookmarkKind.localFolder,
          label: 'Docs',
          localPath: '/home/deploy/docs',
          sortKey: 'md',
          createdAt: _now,
          updatedAt: _now,
        ),
        Bookmark(
          id: 'ws1',
          kind: BookmarkKind.workspace,
          label: 'Daily pair',
          sortKey: 'me',
          createdAt: _now,
          updatedAt: _now,
        ),
        Bookmark(
          id: 'sync1',
          kind: BookmarkKind.savedSync,
          label: 'Mirror',
          sortKey: 'mf',
          createdAt: _now,
          updatedAt: _now,
        ),
      ];
    final controller = SidebarController(store: store);
    addTearDown(controller.dispose);
    unawaited(controller.reload());

    tester.view.physicalSize = const Size(300, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final base = buildPoltergeistTheme(
      Brightness.dark,
      platform: TargetPlatform.linux,
    );
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme: base.primaryTextTheme.apply(
        fontFamily: 'DejaVu Sans',
      ),
    );
    await tester.pumpWidget(
      // The boundary wraps the app, not the sidebar: a context-menu
      // popup renders on the Navigator's overlay — a SIBLING of `home`
      // — so a boundary inside the app would capture no popup.
      RepaintBoundary(
        key: const ValueKey('capture.sidebar'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: SidebarView(
                controller: controller,
                onOpenFavorite: (_, _) {},
                onDisconnect: (_) {},
                onReviewBlocked: (_) {},
                volumes: _CaptureVolumes(),
                onQuickConnect: () {},
                onOpenSettings: () {},
                syncStatus: () => SidebarSyncStatus(
                  enrolled: true,
                  lastSyncAt: DateTime.now().subtract(
                    const Duration(minutes: 2),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.sidebar')),
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
      // Sync file IO: awaiting real async directory/file futures can
      // strand the fake-async zone (the established capture pattern).
      outDir.createSync(recursive: true);
      File('${outDir.path}/$name.png').writeAsBytesSync(bytes);
    }

    // DEVICES, then the loose favorites, then SERVERS with the 'work'
    // and 'home' groups as nested disclosure rows.
    expect(find.text('work'), findsOneWidget);
    expect(find.text('home'), findsOneWidget);
    await capture('sidebar-grouped');

    // The collapsed 'home' group keeps its header but drops its row.
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('sidebar.favorite.gamma')),
      findsNothing,
    );
    await capture('sidebar-collapsed-group');
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();

    // A row's context menu over the populated list.
    await tester.tap(
      find.byKey(const ValueKey('sidebar.favorite.alpha')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await capture('sidebar-context-menu');
  });
}
