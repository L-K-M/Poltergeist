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

/// Real-font captures of the editable path field and its invalid-input
/// error state (02 §2.1) for visual review. The widget-test default
/// font renders hollow boxes, so the capture loads a real face when the
/// host provides one — set POLTERGEIST_CAPTURE_FONT_DIR or rely on the
/// DejaVu fallback. The PNGs land in tasks/run3-task42/ at the repo
/// root (or POLTERGEIST_CAPTURE_DIR when set), and POLTERGEIST_CAPTURE=1
/// gates every artifact write so an ordinary suite run produces no
/// files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task42';

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
  testWidgets('captures the path field editing and error states',
      (tester) async {
    // Real faces matter only when artifacts are written; an ordinary
    // suite run skips the file IO entirely.
    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      await tester.runAsync(_loadRealFonts);
    }

    final lanes = controller_test.FakePaneLanes();
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('docs', type: RemoteFileType.directory),
      _entry('notes.txt', size: 640),
      _entry('photo-01.png', size: 40240),
      _entry('report.txt', size: 2048),
    ];
    channel.listings['/home/tester/docs'] = [
      _entry('inner.txt', size: 12),
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

    final field = find.byKey(const ValueKey('pane.left.path.field'));

    // Segment-bar baseline.
    await capture('pathbar-closed');

    // go.editPath: the bar becomes a field seeded with the current
    // path, selected whole (02 §2.1).
    left.editPath();
    await tester.pump();
    await tester.pump();
    expect(left.pathFieldOpen, isTrue);
    await capture('pathbar-editing');

    // An unresolvable submission closes the field and surfaces the
    // pane's inline error affordance — no dialog.
    await tester.enterText(field, '~root/docs');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(left.pathFieldOpen, isFalse);
    expect(left.error, isA<PaneFaultException>());
    expect(
      (left.error as PaneFaultException).fault,
      PaneFault.invalidPath,
    );
    await capture('pathbar-invalid');

    // go.toFolder on a healthy pane: the same field, seeded empty.
    // Clear the error first — Esc on the focused listing retries it.
    leftNode.requestFocus();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(left.error, isNull);
    left.goToFolder();
    await tester.pump();
    await tester.pump();
    expect(
      tester.widget<TextField>(field).controller!.text,
      isEmpty,
    );
    await capture('pathbar-tofolder');
  });
}
