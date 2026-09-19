@Tags(['integration'])
@Timeout(Duration(minutes: 3))
library;

// 07 §3.5's last exit criterion: a remote→remote transfer pipes bytes
// between two *distinct* Docker sshds — source reads ride one server's
// SFTP channel, destination writes the other's, and every byte crosses
// the client through the queue's BoundedTransferSink pipe (03 §4.5).
// The run.sh fixture exports both endpoints (sshd-modern on 2201,
// sshd-legacy on 2202) with the same user, key, and host-key material;
// TOFU pins key on (host, port), so the two services take two pins.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

const _hostVariable = 'POLTERGEIST_SSHD';
const _modernPortVariable = 'POLTERGEIST_SSHD_MODERN';
const _legacyPortVariable = 'POLTERGEIST_SSHD_LEGACY';
const _remoteRootVariable = 'POLTERGEIST_SSHD_REMOTE_ROOT';
const _modernId = 'fixture-modern';
const _legacyId = 'fixture-legacy';

void main() {
  final environment = Platform.environment;
  final enabled =
      environment[_hostVariable] != null &&
      environment[_modernPortVariable] != null &&
      environment[_legacyPortVariable] != null;

  test(
    'a directory copies remote→remote through the client pipe between '
    'two Docker sshds',
    () async {
      String requiredVariable(String name) =>
          environment[name] ??
          (throw StateError('The enabled fixture requires $name.'));
      final host = requiredVariable(_hostVariable);
      if (host != InternetAddress.loopbackIPv4.address) {
        throw StateError('The Docker fixture must use IPv4 loopback.');
      }
      final modernPort = int.parse(requiredVariable(_modernPortVariable));
      final legacyPort = int.parse(requiredVariable(_legacyPortVariable));
      final username = requiredVariable('POLTERGEIST_SSHD_USER');
      final privateKey = await File(
        requiredVariable('POLTERGEIST_SSHD_KEY'),
      ).readAsString();
      final remoteRoot = requiredVariable(_remoteRootVariable);

      // Both services share the fixture host keys; the pin binds
      // (host, port), so each endpoint needs its own entry.
      final package = await Isolate.resolvePackageUri(
        Uri.parse('package:poltergeist_core/poltergeist_core.dart'),
      );
      if (package == null) {
        throw StateError('Core package is unresolved.');
      }
      final publicKey = (await File.fromUri(
        package.resolve(
          '../../../test/integration/keys/ssh_host_ed25519_key.pub',
        ),
      ).readAsString()).trim().split(RegExp(r'\s+'));
      final store = InMemoryHostKeyStore();
      for (final port in [modernPort, legacyPort]) {
        await store.put(
          HostKey.fromPublicKey(
            host: host,
            port: port,
            type: publicKey[0],
            publicKeyBase64: publicKey[1],
            pinnedAt: 0,
          ),
        );
      }

      ServerConfig server(String id, int port) => ServerConfig(
        id: id,
        label: id,
        host: host,
        port: port,
        username: username,
        authMethod: AuthMethod.privateKey,
        createdAt: 0,
        updatedAt: 0,
      );
      final servers = {
        _modernId: server(_modernId, modernPort),
        _legacyId: server(_legacyId, legacyPort),
      };

      final unexpectedPrompts = <String>[];
      final manager = PooledConnectionManager(
        resolveServer: (serverId) async => servers[serverId]!,
        resolveCredentials: (_, _) async => ResolvedCredentials(
          credentials: SshCredentials.privateKey(privateKey),
          origin: CredentialOrigin.stored,
        ),
        tofu: TofuVerifier(store),
        onHostKey: (_) async {
          unexpectedPrompts.add('host key');
          fail('A pre-seeded fixture must never prompt.');
        },
        onKeyboardInteractive: (_, _, _) async {
          unexpectedPrompts.add('keyboard interactive');
          fail('Stored credentials must not prompt.');
        },
      );
      addTearDown(() async {
        for (final serverId in servers.keys) {
          await manager.disconnectServer(serverId);
        }
        expect(unexpectedPrompts, isEmpty);
      });

      // Browse handles on BOTH endpoints — the proof that two separate
      // sshd containers served this transfer.
      final modern = await manager.openBrowseChannel(
        _modernId,
        paneTabId: 'source',
      );
      final legacy = await manager.openBrowseChannel(
        _legacyId,
        paneTabId: 'destination',
      );
      final sourceEntry = await modern.fs.stat(
        '$remoteRoot/fixtures/readdir-00',
      );
      expect(sourceEntry.type, RemoteFileType.directory);

      final queue = TransferQueue(connections: manager);
      addTearDown(queue.dispose);
      final task = queue.enqueue(
        TransferTaskSpec(
          source: const ServerFsLocation(_modernId),
          destination: const ServerFsLocation(_legacyId),
          rootPaths: ['$remoteRoot/fixtures/readdir-00'],
          destinationDir: '$remoteRoot/uploads/host',
          // The uploads fixture is wiped per run; replace keeps a rerun
          // inside one session honest instead of colliding on ask.
          policy: ResolvedConflictPolicy(
            files: ConflictResolution.replace,
            folders: ConflictResolution.merge,
          ),
        ),
      );

      final clock = Stopwatch()..start();
      while (!task.isTerminal) {
        if (clock.elapsed > const Duration(minutes: 2)) {
          fail('remote→remote transfer never settled');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(task.state, TransferTaskState.completed, reason: task.error);
      // 100 fixture files plus their materialized container.
      expect(task.items, hasLength(101));
      expect(
        task.items.map((item) => item.state),
        everyElement(TransferItemState.completed),
      );

      // The destination really is the legacy sshd: list and read back
      // through ITS channel, then byte-compare one file's content.
      final landed = await legacy.fs.listDirectory(
        '$remoteRoot/uploads/host/readdir-00',
      );
      expect(landed, hasLength(100));

      final collected = BytesBuilder(copy: false);
      final sink = StreamController<List<int>>();
      final subscription = sink.stream.listen(collected.add);
      await legacy.fs.download(
        '$remoteRoot/uploads/host/readdir-00/readdir-00-entry-000.txt',
        sink,
      );
      await sink.close();
      await subscription.cancel();
      expect(
        utf8.decode(collected.toBytes()),
        'readdir-00/readdir-00-entry-000.txt\n',
      );

      await modern.close();
      await legacy.close();
    },
    skip: enabled
        ? false
        : 'Set $_hostVariable, $_modernPortVariable, and '
              '$_legacyPortVariable to enable.',
  );
}
