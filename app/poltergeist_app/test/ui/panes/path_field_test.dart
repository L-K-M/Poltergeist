import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

/// The editable path field and the history commands (02 §2.1/§8):
/// open/seed/cancel per command, Enter through the navigation seam,
/// inline invalid-input error, and the §8.2 field-first focus rules.
void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController left;
  late PaneController right;
  late PaneTabsController leftStrip;
  late PaneTabsController rightStrip;
  late WorkspaceController workspace;
  late FocusNode leftNode;
  late FocusNode rightNode;

  final fieldKey = const ValueKey('pane.left.path.field');
  final barKey = const ValueKey('pane.left.path');

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

  controller_test.FakePaneChannel scriptLocal(List<String> paths) {
    final channel = controller_test.FakePaneChannel('/home/tester');
    for (final path in ['/home/tester', ...paths]) {
      channel.listings[path] = [
        RemoteFileEntry(
          path: '$path/row.txt',
          name: 'row.txt',
          type: RemoteFileType.file,
        ),
      ];
    }
    lanes.nextLocalChannel = channel;
    return channel;
  }

  /// The shell under test carries the chord layer so the registered
  /// bindings (⌘L/Ctrl+L, Alt+Left, …) dispatch for real.
  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final commands = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CommandChordScope(
          commands: commands,
          child: Scaffold(
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
      ),
    );
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
    bool alt = false,
    bool meta = false,
    bool shift = false,
  }) async {
    for (final (held, modifier) in [
      (control, LogicalKeyboardKey.controlLeft),
      (alt, LogicalKeyboardKey.altLeft),
      (meta, LogicalKeyboardKey.metaLeft),
      (shift, LogicalKeyboardKey.shiftLeft),
    ]) {
      if (held) await tester.sendKeyDownEvent(modifier);
    }
    await tester.sendKeyEvent(key);
    for (final (held, modifier) in [
      (shift, LogicalKeyboardKey.shiftLeft),
      (meta, LogicalKeyboardKey.metaLeft),
      (alt, LogicalKeyboardKey.altLeft),
      (control, LogicalKeyboardKey.controlLeft),
    ]) {
      if (held) await tester.sendKeyUpEvent(modifier);
    }
    await tester.pump();
  }

  testWidgets('go.editPath swaps the bar for the field, seeded with the '
      'current path selected whole; Enter navigates the listing seam', (
    tester,
  ) async {
    final channel = scriptLocal(['/home/tester/docs']);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    left.editPath();
    await tester.pump();
    await tester.pump();

    final field = find.byKey(fieldKey);
    expect(field, findsOneWidget);
    final text = tester.widget<TextField>(field).controller!;
    expect(text.text, '/home/tester');
    expect(
      text.selection,
      const TextSelection(baseOffset: 0, extentOffset: 12),
      reason: 'the seed arrives selected whole (02 §2.1)',
    );

    await tester.enterText(field, '/home/tester/docs');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // Enter closed the editor and navigated through the ordinary seam:
    // one more listing call, the location already optimistic.
    expect(find.byKey(fieldKey), findsNothing);
    expect(find.byKey(barKey), findsOneWidget);
    expect(left.location, const LocalPaneLocation('/home/tester/docs'));
    expect(
      channel.listCalls,
      containsAllInOrder(['/home/tester', '/home/tester/docs']),
    );
  });

  testWidgets('the entered path joins the trail; a stale listing answer '
      'is still dropped (generation check)', (tester) async {
    final channel = scriptLocal(['/home/tester/a', '/home/tester/b']);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    // Submit /a through the field with its answer held.
    left.editPath();
    await tester.pump();
    await tester.pump();
    final hold = Completer<void>();
    channel.holdNext = hold;
    await tester.enterText(find.byKey(fieldKey), '/home/tester/a');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(left.loading, isTrue);
    expect(left.location?.path, '/home/tester/a');
    // The attempted location is already a trail entry.
    expect(left.canGoBack, isTrue);

    // A newer navigation supersedes; the held answer must go stale.
    left.navigate('/home/tester/b');
    await tester.pump();
    hold.complete();
    await tester.pump();
    expect(left.location?.path, '/home/tester/b');
    expect(left.loading, isFalse);
  });

  testWidgets('go.toFolder opens the same editor seeded empty', (
    tester,
  ) async {
    scriptLocal(const []);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    left.goToFolder();
    await tester.pump();
    await tester.pump();

    final field = tester.widget<TextField>(find.byKey(fieldKey));
    expect(field.controller!.text, isEmpty);
    expect(field.controller!.selection.isValid, isTrue);
  });

  testWidgets('Esc is the field-tier cancel: the editor closes, the bar '
      'returns, and an in-flight navigation underneath keeps loading', (
    tester,
  ) async {
    final channel = scriptLocal(['/home/tester/a', '/home/tester/slow']);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    // Put a listing in flight first — the field's Esc must NOT reach
    // the navigation-cancel tier (02 §8.2's order: field, then nav).
    final hold = Completer<void>();
    channel.holdNext = hold;
    left.navigate('/home/tester/slow');
    await tester.pump();
    expect(left.loading, isTrue);

    left.editPath();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(fieldKey), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(left.pathFieldOpen, isFalse);
    expect(find.byKey(fieldKey), findsNothing);
    expect(find.byKey(barKey), findsOneWidget);
    expect(left.loading, isTrue, reason: 'Esc closed the field only');
    expect(left.location?.path, '/home/tester/slow');

    // Esc again — the listing holds focus now — cancels the navigation
    // (the next Esc tier, 02 §8.2) while its answer is still held.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(left.loading, isFalse);
    expect(left.location?.path, '/home/tester');

    // The released answer arrives stale and is dropped.
    hold.complete();
    await tester.pump();
    expect(left.location?.path, '/home/tester');
    expect(left.entries.single.name, 'row.txt');
  });

  testWidgets('an unresolvable submission surfaces the pane error '
      'affordance without an engine call', (tester) async {
    final channel = scriptLocal(const []);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();
    final callsBefore = channel.listCalls.length;

    left.goToFolder();
    await tester.pump();
    await tester.pump();
    // '~root' is other-user expansion — no app-side meaning (02 §2.1).
    await tester.enterText(find.byKey(fieldKey), '~root/docs');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(find.byKey(fieldKey), findsNothing);
    expect(left.error, isA<PaneFaultException>());
    expect(
      (left.error as PaneFaultException).fault,
      PaneFault.invalidPath,
    );
    expect(channel.listCalls.length, callsBefore,
        reason: 'shape validation precedes any listing request');
    // The pane's own error affordance renders the ARB line — no dialog.
    expect(
      find.textContaining('not a folder path'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('pane.error.retry')), findsOneWidget);

    // Esc/Retry refreshes back to the still-committed location.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(left.error, isNull);
  });

  testWidgets('typing in the field suppresses pane single keys and '
      'type-ahead (02 §8.2)', (tester) async {
    scriptLocal(const []);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();
    left.setCursorIndex(0);
    await tester.pump();

    left.goToFolder();
    await tester.pump();
    await tester.pump();

    // Printable input lands in the field, never in the buffer.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(left.typeAheadActive, isFalse);
    expect(left.typeAheadBuffer, isEmpty);

    // The pane's cursor keys do not move the listing cursor — the
    // primary-focus gate keeps the single-key table inert.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(left.cursorIndex, 0);
  });

  testWidgets('the registered chords reach the commands, and a focused '
      'field suppresses them (field-first, 02 §8.2)', (tester) async {
    scriptLocal(['/home/tester/a', '/home/tester/b']);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    // Alt+Left on the focused listing walks the trail — first give it
    // a second entry so Back is armed.
    left.navigate('/home/tester/a');
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowLeft, alt: true);
    expect(left.location?.path, '/home/tester');

    // Alt+Right returns forward.
    await press(tester, LogicalKeyboardKey.arrowRight, alt: true);
    expect(left.location?.path, '/home/tester/a');

    // Alt+Up climbs to the parent.
    await press(tester, LogicalKeyboardKey.arrowUp, alt: true);
    expect(left.location?.path, '/home/tester');

    // Ctrl+L opens the field; while it holds focus, Alt+Left must NOT
    // walk the trail — the chord layer yields to the field (the
    // command that would run is also disabled mid-type only by focus).
    await press(tester, LogicalKeyboardKey.keyL, control: true);
    await tester.pump();
    expect(left.pathFieldOpen, isTrue);

    left.navigate('/home/tester/b');
    await tester.pump();
    expect(left.location?.path, '/home/tester/b');
    expect(left.canGoBack, isTrue);
    await press(tester, LogicalKeyboardKey.arrowLeft, alt: true);
    expect(
      left.location?.path,
      '/home/tester/b',
      reason: 'a focused text field owns the chord layer entirely',
    );
    expect(left.pathFieldOpen, isTrue);
  });

  testWidgets('a re-invoked go.toFolder re-seeds the mounted field', (
    tester,
  ) async {
    scriptLocal(const []);
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    left.editPath();
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(fieldKey), '/in/progress');
    await tester.pump();

    // While the field holds focus its chord is suppressed (02 §8.2's
    // field-first rule — the reseed covers the command invoked over an
    // open-but-unfocused field, e.g. a menu click after a stray tap).
    await press(
      tester,
      LogicalKeyboardKey.keyG,
      control: true,
      shift: true,
    );
    expect(
      tester.widget<TextField>(find.byKey(fieldKey)).controller!.text,
      '/in/progress',
      reason: 'the focused field owns ⇧⌘G — no chord reaches it',
    );

    // Focus the listing and invoke the command again: the mounted
    // field re-seeds and re-focuses.
    leftNode.requestFocus();
    await tester.pump();
    left.goToFolder();
    await tester.pump();
    await tester.pump();
    final field = tester.widget<TextField>(find.byKey(fieldKey));
    expect(field.controller!.text, isEmpty);
    expect(left.pathFieldOpen, isTrue);
  });
}
