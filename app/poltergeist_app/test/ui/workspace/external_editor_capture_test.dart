// Real-font captures of the §4.1/§3.3 external-editor surfaces for
// visual review: the File ▸ Open With ▸ submenu, the chooser dialog,
// the remember-choice prompt, the §8 editor settings dialog, and the
// dirty-checkout upload toast. The widget-test default font renders
// hollow boxes, so the capture loads a real face when the host provides
// one — set POLTERGEIST_CAPTURE_FONT_DIR or rely on the DejaVu
// fallback. The PNGs land in tasks/run3-task85/ at the repo root, and
// only when the run is armed: POLTERGEIST_CAPTURE=1 gates every
// artifact write so an ordinary `flutter test` never dirties the
// checkout; the UI assertions run regardless.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/editor_registry_controller.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/open_with_commands.dart';
import 'package:poltergeist_app/ui/settings/editor_settings.dart';

import 'built_in_editor_checkout_test.dart';
import 'external_editor_checkout_test.dart' as ext;

const _captureDir = '../../tasks/run3-task85';

Future<ByteData> _fontBytes(String path) async =>
    ByteData.view(File(path).readAsBytesSync().buffer);

/// Registers a readable face under the names the theme resolves — the
/// same loader the other capture suites carry.
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
    final monoLoader = FontLoader('DejaVu Sans Mono')
      ..addFont(_fontBytes(mono.path));
    await monoLoader.load();
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

void main() {
  testWidgets(
    'captures the open-with submenu, chooser, remember prompt, '
    'editors settings, and dirty-upload toast',
    (tester) async {
      await tester.runAsync(() async {
        await _loadRealFonts();
        final harness = await EditorCheckoutHarness.open();
        addTearDown(harness.close);
        // The shared helpers in external_editor_checkout_test read that
        // library's harness global — point it at this run's instance.
        ext.harness = harness;
        // The §3.3 prompt's connected gate reads the bookmark-derived
        // connection list — seed it before the shell mounts.
        harness.bookmarks.bookmarks = [ext.serverBookmark()];
        final dir = await Directory.systemTemp.createTemp('pg-ext-cap-');
        addTearDown(() => dir.delete(recursive: true));
        final exe = File(
          p.join(
            dir.path,
            Platform.isWindows ? 'capture-editor.exe' : 'capture-editor',
          ),
        );
        await exe.writeAsString('# capture\n');
        if (!Platform.isWindows) {
          await Process.run('chmod', ['0755', exe.path]);
        }
        final seams = ext.OpenerSeams()..pickedExecutablePath = exe.path;
        final store = SettingsStore(
          path: p.join(dir.path, 'settings.json'),
        );
        final registry = EditorRegistryController(store: store);
        await registry.load();
        final editor = seams.editor(
          displayName: 'Fake Editor',
          acceptedExtensions: ['txt', 'log'],
        );
        await registry.register(editor);

        final base = buildPoltergeistTheme(Brightness.dark);
        final theme = base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
          primaryTextTheme: base.primaryTextTheme.apply(
            fontFamily: 'DejaVu Sans',
          ),
        );
        await mountEditorShell(
          tester,
          harness,
          theme: theme,
          boundaryKey: const ValueKey('capture.shell'),
          editorRegistry: registry,
          externalOpener: seams.opener,
        );
        ext.cursorEntry(tester, 'config.txt');
        await tester.pump();

        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture.shell')),
        );
        final captureEnabled =
            Platform.environment['POLTERGEIST_CAPTURE'] == '1';
        final outDir = Directory(_captureDir);
        if (captureEnabled) outDir.createSync(recursive: true);

        Future<void> capture(String name) async {
          if (!captureEnabled) return;
          final image = await boundary.toImage(pixelRatio: 2);
          try {
            final data = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            File(
              '${outDir.path}/$name.png',
            ).writeAsBytesSync(data!.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        }

        // Advances a route's entrance transition to completion — the
        // animation ticker reads frame timestamps off the FAKE clock
        // even inside runAsync, so real delays never move it. One pump
        // with an elapsed duration lands it at opacity 1.
        Future<void> settleDialog() =>
            tester.pump(const Duration(milliseconds: 600));

        BuildContext shellContext() =>
            tester.element(find.byType(Scaffold).first);
        final l10n = AppLocalizations.of(shellContext());
        // §4.2's Open With ▸ submenu rows inside the File menu — the
        // MenuBar backend only (macOS serializes to the native menu).
        if (find.byType(MenuBar).evaluate().isNotEmpty) {
          await tester.tap(find.text(l10n.menuFile));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(
            find.descendant(
              of: find.byKey(const ValueKey('menu.file')),
              matching: find.text(l10n.fileOpenWithLabel),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.widgetWithText(MenuItemButton, l10n.openWithOtherLabel),
            findsOneWidget,
          );
          await capture('open-with-submenu');
          await tester.tapAt(Offset.zero);
          await tester.pump(const Duration(milliseconds: 300));
        }

        // §4.2's chooser — the dialog rendering of the same rows
        // (built-in, the compatible configured editor, system default,
        // Other…).
        unawaited(
          showOpenWithChooser(
            shellContext(),
            registry: registry.registry,
            path: '/srv/www/config.txt',
          ),
        );
        await ext.pollUntil(
          tester,
          () => find.byType(SimpleDialog).evaluate().isNotEmpty,
        );
        expect(find.text(l10n.openWithBuiltInLabel), findsOneWidget);
        expect(find.text('Fake Editor'), findsOneWidget);
        expect(find.text(l10n.openWithSystemDefaultLabel), findsOneWidget);
        expect(find.text(l10n.openWithOtherLabel), findsOneWidget);
        // Let the route's entrance fade finish — the element mounts
        // at opacity 0, so an early capture reads as the bare shell.
        await settleDialog();
        await capture('open-with-chooser');
        // Pop the route, then elapse its exit transition on the fake
        // clock: one pump starts the ticker, the next lets it finish.
        Navigator.of(shellContext()).pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await ext.pollUntil(
          tester,
          () => find.byType(SimpleDialog).evaluate().isEmpty,
        );

        // §4.1's remember-choice prompt after an Other… pick.
        unawaited(
          showRememberEditorChoice(
            shellContext(),
            name: 'config.txt',
            editor: 'Fake Editor',
            extension: 'txt',
          ),
        );
        await ext.pollUntil(
          tester,
          () =>
              find
                  .byKey(const ValueKey('openWith.confirm'))
                  .evaluate()
                  .isNotEmpty,
        );
        expect(
          find.textContaining('Always use Fake Editor for .txt files'),
          findsOneWidget,
        );
        await settleDialog();
        await capture('open-with-remember');
        await tester.tap(
          find.widgetWithText(TextButton, l10n.openWithCancel),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // §8's bounded mount — the Configure Editors… destination.
        unawaited(
          showEditorsSettingsDialog(
            shellContext(),
            controller: registry,
            opener: seams.opener,
          ),
        );
        await ext.pollUntil(
          tester,
          () =>
              find
                  .byKey(const ValueKey('editors.settings.dialog'))
                  .evaluate()
                  .isNotEmpty,
        );
        expect(find.text('Fake Editor'), findsOneWidget);
        expect(find.text('*.txt'), findsOneWidget);
        expect(find.text(l10n.editorAddLabel), findsOneWidget);
        await settleDialog();
        await capture('editors-settings');
        await tester.tap(
          find.byKey(const ValueKey('editors.settings.close')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // §3.3's dirty prompt — the real watch → debounce → reconcile
        // chain, captured with the Upload action armed.
        await registry.setDefault(editor.id);
        final pane = leftPane(tester);
        unawaited(pane.openEntry(ext.cursorEntry(tester, 'config.txt')));
        final record = await ext.checkoutOf(tester, remoteConfigPath);
        await ext.pollUntil(tester, () => seams.launches.isNotEmpty);
        await harness.checkout
            .localFile(record)
            .writeAsString('capture edit\n');
        await ext.pollForDirtyPrompt(tester, 'config.txt');
        await tester.pump(const Duration(milliseconds: 300));
        await capture('dirty-upload-toast');
        expect(find.widgetWithText(TextButton, 'Upload'), findsWidgets);
      });
    },
  );
}
