// Pins the header chords against 10 §4's table (D32) on the registry
// the real shell wires with every seam that registers a command, and
// checks that no two commands claim one chord on any platform.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/bookmark_backup_service.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/ssh_config_import_setup.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/services/update_check_controller.dart';
import 'package:poltergeist_app/services/workspace_library.dart';
import 'package:poltergeist_app/services/workspace_list_store.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/shell/header_toolbar.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_app_transfer_queue.dart';
import '../../support/fake_bookmark_store.dart';
import '../../support/fake_ssh_config_source.dart';
import '../../support/fake_sync_backup.dart';
import '../../support/shell_commands.dart';
import '../../support/sync_harness.dart';

/// The real shell over fakes, with every seam that registers a menu row:
/// the transfer queue, ssh_config import, the bookmark backup, the
/// update check (Settings…), saved workspaces, and sync.
Future<void> _pumpShell(WidgetTester tester) async {
  final engine = session_test.FakeAppEngine();
  engine.localChannels.addAll([
    session_test.FakeAppBrowseChannel(homePath: '/home/tester'),
    session_test.FakeAppBrowseChannel(homePath: '/home/tester'),
  ]);
  addTearDown(engine.close);
  final queue = FakeAppTransferQueue();
  addTearDown(queue.close);

  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final scratch = Directory.systemTemp.createTempSync('pg-menu-tree-');
  addTearDown(() {
    try {
      scratch.deleteSync(recursive: true);
    } on FileSystemException {
      // Best-effort: a stuck handle must not mask the result.
    }
  });
  final navigatorKey = GlobalKey<NavigatorState>();
  final bookmarks = FakeBookmarkStore();
  final session = await startEngineSession(
    supportDirectoryPath: scratch.path,
    bookmarks: bookmarks,
    navigatorKey: navigatorKey,
    pinStore: InMemoryHostKeyStore(),
    incidentStore: InMemoryIncidentStore(),
    spawn: (config) async => engine,
  );
  addTearDown(session!.shutdown);

  // Built on the real loop: the store's writes never deliver to the
  // fake zone's microtask queue.
  late final WorkspaceLibrary workspaces;
  await tester.runAsync(() async {
    workspaces = WorkspaceLibrary(
      store: WorkspaceListStore(
        store: SettingsStore(path: p.join(scratch.path, 'settings.json')),
      ),
      bookmarks: bookmarks,
    );
    await workspaces.load();
  });

  var records = InMemorySyncRecordStore();
  final credentials = FakeSyncCredentialStore();
  final backup = BookmarkBackupService(
    credentials: credentials,
    retainedTokens: FakeRetainedSyncTokenStore(),
    enrollmentState: FakeSyncEnrollmentState(),
    records: records,
    resetRecords: () async => records = InMemorySyncRecordStore(),
    bookmarks: FakeSyncTrackingBookmarkStore(),
    hostKeys: InMemoryHostKeyStore(),
    pinVerdicts: InMemoryPinVerdictStore(),
    tripwires: InMemorySyncTripwireStore(),
    transportFactory: fakeTransportFactory(FakeSyncServer(), []),
    vaultKey: () async => credentials.vaultKey,
    servers: FakeSyncTrackingServerStore(),
    vaultStore: InMemoryVaultStore(),
  );

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildPoltergeistTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorKey: navigatorKey,
      home: WorkspaceShell(
        bookmarks: bookmarks,
        engineSession: session,
        transferQueue: queue,
        workspaces: workspaces,
        bookmarkBackup: backup,
        updateCheck: UpdateCheckController(),
        syncEnvironment: testSyncEnvironment(scratch),
        syncTasks: SyncQueueTasks(),
        sshConfigImport: SshConfigImportSetup(
          service: SshConfigImportService(
            homeDirectory: '/home/tester',
            source: FakeSshConfigSource(const {}),
            mintId: () => 'imported',
          ),
          bookmarks: bookmarks,
          configPath: '/home/tester/.ssh/config',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<ShortcutActivator> _chords(
  WidgetTester tester,
  String id,
  TargetPlatform platform,
) => shellCommand(tester, id).activators!(platform);

void main() {
  testWidgets('header chords follow 10 §4', (tester) async {
    await _pumpShell(tester);
    const mac = TargetPlatform.macOS;
    const linux = TargetPlatform.linux;

    // ⌃⌘S is the macOS sidebar standard; Ctrl+Alt+S stays elsewhere.
    expect(_chords(tester, kViewToggleSidebarCommandId, mac), const [
      SingleActivator(LogicalKeyboardKey.keyS, control: true, meta: true),
    ]);
    expect(_chords(tester, kViewToggleSidebarCommandId, linux), const [
      SingleActivator(LogicalKeyboardKey.keyS, control: true, alt: true),
    ]);

    // F5 / ⇧⌘C. A Mac laptop's F5 is a media key, so ⇧⌘C leads there:
    // it is the chord the tooltip and the native key equivalent show.
    expect(_chords(tester, kSelectionTransferToOtherPaneCommandId, mac), const [
      SingleActivator(LogicalKeyboardKey.keyC, meta: true, shift: true),
      SingleActivator(LogicalKeyboardKey.f5),
    ]);
    expect(
      _chords(tester, kSelectionTransferToOtherPaneCommandId, linux),
      const [
        SingleActivator(LogicalKeyboardKey.f5),
        SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true),
      ],
    );
    final l10n = AppLocalizationsEn();
    expect(
      commandTooltip(
        shellCommand(tester, kSelectionTransferToOtherPaneCommandId),
        l10n,
        mac,
      ),
      l10n.toolbarTooltipWithShortcut('Copy to Other Pane', '⇧⌘C'),
    );
    expect(
      commandTooltip(
        shellCommand(tester, kViewToggleSidebarCommandId),
        l10n,
        mac,
      ),
      l10n.toolbarTooltipWithShortcut('Show/Hide Sidebar', '⌃⌘S'),
    );
  });

  testWidgets('no two commands claim one chord on any platform', (
    tester,
  ) async {
    await _pumpShell(tester);
    for (final platform in const [
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    ]) {
      final owners = <ShortcutActivator, String>{};
      for (final command in shellCommands(tester)) {
        for (final chord
            in command.activators?.call(platform) ??
                const <ShortcutActivator>[]) {
          final previous = owners[chord];
          expect(
            previous,
            isNull,
            reason:
                '$chord is claimed by $previous and ${command.id} on '
                '${platform.name}',
          );
          owners[chord] = command.id;
        }
      }
    }
  });
}
