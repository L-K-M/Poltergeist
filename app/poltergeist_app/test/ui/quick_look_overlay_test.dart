import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/in_app_quick_look.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/preview_panel.dart' show PreviewPdfBuilder;
import 'package:poltergeist_app/ui/quick_look_overlay.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show previewImageKindCapBytes, previewPdfKindCapBytes;

import '../support/preview_harness.dart';

/// D32's Quick Look on Linux and Windows: the in-app surface Space
/// opens for the focused item (the macOS native panel's stand-in), and
/// the overlay that renders it without ever taking the keyboard.
void main() {
  group('InAppQuickLook', () {
    test('shows, follows, hides; only the user close reports an edge',
        () async {
      final quickLook = InAppQuickLook();
      addTearDown(quickLook.dispose);
      var closes = 0;
      final sub = quickLook.onClosed.listen((_) => closes++);
      addTearDown(sub.cancel);

      expect(await quickLook.isAvailable(), isTrue);
      await quickLook.updatePreview(['/a'], 0);
      expect(quickLook.visible, isFalse, reason: 'update never opens');

      await quickLook.showPreview(['/a', '/b'], 1);
      expect(quickLook.currentPath, '/b');
      await quickLook.updatePreview(['/c'], 0);
      expect(quickLook.currentPath, '/c');

      await quickLook.hidePreview();
      expect(quickLook.visible, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(closes, 0);

      await quickLook.showPreview(['/a'], 0);
      quickLook.close();
      expect(quickLook.visible, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(closes, 1);
    });

    test('drives the session: Space opens, the overlay\'s own close '
        'clears the session\'s Quick Look state', () async {
      final quickLook = InAppQuickLook();
      addTearDown(quickLook.dispose);
      final h = await PreviewHarness.create(
        quickLook: quickLook,
        infoTabShown: true,
      );
      File('${h.tempDir.path}/notes.txt').writeAsStringSync('hi\n');
      await h.connectLocal(h.tempDir, [
        previewEntry('notes.txt', size: 3, parent: h.tempDir.path),
      ]);

      h.session.previewFocused();
      await untilTrue(() => h.session.quickLookActive);
      expect(quickLook.currentPath, endsWith('notes.txt'));
      expect(h.session.quickLookNameFor(quickLook.currentPath!), 'notes.txt');
      expect(h.workspace.inspectorHidden, isFalse);

      quickLook.close();
      await untilTrue(() => !h.session.quickLookActive);
      expect(h.workspace.inspectorHidden, isFalse);
    });
  });

  group('QuickLookOverlay', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('quick_look_overlay');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<InAppQuickLook> pumpOverlay(
      WidgetTester tester, {
      PreviewPdfBuilder? pdfRenderer,
    }) async {
      final quickLook = InAppQuickLook();
      addTearDown(quickLook.dispose);
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPoltergeistTheme(
            Brightness.light,
            platform: TargetPlatform.linux,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.white),
                QuickLookOverlay(
                  controller: quickLook,
                  nameFor: (path) => path.split('/').last,
                  pdfRenderer: pdfRenderer,
                ),
              ],
            ),
          ),
        ),
      );
      return quickLook;
    }

    /// The body's type check and text read are real file I/O, each hop
    /// completing on the real loop and resuming on the next pump.
    Future<void> settleBody(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    testWidgets('renders the shown text file large, with its position',
        (tester) async {
      File('${dir.path}/a.txt').writeAsStringSync('alpha body\n');
      File('${dir.path}/b.txt').writeAsStringSync('bravo\n');
      final quickLook = await pumpOverlay(tester);
      expect(find.byKey(const ValueKey('quickLook.overlay')), findsNothing);

      await tester.runAsync(
        () => quickLook.showPreview(['${dir.path}/a.txt', '${dir.path}/b.txt'], 0),
      );
      await tester.pump();
      await settleBody(tester);

      expect(find.byKey(const ValueKey('quickLook.overlay')), findsOneWidget);
      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('1 of 2'), findsOneWidget);
      expect(find.textContaining('alpha body'), findsOneWidget);
      // A large surface, not a card.
      final size = tester.getSize(
        find.byKey(const ValueKey('quickLook.overlay')),
      );
      expect(size.width, greaterThan(800));
      expect(size.height, greaterThan(500));

      // The selection follows: the next item replaces the body.
      await tester.runAsync(
        () => quickLook.updatePreview(['${dir.path}/b.txt'], 0),
      );
      await tester.pump();
      await settleBody(tester);
      expect(find.text('b.txt'), findsOneWidget);
      expect(find.textContaining('bravo'), findsOneWidget);
      expect(find.text('1 of 2'), findsNothing);
    });

    testWidgets('a folder or an unreadable kind gets the no-preview card',
        (tester) async {
      Directory('${dir.path}/photos').createSync();
      final quickLook = await pumpOverlay(tester);
      await tester.runAsync(
        () => quickLook.showPreview(['${dir.path}/photos'], 0),
      );
      await tester.pump();
      await settleBody(tester);
      expect(find.byKey(const ValueKey('quickLook.noPreview')), findsOneWidget);
      // The body's large glyph and the title bar's both say folder.
      expect(find.byIcon(Icons.folder), findsNWidgets(2));
    });

    testWidgets('an image or PDF over the Info well\'s decode cap is '
        'refused, never decoded', (tester) async {
      // Sparse files: past the 64 MiB cap without writing the bytes.
      for (final (name, cap) in [
        ('huge.png', previewImageKindCapBytes),
        ('huge.pdf', previewPdfKindCapBytes),
      ]) {
        File('${dir.path}/$name').openSync(mode: FileMode.write)
          ..truncateSync(cap + 1)
          ..closeSync();
      }
      final rendered = <String>[];
      final quickLook = await pumpOverlay(
        tester,
        pdfRenderer: (context, file, {onOpenExternal}) {
          rendered.add(file.path);
          return const SizedBox.shrink();
        },
      );

      for (final name in ['huge.png', 'huge.pdf']) {
        await tester.runAsync(
          () => quickLook.showPreview(['${dir.path}/$name'], 0),
        );
        await tester.pump();
        await settleBody(tester);
        expect(find.byKey(const ValueKey('quickLook.image')), findsNothing);
        expect(
          find.text('This file is too large to preview.'),
          findsOneWidget,
          reason: name,
        );
      }
      expect(rendered, isEmpty);
    });

    testWidgets('the close button, Esc and Space inside it close it', (
      tester,
    ) async {
      File('${dir.path}/a.txt').writeAsStringSync('alpha\n');
      final quickLook = await pumpOverlay(tester);
      final closes = <void>[];
      final sub = quickLook.onClosed.listen(closes.add);
      addTearDown(sub.cancel);
      Future<void> open() async {
        await tester.runAsync(
          () => quickLook.showPreview(['${dir.path}/a.txt'], 0),
        );
        await tester.pump();
        await settleBody(tester);
      }

      await open();
      await tester.tap(find.byKey(const ValueKey('quickLook.close')));
      await tester.pump();
      expect(find.byKey(const ValueKey('quickLook.overlay')), findsNothing);

      for (final key in [LogicalKeyboardKey.escape, LogicalKeyboardKey.space]) {
        await open();
        // A click on the close button focuses it inside the panel.
        Focus.of(
          tester.element(
            find.descendant(
              of: find.byKey(const ValueKey('quickLook.close')),
              matching: find.byType(Icon),
            ),
          ),
        ).requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(key);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('quickLook.overlay')),
          findsNothing,
          reason: key.keyLabel,
        );
      }
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(closes, hasLength(3));
    });
  });
}
