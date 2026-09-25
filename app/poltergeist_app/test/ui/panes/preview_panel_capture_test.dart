// Real-font captures of the 06 §5 preview surfaces for visual review:
// the docked panel's prompt / confirm / producing / gate / rendered /
// refusal cards, the macOS Quick Look overlay card, and the §8
// "Preview & downloads" settings section. The widget-test default font
// renders hollow boxes, so the capture loads a real face when the host
// provides one — set POLTERGEIST_CAPTURE_FONT_DIR or rely on the DejaVu
// fallback. The PNGs land in tasks/run3-task86/ at the repo root, and
// only when the run is armed: POLTERGEIST_CAPTURE=1 gates every
// artifact write so an ordinary `flutter test` never dirties the
// checkout; the UI assertions run regardless.
//
// Ordering matters for the fonts: registration only lands for
// paragraphs laid out AFTER the loading runAsync returns, so fonts load
// in a standalone runAsync, all pumpWidget/pump calls run in the fake
// zone, and toImage runs in a fresh runAsync — the same recipe the
// other capture suites carry.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/editor_registry_controller.dart';
import 'package:poltergeist_app/services/preview_session.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/settings/editor_settings.dart';
import 'package:poltergeist_app/ui/preview_panel.dart';
import 'package:poltergeist_app/ui/settings/preview_settings.dart';

import '../../support/preview_harness.dart';

// Resolves against the invocation CWD — lands at the repo root when
// `flutter test` runs from app/poltergeist_app; POLTERGEIST_CAPTURE_DIR
// overrides it for other roots.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task86';

Future<ByteData> _fontBytes(String path) async =>
    ByteData.view(File(path).readAsBytesSync().buffer);

/// Registers a readable face under the names the theme resolves — the
/// same loader the other capture suites carry, plus a 'JetBrains Mono'
/// alias: the code row's primary family, since the test engine does not
/// apply fontFamilyFallback to dynamically registered faces.
Future<void> _loadRealFonts() async {
  final dir =
      Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
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
    final monoBytes = _fontBytes(mono.path);
    await (FontLoader('DejaVu Sans Mono')..addFont(monoBytes)).load();
    await (FontLoader('JetBrains Mono')..addFont(monoBytes)).load();
  }
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

/// A valid 1x1 PNG (transparent) — small enough for the §5.2 image row.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

void main() {
  late bool captureEnabled;
  late Directory outDir;
  late RenderRepaintBoundary boundary;

  // toImage needs the real event loop; run in the fake zone it wedges
  // the next runAsync.
  Future<void> capture(WidgetTester tester, String name) async {
    if (!captureEnabled) return;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${outDir.path}/$name.png',
        ).writeAsBytesSync(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  Widget app(Widget child) {
    final base = buildPoltergeistTheme(Brightness.dark);
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme: base.primaryTextTheme.apply(
        fontFamily: 'DejaVu Sans',
      ),
    );
    return MaterialApp(
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('capture.preview'),
          child: SizedBox(
            width: 420,
            height: 620,
            child: child,
          ),
        ),
      ),
    );
  }

  Future<void> pumpPanel(
    WidgetTester tester,
    PreviewSession session, {
    PreviewPdfBuilder? pdfRenderer,
  }) async {
    tester.view.physicalSize = const Size(480, 660);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        PreviewPanel(
          session: session,
          pdfRenderer: pdfRenderer,
          onOpen: (_, _) {},
          onOpenWith: (_, _, _) {},
          onOpenInEditor: (_, _) {},
          onClose: session.closePanel,
          onEscape: (event) => session.escape()
              ? KeyEventResult.handled
              : KeyEventResult.ignored,
        ),
      ),
    );
    boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.preview')),
    );
  }

  testWidgets('captures every docked-panel card and the QL overlay', (
    tester,
  ) async {
    captureEnabled = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
    // toImage needs the real event loop; the fake zone wedges the next
    // runAsync. Session verbs need it too — cache.prepare/commit shell
    // out to chmod, whose zero-duration timer never fires under
    // FakeAsync. Widget mounts and pumps stay in the fake zone so text
    // lays out after font registration lands.
    late PreviewHarness h;
    Future<void> act(Future<void> Function() body) => tester.runAsync(body);

    await tester.runAsync(() async {
      await _loadRealFonts();
      h = await PreviewHarness.create(thresholdBytes: 4096);
      await h.connectRemote([
        previewEntry('notes.txt', size: 4),
        previewEntry('big-notes.txt', size: 6000),
        previewEntry('stream.txt'),
        previewEntry('huge.txt', size: 8 << 20),
        previewEntry('photo.png', size: 67),
        previewEntry('report.pdf', size: 3000),
      ]);
    });
    outDir = Directory(_captureDir);
    if (captureEnabled) outDir.createSync(recursive: true);
    await pumpPanel(tester, h.session);

    // 01 — the §5.3 prompt: selection alone never downloads.
    await act(() async {
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.prompt);
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('preview.download')), findsOneWidget);
    await capture(tester, '01-prompt');

    // 02 — in-flight production with partial progress (notes.txt at
    // index 2: the pane sorts entries by name).
    await act(() async {
      h.left.setCursorIndex(2);
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      h.producer.progress(0, 2, 4);
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('preview.progress')), findsOneWidget);
    await capture(tester, '02-producing');

    // 03 — rendered text (syntax-highlighted window).
    await act(() async {
      await h.producer.complete(
        0,
        utf8.encode('import "seance";\n\nvoid main() {\n  run();\n}\n'),
      );
      await untilPhase(h.session, PreviewPhase.rendered);
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('preview.text')), findsOneWidget);
    await capture(tester, '03-rendered-text');

    // 04 — the §8 up-front confirmation on a known over-threshold size
    // (big-notes.txt at index 0).
    await act(() async {
      h.left.setCursorIndex(0);
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.confirm);
    });
    await tester.pump();
    expect(
      find.byKey(const ValueKey('preview.confirm.download')),
      findsOneWidget,
    );
    await capture(tester, '04-confirm');

    // 05 — the unknown-size gate parked at the threshold (stream.txt at
    // index 5).
    await act(() async {
      h.left.setCursorIndex(5);
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      h.producer.specs.last.gate!
          .wrap(const NullByteSink())
          .add(List.filled(5000, 0));
      await untilPhase(h.session, PreviewPhase.gateConfirm);
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('preview.gate.keep')), findsOneWidget);
    await capture(tester, '05-gate-confirm');

    // 06 — the §5.3 refusal card (over the cache cap) with the Open /
    // Open With affordances (huge.txt at index 1).
    await act(() async {
      h.left.setCursorIndex(1);
      await untilPhase(h.session, PreviewPhase.rendered);
    });
    await tester.pump();
    expect(h.session.refusal, PreviewRefusal.overCacheCap);
    expect(find.byKey(const ValueKey('preview.open')), findsOneWidget);
    await capture(tester, '06-refusal-over-cap');

    // 07 — a rendered image with its dimensions caption (photo.png at
    // index 3).
    await act(() async {
      h.left.setCursorIndex(3);
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await h.producer.complete(
        h.producer.specs.length - 1,
        _pngBytes,
      );
      await untilPhase(h.session, PreviewPhase.rendered);
    });
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('preview.image')), findsOneWidget);
    await capture(tester, '07-rendered-image');

    // 08 — the PDF row through the §5.2 builder seam (a stub renderer
    // stands in for pdfrx — the rasterizer only ships where supported;
    // report.pdf sits at index 4).
    await act(() async {
      h.left.setCursorIndex(4);
      await untilPhase(h.session, PreviewPhase.prompt);
      h.session.previewFocused();
      await untilPhase(h.session, PreviewPhase.producing);
      await h.producer.complete(
        h.producer.specs.length - 1,
        utf8.encode('%PDF-1.4 stub\n'),
      );
      await untilPhase(h.session, PreviewPhase.rendered);
    });
    await pumpPanel(
      tester,
      h.session,
      pdfRenderer: (context, file, {onOpenExternal}) => Center(
        child: Text(
          'PDF preview (pdfrx surface)',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
    await tester.pump();
    await capture(tester, '08-rendered-pdf-stub');
  });

  testWidgets('captures the Quick Look overlay card and settings', (
    tester,
  ) async {
    captureEnabled = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
    late PreviewHarness h;
    Future<void> act(Future<void> Function() body) => tester.runAsync(body);

    await tester.runAsync(() async {
      await _loadRealFonts();
      h = await PreviewHarness.create(
        platform: TargetPlatform.macOS,
        quickLookAvailable: true,
      );
      await h.connectRemote([previewEntry('photo.png', size: 10)]);
    });
    outDir = Directory(_captureDir);
    if (captureEnabled) outDir.createSync(recursive: true);

    // 09 — the §5.1 overlay card: progress/confirm render in-window
    // because the native panel cannot host Flutter content.
    await act(() async {
      h.session.previewFocused();
      await untilTrue(
        () => h.session.quickLookCard == QuickLookCardKind.producing,
      );
    });
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        SizedBox.expand(
          child: Stack(
            children: [PreviewQuickLookOverlay(session: h.session)],
          ),
        ),
      ),
    );
    boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.preview')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('preview.quickLookCard')),
      findsOneWidget,
    );
    await capture(tester, '09-quicklook-overlay');
  });

  testWidgets('captures the preview/download settings section', (
    tester,
  ) async {
    captureEnabled = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
    late PreviewHarness h;
    await tester.runAsync(() async {
      await _loadRealFonts();
      h = await PreviewHarness.create();
    });
    outDir = Directory(_captureDir);
    if (captureEnabled) outDir.createSync(recursive: true);

    // 10 — the §8 "Preview & downloads" section through the real
    // Editing-settings dialog: the route's entrance transition re-lays
    // out its paragraphs, which is what lands the registered faces —
    // a cold static mount of the section keeps the test-font boxes.
    // The boundary wraps the whole app so the dialog's overlay is
    // inside it.
    late EditorRegistryController registry;
    await tester.runAsync(() async {
      registry = EditorRegistryController(
        store: SettingsStore(
          path: '${h.tempDir.path}/capture-settings.json',
        ),
      );
      await registry.load();
    });
    addTearDown(registry.dispose);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture.preview.shell'),
        child: app(const SizedBox.expand()),
      ),
    );
    boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.preview.shell')),
    );
    unawaited(
      showEditorsSettingsDialog(
        tester.element(find.byType(Scaffold)),
        controller: registry,
        previewSettings: PreviewDownloadsSettings(
          available: true,
          capacityBytes: 512 << 20,
          thresholdBytes: 100 << 20,
          onCapacityChanged: (_) async {},
          onThresholdChanged: (_) async {},
          onClearCache: () async => 0,
        ),
      ),
    );
    await tester.pump();
    // The entrance transition reads the fake clock; one elapsed pump
    // lands it at opacity 1.
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      find.byKey(const ValueKey('preview.cacheLimitField')),
      findsOneWidget,
    );
    await capture(tester, '10-settings-preview-downloads');
  });
}
