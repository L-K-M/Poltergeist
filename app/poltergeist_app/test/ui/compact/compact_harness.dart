import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/app_transfer_queue.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/local_volumes.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/ssh_config_import_setup.dart';
import 'package:poltergeist_app/services/sync_environment.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/compact/compact_posture.dart';
import 'package:poltergeist_app/ui/compact/compact_workspace.dart';
import 'package:poltergeist_app/ui/menus/app_menu_host.dart';
import 'package:poltergeist_app/ui/server_editor.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_app_transfer_queue.dart';
import '../../support/fake_bookmark_store.dart';
import '../../support/fake_ssh_config_source.dart';

/// The phone the compact tests run on: a 390 × 844 dp portrait screen.
const phoneSize = Size(390, 844);

final _stamp = DateTime.utc(2026, 9, 20, 9, 30);

/// A scripted file row.
RemoteFileEntry fileEntry(
  String parent,
  String name, {
  int size = 4200,
  DateTime? modified,
}) => RemoteFileEntry(
  path: '$parent/$name',
  name: name,
  type: RemoteFileType.file,
  size: size,
  modifiedAt: modified ?? _stamp,
);

/// A scripted folder row.
RemoteFileEntry folderEntry(String parent, String name, {DateTime? modified}) =>
    RemoteFileEntry(
      path: '$parent/$name',
      name: name,
      type: RemoteFileType.directory,
      modifiedAt: modified ?? _stamp,
    );

/// A saved server with an embedded identity (`deploy@<id>.example.com`).
Bookmark serverBookmark(String id, {String? label}) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: label ?? id,
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: '$id.example.com',
      port: 22,
      username: 'deploy',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/',
  sortKey: id,
  createdAt: _stamp,
  updatedAt: _stamp,
);

/// A local-folder favorite.
Bookmark folderFavorite(String id, String path, {String? label}) => Bookmark(
  id: id,
  kind: BookmarkKind.localFolder,
  label: label ?? id,
  localPath: path,
  sortKey: id,
  createdAt: _stamp,
  updatedAt: _stamp,
);

/// DEVICES as a phone lists them: nothing (the app's own storage is the
/// local pane), so the "This device" row stands in.
final class PhoneVolumes implements LocalVolumeSource {
  @override
  Future<List<LocalVolume>> list() async => const [];

  @override
  Future<List<String>> standardFolders() async => const [];

  @override
  String? get homeDirectory => '/home/deploy';

  @override
  Future<bool> isDirectory(String path) async => false;

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Future<bool> eject(LocalVolume volume) async => false;
}

/// A server editor that is never opened: its presence is what offers
/// "New Server…" (the shell gates the catalog verbs on the seam).
final class InertServerEditor extends ServerEditorDelegate {
  @override
  List<ServerConfig> get servers => const [];

  @override
  bool get syncConfigured => false;

  @override
  Color get themeSeed => const Color(0xFF3D8A78);

  @override
  Future<String?> pickIdentityFile() async => null;

  @override
  Future<Secret?> readSecret(String secretId) async => null;

  @override
  Future<void> save(ServerConfig config, {Secret? secret}) async {}

  @override
  Future<ConnectionTestResult> testConnection(
    ServerConfig config, {
    String? draftPassword,
    String? draftPrivateKey,
    String? draftKeyPassphrase,
    SshConnectionLog? log,
  }) async => const ConnectionTestResult(ok: true, summary: '', log: '');
}

/// The ssh_config import wired over an empty config, so its command (and
/// the Home verbs that run it) register.
SshConfigImportSetup emptySshConfigImport(BookmarkRepository bookmarks) =>
    SshConfigImportSetup(
      service: SshConfigImportService(
        homeDirectory: '/home/deploy',
        source: FakeSshConfigSource(const {}),
        mintId: () => 'imported',
      ),
      bookmarks: bookmarks,
      configPath: '/home/deploy/.ssh/config',
    );

/// The real shell over a fake engine, in the compact posture: two local
/// panes on `/home/deploy` (pane A with a small listing, pane B with a
/// backup folder) and one remote channel for server opens.
final class CompactHarness {
  CompactHarness({List<Bookmark>? bookmarks})
    : store = FakeBookmarkStore(
        bookmarks ??
            [
              folderFavorite(
                'docs',
                '/home/deploy/Documents',
                label: 'Documents',
              ),
              serverBookmark('demo', label: 'demo'),
              serverBookmark('backup', label: 'backup box'),
            ],
      ) {
    session_test.FakeAppBrowseChannel paneA() =>
        session_test.FakeAppBrowseChannel(homePath: '/home/deploy')
          ..listings['/home/deploy'] = [
            folderEntry('/home/deploy', 'Documents'),
            folderEntry('/home/deploy', 'Downloads'),
            folderEntry('/home/deploy', 'Music'),
            fileEntry('/home/deploy', 'notes.txt', size: 4200),
            fileEntry('/home/deploy', 'photo.jpg', size: 2400000),
            fileEntry('/home/deploy', 'report.pdf', size: 38000000),
            fileEntry('/home/deploy', 'site.tar.gz', size: 120000000),
          ]
          ..listings['/home/deploy/Documents'] = [
            folderEntry('/home/deploy/Documents', 'Invoices'),
            fileEntry('/home/deploy/Documents', 'plan.md', size: 1800),
          ];
    final left = paneA();
    final right = session_test.FakeAppBrowseChannel(homePath: '/home/deploy')
      ..listings['/home/deploy'] = [
        folderEntry('/home/deploy', 'backups'),
        fileEntry('/home/deploy', 'old.log', size: 91000),
      ];
    // The two startup panes, then spares for every later local open
    // (the "This device" row, a local favorite) — the fake engine hands
    // channels out first in, first out.
    engine.localChannels.addAll([
      left,
      right,
      for (var i = 0; i < 8; i++) paneA(),
    ]);
    leftChannel = left;
    rightChannel = right;
    engine.channel = session_test.FakeAppBrowseChannel(homePath: '/srv/www')
      ..listings['/srv/www'] = [
        folderEntry('/srv/www', 'assets'),
        folderEntry('/srv/www', 'logs'),
        fileEntry('/srv/www', 'index.html', size: 12000),
        fileEntry('/srv/www', 'deploy.sh', size: 900),
      ];
  }

  final engine = session_test.FakeAppEngine();
  final FakeBookmarkStore store;
  final queue = FakeAppTransferQueue();
  late final session_test.FakeAppBrowseChannel leftChannel;
  late final session_test.FakeAppBrowseChannel rightChannel;
  final navigatorKey = GlobalKey<NavigatorState>();
  EngineSession? session;

  /// Pumps the shell at [size] and settles the first listings.
  Future<void> pump(
    WidgetTester tester, {
    Size size = phoneSize,
    Brightness brightness = Brightness.light,
    ThemeData Function(ThemeData theme)? decorate,
    AppTransferQueue? transferQueue,
    bool settle = true,
    bool systemInsets = false,
    Widget Function(Widget app)? wrap,
    SyncEnvironment? syncEnvironment,
    SyncQueueTasks? syncTasks,
    bool serverEditor = false,
    bool sshConfigImport = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    if (systemInsets) {
      // An edge-to-edge Android phone: status bar above, gesture bar
      // below (logical px at DPR 1).
      tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
    }
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    addTearDown(engine.close);
    addTearDown(queue.close);
    final supportDir = Directory.systemTemp.createTempSync('pg-compact-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
      bookmarks: store,
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    addTearDown(session!.shutdown);
    ThemeData theme(Brightness b) {
      final base = buildPoltergeistTheme(b);
      return decorate == null ? base : decorate(base);
    }

    final app = MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WorkspaceShell(
        bookmarks: store,
        engineSession: session,
        transferQueue: transferQueue ?? queue,
        localVolumes: PhoneVolumes(),
        syncEnvironment: syncEnvironment,
        syncTasks: syncTasks,
        serverEditor: serverEditor ? InertServerEditor() : null,
        sshConfigImport: sshConfigImport ? emptySshConfigImport(store) : null,
      ),
    );
    await tester.pumpWidget(wrap == null ? app : wrap(app));
    await tester.pump();
    if (settle) await tester.pumpAndSettle();
  }

  /// The mounted compact surface's state.
  CompactWorkspaceState compact(WidgetTester tester) =>
      tester.state<CompactWorkspaceState>(
        find.byType(CompactWorkspace, skipOffstage: false),
      );

  WorkspaceController workspace(WidgetTester tester) => tester
      .widget<CompactWorkspace>(
        find.byType(CompactWorkspace, skipOffstage: false),
      )
      .workspace;

  /// The shown pane's listing controller.
  PaneController activePane(WidgetTester tester) =>
      workspace(tester).activeTabController!;

  /// Delivers one system back (the platform's popRoute) and settles.
  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }
}

/// A row of the compact listing, by its entry path.
Finder compactRow(String path) => find.byKey(ValueKey((CompactKey.row, path)));

/// The registry the shell rendered last.
AppMenuHost menuHost(WidgetTester tester) =>
    tester.widget<AppMenuHost>(find.byType(AppMenuHost));

/// Keeps an otherwise-unawaited future's error visible in a test.
void ignoreResult(Future<void> future) => unawaited(future);
