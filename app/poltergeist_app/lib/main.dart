import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show GlobalKey, ScaffoldMessengerState;
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'app.dart';
import 'services/app_preferences.dart';
import 'services/application_error_reporter.dart';
import 'services/bookmark_backup_service.dart';
import 'services/checkout_session.dart';
import 'services/desktop_window_lifecycle.dart';
import 'services/dock_progress.dart';
import 'services/drag_out_producer.dart';
import 'services/dynamic_secret_vault.dart';
import 'services/editor_registry_controller.dart';
import 'services/engine_session.dart';
import 'services/file_stores.dart';
import 'services/identity_audit_log.dart';
import 'services/identity_file_reader.dart';
import 'services/macos_toolbar_band_channel.dart';
import 'services/os_drag_out.dart' show platformDragOutBackend;
import 'services/probe_settings_store.dart';
import 'services/quit_guard.dart';
import 'services/recent_locations.dart';
import 'services/secure_master_key.dart';
import 'services/server_config_source.dart';
import 'services/server_editor_backend.dart';
import 'services/session_persistence.dart';
import 'services/session_state.dart';
import 'services/session_state_store.dart';
import 'services/settings_store.dart';
import 'services/ssh_config_import_setup.dart';
import 'services/sync_credentials.dart';
import 'services/sync_environment.dart';
import 'services/sync_queue_facade.dart';
import 'services/sync_transport.dart';
import 'services/sync_verdict_stores.dart';
import 'services/transfer_queue_session.dart';
import 'services/update_check_controller.dart';
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
  // The shared-mode server domain (04 §4.2, amended): local ServerConfig
  // rows plus their LWW tuples — the coordinator materializes pulled
  // records in and seals local edits out. Same lazy device-id binding as
  // the bookmark store, so unenrolled installs keep the clean shape.
  final servers = FileServerConfigStore(
    path: '${supportDirectory.path}${Platform.pathSeparator}servers.json',
    onError: errorReporter.report,
    syncDeviceId: () => syncEnrollmentState.cachedDeviceId,
  );
  // The credential vault: one FileVaultStore beside the settings file
  // feeds every consumer so its serialized-write discipline covers all
  // of them. DynamicSecretVault re-resolves the key per call —
  // enrollment's re-key swaps the keystore entry underneath long-lived
  // consumers like the prompt coordinator.
  final masterKeys = MasterKeyManager();
  final vaultStore = FileVaultStore(
    File('${supportDirectory.path}${Platform.pathSeparator}vault.json'),
  );
  // Settle an interrupted re-key before anything else reads the vault:
  // a crash between the keystore swap and the settle leaves .rekey
  // behind, and whichever sealed generation the installed key still
  // opens wins.
  try {
    final vaultKey = await masterKeys.probeKeystore();
    if (vaultKey != null) await vaultStore.settleRekey(vaultKey);
  } on Object catch (error, stack) {
    errorReporter.report(error, stack);
  }
  final dynamicVault = DynamicSecretVault(
    vaultStore,
    () async {
      final key = await masterKeys.probeKeystore();
      return key == null ? null : SecretVault(vaultStore, key);
    },
    onError: errorReporter.report,
  );
  final preferences = AppPreferences(store: settingsStore);
  // The external-editor registry (06 §4.1): one versioned document in
  // the shared settings.json — the Open With ▸ submenu and the remote
  // Open verb resolve through it. Tolerant decode: a malformed document
  // boots the default registry, never a startup failure.
  final editorRegistry = EditorRegistryController(
    store: settingsStore,
    errors: errorReporter,
  );
  try {
    await editorRegistry.load();
  } on Object catch (error, stack) {
    errorReporter.report(error, stack);
  }
  final paneRatio = await preferences.loadPaneRatio();
  final newTabTarget = await preferences.loadNewTabTarget();
  final doubleClickAction = await preferences.loadDoubleClickAction();
  final reconnectRestoredTabs =
      await preferences.loadReconnectRestoredTabs();
  // The activity panel's persisted chrome state (02 §1/§6): height,
  // per-direction throttle limits, and the auto-remove setting — all
  // plain settings keys beside the pane ratio.
  final sidebarWidth = await preferences.loadSidebarWidth();
  final inspectorWidth = await preferences.loadInspectorWidth();
  final downloadLimit = await preferences.loadDownloadLimit();
  final uploadLimit = await preferences.loadUploadLimit();
  final autoClearCompleted =
      await preferences.loadAutoClearCompletedTransfers();
  // The sidebar's persisted chrome state (02 §1/§4, D33): visibility
  // intent, the device-local collapsed-group keys, the row density, and
  // the PINNED shortlist.
  // The stage-1 drawer never lands here — it is recomputed from the
  // window size per launch.
  final sidebarHidden = await preferences.loadSidebarHidden();
  final sidebarCollapsedGroups =
      await preferences.loadSidebarCollapsedGroups();
  final sidebarDensity = await preferences.loadSidebarDensity();
  final sidebarPinnedServers = await preferences.loadSidebarPinnedServers();
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
  // Quick Open's Recents (02 §8.4): one versioned document inside the
  // shared settings.json, fed by the panes' location-commit hook and
  // flushed inside onExitRequested's bounded wait. Same fail-closed
  // decode as the session document — a malformed or newer-schema
  // document reports and yields an empty list, never a boot failure.
  final recentLocations = RecentLocationsStore(
    store: settingsStore,
    onError: errorReporter.report,
  );
  await errorReporter.guard(recentLocations.load);
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
    // An Android app process has no HOME, so `~` would resolve to "/~".
    // Without a storage permission the app's own documents directory is
    // the one local folder it can always list.
    fallbackHome: Platform.isAndroid
        ? (await getApplicationDocumentsDirectory()).path
        : null,
    navigatorKey: navigatorKey,
    scaffoldMessengerKey: scaffoldMessengerKey,
    vault: dynamicVault,
    onError: errorReporter.report,
  );

  // The bridged transfer lease (protocol v13, STATUS item 23): one
  // engine-backed ConnectionManager every remote byte path leases
  // through — the queue, the checkout manager, the preview producer, and
  // the sync endpoints. The config source answers what each lease dials;
  // the pulled catalog lookup binds once the backup service exists below.
  final serverConfigs = AppServerConfigSource(bookmarks: bookmarks);
  final transferConnections =
      engineSession?.transferConnections(serverConfigs);

  // The transfer queue (03 §4, D16): one real queue over the
  // app-support journal (03 §4.6) restores the crashed session's
  // survivors — journaled-paused stays paused, every other non-terminal
  // task replays queued behind the forced restore pause — and hands the
  // workspace shell's drop delegate, the activity panel, and the quit
  // guard their one shared seam. Remote endpoints lease engine-side;
  // an engine that failed to spawn leaves them failing honestly while
  // local work still runs. Local deletes trash through the engine (D8).
  final transferQueueSession = await startTransferQueue(
    supportDirectoryPath: supportDirectory.path,
    connections: transferConnections,
    localTrash: engineSession == null
        ? null
        : LocalTrashService.withBackend(engineSession.localTrash),
    onError: errorReporter.report,
  );

  // The 05 sync seams (M8): one shared environment — sync_state under
  // app support, sync_runs/ journals beside it, the enrollment device
  // id for runId prefixes — plus the activity-panel registry every
  // plan-view run reports through. The composite queue splices sync
  // task rows into the same AppTransferQueue seam the panel, drop
  // delegate, and quit guard already consume.
  final syncTasks = SyncQueueTasks();
  final syncEnvironment = SyncEnvironment.forSupportDirectory(
    supportDirectory.path,
    deviceId: () async => syncEnrollmentState.cachedDeviceId ?? 'local',
    connections: transferConnections,
    serverConfigs: serverConfigs,
  );
  final transferQueue = transferQueueSession?.queue;
  // D32 §11: Dock/taskbar progress while transfers run (macOS/Windows —
  // window_manager has no Linux progress surface). It stays silent until
  // the window is ready: on Windows an earlier setProgressBar crashes
  // the process natively (see DockProgressReporter).
  if (transferQueue != null && (Platform.isMacOS || Platform.isWindows)) {
    DockProgressReporter(
      queue: transferQueue,
      surface: const WindowManagerDockSurface(),
      surfaceReady: windowLifecycle.windowReady,
    );
  }
  final composedQueue = transferQueue == null
      ? null
      : CompositeAppTransferQueue(transferQueue, syncTasks);

  // 06 §5.3's preview cache + produce seam (M7): an LRU store under
  // app-support `preview-cache/` seeded with the persisted cap, and a
  // QueuePreviewProducer over the same composed queue every other
  // managed download rides (D14). A queue-less boot still previews
  // local files — only remote production needs the producer.
  final previewCacheCapacity =
      await preferences.loadPreviewCacheCapacityBytes();
  final previewThreshold = await preferences.loadPreviewThresholdBytes();
  final previewCache = PreviewCache(
    directory: Directory(
      '${supportDirectory.path}${Platform.pathSeparator}preview-cache',
    ),
    capacityBytes: previewCacheCapacity,
  );
  await errorReporter.guard(previewCache.open);
  final previewProducer = transferQueueSession == null
      ? null
      : QueuePreviewProducer(transferQueueSession.concreteQueue);
  // OS drag-out (00 D14's 2026-09-25 amendment): a remote file dropped
  // on Finder is produced straight into the folder the OS gave, over the
  // same produce hook, as an exclusive hop on its own slot budget (a
  // many-file drop cannot starve Quick Look). The backend is the
  // `poltergeist/dragout` channel on the desktop platforms.
  final dragOutProducer = previewProducer == null
      ? null
      : QueueDragOutProducer(previewProducer);

  // The managed-checkout pipeline (06 §3, M7): one CheckoutManager over
  // the app-support store, driving every byte through the queue session
  // above so checkout downloads and upload-on-save rows surface in the
  // activity panel. It leases through the same engine bridge the queue
  // does, so both answer remote access identically.
  final checkoutSession = transferQueueSession == null
      ? null
      : await startCheckoutSession(
          supportDirectoryPath: supportDirectory.path,
          queue: transferQueueSession.concreteQueue,
          connections: transferQueueSession.connections,
          onError: errorReporter.report,
        );

  // Settings → Backup (04 §3.3, M6): the bookmark-backup service over
  // the same seams the enrolled state renders — the OS keystore for the
  // token and vault key (never settings.json), the shared bookmark and
  // pin stores the coordinator materializes into, and the §3.1 record
  // store behind sync_records.json. The pin store is the engine
  // session's own when one spawned: two FileHostKeyStores over one path
  // would race their load-once caches.
  final syncRecordsPath =
      '${supportDirectory.path}${Platform.pathSeparator}sync_records.json';
  // Concrete type: the reset closure and the quarantine-path reader both
  // need PersistentLocalRecordStore members — an interface-typed binding
  // would hide that dependency behind a runtime cast.
  PersistentLocalRecordStore syncRecords = PersistentLocalRecordStore(
    path: syncRecordsPath,
    onError: errorReporter.report,
  );
  // The pin store the engine's mirror writes to, when an engine spawned —
  // the backup coordinator's TOFU truth and the editor's trial verifier
  // share the instance: two FileHostKeyStores over one path would race
  // their load-once caches.
  final pinStore = engineSession?.pinStore ??
      FileHostKeyStore(
        File(
          '${supportDirectory.path}${Platform.pathSeparator}'
          '$kPinStoreFileName',
        ),
      );
  final bookmarkBackup = BookmarkBackupService(
    credentials: SecureSyncCredentialStore(
      keys: masterKeys,
      vaultJournal: vaultStore,
    ),
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
    hostKeys: pinStore,
    pinVerdicts: SettingsPinVerdictStore(store: settingsStore),
    tripwires: SettingsSyncTripwireStore(store: settingsStore),
    transportFactory: httpSyncTransport,
    vaultKey: masterKeys.probeKeystore,
    servers: servers,
    vaultStore: vaultStore,
    settings: settingsStore,
    recordQuarantinePath: () => syncRecords.quarantinedPath,
  );
  // Durable-state reads are fail-safe by their own contract (corrupt
  // files quarantine, keystore failures read as unavailable), so a load
  // fault here reports and still leaves the service renderable rather
  // than dropping the feature — the enrolled state must never vanish
  // because one status key failed to decode.
  await errorReporter.guard(bookmarkBackup.load);
  // Leases for `serverConfigId` bookmarks resolve through the pulled
  // catalog, exactly like the sidebar's open path.
  serverConfigs.catalogLookup = (id) => bookmarkBackup.catalog?.byId(id);

  // The server editor's application layer (04 §4.2's management verbs):
  // catalog truth and sync writes through the backup service, credential
  // reads through the dynamic vault, the connection test over the real
  // transport with trial-only host-key pinning. The identity reader is a
  // second instance over the same append-only audit log the engine
  // session's own reader writes.
  final serverEditor = ServerEditorBackend(
    backups: bookmarkBackup,
    vault: dynamicVault,
    hostKeys: pinStore,
    identityReader: IdentityFileReader(
      IdentityAuditLog(
        File(
          '${supportDirectory.path}${Platform.pathSeparator}'
          '$kIdentityAuditLogFileName',
        ),
      ),
    ),
    navigatorKey: navigatorKey,
  );

  // The D19 link-only update check (07 §3.10, 01 §6): one plain GET of
  // GitHub's latest-release endpoint per launch, compared locally —
  // opt-out via Settings → General, and never a download. The checker
  // is Séance's UpdateChecker pinned to this repo.
  final updateCheck = UpdateCheckController(
    enabled: await preferences.loadUpdateChecksEnabled(),
    onEnabledChanged: preferences.saveUpdateChecksEnabled,
  );

  // macOS full screen hides the unified toolbar band the shell header
  // draws under (D32 §3); the runner reports the switch so the layout
  // follows it.
  final toolbarBand = Platform.isMacOS ? MacosToolbarBandChannel() : null;
  if (toolbarBand != null) errorReporter.observe(toolbarBand.start());

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
      recentLocations: recentLocations,
      engineSession: engineSession,
      bookmarkBackup: bookmarkBackup,
      serverEditor: serverEditor,
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
      transferQueue: composedQueue,
      checkoutSession: checkoutSession,
      editorRegistry: editorRegistry,
      initialSidebarWidth: sidebarWidth,
      onSidebarWidthChanged: preferences.saveSidebarWidth,
      initialInspectorWidth: inspectorWidth,
      onInspectorWidthChanged: preferences.saveInspectorWidth,
      initialDownloadLimit: downloadLimit,
      initialUploadLimit: uploadLimit,
      onDownloadLimitChanged: preferences.saveDownloadLimit,
      onUploadLimitChanged: preferences.saveUploadLimit,
      autoClearCompletedTransfers: autoClearCompleted,
      probeSettings: probeSettings,
      initialSidebarHidden: sidebarHidden,
      // Touch screens start without the inspector: on a tablet it takes
      // width the two panes need. The header toggle brings it back.
      initialInspectorHidden: Platform.isAndroid || Platform.isIOS,
      onSidebarHiddenChanged: preferences.saveSidebarHidden,
      onSidebarHiddenSaveError: errorReporter.report,
      initialSidebarCollapsedGroups: sidebarCollapsedGroups,
      // Both sinks write one change against the stored set, never the
      // sidebar's own set, which a failed launch read starts empty. The
      // sidebar reports their failures.
      onSidebarCollapsedGroupsChanged: preferences.setSidebarGroupCollapsed,
      initialSidebarDensity: sidebarDensity,
      onSidebarDensityChanged: (density) =>
          errorReporter.observe(preferences.saveSidebarDensity(density)),
      initialSidebarPinnedServers: sidebarPinnedServers,
      onSidebarPinnedServersChanged: preferences.setSidebarServerPinned,
      previewCache: previewCache,
      previewProducer: previewProducer,
      dragOutProducer: dragOutProducer,
      dragOutBackend: platformDragOutBackend(),
      initialPreviewThresholdBytes: previewThreshold,
      onPreviewCacheCapacityChanged:
          preferences.savePreviewCacheCapacityBytes,
      onPreviewThresholdChanged: preferences.savePreviewThresholdBytes,
      syncEnvironment: syncEnvironment,
      syncTasks: syncTasks,
      updateCheck: updateCheck,
      toolbarBand: toolbarBand,
      onContentSizeChanged: (size) {
        errorReporter.observe(windowLifecycle.calibrateMinimumSize(size));
      },
    ),
  );
  // The launch-time check fires beside the window bring-up — the
  // banner mounts whenever the answer lands, and any failure here
  // (no package info, no network) simply leaves it absent.
  unawaited(_checkForUpdate(updateCheck));
  await errorReporter.guard(windowLifecycle.show);
}

/// Look up the running version and ask the controller to compare it
/// against GitHub's latest release tag. Best-effort; a failure must
/// never affect startup.
Future<void> _checkForUpdate(UpdateCheckController updateCheck) async {
  try {
    final info = await PackageInfo.fromPlatform();
    await updateCheck.checkForUpdate(info.version);
  } catch (_) {
    // No version info / platform channel unavailable — skip silently.
  }
}
