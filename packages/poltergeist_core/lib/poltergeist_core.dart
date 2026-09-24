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
        // D19/D23's link-only update check (07 §3.10): Séance's checker,
        // version compare, and info record — bound to this repo by
        // [poltergeistUpdateRepo] below.
        AppVersion,
        UpdateChecker,
        UpdateInfo,
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
        // The resolved mark a config's icon/emoji/image fields become (04
        // §7.2): the sidebar's catalog rows draw `server.mark` through the
        // ported appearance module.
        ServerMark,
        ServerGlyphMark,
        ServerEmojiMark,
        ServerImageMark,
        // The server editor's own vocabulary (04 §4.2, amended — the
        // writable catalog's add/edit surface): emoji/image normalization
        // and caps, the login-script normalizer, and the connection-test
        // seam the editor's Test button drives. (`uuidV4` stays out of the
        // barrel deliberately: it collides with the app's own minter in
        // services/uuid.dart, which the editor uses instead.)
        normalizeServerEmoji,
        normalizeLoginScript,
        kMaxServerIconImageBytes,
        runConnectionTest,
        liveHostAuthenticator,
        ConnectionTestResult,
        // Sync protocol types (04 §3): the record layer, the LWW rule both
        // ends share, and the transport seam the coordinator is driven over.
        ApiError,
        DecryptedRecord,
        EncryptedRecord,
        HttpSyncClient,
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
        normalizeServerCustomColor,
        normalizeServerGroup,
        remoteBasename,
        remoteJoin,
        remoteParent,
        secureRandomBytes,
        serverGroupKey;

export 'src/bookmarks/bookmark_groups.dart'
    show
        BookmarkGroupSection,
        bookmarkGroupNames,
        groupBookmarks,
        kUngroupedBookmarkKey;
export 'src/bookmarks/bookmark_coordinator.dart'
    show ApplyReport, BookmarkCoordinator, HostKeyConflict, SyncRoundResult;
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
export 'src/sync/server_store.dart'
    show
        FileServerConfigStore,
        ServerSyncTuple,
        SyncTrackingServerStore,
        serverStoreQuarantinePath;
export 'src/update/update_check.dart' show poltergeistUpdateRepo;
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
        SshHostKeyPreflight,
        SshTransport,
        SshTransportOpener,
        openDartSshTransport,
        preflightDartSshHostKey;
export 'src/fs/local_file_system.dart'
    show
        LocalFileSystem,
        LocalCrossDeviceRenameException,
        LocalPathTypeChangedException;
export 'src/fs/local_copy_pump.dart'
    show LocalCopyPump, platformLocalCopyPump, streamedLocalCopyPump;
export 'src/fs/local_fs_safety.dart'
    show
        ensureSafeLocalDirectory,
        replaceLocalFile,
        restoreOrphanedLocalBackups,
        restrictLocalPathPermissions,
        validateLocalName,
        validatePathComponent,
        windowsReservedName;
export 'src/checkout/managed_remote_file.dart'
    show
        ManagedRemoteFile,
        copyRemoteEntry,
        remoteFileEntryFromJson,
        remoteFileEntryToJson,
        sameRemoteSnapshot;
export 'src/checkout/managed_remote_file_store.dart'
    show ManagedRemoteFileStore, RecoveredCheckout, streamedFileSha256;
export 'src/checkout/managed_checkout_spec.dart'
    show ManagedCheckoutDirection, ManagedCheckoutSpec;
export 'src/checkout/checkout_manager.dart' show CheckoutManager;
export 'src/preview/preview_kinds.dart'
    show
        PreviewKind,
        defaultLargeDownloadThresholdBytes,
        defaultPreviewCacheCapacityBytes,
        previewCacheKey,
        previewExtension,
        previewImageKindCapBytes,
        previewKindCapBytes,
        previewKindForName,
        previewKindIsRenderable,
        previewPdfKindCapBytes,
        previewProduceSlotLimit,
        previewRawExtension,
        previewTextMaximumBytes,
        previewWindowsExecutableExtensions,
        sanitizePreviewExtension;
export 'src/preview/preview_text.dart'
    show PreviewTextContent, fileLooksLikeUtf8Text, loadPreviewText;
export 'src/preview/preview_cache.dart' show PreviewCache, PreviewCacheSlot;
export 'src/preview/preview_produce.dart'
    show
        PreviewByteGate,
        PreviewProduceSpec,
        PreviewProduceTicket,
        PreviewProducer,
        QueuePreviewProducer,
        TransferProducer;
export 'src/editor/built_in_text_document.dart'
    show
        BuiltInTextDocument,
        BuiltInEditorException,
        CheckoutLimitException,
        LineEnding,
        MaximumByteSink,
        builtInEditorMaximumBytes,
        loadBuiltInTextDocument,
        loadBuiltInTextDocumentDetails,
        resolveBuiltInEditorTarget,
        saveBuiltInTextDocument;
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
        ManagedCheckoutQueue,
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
    show
        EngineBrowseChannel,
        EngineClient,
        EngineVfsStream,
        ProbeBridge,
        PromptBridge;
export 'src/engine/engine_connection_manager.dart'
    show EngineConnectionManager, EngineRemoteFileSystem, ServerConfigSource;
export 'src/engine/engine_trash_backend.dart' show EngineTrashBackend;
export 'src/connection/leased_file_system.dart' show LeasedRemoteFileSystem;
export 'src/fs/content_digest.dart'
    show ContentDigestSource, remoteContentDigest;
export 'src/engine/engine_host.dart' show EngineHost, engineMain;
export 'src/engine/local_file_opener.dart'
    show LocalFileOpener, OpenerProcessRunner;
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
        CancelVfsStreamRequest,
        ChannelTarget,
        DownloadChunkEvent,
        DownloadStreamRequest,
        EngineTrashError,
        LeaseTarget,
        LeaseTransferChannelRequest,
        LocalTrashAvailableRequest,
        LocalTrashRequest,
        ReleaseTransferLeaseRequest,
        StreamCreditRequest,
        TransferLeaseGranted,
        TrashAvailability,
        TrashMoved,
        UploadAbortRequest,
        UploadChunkRequest,
        UploadEndRequest,
        UploadProgressEvent,
        UploadReadyEvent,
        UploadStreamRequest,
        VfsCanonicalize,
        VfsContentDigest,
        VfsCreateDirectory,
        VfsCreateEmptyFile,
        VfsCreateSymbolicLink,
        VfsDelete,
        VfsEntryResult,
        VfsListDirectory,
        VfsOp,
        VfsOpRequest,
        VfsReadSymbolicLink,
        VfsRename,
        VfsSetMode,
        VfsSetOwner,
        VfsSetTimes,
        VfsStat,
        VfsStringResult,
        VfsTarget,
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
