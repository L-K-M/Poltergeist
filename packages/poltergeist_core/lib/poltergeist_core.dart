/// Platform-agnostic core for Poltergeist.
///
/// The barrel exports only neutral types — today the connection layer, the
/// pinned bookmark model, and the vault/keystore plumbing types; task models
/// join as they land per the plan (03 §1). dartssh2 types stop inside
/// `src/connection/` and never reach callers — a property
/// `scripts/check-imports.sh` enforces for this repo's own sources; the
/// re-exported Séance types stay dartssh2-free only as long as the pinned
/// rev keeps them so (re-audit on every re-pin, docs/STATUS.md open item 3).
///
/// The `seance_core` re-exports are part of this package's public API and
/// move in lockstep with the pinned Séance rev (docs/STATUS.md open item 3):
/// consumers use these types via this barrel, never a direct
/// `package:seance_core/...` import.
library;

export 'package:seance_core/seance_core.dart'
    show
        Argon2Params,
        AuthKind,
        AuthMethod,
        Bookmark,
        BookmarkKind,
        BookmarkLocation,
        BookmarkServerRef,
        EmbeddedHostIdentity,
        HostKey,
        HostKeyDecision,
        HostKeyPrompter,
        HostKeyStore,
        HostKeyVerdict,
        ImportedHost,
        InMemoryHostKeyStore,
        InMemoryVaultStore,
        KeyboardInteractiveResponder,
        PreferredPane,
        Prober,
        ProbeStatus,
        RemoteFileEntry,
        RemoteFileType,
        RemoteFileErrorKind,
        RemoteFileException,
        RemoteFileSystem,
        RemoteTransferCancellation,
        RemoteTransferProgress,
        SavedSyncSpec,
        Secret,
        SecretKind,
        SecretVault,
        ServerColor,
        ServerConfig,
        ServerIcon,
        // Sync protocol types (04 §3): the record layer, the LWW rule both
        // ends share, and the transport seam the coordinator is driven over.
        ApiError,
        DecryptedRecord,
        EncryptedRecord,
        LocalRecordStore,
        LoginRequest,
        PreloginResponse,
        PullResponse,
        PushResponse,
        PushResult,
        RecordCodec,
        RecordKind,
        RegisterRequest,
        SyncApi,
        Lww,
        SshConfigImporter,
        SshConnectException,
        SshConnectionLog,
        SshCredentials,
        TofuVerifier,
        VaultCrypto,
        VaultKeys,
        VaultStore,
        expandHomePath,
        normalizeServerGroup,
        remoteBasename,
        remoteJoin,
        remoteParent,
        secureRandomBytes,
        serverGroupKey;

export 'src/bookmarks/bookmark_groups.dart'
    show BookmarkGroupSection, bookmarkGroupNames, groupBookmarks,
        kUngroupedBookmarkKey;
export 'src/bookmarks/bookmark_coordinator.dart'
    show
        ApplyReport,
        BookmarkCoordinator,
        HostKeyConflict,
        SyncRoundResult;
export 'src/bookmarks/bookmark_store.dart'
    show
        BookmarkRemovedChange,
        BookmarkRepository,
        BookmarkSavedChange,
        BookmarkStore,
        BookmarkStoreChange,
        BookmarkSyncTuple,
        BookmarkTooLargeException,
        FileBookmarkStore,
        SyncTrackingBookmarkStore,
        bookmarkPayloadCapBytes,
        bookmarkQuarantinePath;
export 'src/sync/persistent_record_store.dart'
    show
        PersistentLocalRecordStore,
        SyncCursorRejectedException,
        SyncRecordStore,
        recordStoreQuarantinePath;
export 'src/sync/record_crypto.dart' show RecordCrypto, isDecryptableSyncId;
export 'src/sync/enrollment.dart'
    show
        EnrollmentResult,
        KdfDowngradeException,
        RegistrationClosedException,
        SyncAccount,
        SyncAccountMode,
        SyncCredentialStore,
        SyncEnrollment,
        SyncEnrollmentApi,
        SyncEnrollmentException,
        SyncEnrollmentState,
        syncBackupPausedMessage,
        syncBackupPausedWayOutSeparate,
        syncBackupPausedWayOutShared,
        syncNoticeAccountAuthFailed,
        syncNoticePassphraseCheckFailed,
        syncPassphraseCheckFailedMessage,
        syncRegistrationClosedMessage;
export 'src/sync/seance_server_catalog.dart' show SeanceServerCatalog;
export 'src/sync/sync_verdicts.dart'
    show
        InMemoryPinVerdictStore,
        InMemorySyncTripwireStore,
        PinVerdictStore,
        SyncTripwireStore;
export 'src/bookmarks/sort_key.dart'
    show
        SortKeySpaceExhaustedException,
        compareBookmarkSortKeys,
        isValidSortKey,
        sortKeyBetween;
export 'src/browse/file_entry_sort.dart'
    show sortFileEntries, FileSortKey, FileSortDirection, DirectoryGrouping;
export 'src/browse/quick_select_query.dart' show QuickSelectQuery;
export 'src/connection/connection_manager.dart'
    show
        ConnectionManager,
        ConnectLogLine,
        PaneChannel,
        PooledConnectionManager,
        CredentialOrigin,
        ResolvedCredentials,
        ServerConnectionState,
        ServerStatus,
        TransferChannelLease;
export 'src/connection/credential_resolution.dart'
    show CredentialResolutionScope;
export 'src/connection/incident_store.dart'
    show
        FileIncidentStore,
        IncidentRecord,
        IncidentStore,
        InMemoryIncidentStore;
export 'src/connection/pool_key.dart' show PoolKey;
export 'src/connection/pool_policy.dart'
    show PoolPolicy, maxGlobalInFlightTransfers;
export 'src/connection/ssh_transport.dart'
    show
        AuthChallengeRequiredError,
        ConnectPrompting,
        SftpChannel,
        SshTransport,
        SshTransportOpener,
        openDartSshTransport;
export 'src/fs/local_file_system.dart'
    show
        LocalFileSystem,
        LocalCrossDeviceRenameException,
        LocalPathTypeChangedException;
export 'src/fs/local_fs_safety.dart'
    show
        ensureSafeLocalDirectory,
        replaceLocalFile,
        restoreOrphanedLocalBackups,
        validateLocalName,
        validatePathComponent;
export 'src/transfer/bandwidth_limiter.dart'
    show BandwidthLimiter, maxTransferChunkBytes;
export 'src/transfer/conflict_policy.dart'
    show
        ConflictAsk,
        ConflictDisposition,
        ConflictKeepBoth,
        ConflictMerge,
        ConflictPolicy,
        ConflictProceed,
        ConflictReplace,
        ConflictResolutionScope,
        ConflictSkip,
        PendingConflict,
        conflictMtimeTolerance,
        numberedConflictName,
        resolveTransferConflict,
        taskScopePolicy;
export 'src/transfer/recursive_walker.dart'
    show
        RecursiveWalker,
        WalkEntryEvent,
        WalkEvent,
        WalkItemKind,
        WalkListingClosedEvent,
        WalkListingFailedEvent,
        WalkNode,
        WalkPurpose,
        WalkRootFailedEvent;
export 'src/transfer/transfer_queue.dart'
    show
        TransferQueue,
        TransferQueueConflictEvent,
        TransferQueueEvent,
        TransferQueueItemEvent,
        TransferQueueOrderEvent,
        TransferQueueProgressEvent,
        TransferQueueTaskEvent,
        maxSurfacedPendingConflicts;
export 'src/transfer/transfer_task.dart'
    show
        ConflictResolution,
        DeleteDisposition,
        DestinationStat,
        FsLocation,
        ItemDisposition,
        LocalFsLocation,
        PlannedDirectory,
        PlannedFile,
        ResolvedConflictPolicy,
        ServerFsLocation,
        TransferItem,
        TransferItemState,
        TransferOperation,
        TransferPlan,
        TransferTask,
        TransferTaskSpec,
        TransferTaskState;
export 'src/transfer/trash_service.dart'
    show
        ChannelTrashBackend,
        DeleteConfirmation,
        DeleteRequest,
        GioTrashBackend,
        LocalTrashBackend,
        LocalTrashService,
        RemoteTrash,
        TrashChannelInvoker,
        TrashErrorKind,
        TrashException,
        TrashInvokeReply,
        TrashInvokeRequest,
        TrashProcessRunner,
        trashChannelInvokerFor,
        trashChannelMethod,
        trashChannelName,
        trashInvokeTimeout;
export 'src/transfer/transfer_journal.dart'
    show
        FileCompletedRecord,
        FileFailedRecord,
        ItemRemovedRecord,
        PlanEntryRecord,
        RestoredItemOutcome,
        RestoredPlanItem,
        RestoredTransferTask,
        ScanCompleteRecord,
        TaskEnqueuedRecord,
        TaskRemovedRecord,
        TaskStateRecord,
        TransferHistoryEntry,
        TransferJournalIo,
        TransferJournalRecord,
        TransferJournalReplay,
        TransferPersistence,
        transferHistoryFileName,
        transferHistoryLimit,
        transferJournalFileName,
        transferJournalSchemaVersion;
export 'src/transfer/file_transfer_persistence.dart'
    show
        FileTransferPersistence,
        journalCompactBytes,
        journalCompactFinishedTasks,
        journalFsyncEveryRecords,
        journalFsyncInterval;
export 'src/import/ssh_config_import.dart'
    show
        SshConfigFileSource,
        SshConfigImportLimitation,
        SshConfigImportPreview,
        SshConfigImportRow,
        SshConfigImportService,
        SshConfigUnresolvedInclude,
        SshConfigIncludeNote,
        SshConfigUnreadableException;
export 'src/engine/engine_client.dart'
    show EngineBrowseChannel, EngineClient, ProbeBridge, PromptBridge;
export 'src/engine/engine_host.dart' show EngineHost, engineMain;
export 'src/engine/local_file_opener.dart' show LocalFileOpener;
export 'src/engine/protocol.dart'
    show
        CloseBrowseChannelRequest,
        ConnectedServerIdsRequest,
        ConnectionLogEvent,
        CredentialPromptData,
        CredentialPromptReply,
        DirectoryListed,
        DirectoryWatchEvent,
        DirectoryWatchSignal,
        DisconnectServerRequest,
        BrowseChannelOpened,
        EngineAck,
        EngineConfig,
        EngineError,
        EnginePromptData,
        EnginePromptEvent,
        EnginePromptKind,
        EngineRequest,
        EngineResult,
        EngineEvent,
        HostKeyPinnedEvent,
        HostKeyPromptData,
        HostKeyPromptReply,
        IncidentRecordRemovedEvent,
        IncidentRecordStoredEvent,
        IncidentStoreEvent,
        KeyboardInteractivePromptData,
        KeyboardInteractivePromptReply,
        ListDirectoryRequest,
        OpenBrowseChannelRequest,
        OpenLocalBrowseChannelRequest,
        OpenLocalFileRequest,
        PromptDismissedEvent,
        PromptReply,
        PromptReplyRequest,
        ProbeActivity,
        ProbeStatusesEvent,
        RecoveryFailedEvent,
        RemoveBookmarkRequest,
        RenameEntryRequest,
        ResponseEvent,
        ServerIdsListed,
        ServerStateEvent,
        SetPermissionsRequest,
        SetProbeActivityRequest,
        SetProbeTargetsRequest,
        ShutdownRequest,
        TransferProgressEvent,
        TransferProgressBatchEvent,
        UnwatchLocalDirectoryRequest,
        UnwatchServerRequest,
        WatchLocalDirectoryRequest,
        WatchServerRequest,
        engineProtocolVersion;

/// The user-facing product name.
///
/// Deliberately plain ASCII: macOS codesign rejects accented file names in
/// bundle paths (Séance ships as ASCII `Seance.app` and renames after
/// signing for exactly this reason). Poltergeist avoids the whole dance by
/// keeping the name ASCII — `product_name_test.dart` guards the invariant.
const String productName = 'Poltergeist';

/// One-line description used by packaging metadata and about screens.
const String productTagline = 'The ghost that moves your files.';

/// Home of the source repository, referenced by packaging metadata.
const String productHomepage = 'https://github.com/L-K-M/Poltergeist';
