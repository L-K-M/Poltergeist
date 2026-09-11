// Ported from Séance app/seance_app/lib/services/app_services.dart @ 99a3585
// (_readIdentityFile/_auditIdentityRead, IdentityFileException); see docs/PORTS.md.
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';

import 'identity_audit_log.dart';

const _defaultAuditTimeout = Duration(seconds: 2);

/// Reads "reference, don't store" identity files for the credential prompt
/// (D18): expand `~` against the environment, read the key, and record every
/// attempt — success or failure — in the local audit log. Audit failures
/// never block connecting.
class IdentityFileReader {
  final IdentityAuditLog audit;
  final Map<String, String> environment;
  final Duration _auditTimeout;

  IdentityFileReader(
    this.audit, {
    Map<String, String>? environment,
    Duration? auditTimeout,
  }) : environment = environment ?? Platform.environment,
       _auditTimeout = auditTimeout ?? _defaultAuditTimeout;

  /// Returns the key material, or throws [IdentityFileReadException].
  Future<String> read({
    required String serverId,
    required String serverLabel,
    required String identityFilePath,
  }) async {
    final readPath = expandHomePath(identityFilePath, environment: environment);

    String pem;
    try {
      pem = await File(readPath).readAsString();
    } on Exception catch (error) {
      // Normalize decoder and argument failures without exposing arbitrary
      // exception text through the credential dialog.
      final (cause, kind) = error is FileSystemException
          ? (error, IdentityFileReadFailureKind.fileSystem)
          : (
              FileSystemException(error.runtimeType.toString(), readPath),
              IdentityFileReadFailureKind.invalidText,
            );

      // Record, then surface: an unauditable failed read must not hide the
      // failure itself behind an audit error.
      await _record(
        serverId: serverId,
        serverLabel: serverLabel,
        path: readPath,
        ok: false,
        error: cause.toString(),
      );
      throw IdentityFileReadException(readPath, cause, kind: kind);
    }

    await _record(
      serverId: serverId,
      serverLabel: serverLabel,
      path: readPath,
      ok: true,
    );
    return pem;
  }

  Future<void> _record({
    required String serverId,
    required String serverLabel,
    required String path,
    required bool ok,
    String? error,
  }) async {
    try {
      await audit
          .record(
            IdentityReadEvent(
              at: DateTime.now().toUtc().toIso8601String(),
              serverId: serverId,
              serverLabel: serverLabel,
              path: path,
              viaBookmark: false,
              ok: ok,
              error: error,
            ),
          )
          .timeout(_auditTimeout);
    } on Object {
      // Best-effort by contract: the connect attempt must not fail (nor
      // wait forever) over the audit trail.
    }
  }
}

enum IdentityFileReadFailureKind { fileSystem, invalidText }

/// The identity file could not be read. [message] carries filesystem detail;
/// callers localize [IdentityFileReadFailureKind.invalidText]. [toString]
/// keeps the full sentence for logs.
class IdentityFileReadException implements Exception {
  final String path;
  final FileSystemException cause;
  final IdentityFileReadFailureKind kind;

  const IdentityFileReadException(
    this.path,
    this.cause, {
    this.kind = IdentityFileReadFailureKind.fileSystem,
  });

  String get _causeMessage {
    final os = cause.osError?.message;
    return (os == null || os.isEmpty) ? cause.message : os;
  }

  String get message => '$_causeMessage ($path)';

  @override
  String toString() => 'Could not read identity file $path: $_causeMessage';
}
