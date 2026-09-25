import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/application_error_reporter.dart';
import 'package:poltergeist_app/services/connection_status_controller.dart';
import 'package:poltergeist_app/services/local_volumes.dart';
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_bookmark_store.dart';
import '../../support/fake_connection_state_bridge.dart';

/// Real-font captures of the D32 sidebar (10 §5, D33) for visual review:
/// DEVICES, FAVORITES with remote favorites among them, PINNED, and
/// grouped SERVERS over the shared kit, in both densities on the desktop
/// rail (at 300 px and at the 180 px minimum) and on a tablet's touch
/// rail, in both themes, plus a folded group's live dot and a row's
/// context menu. The widget-test default font renders hollow boxes, so
/// the capture loads a real face when the host provides one — set
/// POLTERGEIST_CAPTURE_FONT_DIR or rely on the DejaVu fallback. The PNGs
/// land in tasks/run3-task76/captures/ at the repo root (or
/// POLTERGEIST_CAPTURE_DIR when set), and POLTERGEIST_CAPTURE=1 gates
/// every artifact write so an ordinary suite run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task76/captures';

final _now = DateTime.utc(2026, 10, 1);

Bookmark _remote(
  String id, {
  String? group,
  String sortKey = 'mm',
  ServerColor? color,
}) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: 'label-$id',
  group: group,
  color: color,
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

/// One scene's posture: the platform decides desktop or touch sizes, the
/// density the rows, and the width the rail.
typedef _Scene = ({
  String name,
  TargetPlatform platform,
  Brightness brightness,
  SidebarDensity density,
  double width,
});

ServerConfig _account(
  String id,
  String label, {
  String? group,
  ServerColor? color,
  String? iconEmoji,
}) => ServerConfig(
  id: id,
  label: label,
  host: '$id.example.net',
  port: 22,
  username: 'ops',
  authMethod: AuthMethod.agent,
  group: group,
  color: color,
  iconEmoji: iconEmoji,
  createdAt: 1780000000000,
  updatedAt: 1780000000000,
);

void main() {
  const scenes = <_Scene>[
    (
      name: 'sidebar-comfortable-dark',
      platform: TargetPlatform.linux,
      brightness: Brightness.dark,
      density: SidebarDensity.comfortable,
      width: 300,
    ),
    (
      name: 'sidebar-compact-dark',
      platform: TargetPlatform.linux,
      brightness: Brightness.dark,
      density: SidebarDensity.compact,
      width: 300,
    ),
    (
      name: 'sidebar-comfortable-light',
      platform: TargetPlatform.linux,
      brightness: Brightness.light,
      density: SidebarDensity.comfortable,
      width: 300,
    ),
    (
      name: 'sidebar-compact-light',
      platform: TargetPlatform.linux,
      brightness: Brightness.light,
      density: SidebarDensity.compact,
      width: 300,
    ),
    // The rail's 180 px minimum (10 §3.1): nothing may overflow there.
    (
      name: 'sidebar-comfortable-narrow',
      platform: TargetPlatform.linux,
      brightness: Brightness.dark,
      density: SidebarDensity.comfortable,
      width: 180,
    ),
    (
      name: 'sidebar-compact-narrow',
      platform: TargetPlatform.linux,
      brightness: Brightness.dark,
      density: SidebarDensity.compact,
      width: 180,
    ),
    // A tablet: the desktop layout's rail at touch sizes (10 §9).
    (
      name: 'sidebar-tablet-comfortable',
      platform: TargetPlatform.android,
      brightness: Brightness.light,
      density: SidebarDensity.comfortable,
      width: 320,
    ),
    (
      name: 'sidebar-tablet-compact',
      platform: TargetPlatform.android,
      brightness: Brightness.light,
      density: SidebarDensity.compact,
      width: 320,
    ),
  ];

  FakeBookmarkStore seededStore() => FakeBookmarkStore()
    ..bookmarks = [
      _remote('alpha', group: 'work', sortKey: 'ma', color: ServerColor.teal),
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
      _remote('delta', sortKey: 'mg'),
    ];

  SeanceServerCatalog seededCatalog() => SeanceServerCatalog()
    ..replace([
      _account(
        'prod-db',
        'prod-db',
        group: 'Production',
        color: ServerColor.red,
      ),
      _account('prod-web', 'prod-web', group: 'Production'),
      _account('staging', 'staging', iconEmoji: '🧪'),
      _account('nas', 'nas', color: ServerColor.blue),
    ]);

  /// Pumps the rail for [scene]; returns its controller. The live states
  /// cover every dot and ring: alpha connected (the ring, and its group's
  /// live dot when folded), beta connecting, gamma's host key blocked,
  /// delta failed.
  Future<SidebarController> pumpScene(WidgetTester tester, _Scene scene) async {
    final store = seededStore();
    final controller = SidebarController(
      store: store,
      density: scene.density,
      initiallyPinned: const {'nas'},
    );
    addTearDown(controller.dispose);
    unawaited(controller.reload());
    final bridge = FakeConnectionStateBridge();
    final connections = ConnectionStatusController(
      bookmarks: store,
      bridge: bridge,
      errors: ApplicationErrorReporter(sink: (_, _) {}),
    );
    addTearDown(connections.dispose);
    unawaited(connections.loadServers());

    tester.view.physicalSize = Size(scene.width, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final base = buildPoltergeistTheme(
      scene.brightness,
      platform: scene.platform,
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
              width: scene.width,
              child: SidebarView(
                controller: controller,
                connections: connections,
                catalog: seededCatalog(),
                onOpenFavorite: (_, _) {},
                onOpenCatalogServer: (_, _) {},
                onEditCatalogServer: (_) {},
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
    bridge
      ..emitStatus('alpha', const ServerStatus(ServerConnectionState.connected))
      ..emitStatus('beta', const ServerStatus(ServerConnectionState.connecting))
      ..emitStatus(
        'gamma',
        const ServerStatus(
          ServerConnectionState.blocked,
          detail: 'Host key changed.',
        ),
      )
      ..emitStatus(
        'delta',
        const ServerStatus(
          ServerConnectionState.disconnected,
          detail: 'Connection refused',
        ),
      );
    await tester.pumpAndSettle();
    return controller;
  }

  final captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
  final outDir = Directory(_captureDir);

  Future<void> capture(WidgetTester tester, String name) async {
    if (!captureOn) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.sidebar')),
    );
    final bytes = (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
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

  for (final scene in scenes) {
    testWidgets('captures ${scene.name}', (tester) async {
      await tester.runAsync(_loadRealFonts);
      await pumpScene(tester, scene);

      // DEVICES, FAVORITES with its 'work' and 'home' groups (remote
      // favorites among the folders), PINNED, then SERVERS with the
      // account's Production group; no overflow at any width.
      expect(find.text('work'), findsOneWidget);
      expect(find.text('home'), findsOneWidget);
      expect(find.text('Production'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, scene.name);
    });
  }

  testWidgets('captures a folded group\'s live dot and a row menu', (
    tester,
  ) async {
    await tester.runAsync(_loadRealFonts);
    final controller = await pumpScene(tester, scenes.first);

    // The folded 'work' group keeps its header, drops its rows, and
    // shows the connected server it hides as a dot.
    controller.toggleCollapsed(SidebarCollapseKeys.favoriteGroup('work'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sidebar.favorite.alpha')), findsNothing);
    await capture(tester, 'sidebar-collapsed-group');
    controller.toggleCollapsed(SidebarCollapseKeys.favoriteGroup('work'));
    await tester.pumpAndSettle();

    // A row's context menu over the populated list.
    await tester.tap(
      find.byKey(const ValueKey('sidebar.favorite.alpha')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await capture(tester, 'sidebar-context-menu');
  });
}
