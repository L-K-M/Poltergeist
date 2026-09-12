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
        SshConfigImporter,
        SshConnectException,
        SshConnectionLog,
        SshCredentials,
        TofuVerifier,
        VaultCrypto,
        VaultKeys,
        VaultStore,
        expandHomePath,
        remoteBasename,
        remoteJoin,
        remoteParent,
        secureRandomBytes;

export 'src/browse/file_entry_sort.dart'
    show sortFileEntries, FileSortKey, FileSortDirection, DirectoryGrouping;
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
export 'src/connection/pool_policy.dart' show PoolPolicy;
export 'src/connection/ssh_transport.dart'
    show
        AuthChallengeRequiredError,
        ConnectPrompting,
        SftpChannel,
        SshTransport,
        SshTransportOpener,
        openDartSshTransport;
export 'src/fs/local_file_system.dart'
    show LocalFileSystem, LocalPathTypeChangedException;
export 'src/fs/local_fs_safety.dart'
    show
        ensureSafeLocalDirectory,
        replaceLocalFile,
        restoreOrphanedLocalBackups,
        validateLocalName,
        validatePathComponent;
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
export 'src/engine/protocol.dart'
    show
        CloseBrowseChannelRequest,
        ConnectedServerIdsRequest,
        ConnectionLogEvent,
        CredentialPromptData,
        CredentialPromptReply,
        DirectoryListed,
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
        PromptDismissedEvent,
        PromptReply,
        PromptReplyRequest,
        ProbeActivity,
        ProbeStatusesEvent,
        RecoveryFailedEvent,
        RemoveBookmarkRequest,
        ResponseEvent,
        ServerIdsListed,
        ServerStateEvent,
        SetProbeActivityRequest,
        SetProbeTargetsRequest,
        ShutdownRequest,
        TransferProgressEvent,
        TransferProgressBatchEvent,
        UnwatchServerRequest,
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
