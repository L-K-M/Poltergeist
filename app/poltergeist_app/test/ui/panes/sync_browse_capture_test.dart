import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_app/ui/panes/sync_browse_chip.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

/// Real-font captures of Sync Browsing's visible surface (02 §7): the
/// linked chips on both anchored path bars plus the status-bar chip, in
/// the linked state and both named suspension states. The widget-test
/// default font renders hollow boxes, so the capture loads a real face
/// when the host provides one — set POLTERGEIST_CAPTURE_FONT_DIR or rely
/// on the DejaVu fallback. The PNGs land in tasks/run3-task44/captures/
/// at the repo root (or POLTERGEIST_CAPTURE_DIR when set), and
/// POLTERGEIST_CAPTURE=1 gates every artifact write so an ordinary suite
/// run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task44/captures';

Future<ByteData> _fontBytes(String path) async =>
    ByteData.view(File(path).readAsBytesSync().buffer);

/// Registers a readable face under the names the theme resolves: the
/// default family name for body text plus the mono fallback chain the
/// row metrics style reaches for.
Future<void> _loadRealFonts() async {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final dir = Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      (home != null ? '$home/.local/share/fonts' : '');
  final sans = File('$dir/DejaVuSans.ttf');
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  final mono = File('$dir/DejaVuSansMono.ttf');
  // The link/link_off glyphs are MaterialIcons codepoints: without the
  // icon font they rasterize as tofu boxes. It ships inside the Flutter
  // SDK, so it loads even when the host has no DejaVu faces.
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

RemoteFileEntry _entry(
  String name, {
  required String parent,
  RemoteFileType type = RemoteFileType.file,
  int? size,
  DateTime? modified,
}) {
  return RemoteFileEntry(
    path: '$parent/$name',
    name: name,
    type: type,
    size: size ?? 10,
    modifiedAt: modified,
  );
}

void main() {
  testWidgets('captures the linked and suspended chip states',
      (tester) async {
    // Real faces matter only when artifacts are written; an ordinary
    // suite run skips the file IO entirely.
    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      await tester.runAsync(_loadRealFonts);
    }

    final lanes = controller_test.FakePaneLanes();
    // Left root carries a `leftOnly/` child the right lacks — the two
    // named suspension causes both become reachable.
    final leftChannel = controller_test.FakePaneChannel('/left/home')
      ..listings['/left/home'] = [
        _entry('docs', parent: '/left/home', type: RemoteFileType.directory),
        _entry(
          'leftOnly',
          parent: '/left/home',
          type: RemoteFileType.directory,
        ),
        _entry('notes.txt', parent: '/left/home', size: 640),
      ]
      ..listings['/left/home/docs'] = [
        _entry('inner.txt', parent: '/left/home/docs'),
      ]
      ..listings['/left/home/leftOnly'] = [
        _entry('l.txt', parent: '/left/home/leftOnly'),
      ]
      ..listings['/left'] = [
        _entry('home', parent: '/left', type: RemoteFileType.directory),
      ];
    final rightChannel = controller_test.FakePaneChannel('/right/home')
      ..listings['/right/home'] = [
        _entry('docs', parent: '/right/home', type: RemoteFileType.directory),
        _entry('notes.txt', parent: '/right/home', size: 640),
      ]
      ..listings['/right/home/docs'] = [
        _entry('inner.txt', parent: '/right/home/docs'),
      ];
    final left = PaneController(paneTabId: 'pane.left.tab1', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right.tab1', lanes: lanes);
    final leftStrip = testPaneStrip(left, lanes: lanes);
    final rightStrip = testPaneStrip(right, lanes: lanes);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);
    final leftNode = FocusNode();
    final rightNode = FocusNode();
    addTearDown(leftNode.dispose);
    addTearDown(rightNode.dispose);

    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();
    lanes.nextLocalChannel = rightChannel;
    await right.openLocalHome();
    await tester.pump();

    tester.view.physicalSize = const Size(1400, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final base = buildPoltergeistTheme(Brightness.dark);
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme:
          base.primaryTextTheme.apply(fontFamily: 'DejaVu Sans'),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('capture.sync'),
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: PaneTabsView(
                          tabs: leftStrip,
                          workspace: workspace,
                          focusNode: leftNode,
                          onSwapFocus: () => rightNode.requestFocus(),
                          onCancelRecovery: () {},
                        ),
                      ),
                      Expanded(
                        child: PaneTabsView(
                          tabs: rightStrip,
                          workspace: workspace,
                          focusNode: rightNode,
                          onSwapFocus: () => leftNode.requestFocus(),
                          onCancelRecovery: () {},
                        ),
                      ),
                    ],
                  ),
                ),
                // The status bar's sync corner (02 §7), rendered at the
                // shell's height so the capture reads as the shipped row.
                SizedBox(
                  height: 24,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.symmetric(
                      horizontal: 10,
                    ),
                    child: Row(
                      children: [
                        Text(
                          'Ready',
                          style: theme.textTheme.labelSmall,
                        ),
                        // The shell's enabled gate (02 §7); the chip
                        // itself self-repaints on cause changes.
                        ListenableBuilder(
                          listenable: workspace.syncBrowsing,
                          builder: (context, _) {
                            if (!workspace.syncBrowsing.enabled) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsetsDirectional.only(
                                start: 10,
                              ),
                              child: SyncBrowseChip(
                                link: workspace.syncBrowsing,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    leftNode.requestFocus();
    await tester.pump();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.sync')),
    );
    final captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
    // Only the Directory reference is built here; creation waits inside
    // the gate so an ordinary suite run creates nothing.
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
      File('${outDir.path}/$name.png').writeAsBytesSync(bytes);
    }

    /// Drains the commit → probe → mirrored-list → commit cascade (each
    /// pump flushes the fake zone's microtasks).
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump();
      }
    }

    // Linked: both anchors committed, quiet chips on both path bars and
    // the status bar.
    workspace.syncBrowsing.toggle();
    await settle();
    expect(workspace.syncBrowsing.enabled, isTrue);
    expect(workspace.syncBrowsing.suspended, isFalse);
    await capture('sync-linked');

    // Replayed: the left pane's step into docs/ lands on the right's
    // docs/ — both bars show the mirrored relative tail.
    left.navigate('/left/home/docs');
    await settle();
    expect(right.committedLocation?.path, '/right/home/docs');
    await capture('sync-replayed');

    // Suspended (missing): leftOnly/ has no right mirror — the amber
    // chip names the child and the side it is missing on.
    left.navigate('/left/home/leftOnly');
    await settle();
    expect(workspace.syncBrowsing.suspended, isTrue);
    await capture('sync-suspended-missing');

    // Resumed: stepping the left back to the right's relative path
    // (docs/) satisfies the same-relative-path predicate — the anchors
    // never moved.
    left.navigate('/left/home/docs');
    await settle();
    expect(workspace.syncBrowsing.suspended, isFalse);

    // Suspended (outside): a commit beyond the anchor root shows the
    // other named cause.
    left.navigate('/left');
    await settle();
    expect(workspace.syncBrowsing.suspended, isTrue);
    await capture('sync-suspended-outside');
  });
}
