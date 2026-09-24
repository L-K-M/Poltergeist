// The sync command registrations (M8, 05 §9 / 02 §8.3/§9 plus §2.1's
// rsync export): ids, ⌥⌘Y / Ctrl+Alt+Y activators, Commands-menu
// ordering, enabled predicates, and run delegation.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/sync/sync_commands.dart';

import '../../support/test_panes.dart';

WorkspaceController _workspace() => WorkspaceController(
  left: testPaneStrip(PaneController(paneTabId: 'pane.left')),
  right: testPaneStrip(PaneController(paneTabId: 'pane.right')),
);

void main() {
  testWidgets('registers the 05 §9 verbs with their §8.3 chords',
      (tester) async {
    final workspace = _workspace();
    addTearDown(workspace.dispose);
    var synchronizeCalls = 0;
    var newSavedCalls = 0;
    var copyRsyncCalls = 0;
    var enabled = true;
    final commands = buildSyncCommands(
      workspace: workspace,
      synchronizeEnabled: () => enabled,
      savedSyncEnabled: () => enabled,
      copyRsyncEnabled: () => enabled,
      synchronizePanes: (_) => synchronizeCalls++,
      newSavedSync: (_) => newSavedCalls++,
      copyRsync: (_) => copyRsyncCalls++,
    );

    final synchronize = commands.firstWhere(
      (c) => c.id == kSyncSynchronizePanesCommandId,
    );
    final newSaved = commands.firstWhere(
      (c) => c.id == kSyncNewSavedSyncCommandId,
    );
    final copyRsync = commands.firstWhere(
      (c) => c.id == kSyncCopyRsyncCommandId,
    );

    // ⌥⌘Y on macOS, Ctrl+Alt+Y elsewhere (02 §8.3).
    expect(
      synchronize.activators?.call(TargetPlatform.macOS),
      contains(
        const SingleActivator(
          LogicalKeyboardKey.keyY,
          meta: true,
          alt: true,
        ),
      ),
    );
    expect(
      synchronize.activators?.call(TargetPlatform.linux),
      contains(
        const SingleActivator(
          LogicalKeyboardKey.keyY,
          control: true,
          alt: true,
        ),
      ),
    );
    // New Saved Sync and Copy as rsync Command carry no chord —
    // menu/palette (and, for the latter, the plan view's action bar).
    expect(newSaved.activators, isNull);
    expect(copyRsync.activators, isNull);

    // 02 §9's Commands table: Synchronize sits between the transfer
    // block and Calculate Folder Sizes; New Saved Sync right under it;
    // the rsync export follows inside the sync block (05 §2.1).
    expect(synchronize.menuPlacement?.menu, AppMenuId.server);
    expect(synchronize.menuPlacement?.order, 30);
    expect(newSaved.menuPlacement?.order, 35);
    expect(copyRsync.menuPlacement?.menu, AppMenuId.server);
    expect(copyRsync.menuPlacement?.order, 37);

    // Enabled predicates delegate to the shell's checks.
    expect(synchronize.enabled(), isTrue);
    enabled = false;
    expect(synchronize.enabled(), isFalse);
    expect(newSaved.enabled(), isFalse);
    expect(copyRsync.enabled(), isFalse);
    enabled = true;

    // Runs reach the delegates.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    final context = tester.element(find.byType(Scaffold));
    await synchronize.run(context);
    await newSaved.run(context);
    await copyRsync.run(context);
    expect(synchronizeCalls, 1);
    expect(newSavedCalls, 1);
    expect(copyRsyncCalls, 1);
  });
}
