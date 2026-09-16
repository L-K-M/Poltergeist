import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/test_panes.dart';

/// Real-font captures of the Quick Connect surfaces (02 §2.7) for visual
/// review: the launcher's address field with its port interpretation,
/// the IPv6 rejection hint, and the post-connect "Save as favorite…"
/// bar. The widget-test default font renders hollow boxes, so the
/// capture loads a real face when the host provides one — set
/// POLTERGEIST_CAPTURE_FONT_DIR or rely on the DejaVu fallback. The PNGs
/// land in tasks/run3-task55/captures/ at the repo root (or
/// POLTERGEIST_CAPTURE_DIR when set), and POLTERGEIST_CAPTURE=1 gates
/// every artifact write so an ordinary suite run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task55/captures';

Future<ByteData> _fontBytes(String path) async =>
    ByteData.view(File(path).readAsBytesSync().buffer);

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

Future<void> _pumpLauncher(
  WidgetTester tester,
  PaneTabsController strip,
  WorkspaceController workspace,
  FocusNode node,
) async {
  final base = buildPoltergeistTheme(Brightness.dark);
  final theme = base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'DejaVu Sans'),
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('capture.quickConnect'),
          child: PaneTabsView(
            tabs: strip,
            workspace: workspace,
            focusNode: node,
            onSwapFocus: () {},
            onCancelRecovery: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('captures the Quick Connect hint states', (tester) async {
    await tester.runAsync(_loadRealFonts);

    final lanes = controller_test.FakePaneLanes();
    final strip = PaneTabsController(paneId: 'pane.left', lanes: lanes);
    addTearDown(strip.dispose);
    final right = PaneTabsController(paneId: 'pane.right', lanes: lanes);
    addTearDown(right.dispose);
    final workspace = WorkspaceController(left: strip, right: right);
    addTearDown(workspace.dispose);
    final node = FocusNode();
    addTearDown(node.dispose);

    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpLauncher(tester, strip, workspace, node);

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.quickConnect')),
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

    final field = find.byKey(const ValueKey('quickConnect.field'));

    // The in-range port interpretation: the visible `→ port` hint with
    // the sftp:// escape hatch for a folder of that name.
    await tester.enterText(field, 'deploy@example.com:2222');
    await tester.pump();
    expect(find.textContaining('2222'), findsWidgets);
    await capture('quick-connect-port-hint');

    // The unbracketed-IPv6 rejection with the bracket hint; Connect is
    // disabled. The error text animates in, so settle past it before
    // capturing.
    await tester.enterText(field, 'deploy@2001:db8::1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('[ ]'), findsOneWidget);
    await capture('quick-connect-ipv6-hint');
  });

  testWidgets('captures the save-as-favorite bar', (tester) async {
    await tester.runAsync(_loadRealFonts);

    final lanes = controller_test.FakePaneLanes();
    final channel = controller_test.FakePaneChannel('/home/deploy');
    channel.listings['/srv/www'] = const [];
    lanes.nextRemoteChannel = channel;
    final now = DateTime.utc(2026, 9, 16);
    final adhoc = Bookmark(
      id: 'adhoc:capture',
      kind: BookmarkKind.remotePath,
      label: 'deploy@example.com',
      server: BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: 'example.com',
          port: 22,
          username: 'deploy',
          authMethod: AuthMethod.password,
        ),
      ),
      remotePath: '/srv/www',
      sortKey: 'adhoc:capture',
      createdAt: now,
      updatedAt: now,
    );
    final controller = PaneController(
      paneTabId: 'pane.left.tab1',
      lanes: lanes,
    );
    addTearDown(controller.dispose);
    await controller.connectRemote(adhoc, initialPath: '/srv/www');
    final strip = testPaneStrip(controller, lanes: lanes);
    final right = PaneTabsController(paneId: 'pane.right', lanes: lanes);
    addTearDown(right.dispose);
    final workspace = WorkspaceController(left: strip, right: right);
    addTearDown(workspace.dispose);
    final node = FocusNode();
    addTearDown(node.dispose);

    tester.view.physicalSize = const Size(1100, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final base = buildPoltergeistTheme(Brightness.dark);
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme: base.primaryTextTheme.apply(
        fontFamily: 'DejaVu Sans',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('capture.saveFavorite'),
            child: PaneView(
              controller: controller,
              pane: strip,
              workspace: workspace,
              focusNode: node,
              onSwapFocus: () {},
              onCancelRecovery: () {},
              bookmarks: FakeBookmarkStore(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('saveFavorite.bar')),
      findsOneWidget,
    );
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.saveFavorite')),
    );
    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      final outDir = Directory(_captureDir);
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
      File(
        '${outDir.path}/quick-connect-save-bar.png',
      ).writeAsBytesSync(bytes);
    }
  });
}
