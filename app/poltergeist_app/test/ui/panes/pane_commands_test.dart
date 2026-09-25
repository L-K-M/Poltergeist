import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

void main() {
  RegisteredCommand command(
    String id, {
    List<ShortcutActivator> Function(TargetPlatform)? activators,
    bool enabled = true,
    void Function()? onRun,
  }) {
    return RegisteredCommand(
      id: id,
      scope: CommandScope.app,
      label: (l10n) => id,
      activators: activators,
      enabled: () => enabled,
      run: (_) async => onRun?.call(),
    );
  }

  final activator = SingleActivator(LogicalKeyboardKey.keyR, control: true);

  testWidgets('a disabled command still consumes its chord', (tester) async {
    var outerSawKey = false;
    var ran = false;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // The observer sits OUTSIDE the command layer: a disabled
        // command's chord must not fall through to farther scopes
        // (nearer scopes win by Flutter's focus precedence regardless).
        // CallbackShortcuts pairs the intent with its own action, so the
        // detector actually fires if the chord escapes the command layer
        // — a bare Shortcuts mapping could never invoke it.
        home: CallbackShortcuts(
          bindings: {activator: () => outerSawKey = true},
          child: CommandChordScope(
            commands: [
              command(
                'x',
                activators: (_) => [activator],
                enabled: false,
                onRun: () => ran = true,
              ),
            ],
            child: const Scaffold(
              body: Focus(autofocus: true, child: SizedBox.expand()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    // The command layer owns the chord even when the command is
    // disabled: outer scopes never see it, and the command never runs.
    expect(outerSawKey, isFalse);
    expect(ran, isFalse);
  });

  testWidgets('an enabled command\'s chord runs it', (tester) async {
    var ran = false;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CommandChordScope(
          commands: [
            command(
              'x',
              activators: (_) => [activator],
              onRun: () => ran = true,
            ),
          ],
          child: const Scaffold(
            body: Focus(autofocus: true, child: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(ran, isTrue);
  });

  testWidgets('duplicate activators fail the registration assert', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CommandChordScope(
          commands: [
            command('a', activators: (_) => [activator]),
            command('b', activators: (_) => [activator]),
          ],
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );

    // The registration assert trips in debug builds; release keeps the
    // documented later-command-wins behavior.
    expect(tester.takeException(), isA<AssertionError>());
  });

  testWidgets('select-all and invert act on the active pane only', (
    tester,
  ) async {
    final lanes = controller_test.FakePaneLanes();
    final leftChannel = controller_test.FakePaneChannel('/home/tester');
    leftChannel.listings['/home/tester'] = [_entry('a'), _entry('b')];
    final rightChannel = controller_test.FakePaneChannel('/home/tester');
    rightChannel.listings['/home/tester'] = [
      _entry('x'),
      _entry('y'),
      _entry('z'),
    ];
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final leftStrip = testPaneStrip(left);
    final rightStrip = testPaneStrip(right);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);

    // Negative enablement first: right is the active pane and has no
    // listing yet, so its verbs are disabled — the command must report
    // disabled even once the inactive pane would be verb-enabled.
    workspace.setActivePane(rightStrip);
    final earlyCommands = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    );
    expect(
      earlyCommands
          .firstWhere((c) => c.id == kEditSelectAllCommandId)
          .enabled(),
      isFalse,
      reason: 'enablement follows the ACTIVE pane, not any pane',
    );
    expect(
      earlyCommands
          .firstWhere((c) => c.id == kEditInvertSelectionCommandId)
          .enabled(),
      isFalse,
    );

    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();
    lanes.nextLocalChannel = rightChannel;
    await right.openLocalHome();
    // Flush the fake listing microtasks (a Future.delayed never fires in
    // the widget test's fake-async zone).
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    final context = tester.element(find.byType(Scaffold));

    final commands = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    );
    final selectAll = commands.firstWhere(
      (command) => command.id == kEditSelectAllCommandId,
    );
    final invert = commands.firstWhere(
      (command) => command.id == kEditInvertSelectionCommandId,
    );

    // Right is the active pane: both commands act on it alone.
    workspace.setActivePane(rightStrip);
    expect(selectAll.enabled(), isTrue);
    await selectAll.run(context);
    await tester.pump();
    expect(right.selectedCount, 3);
    expect(left.selectedCount, 0);

    await invert.run(context);
    await tester.pump();
    expect(right.selectedCount, 0);
    expect(left.selectedCount, 0);

    // Enablement tracks the active pane's verb state, not any pane's.
    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();
    await tester.pump();
    workspace.setActivePane(leftStrip);
    expect(selectAll.enabled(), isTrue);
    await selectAll.run(context);
    await tester.pump();
    expect(left.selectedCount, 2);
    expect(right.selectedCount, 0, reason: 'the inactive pane never changes');

    // The distinguishing case: the ACTIVE pane's verbs fail while the
    // inactive pane stays verb-enabled — an any-pane OR gate would
    // still report enabled here.
    leftChannel.listingFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.permissionDenied,
      operation: 'list',
      message: 'Denied',
    );
    left.refresh();
    await tester.pump();
    expect(workspace.activePane, leftStrip);
    expect(left.verbsEnabled, isFalse);
    expect(right.verbsEnabled, isTrue);
    expect(selectAll.enabled(), isFalse);
    expect(invert.enabled(), isFalse);
  });

  testWidgets('quick select is registered, pane-scoped, and resolves the '
      'active pane at invocation', (tester) async {
    final lanes = controller_test.FakePaneLanes();
    final leftChannel = controller_test.FakePaneChannel('/home/tester');
    leftChannel.listings['/home/tester'] = [_entry('a')];
    final rightChannel = controller_test.FakePaneChannel('/srv/home');
    rightChannel.listings['/srv/home'] = [_entry('x')];
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final leftStrip = testPaneStrip(left);
    final rightStrip = testPaneStrip(right);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);

    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();
    lanes.nextRemoteChannel = rightChannel;
    await right.connectRemote(_remoteBookmark());
    await tester.pump();

    final quickSelect = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    ).firstWhere((c) => c.id == kSelectionQuickSelectCommandId);

    // 02 §8.3's table: pane scope, ⌘E on macOS, Ctrl+E elsewhere.
    expect(quickSelect.scope, CommandScope.pane);
    expect(
      quickSelect.activators!(TargetPlatform.macOS),
      [
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true),
      ],
    );
    expect(
      quickSelect.activators!(TargetPlatform.linux),
      [
        const SingleActivator(LogicalKeyboardKey.keyE, control: true),
      ],
    );
    expect(
      quickSelect.activators!(TargetPlatform.windows),
      [
        const SingleActivator(LogicalKeyboardKey.keyE, control: true),
      ],
    );

    // Enablement follows the ACTIVE pane; running opens the field on
    // that pane alone.
    workspace.setActivePane(rightStrip);
    expect(quickSelect.enabled(), isTrue);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    await quickSelect.run(tester.element(find.byType(Scaffold)));
    expect(right.quickSelectActive, isTrue);
    expect(left.quickSelectActive, isFalse);
  });

  testWidgets('view.filter is registered, pane-scoped, and resolves the '
      'active pane at invocation', (tester) async {
    final lanes = controller_test.FakePaneLanes();
    final leftChannel = controller_test.FakePaneChannel('/home/tester');
    leftChannel.listings['/home/tester'] = [_entry('a')];
    final rightChannel = controller_test.FakePaneChannel('/srv/home');
    rightChannel.listings['/srv/home'] = [_entry('x')];
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final leftStrip = testPaneStrip(left);
    final rightStrip = testPaneStrip(right);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);

    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();
    lanes.nextRemoteChannel = rightChannel;
    await right.connectRemote(_remoteBookmark());
    await tester.pump();

    final filter = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    ).firstWhere((c) => c.id == kViewFilterCommandId);

    // 02 §8.3's table: pane scope, ⌘F on macOS, Ctrl+F elsewhere.
    expect(filter.scope, CommandScope.pane);
    expect(
      filter.activators!(TargetPlatform.macOS),
      [
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true),
      ],
    );
    expect(
      filter.activators!(TargetPlatform.linux),
      [
        const SingleActivator(LogicalKeyboardKey.keyF, control: true),
      ],
    );
    expect(
      filter.activators!(TargetPlatform.windows),
      [
        const SingleActivator(LogicalKeyboardKey.keyF, control: true),
      ],
    );

    // Enablement follows the ACTIVE pane; running opens the strip on
    // that pane alone.
    workspace.setActivePane(rightStrip);
    expect(filter.enabled(), isTrue);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    await filter.run(tester.element(find.byType(Scaffold)));
    expect(right.filterFieldOpen, isTrue);
    expect(left.filterFieldOpen, isFalse);

    // Re-resolution: switch the active pane and the same command object
    // opens the other pane's strip.
    workspace.setActivePane(leftStrip);
    await filter.run(tester.element(find.byType(Scaffold)));
    expect(left.filterFieldOpen, isTrue);
    expect(right.filterFieldOpen, isTrue,
        reason: 'the first open is per-pane state — it stays put');
  });

  testWidgets('the go.* path and history commands carry the §8.3 chords '
      'and §9 Go-menu slots', (tester) async {
    final lanes = controller_test.FakePaneLanes();
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('a')];
    channel.listings['/home/tester/a'] = [_entry('inner')];
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final leftStrip = testPaneStrip(left);
    final rightStrip = testPaneStrip(right);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);

    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await tester.pump();
    workspace.setActivePane(leftStrip);

    final commands = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    );
    RegisteredCommand byId(String id) =>
        commands.firstWhere((command) => command.id == id);

    final back = byId(kGoBackCommandId);
    final forward = byId(kGoForwardCommandId);
    final toFolder = byId(kGoToFolderCommandId);
    final editPath = byId(kGoEditPathCommandId);

    // 02 §8.3's table: ⌘[/⌘] on macOS, Alt+Left/Right elsewhere.
    expect(back.scope, CommandScope.pane);
    expect(
      back.activators!(TargetPlatform.macOS),
      [const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true)],
    );
    expect(
      back.activators!(TargetPlatform.linux),
      [const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true)],
    );
    expect(
      forward.activators!(TargetPlatform.macOS),
      [const SingleActivator(LogicalKeyboardKey.bracketRight, meta: true)],
    );
    expect(
      forward.activators!(TargetPlatform.windows),
      [const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true)],
    );
    // ⇧⌘G / Ctrl+Shift+G and ⌘L / Ctrl+L.
    expect(
      toFolder.activators!(TargetPlatform.macOS),
      [
        const SingleActivator(
          LogicalKeyboardKey.keyG,
          meta: true,
          shift: true,
        ),
      ],
    );
    expect(
      toFolder.activators!(TargetPlatform.linux),
      [
        const SingleActivator(
          LogicalKeyboardKey.keyG,
          control: true,
          shift: true,
        ),
      ],
    );
    expect(
      editPath.activators!(TargetPlatform.macOS),
      [const SingleActivator(LogicalKeyboardKey.keyL, meta: true)],
    );
    expect(
      editPath.activators!(TargetPlatform.windows),
      [const SingleActivator(LogicalKeyboardKey.keyL, control: true)],
    );

    // 10 §8's Go menu: Back 10, Forward 20, Enclosing 30, Home 40,
    // then the path-field section at 50/60.
    expect(back.menuPlacement?.menu, AppMenuId.go);
    expect(back.menuPlacement?.order, 10);
    expect(forward.menuPlacement?.order, 20);
    expect(toFolder.menuPlacement?.menu, AppMenuId.go);
    expect(toFolder.menuPlacement?.order, 50);
    expect(editPath.menuPlacement?.order, 60);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    final context = tester.element(find.byType(Scaffold));

    // Disabled at the trail's ends; enabled once a second entry exists.
    expect(back.enabled(), isFalse);
    expect(forward.enabled(), isFalse);
    left.navigate('/home/tester/a');
    await tester.pump();
    expect(back.enabled(), isTrue);
    expect(forward.enabled(), isFalse);
    await back.run(context);
    await tester.pump();
    expect(left.location?.path, '/home/tester');
    expect(forward.enabled(), isTrue);

    // The field commands open the editor on the ACTIVE pane only.
    expect(editPath.enabled(), isTrue);
    await editPath.run(context);
    expect(left.pathFieldOpen, isTrue);
    expect(left.pathFieldSeed, '/home/tester');
    expect(right.pathFieldOpen, isFalse);
    left.closePathField();
    await toFolder.run(context);
    expect(left.pathFieldSeed, isEmpty);
    left.closePathField();

    // An unbound active pane reports disabled — no location model to
    // edit or walk.
    workspace.setActivePane(rightStrip);
    expect(back.enabled(), isFalse);
    expect(editPath.enabled(), isFalse);
    expect(toFolder.enabled(), isFalse);
  });

  testWidgets('go.home browses the binding\'s home with ⇧⌘H / '
      'Ctrl+Shift+H from 10 §8\'s Go menu', (tester) async {
    final lanes = controller_test.FakePaneLanes();
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('a')];
    channel.listings['/home/tester/a'] = [_entry('inner')];
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final leftStrip = testPaneStrip(left);
    final rightStrip = testPaneStrip(right);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await tester.pump();
    workspace.setActivePane(leftStrip);

    final home = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    ).firstWhere((command) => command.id == kGoHomeCommandId);

    expect(home.scope, CommandScope.pane);
    expect(home.activators!(TargetPlatform.macOS), const [
      SingleActivator(LogicalKeyboardKey.keyH, meta: true, shift: true),
    ]);
    expect(home.activators!(TargetPlatform.linux), const [
      SingleActivator(LogicalKeyboardKey.keyH, control: true, shift: true),
    ]);
    expect(home.menuPlacement?.menu, AppMenuId.go);
    expect(home.menuPlacement?.order, 40);
    expect(home.menuPlacement?.group, 0);

    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    left.navigate('/home/tester/a');
    await tester.pump();
    expect(home.enabled(), isTrue);
    await home.run(context);
    await tester.pump();
    expect(left.location?.path, '/home/tester');

    // An unbound pane has no home to browse.
    workspace.setActivePane(rightStrip);
    expect(home.enabled(), isFalse);
  });

  testWidgets('file.rename is selection-scoped, opens the editor on '
      'the active pane\'s cursor row, and documents its §8.3 keys', (
    tester,
  ) async {
    final lanes = controller_test.FakePaneLanes();
    final leftChannel = controller_test.FakePaneChannel('/home/tester');
    leftChannel.listings['/home/tester'] = [_entry('a'), _entry('b')];
    final rightChannel = controller_test.FakePaneChannel('/srv/home');
    rightChannel.listings['/srv/home'] = [_entry('x')];
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final leftStrip = testPaneStrip(left);
    final rightStrip = testPaneStrip(right);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);

    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();
    lanes.nextRemoteChannel = rightChannel;
    await right.connectRemote(_remoteBookmark());
    await tester.pump();

    final rename = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    ).firstWhere((c) => c.id == kFileRenameCommandId);

    // 02 §8.3's table: a file-verb (selection) scope; Return on macOS,
    // F2 elsewhere — declared for menus, dispatched by the pane's focus
    // node (02 §8.2), never by the chord layer.
    expect(rename.scope, CommandScope.selection);
    expect(
      rename.activators!(TargetPlatform.macOS),
      [const SingleActivator(LogicalKeyboardKey.enter)],
    );
    expect(
      rename.activators!(TargetPlatform.linux),
      [const SingleActivator(LogicalKeyboardKey.f2)],
    );
    expect(
      rename.activators!(TargetPlatform.windows),
      [const SingleActivator(LogicalKeyboardKey.f2)],
    );
    // 02 §9's File menu: Rename follows Open in the file-verb group.
    expect(rename.menuPlacement?.menu, AppMenuId.file);
    expect(rename.menuPlacement?.order, 70);

    // Enablement follows the ACTIVE pane's cursor: no cursor, no verb.
    workspace.setActivePane(rightStrip);
    expect(rename.enabled(), isFalse);

    left.setCursorIndex(1);
    workspace.setActivePane(leftStrip);
    expect(rename.enabled(), isTrue);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    await rename.run(tester.element(find.byType(Scaffold)));
    expect(left.renameTarget?.name, 'b');
    expect(right.renameTarget, isNull,
        reason: 'the inactive pane never opens a session');
  });

  testWidgets('file.getInfo is selection-scoped, toggles the inspector\'s '
      'Info tab (D32), and documents its §8.3 keys', (tester) async {
    final lanes = controller_test.FakePaneLanes();
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('a'), _entry('b')];
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final leftStrip = testPaneStrip(left);
    final rightStrip = testPaneStrip(right);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);

    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await tester.pump();

    final getInfo = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    ).firstWhere((c) => c.id == kFileGetInfoCommandId);

    // 02 §8.3's table: selection scope; ⌘I on macOS, Alt+Enter
    // elsewhere.
    expect(getInfo.scope, CommandScope.selection);
    expect(
      getInfo.activators!(TargetPlatform.macOS),
      [const SingleActivator(LogicalKeyboardKey.keyI, meta: true)],
    );
    expect(
      getInfo.activators!(TargetPlatform.linux),
      [const SingleActivator(LogicalKeyboardKey.enter, alt: true)],
    );
    expect(
      getInfo.activators!(TargetPlatform.windows),
      [const SingleActivator(LogicalKeyboardKey.enter, alt: true)],
    );
    // 10 §8's File menu: Get Info leads its section, ahead of Rename
    // at 70.
    expect(getInfo.menuPlacement?.menu, AppMenuId.file);
    expect(getInfo.menuPlacement?.order, 65);
    expect(getInfo.menuPlacement?.group, 2);

    // D32: the Info tab follows the focused item and shows its own
    // empty state, so the verb is live whenever a browsing tab exists —
    // with or without a row to describe.
    workspace.setActivePane(rightStrip);
    expect(getInfo.enabled(), isTrue);
    workspace.setActivePane(leftStrip);
    expect(getInfo.enabled(), isTrue);
    left.setCursorIndex(1);
    expect(getInfo.enabled(), isTrue);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    final context = tester.element(find.byType(Scaffold));
    // The inspector opens on Info by default: the chord toggles it away
    // and back — window chrome, never a per-pane overlay.
    expect(workspace.inspectorHidden, isFalse);
    expect(workspace.inspectorTab, InspectorTab.info);
    await getInfo.run(context);
    expect(workspace.inspectorHidden, isTrue);
    await getInfo.run(context);
    expect(workspace.inspectorHidden, isFalse);
    expect(workspace.inspectorTab, InspectorTab.info);

    // From another tab it switches to Info rather than hiding.
    workspace.selectInspectorTab(InspectorTab.transfers);
    await getInfo.run(context);
    expect(workspace.inspectorHidden, isFalse);
    expect(workspace.inspectorTab, InspectorTab.info);
  });

  testWidgets('file.editBuiltIn is selection-scoped, opens the cursor row '
      'through the pane\'s editor seam, and documents its §8.3 keys', (
    tester,
  ) async {
    final lanes = controller_test.FakePaneLanes();
    final leftChannel = controller_test.FakePaneChannel('/home/tester');
    leftChannel.listings['/home/tester'] = [
      _entry('dir', type: RemoteFileType.directory),
      _entry('note.txt'),
      _entry('link.txt', type: RemoteFileType.symbolicLink),
    ];
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final leftStrip = testPaneStrip(left);
    final rightStrip = testPaneStrip(right);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);

    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();
    await tester.pump();

    final edit = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    ).firstWhere((c) => c.id == kFileEditBuiltInCommandId);

    // 02 §8.3's table: selection scope; ⌥⌘E on macOS, Ctrl+Alt+E
    // elsewhere.
    expect(edit.scope, CommandScope.selection);
    expect(
      edit.activators!(TargetPlatform.macOS),
      [const SingleActivator(LogicalKeyboardKey.keyE, meta: true, alt: true)],
    );
    expect(
      edit.activators!(TargetPlatform.linux),
      [
        const SingleActivator(
          LogicalKeyboardKey.keyE,
          control: true,
          alt: true,
        ),
      ],
    );
    expect(
      edit.activators!(TargetPlatform.windows),
      [
        const SingleActivator(
          LogicalKeyboardKey.keyE,
          control: true,
          alt: true,
        ),
      ],
    );
    // 02 §9's File menu: between Open (60) and Get Info (65) — order 63
    // leaves the unregistered Open With slot open.
    expect(edit.menuPlacement?.menu, AppMenuId.file);
    expect(edit.menuPlacement?.order, 63);
    expect(edit.menuPlacement?.group, 1);

    // Enablement needs the ACTIVE pane's cursor on a file or symlink
    // row (06 §4.2's gate): no cursor, the inactive pane, and a
    // directory row all stay disabled.
    workspace.setActivePane(rightStrip);
    expect(edit.enabled(), isFalse);
    workspace.setActivePane(leftStrip);
    expect(edit.enabled(), isFalse);
    left.setCursorIndex(0);
    expect(edit.enabled(), isFalse);
    left.setCursorIndex(2);
    expect(edit.enabled(), isTrue);
    // The distinguishing case: a valid cursor on the now-inactive left
    // pane must not enable the command.
    workspace.setActivePane(rightStrip);
    expect(edit.enabled(), isFalse,
        reason: 'cursor on the inactive pane does not enable the command');
    workspace.setActivePane(leftStrip);
    expect(edit.enabled(), isTrue);

    // run dispatches the cursor row through the strip's editor seam —
    // the same resolution the "Edit in Poltergeist" double-click
    // preference takes (06 §4.2).
    final opened = <RemoteFileEntry>[];
    left.builtInEditorOpen = (pane, entry) async => opened.add(entry);
    left.setCursorIndex(1);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    await edit.run(tester.element(find.byType(Scaffold)));
    expect(opened.map((e) => e.path), [left.entries[1].path]);
    expect(right.builtInEditorOpen, isNull,
        reason: 'the inactive pane never opens an editor');
  });

  testWidgets('go.open is selection-scoped, dispatches openEntry on the '
      'active pane\'s cursor row, and documents its §8.3 keys', (
    tester,
  ) async {
    final lanes = controller_test.FakePaneLanes();
    final leftChannel = controller_test.FakePaneChannel('/home/tester');
    leftChannel.listings['/home/tester'] = [
      _entry('a', type: RemoteFileType.directory),
      _entry('b'),
    ];
    leftChannel.listings['/home/tester/a'] = [_entry('inner')];
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final leftStrip = testPaneStrip(left);
    final rightStrip = testPaneStrip(right);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);

    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();
    await tester.pump();

    final open = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    ).firstWhere((c) => c.id == kGoOpenCommandId);

    // 02 §8.3's table: ⌘↓ and ⌘O on macOS, Enter elsewhere — declared
    // for menus; the bare Enter leg is dispatched by the pane's focus
    // node (02 §8.2), never by the chord layer.
    expect(open.scope, CommandScope.selection);
    expect(
      open.activators!(TargetPlatform.macOS),
      [
        const SingleActivator(LogicalKeyboardKey.arrowDown, meta: true),
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true),
      ],
    );
    expect(
      open.activators!(TargetPlatform.linux),
      [const SingleActivator(LogicalKeyboardKey.enter)],
    );
    expect(
      open.activators!(TargetPlatform.windows),
      [const SingleActivator(LogicalKeyboardKey.enter)],
    );
    // 02 §9's File menu: Open heads the file-verb group after the
    // (unregistered) New Folder/New File slots.
    expect(open.menuPlacement?.menu, AppMenuId.file);
    expect(open.menuPlacement?.order, 60);
    expect(open.menuPlacement?.group, 1);

    // Enablement follows the ACTIVE pane's cursor: no cursor, no verb.
    workspace.setActivePane(rightStrip);
    expect(open.enabled(), isFalse);

    left.setCursorIndex(0);
    workspace.setActivePane(leftStrip);
    expect(open.enabled(), isTrue);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );

    // 02 §2.6: a folder row navigates under every double-click action.
    await open.run(tester.element(find.byType(Scaffold)));
    await tester.pump();
    expect(left.location?.path, '/home/tester/a');
    expect(leftChannel.openCalls, isEmpty);

    // A file row follows the action — default Open launches through the
    // channel; the pane never launches a process itself.
    left.goUp();
    await tester.pump();
    left.setCursorIndex(1); // 'b' — a file
    await open.run(tester.element(find.byType(Scaffold)));
    await tester.pump();
    expect(leftChannel.openCalls, ['/home/tester/b']);
  });

  testWidgets('no chord fires while a text field holds focus', (
    tester,
  ) async {
    var ran = false;
    final fieldNode = FocusNode();
    final siblingNode = FocusNode();
    addTearDown(fieldNode.dispose);
    addTearDown(siblingNode.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CommandChordScope(
          commands: [
            command(
              'x',
              activators: (_) => [activator],
              onRun: () => ran = true,
            ),
          ],
          child: Scaffold(
            body: Column(
              children: [
                TextField(focusNode: fieldNode),
                Focus(
                  focusNode: siblingNode,
                  child: const SizedBox(height: 10),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 02 §8.2's field-first precedence: the field's own editing chords
    // win while it holds focus — the command must not intercept them.
    fieldNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(ran, isFalse);
    expect(fieldNode.hasFocus, isTrue);

    // Focus a plain sibling inside the scope: the same chord runs the
    // command again.
    siblingNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(ran, isTrue);
  });

  testWidgets('view.toggleHidden flips the active tab\'s hidden-file lens '
      'with Finder/GNOME chords and a checked View-menu row', (tester) async {
    final lanes = controller_test.FakePaneLanes();
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('.env'), _entry('a.txt')];
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final workspace = WorkspaceController(
      left: testPaneStrip(left),
      right: testPaneStrip(right),
    );
    addTearDown(workspace.dispose);
    final toggle = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    ).firstWhere((c) => c.id == kViewToggleHiddenCommandId);

    expect(toggle.scope, CommandScope.pane);
    expect(toggle.activators!(TargetPlatform.macOS), [
      const SingleActivator(
        LogicalKeyboardKey.period,
        meta: true,
        shift: true,
      ),
    ]);
    expect(toggle.activators!(TargetPlatform.linux), [
      const SingleActivator(LogicalKeyboardKey.keyH, control: true),
    ]);
    expect(toggle.menuPlacement?.menu, AppMenuId.view);
    // An unbound tab has no lens to flip.
    expect(toggle.enabled(), isFalse);

    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await tester.pump();
    expect(toggle.enabled(), isTrue);
    expect(toggle.checked!(), isFalse);
    expect(left.entries.map((e) => e.name), ['a.txt']);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    final context = tester.element(find.byType(Scaffold));
    await toggle.run(context);
    expect(left.showHidden, isTrue);
    expect(toggle.checked!(), isTrue);
    expect(left.entries.map((e) => e.name), ['.env', 'a.txt']);
    expect(right.showHidden, isFalse, reason: 'the active tab only');
    await toggle.run(context);
    expect(left.showHidden, isFalse);
  });

  testWidgets('view.sortBy is the column header\'s menu path: one row per '
      'column, checked on the sorted one', (tester) async {
    final lanes = controller_test.FakePaneLanes();
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('a.txt'), _entry('b.txt')];
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final workspace = WorkspaceController(
      left: testPaneStrip(left),
      right: testPaneStrip(
        PaneController(paneTabId: 'pane.right', lanes: lanes),
      ),
    );
    addTearDown(workspace.dispose);
    final sortBy = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    ).firstWhere((c) => c.id == kViewSortByCommandId);
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    final context = tester.element(find.byType(Scaffold));
    final l10n = AppLocalizations.of(context);
    expect(sortBy.menuPlacement?.menu, AppMenuId.view);
    final items = sortBy.submenuItems!(l10n);
    expect([for (final item in items) item.label(l10n)], [
      'Name',
      'Size',
      'Date Modified',
    ]);
    expect([for (final item in items) item.checked!()], [true, false, false]);

    await items[1].run(context);
    expect(left.sortKey, FileSortKey.size);
    expect(left.sortDirection, FileSortDirection.descending);
    expect(items[1].checked!(), isTrue);
    // The palette path flips the sorted column.
    await sortBy.run(context);
    expect(left.sortDirection, FileSortDirection.ascending);
  });

  testWidgets('selection.copyPath copies the selection, else the folder, '
      'and confirms through the pane notice', (tester) async {
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final lanes = controller_test.FakePaneLanes();
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('a.txt'), _entry('b.txt')];
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    final workspace = WorkspaceController(
      left: testPaneStrip(left),
      right: testPaneStrip(
        PaneController(paneTabId: 'pane.right', lanes: lanes),
      ),
    );
    addTearDown(workspace.dispose);
    final copy = buildPaneCommands(
      workspace: workspace,
      focusLeft: () {},
      focusRight: () {},
      swapFocus: () {},
    ).firstWhere((c) => c.id == kSelectionCopyPathCommandId);

    expect(copy.scope, CommandScope.selection);
    expect(copy.activators!(TargetPlatform.macOS), [
      const SingleActivator(LogicalKeyboardKey.keyC, meta: true, alt: true),
    ]);
    expect(copy.activators!(TargetPlatform.windows), [
      const SingleActivator(LogicalKeyboardKey.keyC, control: true, alt: true),
    ]);
    expect(copy.menuPlacement?.menu, AppMenuId.edit);
    expect(copy.enabled(), isFalse, reason: 'nothing to name yet');

    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    final context = tester.element(find.byType(Scaffold));

    // No selection: the folder itself (Finder's ⌥⌘C).
    await copy.run(context);
    expect(clipboard.last, '/home/tester');
    expect(left.notice, PaneNotice.pathCopied);

    left.selectAll();
    await copy.run(context);
    expect(clipboard.last, '/home/tester/a.txt\n/home/tester/b.txt');
    // Let the notice's auto-hide timer run out.
    await tester.pump(const Duration(seconds: 5));
  });
}

Bookmark _remoteBookmark() {
  final now = DateTime.utc(2026, 9, 12);
  return Bookmark(
    id: 'srv-1',
    kind: BookmarkKind.remotePath,
    label: 'web.example.com',
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 22,
        username: 'tester',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/srv/home',
    sortKey: 'k',
    createdAt: now,
    updatedAt: now,
  );
}

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
}) =>
    RemoteFileEntry(
      path: '/home/tester/$name',
      name: name,
      type: type,
    );
