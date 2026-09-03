/// Platform-agnostic core for Poltergeist.
///
/// The barrel exports only neutral types — today the connection layer plus
/// the re-exported `RemoteFileSystem` VFS; task and bookmark models join as
/// they land per the plan (03 §1). dartssh2 types stop inside
/// `src/connection/` and never reach callers.
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

export 'src/connection/connection_manager.dart';
export 'src/connection/pool_key.dart';
export 'src/connection/pool_policy.dart';
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
