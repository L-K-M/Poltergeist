import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_context_menu.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
}) => RemoteFileEntry(
  path: '/home/tester/$name',
  name: name,
  type: type,
  size: type == RemoteFileType.file ? 10 : null,
);

/// A registered stand-in for a verb another slice adds (D32 §6's menu
/// renders its slot only once the command exists).
RegisteredCommand _slotCommand(String id) => RegisteredCommand(
  id: id,
  scope: CommandScope.pane,
  label: (_) => id,
  run: (_) async {},
);

void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController left;
  late PaneTabsController leftStrip;
  late PaneTabsController rightStrip;
  late WorkspaceController workspace;
  late FocusNode leftNode;
  late List<String> ran;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    leftStrip = testPaneStrip(left);
    rightStrip = testPaneStrip(
      PaneController(paneTabId: 'pane.right', lanes: lanes),
    );
    workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    leftNode = FocusNode();
    ran = [];
  });

  tearDown(() {
    workspace.dispose();
    leftNode.dispose();
  });

  Future<void> openRows() async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('docs', type: RemoteFileType.directory),
      _entry('a.txt'),
      _entry('b.txt'),
    ];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
  }

  Future<void> pumpPane(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.linux,
    List<RegisteredCommand> extra = const [],
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final commands = [
      ...buildPaneCommands(
        workspace: workspace,
        focusLeft: () {},
        focusRight: () {},
        swapFocus: () {},
      ),
      ...buildShellCommands(
        workspace: workspace,
        dropDelegate: () => null,
        openConnect: () {},
      ),
      ...extra,
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PaneView(
            controller: left,
            pane: leftStrip,
            workspace: workspace,
            focusNode: leftNode,
            onSwapFocus: () {},
            onCancelRecovery: () {},
            commands: commands,
            onRunCommand: (command) async => ran.add(command.id),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> rightClick(WidgetTester tester, Offset position) async {
    final gesture = await tester.startGesture(
      position,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
  }

  // A checkbox row forwards its key to the inner button, so a row can
  // match twice — address the outermost.
  Finder item(String id) => find.byKey(ValueKey('pane.context.$id')).first;
  Finder anyItem(String id) => find.byKey(ValueKey('pane.context.$id'));

  testWidgets('right-click selects the row and opens the registry menu in '
      'D32 order at the pointer', (tester) async {
    await openRows();
    await pumpPane(tester);

    final at = tester.getCenter(find.text('b.txt'));
    await rightClick(tester, at);

    expect(left.cursorIndex, 2);
    expect(left.isRowSelected(2), isTrue);
    final ids = [
      kGoOpenCommandId,
      kFileEditBuiltInCommandId,
      kFilePreviewCommandId,
      kFileGetInfoCommandId,
      kFileRenameCommandId,
      kSelectionCopyPathCommandId,
      kSelectionTransferToOtherPaneCommandId,
      kSelectionMoveToOtherPaneCommandId,
    ];
    for (final id in ids) {
      expect(item(id), findsOneWidget, reason: id);
    }
    final tops = [for (final id in ids) tester.getTopLeft(item(id)).dy];
    expect(tops, orderedEquals([...tops]..sort()));
    // Opened at the pointer, not at the pane's corner.
    expect(
      (tester.getTopLeft(item(kGoOpenCommandId)) - at).distance,
      lessThan(40),
    );
    // Slots for verbs no slice registered yet render nothing.
    expect(anyItem('file.newFolder'), findsNothing);
    expect(anyItem('file.delete'), findsNothing);

    await tester.tap(item(kFileRenameCommandId));
    await tester.pumpAndSettle();
    expect(ran, [kFileRenameCommandId]);
  });

  testWidgets('right-click inside a multi-selection keeps it as the '
      'menu\'s subject', (tester) async {
    await openRows();
    await pumpPane(tester);
    left.selectAll();
    await tester.pump();

    await rightClick(tester, tester.getCenter(find.text('a.txt')));
    expect(left.selectedCount, 3);
    expect(item(kGoOpenCommandId), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(anyItem(kGoOpenCommandId), findsNothing);
  });

  testWidgets('the empty area opens the folder-level menu; registered '
      'slots render', (tester) async {
    await openRows();
    await pumpPane(
      tester,
      extra: [_slotCommand('file.newFolder'), _slotCommand('file.delete')],
    );

    final list = find.byType(ListView);
    await rightClick(
      tester,
      tester.getBottomLeft(list) + const Offset(40, -40),
    );

    expect(item('file.newFolder'), findsOneWidget);
    expect(item(kViewToggleHiddenCommandId), findsOneWidget);
    expect(item(kViewRefreshCommandId), findsOneWidget);
    expect(item(kEditSelectAllCommandId), findsOneWidget);
    // Nothing that acts on a selection the press did not land on.
    expect(anyItem(kGoOpenCommandId), findsNothing);
    expect(anyItem('file.delete'), findsNothing);

    await tester.tap(item(kViewToggleHiddenCommandId));
    await tester.pumpAndSettle();
    expect(ran, [kViewToggleHiddenCommandId]);
  });

  testWidgets('a registered row slot renders in its D32 section', (
    tester,
  ) async {
    await openRows();
    await pumpPane(tester, extra: [_slotCommand('file.delete')]);

    await rightClick(tester, tester.getCenter(find.text('a.txt')));
    expect(item('file.delete'), findsOneWidget);
    expect(
      tester.getTopLeft(item('file.delete')).dy,
      greaterThan(
        tester.getTopLeft(item(kSelectionMoveToOtherPaneCommandId)).dy,
      ),
      reason: 'Move to Trash closes the menu (D32 §6)',
    );
  });

  testWidgets('Shift+F10 opens the menu over the cursor row with focus on '
      'its first row; Esc closes it', (tester) async {
    await openRows();
    await pumpPane(tester);
    leftNode.requestFocus();
    left.setCursorIndex(1);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(item(kGoOpenCommandId), findsOneWidget);
    final firstFocus = Focus.of(
      tester.element(
        find.descendant(
          of: item(kGoOpenCommandId),
          matching: find.byType(Text),
        ).first,
      ),
    );
    expect(firstFocus.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(anyItem(kGoOpenCommandId), findsNothing);

    // The Menu key is the same path.
    leftNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(item(kGoOpenCommandId), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('on touch, a long-press selects the row and opens the '
      'action sheet', (tester) async {
    await openRows();
    await pumpPane(tester, platform: TargetPlatform.android);

    await tester.longPress(find.text('a.txt'));
    await tester.pumpAndSettle();

    expect(left.cursorIndex, 1);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: item(kFileRenameCommandId),
      ),
      findsOneWidget,
    );

    await tester.tap(item(kFileRenameCommandId));
    await tester.pumpAndSettle();
    expect(ran, [kFileRenameCommandId]);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('a press inside a multi-selection keeps it until release, '
      'so a drag can carry every selected row', (tester) async {
    await openRows();
    await pumpPane(tester);
    left.selectAll();
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('a.txt')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(left.selectedCount, 3, reason: 'pointer-down must not collapse');

    await gesture.up();
    await tester.pump();
    expect(left.selectedCount, 1);
    expect(left.cursorIndex, 1);
    await tester.pump(kDoubleTapTimeout);
  });

  testWidgets('no registry mounts no menu', (tester) async {
    await openRows();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PaneView(
            controller: left,
            pane: leftStrip,
            workspace: workspace,
            focusNode: leftNode,
            onSwapFocus: () {},
            onCancelRecovery: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    await rightClick(tester, tester.getCenter(find.text('a.txt')));
    expect(find.byType(MenuItemButton), findsNothing);
    expect(left.cursorIndex, 1, reason: 'the press still selects');
  });

  test('resolvePaneContextSections drops unregistered ids and empty '
      'sections', () {
    final commands = [_slotCommand('a'), _slotCommand('c')];
    final resolved = resolvePaneContextSections(commands, const [
      ['a', 'b'],
      ['x'],
      ['c'],
    ]);
    expect(
      [
        for (final section in resolved) [for (final c in section) c.id],
      ],
      [
        ['a'],
        ['c'],
      ],
    );
  });
}
