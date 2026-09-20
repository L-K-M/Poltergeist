import 'dart:io';

import 'package:flutter/material.dart' show GlobalKey, ScaffoldMessengerState;
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'app.dart';
import 'services/app_preferences.dart';
import 'services/application_error_reporter.dart';
import 'services/bookmark_backup_service.dart';
import 'services/desktop_window_lifecycle.dart';
import 'services/engine_session.dart';
import 'services/file_stores.dart';
import 'services/probe_settings_store.dart';
import 'services/quit_guard.dart';
import 'services/secure_master_key.dart';
import 'services/session_persistence.dart';
import 'services/session_state.dart';
import 'services/session_state_store.dart';
import 'services/settings_store.dart';
import 'services/ssh_config_import_setup.dart';
import 'services/sync_credentials.dart';
import 'services/sync_transport.dart';
import 'services/sync_verdict_stores.dart';
import 'services/transfer_queue_session.dart';
import 'services/workspace_library.dart';
import 'services/workspace_list_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final supportDirectory = await getApplicationSupportDirectory();
  final settingsPath =
      '${supportDirectory.path}${Platform.pathSeparator}settings.json';
  final errorReporter = ApplicationErrorReporter();
  final settingsStore = SettingsStore(
    path: settingsPath,
    onError: errorReporter.report,
  );
  // One store instance for the whole app: the ssh_config import writes it and
  // the Connections surface lists from it, and two instances over one path
  // would race their serialized write tails. The syncDeviceId binding reads
  // the enrollment state's resolved id lazily — null until enrollment (or a
  // backup load) mints one, so non-sync installs keep §3.4's clean shape.
  final syncEnrollmentState =
      SettingsSyncEnrollmentState(store: settingsStore);
  final bookmarks = FileBookmarkStore(
    path: '${supportDirectory.path}${Platform.pathSeparator}bookmarks.json',
    onError: errorReporter.report,
    syncDeviceId: () => syncEnrollmentState.cachedDeviceId,
  );
  final preferences = AppPreferences(store: settingsStore);
  final paneRatio = await preferences.loadPaneRatio();
  final newTabTarget = await preferences.loadNewTabTarget();
  final doubleClickAction = await preferences.loadDoubleClickAction();
  final reconnectRestoredTabs =
      await preferences.loadReconnectRestoredTabs();
  // The activity panel's persisted chrome state (02 §1/§6): height,
  // per-direction throttle limits, and the auto-remove setting — all
  // plain settings keys beside the pane ratio.
  final activityPanelHeight = await preferences.loadActivityPanelHeight();
  final downloadLimit = await preferences.loadDownloadLimit();
  final uploadLimit = await preferences.loadUploadLimit();
  final autoClearCompleted =
      await preferences.loadAutoClearCompletedTransfers();
  // The sidebar's persisted chrome state (02 §1/§4): visibility intent
  // and the device-local collapsed-group keys. The stage-1 drawer never
  // lands here — it is recomputed from the window size per launch.
  final sidebarHidden = await preferences.loadSidebarHidden();
  final sidebarCollapsedGroups =
      await preferences.loadSidebarCollapsedGroups();
  // 02 §4's reachability probes read and write device-local facts through
  // the same settings.json — one instance shared with the preferences
  // facade so their serialized tails cannot interleave clobbering writes.
  final probeSettings = ProbeSettingsStore(store: settingsStore);
  // 02 §3's launch restoration: one versioned document inside
  // settings.json. A malformed or newer-schema document must not fail
  // startup — the app boots the default session and the document stays
  // on disk untouched (the store's read-before-write keeps a document
  // this build cannot decode from ever being overwritten).
  final sessionStore = SessionStateStore(store: settingsStore);
  SessionState? restoredSession;
  try {
    restoredSession = await sessionStore.load();
  } on Object catch (error, stack) {
    errorReporter.report(error, stack);
  }
  final sessionPersistence = SessionPersistence(
    store: sessionStore,
    onError: errorReporter.report,
  );
  // The saved-workspace list (02 §3, M5): the workspace favorites live
  // in the shared bookmark store — label, sidebar order, endpoints —
  // while each one's full tab-set snapshot stays device-local in its own
  // versioned settings.json document keyed by the favorite's id. The
  // same fail-closed rule as the session document applies: a malformed
  // or newer-schema document reports and boots an empty list, never
  // partially trusted and never overwritten unread.
  final workspaces = WorkspaceLibrary(
    store: WorkspaceListStore(store: settingsStore),
    bookmarks: bookmarks,
    errors: errorReporter,
  );
  try {
    await workspaces.load();
  } on Object catch (error, stack) {
    errorReporter.report(error, stack);
  }
  // One navigator key for the app, the session's coordinator, and the
  // quit guard, so dialogs render above whatever surface raised them.
  final navigatorKey = GlobalKey<NavigatorState>();
  final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  // 07 §3.5's quit gate: the intercepted close consults the guard, which
  // warns over live transfers and gates the destroy on the journal
  // flush. The workspace shell binds its queue seam onto the guard.
  final quitGuard = QuitGuard(
    navigatorKey: navigatorKey,
    onError: errorReporter.report,
  );
  final windowLifecycle = DesktopWindowLifecycle(
    preferences,
    onCloseFlush: sessionPersistence.flush,
    confirmClose: quitGuard.confirmClose,
    onError: errorReporter.report,
  );
  await errorReporter.guard(windowLifecycle.prepare);

  // The production engine spawns once at startup, not debug-gated: the
  // app-owned pin and incident stores seed it together (audit finding A),
  // its prompts answer on the root navigator, and its lifetime ends with
  // the app.
  final engineSession = await startEngineSession(
    supportDirectoryPath: supportDirectory.path,
    bookmarks: bookmarks,
    navigatorKey: navigatorKey,
    scaffoldMessengerKey: scaffoldMessengerKey,
    onError: errorReporter.report,
  );

  // The transfer queue (03 §4, D16): one real queue over the
  // app-support journal (03 §4.6) restores the crashed session's
  // survivors — journaled-paused stays paused, every other non-terminal
  // task replays queued behind the forced restore pause — and hands the
  // workspace shell's drop delegate, the activity panel, and the quit
  // guard their one shared seam. Remote endpoints fail honestly until
  // the engine protocol grows transfer verbs (docs/STATUS.md item 23);
  // local work runs for real.
  final transferQueueSession = await startTransferQueue(
    supportDirectoryPath: supportDirectory.path,
    onError: errorReporter.report,
  );

  // Settings → Backup (04 §3.3, M6): the bookmark-backup service over
  // the same seams the enrolled state renders — the OS keystore for the
  // token and vault key (never settings.json), the shared bookmark and
  // pin stores the coordinator materializes into, and the §3.1 record
  // store behind sync_records.json. The pin store is the engine
  // session's own when one spawned: two FileHostKeyStores over one path
  // would race their load-once caches.
  final masterKeys = MasterKeyManager();
  final syncRecordsPath =
      '${supportDirectory.path}${Platform.pathSeparator}sync_records.json';
  SyncRecordStore syncRecords = PersistentLocalRecordStore(
    path: syncRecordsPath,
    onError: errorReporter.report,
  );
  final bookmarkBackup = BookmarkBackupService(
    credentials: SecureSyncCredentialStore(keys: masterKeys),
    retainedTokens: SecureRetainedSyncTokenStore(keys: masterKeys),
    enrollmentState: syncEnrollmentState,
    records: syncRecords,
    // §4.4's wipe: delete the file and hand the service a fresh store —
    // a new instance starts with zeroed cursors, so highWaterSeq resets
    // with it.
    resetRecords: () async {
      final file = File(syncRecordsPath);
      if (await file.exists()) await file.delete();
      syncRecords = PersistentLocalRecordStore(
        path: syncRecordsPath,
        onError: errorReporter.report,
      );
      return syncRecords;
    },
    bookmarks: bookmarks,
    hostKeys: engineSession?.pinStore ??
        FileHostKeyStore(
          File(
            '${supportDirectory.path}${Platform.pathSeparator}'
            '$kPinStoreFileName',
          ),
        ),
    pinVerdicts: SettingsPinVerdictStore(store: settingsStore),
    tripwires: SettingsSyncTripwireStore(store: settingsStore),
    transportFactory: httpSyncTransport,
    vaultKey: masterKeys.probeKeystore,
    settings: settingsStore,
    recordQuarantinePath: () =>
        (syncRecords as PersistentLocalRecordStore).quarantinedPath,
  );
  // Durable-state reads are fail-safe by their own contract (corrupt
  // files quarantine, keystore failures read as unavailable), so a load
  // fault here reports and still leaves the service renderable rather
  // than dropping the feature — the enrolled state must never vanish
  // because one status key failed to decode.
  await errorReporter.guard(bookmarkBackup.load);

  runApp(
    PoltergeistApp(
      initialPaneRatio: paneRatio,
      newTabTarget: newTabTarget,
      doubleClickAction: doubleClickAction,
      reconnectRestoredTabs: reconnectRestoredTabs,
      restoredSession: restoredSession,
      sessionPersistence: sessionPersistence,
      bookmarks: bookmarks,
      workspaces: workspaces,
      engineSession: engineSession,
      bookmarkBackup: bookmarkBackup,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      quitGuard: quitGuard,
      sshConfigImport: buildSshConfigImportSetup(
        environment: Platform.environment,
        isMacOS: Platform.isMacOS,
        isWindows: Platform.isWindows,
        bookmarks: bookmarks,
      ),
      onPaneRatioChanged: preferences.savePaneRatio,
      onPaneRatioSaveError: errorReporter.report,
      transferQueue: transferQueueSession?.queue,
      initialActivityPanelHeight: activityPanelHeight,
      onActivityPanelHeightChanged:
          preferences.saveActivityPanelHeight,
      onActivityPanelHeightSaveError: errorReporter.report,
      initialDownloadLimit: downloadLimit,
      initialUploadLimit: uploadLimit,
      onDownloadLimitChanged: preferences.saveDownloadLimit,
      onUploadLimitChanged: preferences.saveUploadLimit,
      autoClearCompletedTransfers: autoClearCompleted,
      probeSettings: probeSettings,
      initialSidebarHidden: sidebarHidden,
      onSidebarHiddenChanged: preferences.saveSidebarHidden,
      onSidebarHiddenSaveError: errorReporter.report,
      initialSidebarCollapsedGroups: sidebarCollapsedGroups,
      onSidebarCollapsedGroupsChanged: (keys) => errorReporter.observe(
        preferences.saveSidebarCollapsedGroups(keys),
      ),
      onContentSizeChanged: (size) {
        errorReporter.observe(windowLifecycle.calibrateMinimumSize(size));
      },
    ),
  );
  await errorReporter.guard(windowLifecycle.show);
}
