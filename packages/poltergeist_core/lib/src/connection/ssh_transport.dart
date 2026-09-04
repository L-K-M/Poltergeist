import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart';
// The barrel deliberately hides the concrete adapter (UI must not see
// dartssh2), but the connection module IS its sanctioned consumer.
// ignore: implementation_imports
import 'package:seance_core/src/ssh/remote_file_system.dart';

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
  /// How the transport authenticated. Interactive kinds
  /// (`keyboardInteractive`, `promptedPassword`) cap the pool at one
  /// transport (growth rule 2).
  AuthKind get authKind;

  bool get isClosed;

  /// Opens one more SFTP channel on this transport.
  Future<SftpChannel> openChannel();

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
  String toString() => message;
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
/// on transport 1, so the only new reason it can fail is an interaction the
/// disabled prompting refused.
Future<SshTransport> openDartSshTransport({
  required ServerConfig config,
  required SshCredentials credentials,
  required TofuVerifier tofu,
  required HostKeyPrompter onHostKey,
  KeyboardInteractiveResponder? onKeyboardInteractive,
  required ConnectPrompting prompting,
  Duration timeout = const Duration(seconds: 15),
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

  _DartSshTransport(this._client, this.authKind);

  @override
  bool get isClosed => _client.isClosed;

  @override
  Future<SftpChannel> openChannel({
    Duration timeout = const Duration(seconds: 15),
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
      return _DartSftpChannel(DartSshRemoteFileSystem(sftp), sftp.close);
    } catch (error) {
      if (opening == null && pending != null) {
        // The open was abandoned before a channel existed (timeout).
        // Whatever arrives late on the abandoned open — immediately, if
        // it already has — is owned by nobody; close it.
        unawaited(pending.then<void>((lateChannel) async {
          try {
            await lateChannel.close();
          } on Object {
            // Swallow: best-effort hygiene for an abandoned open — its
            // failure must never surface as an unhandled async error.
          }
        }, onError: (Object _) {
          // The abandoned open failed on its own — nothing to close.
        }));
      }
      if (opening != null) {
        try {
          await opening.close();
        } on Object {
          // Swallow: the rethrow below carries the failure that matters.
        }
      }
      throw classifySftpOpenFailure(error, transportClosed: isClosed);
    }
  }

  @override
  Future<void> close() => _client.close();
}

class _DartSftpChannel implements SftpChannel {
  final RemoteFileSystem _fs;
  final Future<void> Function() _close;

  _DartSftpChannel(this._fs, this._close);

  @override
  RemoteFileSystem get fs => _fs;

  @override
  Future<void> close() => _close();
}
