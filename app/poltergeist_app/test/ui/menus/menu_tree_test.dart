// Pins the rendered menu tree per platform against 10 §8's table (D32)
// and the header chords against 10 §4's. The registry is the one the
// real shell wires with every seam that registers a menu row, so a row
// that goes missing, moves between sections, or changes its label or
// shortcut fails here — the §8.1 reachability test only asks whether a
// command has SOME menu path.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/bookmark_backup_service.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/shortcut_format.dart';
import 'package:poltergeist_app/services/ssh_config_import_setup.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/services/update_check_controller.dart';
import 'package:poltergeist_app/services/window_full_screen.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/services/workspace_library.dart';
import 'package:poltergeist_app/services/workspace_list_store.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/menus/menu_shortcut_hint.dart';
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

/// A divider between two sections of one menu.
const _divider = '---';

/// Records what PlatformMenuBar pushes, so the macOS branch runs on a
/// Linux test host (the default delegate's serialization asserts the real
/// platform for provided items).
final class _RecordingMenuDelegate extends PlatformMenuDelegate {
  List<PlatformMenuItem> menus = const [];

  @override
  void clearMenus() => menus = const [];

  @override
  void setMenus(List<PlatformMenuItem> topLevelMenus) => menus = topLevelMenus;

  @override
  bool debugLockDelegate(BuildContext context) => true;

  @override
  bool debugUnlockDelegate(BuildContext context) => true;
}

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

/// One pushed macOS menu as lines: `label chord`, `label ▸` for a
/// submenu, `<type>` for an AppKit-provided item, [_divider] between
/// sections.
List<String> _macLines(PlatformMenu menu) {
  final lines = <String>[];
  for (final member in menu.menus) {
    if (lines.isNotEmpty) lines.add(_divider);
    final items = member is PlatformMenuItemGroup ? member.members : [member];
    for (final item in items) {
      lines.add(switch (item) {
        PlatformProvidedMenuItem(:final type) => '<${type.name}>',
        PlatformMenu(:final label) => '$label ▸',
        _ => _line(
          item.label,
          item.shortcut is ShortcutActivator
              ? item.shortcut! as ShortcutActivator
              : null,
          TargetPlatform.macOS,
        ),
      });
    }
  }
  return lines;
}

String _line(String label, ShortcutActivator? chord, TargetPlatform platform) {
  final spelled = chord == null
      ? null
      : formatShortcutActivator(chord, platform);
  return spelled == null ? label : '$label $spelled';
}

/// The open ☰ submenu's rows, top to bottom, as the same lines: every
/// command row (a checkbox row renders a MenuItemButton too), every
/// nested submenu (unkeyed, unlike the top-level `menu.<id>` rows), and
/// the section dividers.
List<String> _openSubmenuLines(TargetPlatform platform) {
  final rows = <(double, String)>[];
  for (final element in find.byType(MenuItemButton).evaluate()) {
    final button = element.widget as MenuItemButton;
    final hint = button.trailingIcon;
    rows.add((
      _top(element),
      _line(
        (button.child! as Text).data!,
        hint is MenuShortcutHint ? hint.activator : null,
        platform,
      ),
    ));
  }
  for (final element in find.byType(SubmenuButton).evaluate()) {
    final button = element.widget as SubmenuButton;
    final key = button.key;
    if (key is ValueKey<String> && key.value.startsWith('menu.')) continue;
    rows.add((_top(element), '${(button.child! as Text).data!} ▸'));
  }
  for (final element
      in find
          .byWidgetPredicate((w) => w is Divider && w.height == 9)
          .evaluate()) {
    rows.add((_top(element), _divider));
  }
  rows.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final row in rows) row.$2];
}

/// Where [element] paints, for ordering rows that share a widget
/// instance (the const section dividers).
double _top(Element element) =>
    (element.renderObject! as RenderBox).localToGlobal(Offset.zero).dy;

/// 10 §8's File menu for Windows and Linux. Their two platform labels
/// differ only in the trash and file-manager names.
List<String> _desktopFile(TargetPlatform platform) {
  final windows = platform == TargetPlatform.windows;
  return [
    'New Tab Ctrl+T',
    'New Folder Ctrl+Shift+N',
    'New File Ctrl+Alt+N',
    _divider,
    'Open Enter',
    'Open With ▸',
    'Edit in Poltergeist Ctrl+Alt+E',
    'Quick Look Space',
    windows ? 'Show in Explorer' : 'Show in File Manager',
    _divider,
    'Get Info Alt+Enter',
    'Rename F2',
    'Duplicate Ctrl+D',
    _divider,
    'Copy to Other Pane F5',
    'Move to Other Pane F6',
    _divider,
    '${windows ? 'Move to Recycle Bin' : 'Move to Trash'} Del',
    'Delete Immediately… Shift+Del',
    _divider,
    'Reopen Closed Tab Ctrl+Shift+T',
    'Close Tab Ctrl+W',
    _divider,
    'Settings… Ctrl+,',
    'Quit',
  ];
}

const _desktopMenus = <AppMenuId, List<String>>{
  AppMenuId.edit: [
    'Select All Ctrl+A',
    'Invert Selection Ctrl+Shift+I',
    'Quick Select Ctrl+E',
    _divider,
    'Copy Path Ctrl+Alt+C',
    _divider,
    'Filter Ctrl+F',
    'Filter Sidebar Ctrl+Alt+F',
  ],
  AppMenuId.view: [
    'Show/Hide Sidebar Ctrl+Alt+S',
    'Hide Inspector Ctrl+Alt+I',
    'Show/Hide Second Pane Ctrl+Shift+D',
    _divider,
    'Info Ctrl+Alt+P',
    'Transfers Ctrl+Alt+A',
    'Alerts',
    _divider,
    'Show Hidden Files Ctrl+H',
    'Sort By ▸',
    _divider,
    'Refresh Ctrl+R',
    _divider,
    'Enter Full Screen',
  ],
  AppMenuId.go: [
    'Back Alt+Left',
    'Forward Alt+Right',
    'Enclosing Folder Alt+Up',
    'Home Ctrl+Shift+H',
    _divider,
    'Go to Folder… Ctrl+Shift+G',
    'Edit Path Ctrl+L',
    _divider,
    'Focus Left Pane Ctrl+Alt+Left',
    'Focus Right Pane Ctrl+Alt+Right',
    'Sync Browsing Ctrl+Alt+B',
    _divider,
    'Quick Open… Ctrl+Shift+P',
  ],
  AppMenuId.server: [
    'Connect… Ctrl+K',
    'Disconnect Ctrl+Shift+K',
    'Save to Servers…',
    _divider,
    'Synchronize… Ctrl+Alt+Y',
    'New Saved Sync…',
    'Copy as rsync Command',
    _divider,
    'Import from ssh config…',
    'Back up and sync…',
    _divider,
    'Add Current Folder to Favorites',
    'Save Workspace…',
    'Workspaces ▸',
    _divider,
    'Pause/Resume Transfers',
  ],
  AppMenuId.window: ['Next Tab Ctrl+Tab', 'Previous Tab Ctrl+Shift+Tab'],
  AppMenuId.help: [
    'Keyboard Shortcuts Ctrl+/',
    'Release Notes',
    'Report an Issue',
  ],
};

const _macMenus = <String, List<String>>{
  'Poltergeist': [
    '<about>',
    _divider,
    'Check for Updates…',
    'Settings… ⌘,',
    _divider,
    '<servicesSubmenu>',
    _divider,
    '<hide>',
    '<hideOtherApplications>',
    '<showAllApplications>',
    _divider,
    '<quit>',
  ],
  'File': [
    'New Tab ⌘T',
    'New Folder ⇧⌘N',
    'New File ⌥⌘N',
    _divider,
    'Open ⌘↓',
    'Open With ▸',
    'Edit in Poltergeist ⌥⌘E',
    // Space, Return, and F6 are unmodified: a native key equivalent
    // would steal typing, so the pane's own keys carry them.
    'Quick Look',
    'Show in Finder',
    _divider,
    'Get Info ⌘I',
    'Rename',
    'Duplicate ⌘D',
    _divider,
    'Copy to Other Pane ⇧⌘C',
    'Move to Other Pane',
    _divider,
    'Move to Trash ⌘⌫',
    'Delete Immediately… ⌥⌘⌫',
    _divider,
    'Reopen Closed Tab ⇧⌘T',
    'Close Tab ⌘W',
  ],
  'Edit': [
    'Select All ⌘A',
    'Invert Selection ⇧⌘I',
    'Quick Select ⌘E',
    _divider,
    'Copy Path ⌥⌘C',
    _divider,
    'Filter ⌘F',
    'Filter Sidebar ⌥⌘F',
  ],
  'View': [
    'Show/Hide Sidebar ⌃⌘S',
    'Hide Inspector ⌥⌘I',
    'Show/Hide Second Pane ⇧⌘D',
    _divider,
    'Info ⌥⌘P',
    'Transfers ⌥⌘A',
    'Alerts',
    _divider,
    'Show Hidden Files ⇧⌘.',
    'Sort By ▸',
    _divider,
    'Refresh ⌘R',
    _divider,
    '<toggleFullScreen>',
  ],
  'Go': [
    'Back ⌘[',
    'Forward ⌘]',
    'Enclosing Folder ⌘↑',
    'Home ⇧⌘H',
    _divider,
    'Go to Folder… ⇧⌘G',
    'Edit Path ⌘L',
    _divider,
    'Focus Left Pane ⌥⌘←',
    'Focus Right Pane ⌥⌘→',
    'Sync Browsing ⌥⌘B',
    _divider,
    'Quick Open… ⇧⌘P',
  ],
  'Server': [
    'Connect… ⌘K',
    'Disconnect ⇧⌘K',
    'Save to Servers…',
    _divider,
    'Synchronize… ⌥⌘Y',
    'New Saved Sync…',
    'Copy as rsync Command',
    _divider,
    'Import from ssh config…',
    'Back up and sync…',
    _divider,
    'Add Current Folder to Favorites',
    'Save Workspace…',
    'Workspaces ▸',
    _divider,
    'Pause/Resume Transfers',
  ],
  'Window': [
    '<minimizeWindow>',
    '<zoomWindow>',
    _divider,
    'Next Tab ⌃⇥',
    'Previous Tab ⌃⇧⇥',
    _divider,
    '<arrangeWindowsInFront>',
  ],
  'Help': ['Keyboard Shortcuts ⌘/', 'Release Notes', 'Report an Issue'],
};

/// A window whose full-screen flips are recorded, not performed.
final class _FakeFullScreen implements WindowFullScreen {
  _FakeFullScreen({required this.supported});

  @override
  final bool supported;

  @override
  bool isFullScreen = false;

  var toggles = 0;

  @override
  Future<void> toggle() async {
    toggles++;
    isFullScreen = !isFullScreen;
  }
}

List<ShortcutActivator> _chords(
  WidgetTester tester,
  String id,
  TargetPlatform platform,
) => shellCommand(tester, id).activators!(platform);

void main() {
  testWidgets('the macOS menu bar is 10 §8\'s table', (tester) async {
    final delegate = _RecordingMenuDelegate();
    final original = WidgetsBinding.instance.platformMenuDelegate;
    WidgetsBinding.instance.platformMenuDelegate = delegate;
    addTearDown(() => WidgetsBinding.instance.platformMenuDelegate = original);

    await _pumpShell(tester);

    final pushed = delegate.menus.cast<PlatformMenu>();
    expect(pushed.map((m) => m.label), _macMenus.keys);
    for (final menu in pushed) {
      expect(_macLines(menu), _macMenus[menu.label], reason: menu.label);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the ☰ main menu is 10 §8\'s table', (tester) async {
    const platform = TargetPlatform.linux;
    await _pumpShell(tester);

    final expected = {AppMenuId.file: _desktopFile(platform), ..._desktopMenus};
    await tester.tap(find.byKey(const ValueKey('menu.main')));
    await tester.pumpAndSettle();
    final l10n = AppLocalizationsEn();
    final titles = [
      for (final element in find.byType(SubmenuButton).evaluate())
        if ((element.widget.key as ValueKey<String>?)?.value.startsWith(
              'menu.',
            ) ??
            false)
          (element.widget as SubmenuButton).child,
    ];
    expect(
      [for (final title in titles) (title! as Text).data],
      [
        l10n.menuFile,
        l10n.menuEdit,
        l10n.menuView,
        l10n.menuGo,
        l10n.menuServer,
        l10n.menuWindow,
        l10n.menuHelp,
      ],
    );

    for (final entry in expected.entries) {
      await tester.tap(find.byKey(ValueKey('menu.${entry.key.name}')));
      await tester.pumpAndSettle();
      expect(_openSubmenuLines(platform), entry.value, reason: entry.key.name);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('the Windows ☰ main menu names the Recycle Bin and Explorer', (
    tester,
  ) async {
    await _pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('menu.main')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu.file')));
    await tester.pumpAndSettle();
    expect(
      _openSubmenuLines(TargetPlatform.windows),
      _desktopFile(TargetPlatform.windows),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

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

  testWidgets('Enter Full Screen registers where AppKit supplies none, and '
      'retitles once the window is full screen', (tester) async {
    final workspace = WorkspaceController(
      left: PaneTabsController(paneId: PaneTabsController.leftPaneId),
      right: PaneTabsController(paneId: PaneTabsController.rightPaneId),
    );
    addTearDown(workspace.dispose);
    List<RegisteredCommand> commands(WindowFullScreen window) =>
        buildShellCommands(
          workspace: workspace,
          dropDelegate: () => null,
          openConnect: () {},
          allCommands: () => const [],
          openUrl: (_) async {},
          fileOps: () => null,
          reportFailure: (_) {},
          locationLabel: (_) => '',
          fullScreen: window,
        );

    expect(
      commands(
        _FakeFullScreen(supported: false),
      ).where((c) => c.id == kViewToggleFullScreenCommandId),
      isEmpty,
    );

    final window = _FakeFullScreen(supported: true);
    final command = commands(
      window,
    ).singleWhere((c) => c.id == kViewToggleFullScreenCommandId);
    final l10n = AppLocalizationsEn();
    expect(command.label(l10n), 'Enter Full Screen');
    expect(command.menuPlacement?.menu, AppMenuId.view);

    await tester.pumpWidget(const SizedBox());
    await command.run(tester.element(find.byType(SizedBox)));
    expect(window.toggles, 1);
    expect(command.label(l10n), 'Exit Full Screen');
  });
}
