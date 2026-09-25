import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
}) {
  return RemoteFileEntry(
    path: '/home/tester/$name',
    name: name,
    type: type,
    size: size,
  );
}

void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController left;
  late PaneController right;
  late PaneTabsController leftStrip;
  late PaneTabsController rightStrip;
  late WorkspaceController workspace;
  late FocusNode leftNode;
  late FocusNode rightNode;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    leftStrip = testPaneStrip(left);
    rightStrip = testPaneStrip(right);
    workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    leftNode = FocusNode();
    rightNode = FocusNode();
  });

  tearDown(() {
    workspace.dispose();
    leftNode.dispose();
    rightNode.dispose();
  });

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
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
                  focusNode: leftNode,
                  onSwapFocus: () => rightNode.requestFocus(),
                  onCancelRecovery: () => unawaited(left.cancelRecovery()),
                ),
              ),
              Expanded(
                child: PaneView(
                  controller: right,
                  pane: rightStrip,
                  workspace: workspace,
                  focusNode: rightNode,
                  onSwapFocus: () => leftNode.requestFocus(),
                  onCancelRecovery: () => unawaited(right.cancelRecovery()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  controller_test.FakePaneChannel localChannel() {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('docs', type: RemoteFileType.directory),
      _entry('report.txt', size: 2048),
      _entry('notes.md', size: 10),
    ];
    lanes.nextLocalChannel = channel;
    return channel;
  }

  final fieldKey = const ValueKey('pane.left.rename.field');

  testWidgets('F2 opens the editor on the cursor row, stem selected', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      localChannel();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setCursorIndex(2); // report.txt (docs, notes.md sort ahead)
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();

      expect(left.renameTarget!.name, 'report.txt');
      final field = tester.widget<TextField>(find.byKey(fieldKey));
      expect(field.controller!.text, 'report.txt');
      // The stem is selected, the extension survives the first key; the
      // caret end sits at the start so a long name shows its beginning.
      expect(
        field.controller!.selection,
        const TextSelection(baseOffset: 6, extentOffset: 0),
      );
      expect(field.focusNode!.hasFocus, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the editor replaces the label in place: at its x, sized '
      'to the name, centered in the row', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      localChannel();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();
      // The label x every row shares, read before the edit.
      final labelX = tester.getTopLeft(find.text('notes.md')).dx;
      final notesRow = tester.getRect(
        find
            .ancestor(of: find.text('notes.md'), matching: find.byType(Listener))
            .first,
      );

      left.setCursorIndex(2); // report.txt, the row under notes.md
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();

      // The row's own label is gone while the editor shows its name.
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('report.txt'),
        ),
        findsNothing,
      );
      final editable = find.descendant(
        of: find.byKey(fieldKey),
        matching: find.byType(EditableText),
      );
      expect(tester.getRect(editable).left, closeTo(labelX, 1));

      // Sized to the name plus a little slack — not the whole column —
      // so nothing scrolls the name's start out of view.
      const boxKey = ValueKey('pane.left.rename.box');
      final box = tester.getRect(find.byKey(boxKey));
      final painter = TextPainter(
        text: TextSpan(
          text: 'report.txt',
          style: tester.widget<EditableText>(editable).style,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(box.width, greaterThan(painter.width));
      expect(box.width, lessThan(painter.width + 48));
      painter.dispose();
      expect(
        tester.state<EditableTextState>(editable).renderEditable.offset.pixels,
        0,
      );

      // Vertically centered in its 22 px row (the row below notes.md),
      // and the text centered in the box — nothing hangs out below it.
      expect(box.center.dy, closeTo(notesRow.center.dy + notesRow.height, 1));
      expect(box.height, lessThanOrEqualTo(notesRow.height));
      final text = tester.getRect(editable);
      expect(text.center.dy, closeTo(box.center.dy, 1));
      expect(text.bottom, lessThanOrEqualTo(box.bottom));

      // It grows as the name grows.
      await tester.enterText(find.byKey(fieldKey), 'a-much-longer-name.txt');
      await tester.pump();
      expect(tester.getRect(find.byKey(boxKey)).width, greaterThan(box.width));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('on touch the editor centers in the 48 dp row', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      localChannel();
      await left.openLocalHome();
      await pumpShell(tester);
      final notesRow = tester.getRect(
        find
            .ancestor(
              of: find.text('notes.md'),
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      expect(notesRow.height, 48);

      left.setCursorIndex(2); // report.txt, the row under notes.md
      left.startRename();
      await tester.pumpAndSettle();

      final box = tester.getRect(
        find.byKey(const ValueKey('pane.left.rename.box')),
      );
      expect(box.center.dy, closeTo(notesRow.center.dy + 48, 1));
      expect(box.height, lessThan(48));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Enter opens the editor on macOS and commits through it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final channel = localChannel();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setCursorIndex(2); // report.txt (docs, notes.md sort ahead)
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(fieldKey), findsOneWidget);

      await tester.enterText(find.byKey(fieldKey), 'renamed.txt');
      channel.listings['/home/tester'] = [
        _entry('docs', type: RemoteFileType.directory),
        _entry('notes.md', size: 10),
        _entry('renamed.txt', size: 2048),
      ];
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(channel.renameCalls, [
        ('/home/tester/report.txt', '/home/tester/renamed.txt'),
      ]);
      expect(find.byKey(fieldKey), findsNothing);
      // The refresh re-anchored the cursor on the renamed row.
      expect(left.entries[left.cursorIndex!].name, 'renamed.txt');
      expect(leftNode.hasPrimaryFocus, isTrue,
          reason: 'the closed field returns focus to the listing');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Esc cancels the edit without a request', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final channel = localChannel();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setCursorIndex(2); // report.txt (docs, notes.md sort ahead)
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(fieldKey), 'draft.txt');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byKey(fieldKey), findsNothing);
      expect(left.inlineRenameActive, isFalse);
      expect(channel.renameCalls, isEmpty);
      expect(channel.listCalls, ['/home/tester'],
          reason: 'a cancelled rename must not refresh');
      expect(leftNode.hasPrimaryFocus, isTrue,
          reason: 'the cancelled field returns focus to the listing');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a click outside the field cancels the edit', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final channel = localChannel();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setCursorIndex(2); // report.txt (docs, notes.md sort ahead)
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();

      // A tap on another row is the §2.6 click-outside cancel: focus
      // moves to the listing and the session ends without a request.
      await tester.tap(find.text('notes.md'));
      await tester.pumpAndSettle();

      expect(find.byKey(fieldKey), findsNothing);
      expect(left.inlineRenameActive, isFalse);
      expect(channel.renameCalls, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a refused name shows its validation error inside the '
      'field', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final channel = localChannel();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setCursorIndex(2); // report.txt (docs, notes.md sort ahead)
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(fieldKey), 'a/b');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byKey(fieldKey), findsOneWidget,
          reason: 'a failed validation keeps the field open');
      expect(find.text('A name cannot contain “/”.'), findsOneWidget);
      expect(channel.renameCalls, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a typed refusal re-opens the field with the draft and '
      'the VFS error', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final channel = localChannel();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setCursorIndex(2); // report.txt (docs, notes.md sort ahead)
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(fieldKey), 'taken.txt');
      channel.renameFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'rename',
        path: '/home/tester/report.txt',
        message: 'Permission denied',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byKey(fieldKey), findsOneWidget,
          reason: 'a typed refusal re-opens the field');
      expect(find.text('Permission denied'), findsOneWidget);
      // The refused draft is re-seeded, not the pre-rename name.
      expect(
        tester.widget<TextField>(find.byKey(fieldKey)).controller!.text,
        'taken.txt',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the gone-row fault stays visible and dismissible when '
      'the listing empties', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [_entry('solo.txt')];
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setCursorIndex(0);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.byKey(fieldKey), findsOneWidget);

      // The last visible row leaves the listing: the pane still owes
      // the user the detached session's diagnostic — not a bare
      // "empty folder" that hides the fault while the tab-close guard
      // keeps holding the session.
      channel.listings['/home/tester'] = [];
      left.refresh();
      await tester.pumpAndSettle();

      expect(left.entries, isEmpty);
      expect(find.byKey(fieldKey), findsOneWidget,
          reason: 'the detached editor keeps floating over the empty '
              'state so its fault stays visible');
      expect(
        find.text('The item is no longer in this folder.'),
        findsOneWidget,
      );

      // Dismissal stays reachable: Esc closes the diagnostic session.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(left.inlineRenameActive, isFalse);
      expect(channel.renameCalls, isEmpty);
      expect(find.byKey(fieldKey), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the pane keys stay inert while a commit is in flight', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final channel = localChannel();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setCursorIndex(2); // report.txt (docs, notes.md sort ahead)
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(fieldKey), 'renamed.txt');

      final held = Completer<void>();
      channel.heldRename = held;
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // The field closed; the commit is in flight. Pane keys must not
      // drive the cursor or start a second session.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      expect(left.cursorIndex, 2);
      expect(left.renameTarget, isNull);
      expect(left.inlineRenameActive, isTrue,
          reason: 'the in-flight commit holds the close guard');

      channel.listings['/home/tester'] = [
        _entry('docs', type: RemoteFileType.directory),
        _entry('notes.md', size: 10),
        _entry('renamed.txt', size: 2048),
      ];
      held.complete();
      await tester.pumpAndSettle();
      expect(left.entries[left.cursorIndex!].name, 'renamed.txt');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
