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

    // 02 §9's Go menu: Back 10, Forward 20, Enclosing 30, then the
    // field commands at 50/60 (slot 40 stays open for Home).
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

RemoteFileEntry _entry(String name) => RemoteFileEntry(
  path: '/home/tester/$name',
  name: name,
  type: RemoteFileType.file,
);
