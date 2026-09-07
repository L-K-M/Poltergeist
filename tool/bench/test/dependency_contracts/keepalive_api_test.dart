import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:seance_core/seance_core.dart';
// Concrete transport APIs stay in the sanctioned SSH harness, not the UI.
// ignore: implementation_imports
import 'package:seance_core/src/ssh/remote_file_system.dart';
import 'package:test/test.dart';

void main() {
  test('the pin exposes adapter activity without changing the VFS', () async {
    final client = _PendingSftpClient();
    final adapter = DartSshRemoteFileSystem(client);
    final RemoteFileSystem fs = adapter;
    expect(adapter.hasActiveOperations, isFalse);

    final resolving = fs.canonicalize('.');
    expect(adapter.hasActiveOperations, isTrue);
    client.resolved.complete('/home/test');
    expect(await resolving, '/home/test');
    expect(adapter.hasActiveOperations, isFalse);
  });

  test(
    'the pin validates caller-owned keepalive before socket creation',
    () async {
      var connects = 0;
      await expectLater(
        openAuthenticatedClient(
          config: ServerConfig(
            id: 'test',
            label: 'test',
            host: 'unused.invalid',
            username: 'test',
            createdAt: 0,
            updatedAt: 0,
          ),
          credentials: const SshCredentials.password('fixture'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => false,
          keepAliveInterval: Duration.zero,
          connect: (_, _, _) async {
            connects++;
            throw StateError('must not connect');
          },
        ),
        throwsArgumentError,
      );
      expect(connects, 0);
    },
  );
}

class _PendingSftpClient implements SftpClient {
  final resolved = Completer<String>();

  @override
  Future<String> absolute(String path) => resolved.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
