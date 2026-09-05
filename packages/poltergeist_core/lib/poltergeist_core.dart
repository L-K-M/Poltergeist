/// Platform-agnostic core for Poltergeist.
///
/// The barrel exports only neutral types — today the connection layer plus
/// the re-exported `RemoteFileSystem` VFS; task and bookmark models join as
/// they land per the plan (03 §1). dartssh2 types stop inside
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
        AuthKind,
        AuthMethod,
        HostKey,
        HostKeyDecision,
        HostKeyPrompter,
        HostKeyVerdict,
        KeyboardInteractiveResponder,
        RemoteFileEntry,
        RemoteFileErrorKind,
        RemoteFileException,
        RemoteFileSystem,
        RemoteTransferCancellation,
        RemoteTransferProgress,
        ServerConfig,
        SshConnectException,
        SshConnectionLog,
        SshCredentials,
        TofuVerifier,
        remoteBasename,
        remoteJoin,
        remoteParent;

export 'src/connection/connection_manager.dart'
    show
        ConnectionManager,
        PaneChannel,
        PooledConnectionManager,
        ServerConnectionState,
        TransferChannelLease;
export 'src/connection/pool_key.dart' show PoolKey;
export 'src/connection/pool_policy.dart' show PoolPolicy;
export 'src/connection/resolved_credentials.dart'
    show CredentialOrigin, ResolvedSshCredentials;
export 'src/connection/ssh_transport.dart'
    show
        AuthChallengeRequiredError,
        ConnectPrompting,
        SftpChannel,
        SshTransport,
        SshTransportOpener,
        openDartSshTransport;

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
