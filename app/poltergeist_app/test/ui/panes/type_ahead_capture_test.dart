import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

/// Real-font captures of the type-ahead badge (02 §2.5) for visual
/// review. The widget-test default font renders hollow boxes, so the
/// capture loads a real face when the host provides one — set
/// POLTERGEIST_CAPTURE_FONT_DIR or rely on the DejaVu fallback. The PNGs
/// land in tasks/run3-task32/ at the repo root, and only when the run
/// is armed: POLTERGEIST_CAPTURE=1 gates every artifact write so an
/// ordinary `flutter test` never dirties the checkout; the UI
/// assertions run regardless.
const _captureDir = '../../tasks/run3-task32';

Future<ByteData> _fontBytes(String path) async =>
    ByteData.view(File(path).readAsBytesSync().buffer);

/// Registers a readable face under the names the theme resolves: the
/// default family name for body text plus the mono fallback chain the
/// row metrics style reaches for.
Future<void> _loadRealFonts() async {
  final dir = Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      '${Platform.environment['HOME']}/.local/share/fonts';
  final sans = File('$dir/DejaVuSans.ttf');
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  final mono = File('$dir/DejaVuSansMono.ttf');
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
  // Kind glyphs are MaterialIcons codepoints: without the icon font they
  // rasterize as tofu boxes. It ships inside the Flutter SDK.
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final iconsLoader = FontLoader('MaterialIcons')
      ..addFont(_fontBytes(icons.path));
    await iconsLoader.load();
  }
}

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
  DateTime? modified,
}) {
  return RemoteFileEntry(
    path: '/home/tester/$name',
    name: name,
    type: type,
    size: size,
    modifiedAt: modified,
  );
}

void main() {
  testWidgets('captures the type-ahead badge pending and after reset', (
    tester,
  ) async {
    await tester.runAsync(_loadRealFonts);

    final lanes = controller_test.FakePaneLanes();
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('docs', type: RemoteFileType.directory),
      _entry('notes.txt', size: 640),
      _entry('photo-01.png', size: 40240),
      _entry('photo-02.png', size: 38192),
      _entry('report.txt', size: 2048),
      _entry('résumé.pdf', size: 90112),
      _entry('todo.txt', size: 128),
    ];
    lanes.nextLocalChannel = channel;

    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final leftStrip = testPaneStrip(left);
    final rightStrip = testPaneStrip(right);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);
    final leftNode = FocusNode();
    final rightNode = FocusNode();
    addTearDown(leftNode.dispose);
    addTearDown(rightNode.dispose);

    await left.openLocalHome();

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
          body: Row(
            children: [
              Expanded(
                child: RepaintBoundary(
                  key: const ValueKey('capture.pane'),
                  child: PaneView(
                    controller: left,
                    pane: leftStrip,
                    workspace: workspace,
                    focusNode: leftNode,
                    onSwapFocus: () => rightNode.requestFocus(),
                    onCancelRecovery: () {},
                  ),
                ),
              ),
              Expanded(
                child: PaneView(
                  controller: right,
                  pane: rightStrip,
                  workspace: workspace,
                  focusNode: rightNode,
                  onSwapFocus: () => leftNode.requestFocus(),
                  onCancelRecovery: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    leftNode.requestFocus();
    await tester.pump();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.pane')),
    );
    final captureEnabled =
        Platform.environment['POLTERGEIST_CAPTURE'] == '1';
    final outDir = Directory(_captureDir);
    if (captureEnabled) outDir.createSync(recursive: true);

    Future<void> capture(String name) async {
      if (!captureEnabled) return;
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
      File('${outDir.path}/$name.png').writeAsBytesSync(bytes);
    }

    // Idle baseline — no badge.
    await capture('type-ahead-idle');

    // A pending buffer: the badge floats over the listing showing the
    // accumulated prefix while the cursor row highlights its match.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();
    expect(left.typeAheadBuffer, 're');
    expect(find.byKey(const ValueKey('pane.typeAhead')), findsOneWidget);
    await capture('type-ahead-badge-pending');

    // The reset clears both: badge unmounts, the jumped cursor stays.
    await tester.pump(const Duration(seconds: 2));
    expect(left.typeAheadActive, isFalse);
    expect(find.byKey(const ValueKey('pane.typeAhead')), findsNothing);
    await capture('type-ahead-after-reset');
  });
}
