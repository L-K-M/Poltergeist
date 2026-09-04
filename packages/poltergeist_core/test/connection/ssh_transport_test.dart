import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
// The classifier is connection-module internal (not barrel-exported) — the
// test reaches it directly, like the module's own consumers do.
// ignore: implementation_imports
import 'package:poltergeist_core/src/connection/ssh_transport.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  test('a channel-open timeout classifies as disconnected, not unsupported',
      () {
    final error = classifySftpOpenFailure(
      TimeoutException('SFTP open timed out', const Duration(seconds: 15)),
      transportClosed: false,
    );

    // Transient: the pool's fallbacks and (later) reconnect must treat it
    // as retryable — `unsupported` means "this server cannot do SFTP".
    expect(error.kind, RemoteFileErrorKind.disconnected);
    expect(error.message, contains('timed out'));
  });

  test('a dead transport classifies as disconnected', () {
    final error = classifySftpOpenFailure(
      StateError('connection reset'),
      transportClosed: true,
    );

    expect(error.kind, RemoteFileErrorKind.disconnected);
  });

  test('other failures stay unsupported with the cause attached', () {
    final cause = FormatException('bad subsystem reply');

    final error = classifySftpOpenFailure(cause, transportClosed: false);

    expect(error.kind, RemoteFileErrorKind.unsupported);
    expect(error.cause, same(cause));
  });

  test('VFS exceptions pass through unchanged', () {
    const original = RemoteFileException(
      kind: RemoteFileErrorKind.permissionDenied,
      operation: 'open SFTP',
      message: 'denied',
    );

    expect(
      classifySftpOpenFailure(original, transportClosed: false),
      same(original),
    );
  });
}
