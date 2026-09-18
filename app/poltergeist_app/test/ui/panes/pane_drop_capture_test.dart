import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_drop.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_app_transfer_queue.dart';
import '../../support/test_panes.dart';

/// Real-font captures of 02 §5.1's drag-and-drop affordances (D14): the
/// in-app drag avatar with its verb badge, the destination zone's
/// border and action pill, the folder-row hover highlight, and the OS
/// drop-in's copy label. The widget-test default font renders hollow
/// boxes, so the capture loads a real face when the host provides one —
/// set POLTERGEIST_CAPTURE_FONT_DIR or rely on the DejaVu fallback. PNGs
/// land in tasks/run3-task70/captures/ at the repo root (or
/// POLTERGEIST_CAPTURE_DIR when set), and POLTERGEIST_CAPTURE=1 gates
/// every artifact write so an ordinary suite run produces no files.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task70/captures';

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

RemoteFileEntry _entryAt(
  String dir,
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
}) {
  return RemoteFileEntry(
    path: '$dir/$name',
    name: name,
    type: type,
    size: size,
    modifiedAt: DateTime(2026, 9, 10, 12),
  );
}

/// Drives one platform→Dart `desktop_drop` channel message — the same
/// route a real OS drag takes.
Future<void> _osChannel(
  WidgetTester tester,
  String method,
  Object? arguments,
) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'desktop_drop',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );
  await tester.pump();
}

void main() {
  testWidgets('captures the drop affordances', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    if (Platform.environment['POLTERGEIST_CAPTURE'] == '1') {
      await tester.runAsync(_loadRealFonts);
    }

    final lanes = controller_test.FakePaneLanes();
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final leftStrip = testPaneStrip(left);
    final rightStrip = testPaneStrip(right);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    final queue = FakeAppTransferQueue();
    final delegate = PaneDropDelegate(queue: queue);

    // Cleanup must run even when an assertion fails — and the platform
    // override must reset inside the test BODY: the debug-variable
    // invariant runs before addTearDown callbacks, so a tearDown reset
    // would trip it. try/finally covers both.
    try {
      final leftChannel = controller_test.FakePaneChannel('/home/tester');
      leftChannel.listings['/home/tester'] = [
        _entryAt('/home/tester', 'docs', type: RemoteFileType.directory),
        _entryAt('/home/tester', 'report.txt', size: 2048),
        _entryAt('/home/tester', 'link', type: RemoteFileType.symbolicLink),
        _entryAt('/home/tester', 'photo.png', size: 812345),
      ];
      lanes.nextLocalChannel = leftChannel;
      await left.openLocalHome();

      final rightChannel = controller_test.FakePaneChannel('/home/tester');
      rightChannel.listings['/srv/other'] = [
        _entryAt('/srv/other', 'images', type: RemoteFileType.directory),
        _entryAt('/srv/other', 'archive', type: RemoteFileType.directory),
        _entryAt('/srv/other', 'index.html', size: 512),
        _entryAt('/srv/other', 'notes.txt', size: 128),
      ];
      lanes.nextLocalChannel = rightChannel;
      await right.openLocalAt('/srv/other');

      tester.view.physicalSize = const Size(1400, 900);
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
        RepaintBoundary(
          key: const ValueKey('capture.shell'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Row(
                children: [
                  Expanded(
                    child: PaneView(
                      controller: left,
                      pane: leftStrip,
                      workspace: workspace,
                      focusNode: FocusNode(),
                      onSwapFocus: () {},
                      onCancelRecovery: () {},
                      dropDelegate: delegate,
                      clock: () => DateTime(2026, 9, 15, 10),
                    ),
                  ),
                  Expanded(
                    child: PaneView(
                      controller: right,
                      pane: rightStrip,
                      workspace: workspace,
                      focusNode: FocusNode(),
                      onSwapFocus: () {},
                      onCancelRecovery: () {},
                      dropDelegate: delegate,
                      clock: () => DateTime(2026, 9, 15, 10),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

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
        // The default dir is relative to the test runner's CWD; print
        // where the PNG actually landed so a run launched from another
        // directory is obvious instead of silently writing elsewhere.
        // ignore: avoid_print
        print('capture: ${file.absolute.path}');
        file.writeAsBytesSync(bytes);
      }

      final rightRect = tester.getRect(find.byType(PaneView).last);
      final rightBackground = Offset(
        rightRect.center.dx,
        rightRect.bottom - 60,
      );

      // 1. Idle baseline — no affordances without a drag.
      await capture('dnd-idle');

      // 2. In-app drag over the other pane's background: zone border,
      //    "Move to" action pill, stacked-icon avatar (same filesystem →
      //    move, no `+` badge).
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('report.txt')),
      );
      await tester.pump();
      await gesture.moveTo(rightBackground);
      await tester.pump();
      expect(find.text('Move to /srv/other'), findsOneWidget);
      await capture('dnd-hover-move-current-dir');

      // 3. Hover the 'images' folder row: the row highlights and the
      //    pill names the folder destination.
      await gesture.moveTo(tester.getCenter(find.text('images')));
      await tester.pump();
      expect(find.text('Move to /srv/other/images'), findsOneWidget);
      await capture('dnd-hover-move-folder-row');

      // 4. Ctrl held mid-drag: the verb flips to copy, the avatar grows
      //    the `+` badge.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.text('Copy to /srv/other/images'), findsOneWidget);
      await capture('dnd-hover-copy-modifier');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      // The completed drop: the overlay clears and the queue recorded
      // the move — report.txt onto the 'images' folder row.
      expect(find.text('Move to /srv/other/images'), findsNothing);
      expect(queue.enqueuedSpecs, hasLength(1));
      final spec = queue.enqueuedSpecs.single;
      expect(spec.operation, TransferOperation.move);
      expect(spec.rootPaths, ['/home/tester/report.txt']);
      expect(spec.destinationDir, '/srv/other/images');

      // 5. OS drop-in hover: always a copy (D14), same overlay.
      await _osChannel(tester, 'entered', [
        rightBackground.dx,
        rightBackground.dy,
      ]);
      expect(find.text('Copy to /srv/other'), findsOneWidget);
      await capture('dnd-os-drop-hover');
      await _osChannel(tester, 'exited', null);
    } finally {
      workspace.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
