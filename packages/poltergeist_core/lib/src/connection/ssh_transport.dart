import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart';
// The barrel deliberately hides the concrete adapter (UI must not see
// dartssh2), but the connection module IS its sanctioned consumer.
// ignore: implementation_imports
import 'package:seance_core/src/ssh/remote_file_system.dart';

import 'ssh_cleanup.dart';

/// One open SFTP channel on a transport, and the filesystem view it carries.
///
/// `RemoteFileSystem` has no close (it is a pure VFS interface, D3), so the
/// closable handle lives here: the pool closes channels without exposing
/// dartssh2 types to callers.
abstract interface class SftpChannel {
  RemoteFileSystem get fs;

  Future<void> close();
}

/// One authenticated SSH connection owned by a pool (03 §3.2). Every SFTP
/// channel — browse and transfer alike — is opened on a transport.
///
/// An interface, not the dartssh2 client itself, so pool tests run without
/// sockets (08 §3.2's "pool and lease logic without sockets" pattern).
abstract interface class SshTransport {
  /// Default channel-open budget when a caller does not specify one.
  static const Duration defaultOpenTimeout = Duration(seconds: 15);

  /// Keepalive silence ceiling: a ping that outlives it proves the
  /// transport dead. Matches the VFS adapter's operation timeout (30 s) —
  /// the longest silence a healthy server produces while still answering
  /// anything (03 §3.3).
  static const Duration pingOperationTimeout = Duration(seconds: 30);

  /// How the transport authenticated. Interactive kinds
  /// (`keyboardInteractive`, `promptedPassword`) cap the pool at one
  /// transport (growth rule 2).
  AuthKind get authKind;

  bool get isClosed;

  /// Both normal and error completion signal transport loss to the pool.
  Future<void> get done;

  /// Whether any VFS operation is outstanding on this transport's open
  /// channels — nested calls, streaming, and awaited cleanup included
  /// (03 §3.3). The pool skips keepalive while anything is in flight;
  /// the VFS interface itself is unchanged and unwrapped (D3).
  bool get hasActiveOperations;

  /// Opens one more SFTP channel on this transport. Each stage (channel
  /// open, handshake) is individually bounded by [timeout] — callers own
  /// the per-stage budget they are willing to spend on an open.
  Future<SftpChannel> openChannel({Duration timeout = defaultOpenTimeout});

  /// One keepalive roundtrip. Completes only when the server answers — it
  /// never times itself out: the caller owns the deadline
  /// ([pingOperationTimeout]) and treats its expiry as transport death.
  Future<void> ping();

  Future<void> close();
}

/// Whether a connect attempt may surface prompts to the user.
///
/// The first connect per pool runs [enabled] — one TOFU prompt, one
/// keyboard-interactive round, at most (growth rule 1). Every pool-growth
/// connect runs [disabled]: a background transport growth must never pop a
/// second 2FA prompt (growth rule 3 / D5).
enum ConnectPrompting { enabled, disabled }

/// Thrown by a [SshTransportOpener] whose prompting-disabled connect failed
/// because the server demanded interactive authentication.
///
/// The pool treats this as "growth is impossible without the user": the pool
/// is recorded interactive-capped (growth rule 2 applies from then on) and
/// the attempt falls back to sharing existing channels.
class AuthChallengeRequiredError implements Exception {
  final String message;

  /// The original connect failure (an `SshConnectException` carrying the
  /// attempt log), kept so growth failures stay diagnosable.
  final Object? cause;

  const AuthChallengeRequiredError(this.message, {this.cause});

  @override
  String toString() => cause == null ? message : '$message (cause: $cause)';
}

/// The pool's seam over seance_core's `openAuthenticatedClient` (03 §3.1):
/// everything up to but excluding a shell channel. Production passes
/// [openDartSshTransport]; tests inject a fake that records calls, prompts,
/// and credentials without sockets.
typedef SshTransportOpener = Future<SshTransport> Function({
  required ServerConfig config,
  required SshCredentials credentials,
  required TofuVerifier tofu,
  required HostKeyPrompter onHostKey,
  KeyboardInteractiveResponder? onKeyboardInteractive,
  required ConnectPrompting prompting,
  Duration timeout,
  SshConnectionLog? log,
});

/// Production opener: `openAuthenticatedClient` + a closable SFTP channel
/// factory.
///
/// Auth failures classify as [AuthChallengeRequiredError] only when
/// prompting is disabled: a first-connect auth failure is a plain user-facing
/// failure (wrong key, wrong password — its summarized message must reach
/// the user), while a growth connect already holds credentials that worked
/// on transport 1, so the expected new failure is an interaction the
/// disabled prompting refused. The signal is imperfect — any auth rejection
/// on a growth connect (a since-revoked key, fail2ban throttling of the
/// second connection) classifies identically — and the pool's
/// share-channels fallback keeps that case safe.
Future<SshTransport> openDartSshTransport({
  required ServerConfig config,
  required SshCredentials credentials,
  required TofuVerifier tofu,
  required HostKeyPrompter onHostKey,
  KeyboardInteractiveResponder? onKeyboardInteractive,
  required ConnectPrompting prompting,
  Duration timeout = SshTransport.defaultOpenTimeout,
  SshConnectionLog? log,
}) async {
  final attemptLog = log ?? SshConnectionLog();
  try {
    final (client, authKind) = await openAuthenticatedClient(
      config: config,
      credentials: credentials,
      tofu: tofu,
      onHostKey: onHostKey,
      // The opener is the enforcement point of "prompting disabled means no
      // auth prompts": even a caller that passed a responder gets none when
      // this connect must not interact. Host-key verification is
      // deliberately not suppressed — a changed key must surface to the
      // caller (the pool hard-blocks on it), never be silently bypassed.
      onKeyboardInteractive:
          prompting == ConnectPrompting.enabled ? onKeyboardInteractive : null,
      timeout: timeout,
      // The pool owns the idle-only keepalive policy (03 §3.3): disable
      // the opener's built-in timer so no second keepalive clock runs.
      keepAliveInterval: null,
      log: attemptLog,
    );

    return _DartSshTransport(client, authKind);
  } on SshConnectException catch (error) {
    if (prompting == ConnectPrompting.disabled &&
        error.cause is SSHAuthFailError) {
      throw AuthChallengeRequiredError(error.message, cause: error);
    }
    rethrow;
  }
}

/// Maps a channel-open failure to the VFS error funnel. Transient causes
/// (timeout, transport death) must stay `disconnected` — the pool's
/// fallbacks and (later) reconnect treat them as retryable, while
/// `unsupported` means "this server cannot do SFTP at all".
@visibleForTesting
RemoteFileException classifySftpOpenFailure(
  Object error, {
  required bool transportClosed,
}) {
  if (error is RemoteFileException) return error;

  if (error is TimeoutException) {
    return RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: 'open SFTP',
      message: 'Opening the SFTP channel timed out.',
      cause: error,
    );
  }

  if (transportClosed) {
    return RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: 'open SFTP',
      message: 'The SSH transport disconnected while SFTP was opening.',
      cause: error,
    );
  }

  return RemoteFileException(
    kind: RemoteFileErrorKind.unsupported,
    operation: 'open SFTP',
    message: 'Could not open SFTP on this server: $error',
    cause: error,
  );
}

class _DartSshTransport implements SshTransport {
  final SSHClient _client;

  @override
  final AuthKind authKind;

  /// Channels opened here and not yet closed — the keepalive aggregation
  /// set (03 §3.3). A channel unregisters at close entry: its closing
  /// window is the pool's pending-close count, not adapter activity.
  final List<_DartSftpChannel> _openChannels = [];

  _DartSshTransport(this._client, this.authKind);

  @override
  bool get isClosed => _client.isClosed;

  @override
  bool get hasActiveOperations =>
      _openChannels.any((channel) => channel._fileSystem.hasActiveOperations);

  @override
  Future<void> ping() => _client.ping();

  @override
  Future<void> get done => _client.done;

  @override
  Future<SftpChannel> openChannel({
    Duration timeout = SshTransport.defaultOpenTimeout,
  }) async {
    if (isClosed) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'open SFTP',
        message: 'The SSH transport is disconnected.',
      );
    }

    // Mirrors SshSession._openRemoteFileSystem: open, handshake, wrap. The
    // adapter's safety protocols (double-stat, CAS, sticky cancellation)
    // ride inside DartSshRemoteFileSystem, inherited verbatim per D3.
    SftpClient? opening;
    Future<SftpClient>? pending;
    try {
      // The timeout abandons the open but cannot cancel it: hold the
      // underlying future so a channel arriving after the timeout is
      // closed instead of leaking.
      pending = _client.sftp();
      opening = await pending.timeout(timeout);
      final sftp = opening;
      await sftp.handshake.timeout(timeout);
      final channel = _DartSftpChannel(
        this,
        DartSshRemoteFileSystem(sftp),
        sftp.close,
      );
      _openChannels.add(channel);
      return channel;
    } catch (error) {
      if (opening == null && pending != null) {
        // The open was abandoned before a channel existed (timeout).
        // Whatever arrives late on the abandoned open — immediately, if
        // it already has — is owned by nobody; close it.
        unawaited(pending.then<void>((lateChannel) {
          return closeSshResource(lateChannel.close);
        }, onError: (Object _) {
          // The abandoned open failed on its own — nothing to close.
        }));
      }
      if (opening != null) {
        await closeSshResource(opening.close, maxWait: timeout);
      }
      throw classifySftpOpenFailure(error, transportClosed: isClosed);
    }
  }

  @override
  Future<void> close() => closeSshResource(_client.close);
}

class _DartSftpChannel implements SftpChannel {
  final _DartSshTransport _owner;
  final DartSshRemoteFileSystem _fileSystem;
  final Future<void> Function() _close;

  _DartSftpChannel(this._owner, this._fileSystem, this._close);

  @override
  RemoteFileSystem get fs => _fileSystem;

  @override
  Future<void> close() {
    _owner._openChannels.remove(this);
    return closeSshResource(_close);
  }
}
