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
    final workspace = WorkspaceController(left: left, right: right);
    addTearDown(workspace.dispose);

    // Negative enablement first: right is the active pane and has no
    // listing yet, so its verbs are disabled — the command must report
    // disabled even once the inactive pane would be verb-enabled.
    workspace.setActivePane(right);
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
    workspace.setActivePane(right);
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
    workspace.setActivePane(left);
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
    expect(workspace.activePane, left);
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
    final workspace = WorkspaceController(left: left, right: right);
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
    workspace.setActivePane(right);
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
