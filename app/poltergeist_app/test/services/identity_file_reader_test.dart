// Ported from Séance app/seance_app/test/identity_file_exception_test.dart @ ffac90f
// (exception cases); see docs/PORTS.md.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/identity_audit_log.dart';
import 'package:poltergeist_app/services/identity_file_reader.dart';

const _shortAuditTimeout = Duration(milliseconds: 1);

/// An audit sink that never completes a write.
class _HangingAudit implements IdentityAuditLog {
  final _gate = Completer<void>();

  @override
  File get file => File('/dev/null');

  @override
  int get maxEntries => 0;

  @override
  Future<void> record(IdentityReadEvent event) => _gate.future;

  @override
  Future<List<IdentityReadEvent>> readAll() async => const [];
}

/// A failing audit sink: every record throws.
class _FailingAudit implements IdentityAuditLog {
  @override
  File get file => File('/dev/null');

  @override
  int get maxEntries => 0;

  @override
  Future<void> record(IdentityReadEvent event) async {
    throw StateError('disk full');
  }

  @override
  Future<List<IdentityReadEvent>> readAll() async => const [];
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('poltergeist-identity-');
  });

  tearDown(() => dir.delete(recursive: true));

  group('IdentityFileReadException', () {
    // Séance's identity_file_exception_test.dart minus the macOS sandbox
    // hint: Poltergeist is unsandboxed at v1 (D23), so no EPERM hint exists.
    test('message prefers the OS detail and names the path', () {
      const e = IdentityFileReadException(
        '/home/ada/.ssh/id_ed25519',
        FileSystemException('Cannot open file', '/home/ada/.ssh/id_ed25519',
            OSError('Operation not permitted', 1)),
      );
      expect(e.message, contains('Operation not permitted'));
      expect(e.message, contains('/home/ada/.ssh/id_ed25519'));
      expect(e.toString(), contains('Operation not permitted'));
    });

    test('falls back to the exception message when the OS detail is absent',
        () {
      const withoutOsError = IdentityFileReadException(
        '/home/ada/.ssh/id_ed25519',
        FileSystemException('Cannot open file', '/home/ada/.ssh/id_ed25519'),
      );
      expect(withoutOsError.message, contains('Cannot open file'));
      const emptyOsMessage = IdentityFileReadException(
        '/home/ada/.ssh/id_ed25519',
        FileSystemException('Cannot open file', '/home/ada/.ssh/id_ed25519',
            OSError('', 2)),
      );
      expect(emptyOsMessage.message, contains('Cannot open file'));
    });
  });

  group('IdentityFileReader', () {
    test('expands ~, reads the key, and audits the success', () async {
      final home = Directory('${dir.path}/home');
      final ssh = Directory('${home.path}/.ssh');
      await ssh.create(recursive: true);
      final key = File('${ssh.path}/id_ed25519');
      await key.writeAsString('KEY PEM');

      final file = File('${dir.path}/reads.jsonl');
      final reader = IdentityFileReader(
        IdentityAuditLog(file),
        environment: {'HOME': home.path},
      );

      final pem = await reader.read(
        serverId: 's1',
        serverLabel: 'deploy@example.com',
        identityFilePath: '~/.ssh/id_ed25519',
      );

      expect(pem, 'KEY PEM');
      final entries = await IdentityAuditLog(file).readAll();
      expect(entries, hasLength(1));
      expect(entries.single.ok, isTrue);
      expect(entries.single.serverId, 's1');
      expect(entries.single.path, key.path);
    });

    test('a failed read throws and audits the failure with its error',
        () async {
      final file = File('${dir.path}/reads.jsonl');
      final reader = IdentityFileReader(
        IdentityAuditLog(file),
        environment: {'HOME': dir.path},
      );

      await expectLater(
        reader.read(
          serverId: 's1',
          serverLabel: 'deploy@example.com',
          identityFilePath: '~/.ssh/absent',
        ),
        throwsA(isA<IdentityFileReadException>()),
      );

      final entries = await IdentityAuditLog(file).readAll();
      expect(entries, hasLength(1));
      expect(entries.single.ok, isFalse);
      // The OS error wording differs per platform; only its presence is
      // the contract here.
      expect(entries.single.error, isNotEmpty);
    });

    test('a hanging audit write never blocks the read', () async {
      final key = File('${dir.path}/id.pem');
      await key.writeAsString('KEY PEM');
      final reader = IdentityFileReader(
        _HangingAudit(),
        environment: {'HOME': dir.path},
        auditTimeout: _shortAuditTimeout,
      );

      final pem = await reader.read(
        serverId: 's1',
        serverLabel: 'deploy@example.com',
        identityFilePath: '${dir.path}/id.pem',
      );

      expect(pem, 'KEY PEM');
    });

    test('an audit failure never blocks the read (D18: best-effort trail)',
        () async {
      final key = File('${dir.path}/id.pem');
      await key.writeAsString('KEY PEM');
      final reader = IdentityFileReader(
        _FailingAudit(),
        environment: {'HOME': dir.path},
      );

      final pem = await reader.read(
        serverId: 's1',
        serverLabel: 'deploy@example.com',
        identityFilePath: '${dir.path}/id.pem',
      );

      expect(pem, 'KEY PEM');
    });
  });
}
