// Ported from Séance
// app/seance_app/test/built_in_text_editor_test.dart @ 2e6d1f1; see
// docs/PORTS.md. Adaptations: the document I/O lives in
// poltergeist_core, every screen carries the §2.3 seams (showToast,
// monoFontFallback, basenameOf), saveDocument returns the new baseline
// digest, and user copy resolves through AppLocalizations. Plus the
// §2.5 production-path tests the Séance suite lacks: real
// saveBuiltInTextDocument saves with BOM/CRLF round-trip, the
// modified-on-disk conflict, and the 0600 temp window.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/built_in_text_editor.dart';
import 'package:poltergeist_app/ui/editor_syntax.dart';
import 'package:poltergeist_app/ui/top_toast.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'poltergeist-editor-test-',
    );
    file = File('${directory.path}/config.txt');
    await file.writeAsString('one\ntwo\n');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  /// The §2.3 seam values every pumped screen carries — production wires
  /// showTopToastIn, the app mono stack, and a path-aware basename.
  Widget editorApp({
    String? remotePath,
    String? initialText,
    Future<String> Function(File, String)? saveDocument,
    Future<void> Function()? onSaved,
    Future<bool> Function()? onUpload,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: BuiltInTextEditorScreen(
      file: file,
      remotePath: remotePath,
      initialText: initialText,
      saveDocument: saveDocument,
      onSaved: onSaved,
      onUpload: onUpload,
      showToast: (context, message) =>
          showTopToastIn(context, message: message),
      monoFontFallback: const ['monospace'],
      basenameOf: remoteBasename,
    ),
  );

  testWidgets('edits, saves, and reports the local save', (tester) async {
    var saved = 0;
    String? savedText;
    await tester.pumpWidget(
      editorApp(
        remotePath: '/etc/config.txt',
        initialText: 'one\ntwo\n',
        saveDocument: (_, text) async {
          savedText = text;
          return 'baseline';
        },
        onSaved: () async => saved++,
      ),
    );
    await tester.pump();

    expect(find.text('one\ntwo\n'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'edited locally\n');
    await tester.pump();
    await tester.tap(find.byTooltip('Save locally'));
    await tester.pumpAndSettle();

    expect(savedText, 'edited locally\n');
    expect(saved, 1);
    expect(find.textContaining('Saved locally'), findsOneWidget);
  });

  testWidgets('protects unsaved changes when leaving', (tester) async {
    await tester.pumpWidget(
      editorApp(remotePath: '/etc/config.txt', initialText: 'one\ntwo\n'),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'unsaved');
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    expect(find.text('unsaved'), findsOneWidget);
  });

  Future<void> pressCtrlS(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  testWidgets('Ctrl-S saves and uploads a server file immediately', (
    tester,
  ) async {
    var uploads = 0;
    var saved = 0;
    String? savedText;
    await tester.pumpWidget(
      editorApp(
        remotePath: '/etc/config.txt',
        initialText: 'one\ntwo\n',
        saveDocument: (_, text) async {
          savedText = text;
          return 'baseline';
        },
        onSaved: () async => saved++,
        onUpload: () async {
          uploads++;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await pressCtrlS(tester);
    await tester.pumpAndSettle();

    expect(savedText, 'edited\n');
    expect(uploads, 1);
    // The upload reconciles the copy itself; onSaved only runs when it fails.
    expect(saved, 0);
    expect(find.text('Saved and uploaded.'), findsOneWidget);
    // No confirmation dialog of any kind appeared.
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Cmd-S (meta) is the same save-and-upload as Ctrl-S', (
    tester,
  ) async {
    var uploads = 0;
    await tester.pumpWidget(
      editorApp(
        remotePath: '/etc/config.txt',
        initialText: 'one\n',
        saveDocument: (_, text) async => 'baseline',
        onUpload: () async {
          uploads++;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(uploads, 1);
    expect(find.text('Saved and uploaded.'), findsOneWidget);
  });

  testWidgets('Ctrl-S falls back to reconciling when the upload fails', (
    tester,
  ) async {
    var saved = 0;
    await tester.pumpWidget(
      editorApp(
        remotePath: '/etc/config.txt',
        initialText: 'one\n',
        saveDocument: (_, text) async => 'baseline',
        onSaved: () async => saved++,
        onUpload: () async => false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await pressCtrlS(tester);
    await tester.pumpAndSettle();

    expect(saved, 1);
    expect(find.text('Saved locally; not uploaded.'), findsOneWidget);
  });

  testWidgets('Ctrl-S still reconciles when the upload throws', (
    tester,
  ) async {
    var saved = 0;
    await tester.pumpWidget(
      editorApp(
        remotePath: '/etc/config.txt',
        initialText: 'one\n',
        saveDocument: (_, text) async => 'baseline',
        onSaved: () async => saved++,
        onUpload: () async => throw StateError('connection lost'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await pressCtrlS(tester);
    await tester.pumpAndSettle();

    expect(saved, 1);
    expect(find.textContaining('connection lost'), findsOneWidget);
  });

  testWidgets('Ctrl-S saves locally when there is no upload target', (
    tester,
  ) async {
    var saved = 0;
    String? savedText;
    await tester.pumpWidget(
      editorApp(
        remotePath: '/etc/config.txt',
        initialText: 'one\n',
        saveDocument: (_, text) async {
          savedText = text;
          return 'baseline';
        },
        onSaved: () async => saved++,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await pressCtrlS(tester);
    await tester.pumpAndSettle();

    expect(savedText, 'edited\n');
    expect(saved, 1);
    expect(find.text('Saved locally.'), findsOneWidget);
  });

  testWidgets('opens scrolled to the top with the caret at the start', (
    tester,
  ) async {
    final longText = List.generate(400, (index) => 'line $index').join(
      '\n',
    );
    await tester.pumpWidget(
      editorApp(remotePath: '/etc/long.txt', initialText: longText),
    );
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(TextField),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.position.pixels, 0);
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.selection.baseOffset, 0);
  });

  testWidgets('uses the injected monospace font stack', (tester) async {
    await tester.pumpWidget(
      editorApp(remotePath: '/etc/config.txt', initialText: 'one\n'),
    );
    await tester.pumpAndSettle();

    final style = tester.widget<TextField>(find.byType(TextField)).style;
    expect(style?.fontFamilyFallback, contains('monospace'));
  });

  testWidgets(
    'find bar counts matches, navigates, wraps, and toggles case',
    (tester) async {
      await tester.pumpWidget(
        editorApp(
          remotePath: '/etc/config.txt',
          initialText: 'alpha beta\nBeta gamma\nbeta end\n',
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Find'));
      await tester.pumpAndSettle();
      final searchField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Find in file',
      );
      expect(searchField, findsOneWidget);

      await tester.enterText(searchField, 'beta');
      await tester.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget);

      await tester.tap(find.byTooltip('Next match'));
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);

      await tester.tap(find.byTooltip('Previous match'));
      await tester.pumpAndSettle();
      expect(find.text('1/3'), findsOneWidget);

      await tester.tap(find.byTooltip('Previous match'));
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget); // wraps backwards

      // The caret is parked on the third match; the case-sensitive re-search
      // drops 'Beta' and resumes from the caret, i.e. its second match.
      await tester.tap(find.byTooltip('Match case'));
      await tester.pumpAndSettle();
      expect(find.text('2/2'), findsOneWidget);

      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(searchField, findsNothing);
    },
  );

  testWidgets('search highlights land on the editor text', (tester) async {
    await tester.pumpWidget(
      editorApp(remotePath: '/etc/config.txt', initialText: 'alpha beta\n'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Find'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Find in file',
      ),
      'beta',
    );
    await tester.pumpAndSettle();

    final editorField = find
        .byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.controller is CodeEditingController,
        )
        .first;
    final controller =
        tester.widget<TextField>(editorField).controller!
            as CodeEditingController;
    expect(controller.searchMatches, hasLength(1));
    expect(controller.searchMatches.single.start, 6);
    expect(controller.activeMatchIndex, 0);
  });

  testWidgets('edits made during a save remain unsaved', (tester) async {
    final saveStarted = Completer<void>();
    final finishSave = Completer<void>();
    String? persisted;
    await tester.pumpWidget(
      editorApp(
        remotePath: '/etc/config.txt',
        initialText: 'initial',
        saveDocument: (_, text) async {
          persisted = text;
          saveStarted.complete();
          await finishSave.future;
          return 'baseline';
        },
      ),
    );

    await tester.enterText(find.byType(TextField), 'first edit');
    await tester.pump();
    await tester.tap(find.byTooltip('Save locally'));
    await tester.pump();
    await saveStarted.future;
    await tester.enterText(find.byType(TextField), 'newer edit');
    finishSave.complete();
    await tester.pumpAndSettle();

    expect(persisted, 'first edit');
    expect(find.textContaining('Unsaved'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.save_outlined),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('the AppBar shows basename over the full path', (
    tester,
  ) async {
    await tester.pumpWidget(
      editorApp(remotePath: '/etc/nginx/nginx.conf', initialText: 'x\n'),
    );
    await tester.pumpAndSettle();

    expect(find.text('nginx.conf'), findsOneWidget);
    expect(find.text('/etc/nginx/nginx.conf'), findsOneWidget);
  });

  // ---- §2.5 production-path saves (no saveDocument override) ---------------

  testWidgets(
    'production save round-trips BOM and CRLF through the real saver',
    (tester) async {
      // Real disk I/O — the whole flow runs in the real-async zone (the
      // widget's own load/save futures are real I/O too, so pumpWidget,
      // the tap, and the wait-for-toast poll all live inside runAsync).
      await tester.runAsync(() async {
        await file.writeAsBytes([
          0xef,
          0xbb,
          0xbf,
          ...'one\r\ntwo\r\n'.codeUnits,
        ]);
        // 0644 so a missing step-1 chmod would be observable downstream.
        await Process.run('chmod', ['644', file.path]);

        // The temp sibling's 0600 window (between step 1's chmod and
        // step 4's mode restore) is sampled by a poll loop: directory-
        // watch events arrive with OS latency, so a stat on delivery
        // can land before the chmod or after the restore and read 0644
        // either way. Polling stats the live mode every event-loop turn
        // for the whole save — the 0600 window spans the write, flush,
        // close, and SHA syscalls, so it cannot slip past unsampled.
        final modes = <int>{};
        var watching = true;
        final poll = () async {
          while (watching) {
            for (final entity in directory.listSync()) {
              if (entity.path.endsWith('.edit')) {
                try {
                  modes.add(FileStat.statSync(entity.path).mode);
                } on FileSystemException {
                  // Renamed between list and stat — the save finished.
                }
              }
            }
            await Future<void>.delayed(Duration.zero);
          }
        }();
        try {
          await tester.pumpWidget(
            editorApp(remotePath: '/etc/config.txt'), // real disk load
          );
          // The load is real I/O and the spinner animates meanwhile —
          // pumpAndSettle would never settle inside runAsync, so poll
          // the real event loop until the document appears.
          for (var i = 0; i < 40; i++) {
            await tester.pump();
            if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }

          await tester.enterText(
            find.byType(TextField),
            'one\r\ntwo\r\nthree\r\n',
          );
          await tester.pump();
          await tester.tap(find.byTooltip('Save locally'));
          // The save is real I/O — poll the real event loop until the
          // success toast lands rather than betting on a fixed delay.
          for (var i = 0; i < 40; i++) {
            await tester.pump();
            if (find.text('Saved locally.').evaluate().isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          // Let the toast's entrance animation run out before asserting.
          await tester.pump(const Duration(milliseconds: 300));

          // BOM + CRLF reconstruction through the real save dance.
          expect(await file.readAsBytes(), [
            0xef,
            0xbb,
            0xbf,
            ...'one\r\ntwo\r\nthree\r\n'.codeUnits,
          ]);
          // The committed file keeps the original 0644 (step-4 restore).
          expect(FileStat.statSync(file.path).mode & 0x1ff, 0x1a4);
          // §2.1 step 1: the temp sibling was owner-only before any
          // write — at least one sample must have landed inside the
          // 0600 window (the create itself, at umask 0644, and the
          // step-4 restore legitimately sample as 0644).
          expect(
            modes.any((mode) => mode & 0x3f == 0),
            isTrue,
            reason: 'no 0600 sample in ${modes.toList()}',
          );
          expect(find.text('Saved locally.'), findsOneWidget);
        } finally {
          watching = false;
          await poll;
        }
      });
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
  );

  testWidgets(
    'production save on an independently changed file surfaces the '
    'conflict, leaves the disk copy alone, and never uploads',
    (tester) async {
      // Real disk I/O throughout — see the BOM/CRLF test above.
      var uploads = 0;
      await tester.runAsync(() async {
        await tester.pumpWidget(
          editorApp(
            remotePath: '/etc/config.txt', // real disk load
            // A managed checkout's seam — the conflict must refuse the
            // local save before this is ever invoked.
            onUpload: () async {
              uploads++;
              return true;
            },
          ),
        );
        for (var i = 0; i < 40; i++) {
          await tester.pump();
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        // Another program rewrote the file under the open editor.
        await file.writeAsString('external change\n');
        await tester.enterText(find.byType(TextField), 'built-in change\n');
        await tester.pump();
        await tester.tap(find.byTooltip('Save and upload'));
        for (var i = 0; i < 40; i++) {
          await tester.pump();
          if (find
              .textContaining('changed in another editor')
              .evaluate()
              .isNotEmpty) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.textContaining('changed in another editor'),
          findsOneWidget,
        );
        // The external write stands — the editor refused rather than
        // clobber — and the refused save never reached the upload seam.
        expect(await file.readAsString(), 'external change\n');
        expect(uploads, 0);
      });
    },
  );

  testWidgets('a local file exposes no upload action', (tester) async {
    await tester.pumpWidget(
      editorApp(
        remotePath: '/srv/etc/config.txt',
        initialText: 'one\n',
        // onUpload deliberately null — a plain local file (06 §4.2).
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Save locally'), findsOneWidget);
    expect(find.byTooltip('Save and upload'), findsNothing);
  });
}
