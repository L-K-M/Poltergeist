import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;

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

DateTime _fixedClock() => DateTime(2026, 9, 15, 10);

void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController left;
  late PaneController right;
  late WorkspaceController workspace;
  late FocusNode leftNode;
  late FocusNode rightNode;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    workspace = WorkspaceController(left: left, right: right);
    leftNode = FocusNode();
    rightNode = FocusNode();
  });

  tearDown(() {
    workspace.dispose();
    leftNode.dispose();
    rightNode.dispose();
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    Widget? above,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final panes = Row(
      children: [
        Expanded(
          child: PaneView(
            controller: left,
            workspace: workspace,
            focusNode: leftNode,
            onSwapFocus: () => rightNode.requestFocus(),
            onCancelRecovery: () => unawaited(left.cancelRecovery()),
            clock: _fixedClock,
          ),
        ),
        Expanded(
          child: PaneView(
            controller: right,
            workspace: workspace,
            focusNode: rightNode,
            onSwapFocus: () => leftNode.requestFocus(),
            onCancelRecovery: () => unawaited(right.cancelRecovery()),
            clock: _fixedClock,
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: above == null
              ? panes
              : Column(children: [above, Expanded(child: panes)]),
        ),
      ),
    );
  }

  void listLeft(List<RemoteFileEntry> entries) {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = entries;
    lanes.nextLocalChannel = channel;
  }

  int indexOf(String name) => left.entries.indexWhere((e) => e.name == name);

  testWidgets('typed characters jump the cursor and show the badge', (
    tester,
  ) async {
    listLeft([
      _entry('docs', type: RemoteFileType.directory),
      _entry('readme.md'),
      _entry('report.txt'),
      _entry('zebra.png'),
    ]);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    expect(find.byKey(const ValueKey('pane.typeAhead')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(left.typeAheadBuffer, 'r');
    expect(left.entries[left.cursorIndex!].name, 'readme.md');
    expect(find.byKey(const ValueKey('pane.typeAhead')), findsOneWidget);
    expect(find.text('r'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(left.typeAheadBuffer, 'rep');
    expect(left.entries[left.cursorIndex!].name, 'report.txt');
    expect(find.text('rep'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the badge announces the prefix through a live region', (
    tester,
  ) async {
    listLeft([_entry('readme.md'), _entry('report.txt')]);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();

    final node = tester.getSemantics(
      find.byKey(const ValueKey('pane.typeAhead')),
    );
    expect(node.label, 'Names starting with "re"');
    expect(node.flagsCollection.isLiveRegion, isTrue);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('space never enters the buffer and shows no badge', (
    tester,
  ) async {
    listLeft([_entry('my file.txt'), _entry('other.txt')]);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(left.typeAheadBuffer, '');
    expect(left.typeAheadActive, isFalse);
    expect(find.byKey(const ValueKey('pane.typeAhead')), findsNothing);

    // Space-prefixed keys still match by their non-space prefix.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
    await tester.pump();
    expect(left.typeAheadBuffer, 'my');
    expect(left.entries[left.cursorIndex!].name, 'my file.txt');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the badge disappears with the one-second reset', (
    tester,
  ) async {
    listLeft([_entry('readme.md')]);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(find.byKey(const ValueKey('pane.typeAhead')), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(left.typeAheadBuffer, '');
    expect(find.byKey(const ValueKey('pane.typeAhead')), findsNothing,
        reason: 'the badge is transient — it unmounts on buffer reset');
  });

  testWidgets('a jump scrolls the matched row into view', (tester) async {
    listLeft([
      for (var i = 0; i < 60; i++) _entry('row${i.toString().padLeft(2, '0')}'),
      _entry('zeta-final.txt'),
    ]);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    expect(find.text('zeta-final.txt'), findsNothing,
        reason: 'the target starts scrolled off-screen');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.pump();
    await tester.pump();

    expect(left.entries[left.cursorIndex!].name, 'zeta-final.txt');
    expect(find.text('zeta-final.txt'), findsOneWidget);
    expect(find.text('row00'), findsNothing,
        reason: 'the viewport moved to the match');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a focused Quick Select field suppresses type-ahead', (
    tester,
  ) async {
    listLeft([_entry('readme.md'), _entry('report.txt')]);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    left.openQuickSelect();
    await tester.pump();
    final field = find.byKey(const ValueKey('pane.left.quickSelect.field'));
    expect(field, findsOneWidget);
    expect(
      tester.binding.focusManager.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>(),
      isNotNull,
      reason: 'the field owns primary focus while open',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(left.typeAheadBuffer, '',
        reason: 'no type-ahead while a text field holds focus (02 §2.5)');
    expect(find.byKey(const ValueKey('pane.typeAhead')), findsNothing);
    expect(left.cursorIndex, isNull,
        reason: 'no prefix jump ran behind the focused field');
  });

  testWidgets('a focused text field outside the pane suppresses it too', (
    tester,
  ) async {
    listLeft([_entry('readme.md'), _entry('report.txt')]);
    await left.openLocalHome();
    final outsideNode = FocusNode();
    addTearDown(outsideNode.dispose);
    await pumpShell(
      tester,
      above: TextField(
        key: const ValueKey('outside.field'),
        focusNode: outsideNode,
      ),
    );
    leftNode.requestFocus();
    await tester.pump();

    outsideNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR, character: 'r');
    await tester.pump();
    expect(left.typeAheadBuffer, '');
    expect(find.byKey(const ValueKey('pane.typeAhead')), findsNothing);
  });

  testWidgets('Esc clears the pending buffer above deselect', (tester) async {
    listLeft([_entry('readme.md'), _entry('report.txt')]);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(left.typeAheadActive, isTrue);
    final jumpedTo = left.cursorIndex;

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(left.typeAheadBuffer, '');
    expect(find.byKey(const ValueKey('pane.typeAhead')), findsNothing);
    expect(left.cursorIndex, jumpedTo,
        reason: 'Esc clears the buffer, not the cursor it jumped');
  });

  testWidgets('flagged rows are skipped but stay pointer-selectable', (
    tester,
  ) async {
    listLeft([_entry('apple.txt'), _entry('fl\u{FFFD}ag.bin')]);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    expect(left.cursorIndex, isNull,
        reason: 'the only f-prefixed row is flagged — no match is a no-op');

    expect(find.text('fl\u{FFFD}ag.bin'), findsOneWidget);
    expect(left.entries.length, 2);
    // Rows carry onTap and onDoubleTap — the single tap commits only
    // after the double-tap window closes.
    await tester.tap(find.text('fl\u{FFFD}ag.bin'));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect(left.cursorIndex, indexOf('fl\u{FFFD}ag.bin'));
    expect(left.isRowSelected(indexOf('fl\u{FFFD}ag.bin')), isTrue);
    await tester.pump(const Duration(seconds: 2));
    leftNode.unfocus();
    await tester.pump();
  });

  testWidgets('hidden files never match, even on a dot', (tester) async {
    listLeft([_entry('.hidden'), _entry('visible.txt')]);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.period, character: '.');
    await tester.pump();
    expect(left.typeAheadBuffer, '.');
    expect(left.cursorIndex, isNull);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a modified printable chord never reaches the buffer', (
    tester,
  ) async {
    listLeft([_entry('readme.md')]);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR, character: 'r');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(left.typeAheadBuffer, '',
        reason: 'Ctrl+R is a chord for whoever binds it, not type-ahead');
  });
}
