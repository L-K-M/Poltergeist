import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/quit_guard.dart';
import 'package:poltergeist_app/services/workspace_windows/workspace_windows.dart';
import 'package:poltergeist_app/ui/built_in_text_editor.dart';
import 'package:poltergeist_app/ui/editor_window_app.dart';
import 'package:poltergeist_app/ui/menus/app_menu_host.dart';

import '../services/workspace_windows_test.dart' show FakeWindowHost;

void main() {
  late FakeWindowHost host;
  late WorkspaceWindows windows;
  late WorkspaceWindow editor;

  Future<void> mount(
    WidgetTester tester, {
    Future<String> Function(File, String)? saveDocument,
  }) async {
    host = FakeWindowHost();
    windows = WorkspaceWindows(
      host: host,
      quitApplication: () async {},
      afterFrame: () async {},
    );
    await windows.start();
    await windows.openEditor(
      key: 'local:/config.txt',
      builder: (window) => ValueListenableBuilder<bool>(
        valueListenable: window.editorQuitPending,
        builder: (context, pending, _) => BuiltInTextEditorScreen(
          file: File('/config.txt'),
          initialText: 'original',
          saveDocument: saveDocument,
          quitPending: pending,
          onCloseRequested: window.close,
          onQuitRequested: window.quitApplication,
          onNewWindowRequested: window.openWindow,
          onCloseGuardChanged: window.setEditorCloseGuard,
          showToast: (_, _) {},
          monoFontFallback: const ['monospace'],
          basenameOf: (_) => 'config.txt',
        ),
      ),
    );
    editor = windows.windows.last;
    await tester.pumpWidget(EditorWindowApp(window: editor));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      windows.dispose();
    });
  }

  testWidgets('native close preserves dirty text until discard is accepted', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField), 'unsaved');
    final closing = editor.close();
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Keep editing'));
    await tester.pumpAndSettle();
    await closing;
    expect(windows.windows, hasLength(2));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'unsaved',
    );

    final discard = editor.close();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
    await tester.pumpAndSettle();
    await discard;
    expect(windows.windows, hasLength(1));
    expect(host.calls, contains('destroy 1'));
  });

  testWidgets(
    'a save started from the menu during discard keeps the window open',
    (tester) async {
      final saveGate = Completer<String>();
      var saveStarted = false;
      await mount(
        tester,
        saveDocument: (_, _) {
          saveStarted = true;
          return saveGate.future;
        },
      );
      await tester.enterText(find.byType(TextField), 'unsaved');
      final closing = editor.close();
      await tester.pumpAndSettle();
      expect(find.text('Discard unsaved changes?'), findsOneWidget);

      // A Flutter dialog does not disable the native menu. Run the same
      // registered Save callback that its File menu item invokes.
      final menu = tester.widget<AppMenuHost>(find.byType(AppMenuHost));
      final saving = menu.onRun(
        menu.commands.singleWhere((command) => command.id == 'editor.save'),
      );
      await tester.pump();
      expect(saveStarted, isTrue);
      await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
      await tester.pump(const Duration(milliseconds: 300));
      await closing;
      final stayedOpenDuringSave = windows.windows.contains(editor);
      final destroyedDuringSave = host.calls.contains('destroy 1');

      // Release the write before asserting so a failure leaves no pending
      // save or controller callbacks behind in the test process.
      saveGate.complete('baseline');
      await saving;
      await tester.pumpAndSettle();
      expect(stayedOpenDuringSave, isTrue);
      expect(destroyedDuringSave, isFalse);
    },
  );

  testWidgets('quit freezes buffers and new windows, and a veto unlocks them', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField), 'unsaved');
    await tester.pump(const Duration(seconds: 1));
    final guard = QuitGuard(
      navigatorKey: windows.navigatorKey,
      confirmEditorsClose: windows.confirmEditorsClose,
      setEditorQuitPending: windows.setEditorQuitPending,
    )..bindQueue(() => null);
    final quitting = guard.confirmClose();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    final editable = tester.element(find.byType(EditableText));
    Actions.maybeInvoke(
      editable,
      const UndoTextIntent(SelectionChangedCause.keyboard),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'unsaved',
    );
    await windows.openEditor(
      key: 'local:/new',
      builder: (_) => const SizedBox(),
    );
    await windows.openWindow();
    expect(windows.windows, hasLength(2));
    await tester.tap(find.widgetWithText(TextButton, 'Keep editing'));
    await tester.pumpAndSettle();
    expect(await quitting, isFalse);
    expect(editor.editorQuitPending.value, isFalse);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);

    final accepted = guard.confirmClose();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
    await tester.pumpAndSettle();
    expect(await accepted, isTrue);
    expect(editor.editorQuitPending.value, isTrue);
  });

  testWidgets('editor menus contain text actions and no workspace file verbs', (
    tester,
  ) async {
    await mount(tester);
    final menu = tester.widget<AppMenuHost>(find.byType(AppMenuHost));
    final ids = menu.commands.map((command) => command.id).toSet();
    expect(
      ids,
      containsAll([
        'editor.save',
        'editor.close',
        'editor.find',
        'editor.undo',
        'editor.redo',
        'editor.cut',
        'editor.copy',
        'editor.paste',
        'editor.selectAll',
      ]),
    );
    expect(ids.any((id) => id.startsWith('file.')), isFalse);
    await menu.onRun(
      menu.commands.singleWhere((command) => command.id == 'editor.selectAll'),
    );
    final text = tester.widget<TextField>(find.byType(TextField)).controller!;
    expect(text.selection, const TextSelection(baseOffset: 0, extentOffset: 8));
    await menu.onRun(
      menu.commands.singleWhere((command) => command.id == 'editor.cut'),
    );
    expect(text.text, isEmpty);
    for (final command in menu.commands.where(
      (command) => command.id.startsWith('editor.'),
    )) {
      expect(command.activators!(TargetPlatform.macOS), isNotEmpty);
      expect(command.activators!(TargetPlatform.windows), isNotEmpty);
    }
  });
}
