import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/built_in_text_editor.dart';
import 'package:poltergeist_app/ui/top_toast.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'workspace/built_in_editor_checkout_test.dart';

/// Real-font captures of the built-in editor's two reviewable states
/// (06): the find bar mid-search, and the §3.4 conflict-blocked save —
/// the escalation dialog the editor surfaces when the remote moved
/// under an open checkout. Follows the workspace capture's convention —
/// a real face when the host provides one
/// (POLTERGEIST_CAPTURE_FONT_DIR or the DejaVu fallback), PNGs under
/// tasks/run3-task84/ (or POLTERGEIST_CAPTURE_DIR),
/// POLTERGEIST_CAPTURE=1 gating every write.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task84';

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

ThemeData _captureTheme({Brightness brightness = Brightness.dark}) {
  final base = buildPoltergeistTheme(brightness);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'DejaVu Sans'),
  );
}

Future<void> Function(String name) _capture(WidgetTester tester) {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture.editor')),
  );
  final captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
  final outDir = Directory(_captureDir);
  return (name) async {
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
    // ignore: avoid_print
    print('capture: ${file.absolute.path}');
    file.writeAsBytesSync(bytes);
  };
}

void main() {
  testWidgets('captures the standalone editor window in the light theme', (
    tester,
  ) async {
    await tester.runAsync(_loadRealFonts);
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final separateWindow in [false, true]) {
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture.editor'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _captureTheme(brightness: Brightness.light),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BuiltInTextEditorScreen(
              file: File('/Users/lmathis/Projects/poltergeist/config.yaml'),
              initialText:
                  '# Poltergeist development settings\n'
                  'server:\n  host: staging.example.com\n  port: 22\n\n'
                  'transfers:\n  concurrent: 3\n  verify_checksums: true\n',
              onCloseRequested: separateWindow ? () async {} : null,
              onQuitRequested: separateWindow ? () async {} : null,
              onNewWindowRequested: separateWindow ? () async {} : null,
              showToast: (context, message) =>
                  showTopToastIn(context, message: message),
              monoFontFallback: const ['DejaVu Sans Mono'],
              basenameOf: remoteBasename,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _capture(tester)(
        separateWindow ? 'editor-window-light' : 'editor-route-light',
      );
    }
  });

  testWidgets('captures the find bar mid-search', (tester) async {
    await tester.runAsync(_loadRealFonts);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final file = File(
      '${Directory.systemTemp.createTempSync('pg-editor-cap-').path}'
      '/config.txt',
    );
    addTearDown(() => file.parent.deleteSync(recursive: true));

    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture.editor'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _captureTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BuiltInTextEditorScreen(
            file: file,
            remotePath: '/srv/www/config.txt',
            // initialText skips the disk load — the capture needs the
            // surface, not the I/O.
            initialText:
                'listen_addr = 0.0.0.0\nlog_level = debug\n'
                'debug_port = 8080\nrelease_tag = v1\n',
            showToast: (context, message) =>
                showTopToastIn(context, message: message),
            monoFontFallback: poltergeistMonoFontFamilies,
            basenameOf: remoteBasename,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final capture = _capture(tester);

    await tester.tap(find.byTooltip('Find'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Find in file',
      ),
      'debug',
    );
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
    await capture('editor-find-bar');
  });

  testWidgets('captures the conflict-blocked save dialog', (tester) async {
    EditorCheckoutHarness? harness;
    try {
      // The drive rides real I/O — runAsync owns it. The capture call
      // sits between zones because it enters runAsync itself.
      await tester.runAsync(() async {
        await _loadRealFonts();
        harness = await EditorCheckoutHarness.open();
        await mountEditorShell(
          tester,
          harness!,
          boundaryKey: const ValueKey('capture.editor'),
          theme: _captureTheme(),
        );
        await openEditorViaCommand(tester, harness!);

        // The server moved after the checkout — the save's metadata
        // preflight and the CAS digest both refuse, surfacing the §3.4
        // escalation dialog instead of uploading.
        harness!.fs.seed(
          remoteConfigPath,
          utf8.encode('server rewrite\n'),
          modifiedAt: DateTime.utc(2026, 3, 3),
        );
        await tester.enterText(editorField, 'local edit\n');
        await tester.pump();
        await tester.tap(find.byTooltip('Save and upload'));
        await pollFor(tester, find.text('Remote file changed'));
        await tester.pump(const Duration(milliseconds: 300));
      });

      // The dialog is the captured state; nothing uploaded.
      expect(harness!.fs.uploadCalls, isEmpty);
      await _capture(tester)('editor-conflict-save');

      // Cancel out so the teardown never holds a dirty route.
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await pollFor(tester, find.text('Saved locally; not uploaded.'));
      });
    } finally {
      await tester.runAsync(() async => harness?.close());
    }
  });
}
