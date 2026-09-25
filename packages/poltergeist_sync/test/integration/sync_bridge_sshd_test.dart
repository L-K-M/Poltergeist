@Tags(['integration'])
@Timeout(Duration(minutes: 3))
library;

// Remote sync endpoints over the bridged transfer lease (protocol v13,
// STATUS item 23): a spawned engine isolate owns the SFTP channels; the
// scanner and executor run here over LeasedRemoteFileSystem — the exact
// shape SyncEnvironment hands the plan view. A local tree copies to a real
// OpenSSH server, the rescan converges, and a content-hash comparison
// hashes the remote side engine-side.
//
// Env-gated like core's engine_transfer_sshd_test:
//   POLTERGEIST_BRIDGE_SSHD=host:port
//   POLTERGEIST_BRIDGE_SSHD_USER / POLTERGEIST_BRIDGE_SSHD_PASSWORD
//   POLTERGEIST_BRIDGE_SSHD_ROOT (optional; default the login home)

import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

void main() {
  final environment = Platform.environment;
  final address = environment['POLTERGEIST_BRIDGE_SSHD'];
  final username = environment['POLTERGEIST_BRIDGE_SSHD_USER'];
  final password = environment['POLTERGEIST_BRIDGE_SSHD_PASSWORD'];
  final enabled = address != null && username != null && password != null;

  test(
    'a local tree syncs to a bridged remote endpoint and converges',
    () async {
      final separator = address!.lastIndexOf(':');
      final host = address.substring(0, separator);
      final port = int.parse(address.substring(separator + 1));
      final config = ServerConfig(
        id: 'sync-bridge',
        label: 'sync bridge',
        host: host,
        port: port,
        username: username!,
        authMethod: AuthMethod.password,
        createdAt: 0,
        updatedAt: 0,
      );
      final client = await EngineClient.spawn(const EngineConfig());
      addTearDown(client.shutdown);
      final prompts = client.prompts.listen((prompt) {
        final reply = switch (prompt.kind) {
          EnginePromptKind.hostKeyFirstUse => const HostKeyPromptReply(
            accepted: true,
          ),
          EnginePromptKind.credentialNeeded => CredentialPromptReply(
            password: password,
            origin: CredentialOrigin.stored,
          ),
          _ => null,
        };
        if (reply != null) {
          client.replyPrompt(prompt.promptId, prompt.kind, reply);
        }
      });
      addTearDown(prompts.cancel);
      final remoteFs = LeasedRemoteFileSystem(
        EngineConnectionManager(client, configs: _Fixed(config)),
        'sync-bridge',
        idleRelease: null,
      );
      addTearDown(remoteFs.release);

      final parent =
          environment['POLTERGEIST_BRIDGE_SSHD_ROOT'] ??
          await remoteFs.canonicalize('.');
      final remoteDir =
          '$parent/poltergeist-sync-bridge-'
          '${DateTime.now().microsecondsSinceEpoch}';
      await remoteFs.createDirectory(remoteDir);
      addTearDown(() => _removeTree(remoteFs, remoteDir));

      final localDir = Directory(
        Directory.systemTemp
            .createTempSync('pgst-sync-bridge-')
            .resolveSymbolicLinksSync(),
      );
      final journalDir = Directory.systemTemp.createTempSync('pgst-sync-jr-');
      addTearDown(() {
        localDir.deleteSync(recursive: true);
        journalDir.deleteSync(recursive: true);
      });
      File('${localDir.path}/a.txt').writeAsStringSync('alpha\n');
      Directory('${localDir.path}/sub').createSync();
      File(
        '${localDir.path}/sub/b.bin',
      ).writeAsBytesSync(List.generate(200 * 1024, (i) => i % 253));

      const rules = SyncRuleSet();
      final pair = SyncPair(
        id: 'bridge-itest',
        name: 'bridge itest',
        left: LocalEndpoint(localDir.path),
        right: RemoteEndpoint(
          server: BookmarkServerRef(
            identity: EmbeddedHostIdentity(
              host: host,
              port: port,
              username: username,
              authMethod: AuthMethod.password,
            ),
          ),
          path: remoteDir,
        ),
        rules: rules,
      );

      final localFs = LocalFileSystem();
      Future<(ScanResult, ScanResult)> scanBoth() async => (
        await TreeScanner(
          localFs,
        ).scan(localDir.path, side: SyncSide.left, rules: rules),
        await TreeScanner(
          remoteFs,
        ).scan(remoteDir, side: SyncSide.right, rules: rules),
      );

      final (left, right) = await scanBoth();
      final plan = await diffScans(left: left, right: right, pair: pair);
      expect(
        plan.items
            .where((item) => item.effective != SyncActionType.skip)
            .map((item) => item.relativePath),
        containsAll(['a.txt', 'sub', 'sub/b.bin']),
      );

      final run = await SyncExecutor(
        leftFileSystem: localFs,
        rightFileSystem: remoteFs,
        leftRoot: left.rootPath,
        rightRoot: right.rootPath,
        syncRunsDirectory: journalDir.path,
        deviceId: 'bridge-itest',
      ).run(plan, pairId: pair.id);
      expect(run.cancelled, isFalse);
      expect(
        run.plan.items.where((item) => item.status == SyncItemStatus.failed),
        isEmpty,
      );

      // The rescan converges: nothing left to do.
      final (left2, right2) = await scanBoth();
      final again = await diffScans(left: left2, right: right2, pair: pair);
      expect(
        again.items.where((item) => item.effective != SyncActionType.skip),
        isEmpty,
      );

      // Content comparison hashes the remote side through the engine.
      final hashed = await diffScans(
        left: left2,
        right: right2,
        pair: SyncPair(
          id: pair.id,
          name: pair.name,
          left: pair.left,
          right: pair.right,
          rules: const SyncRuleSet(comparison: ComparisonMode.contentHash),
        ),
        leftFileSystem: localFs,
        rightFileSystem: remoteFs,
      );
      expect(
        hashed.items.where((item) => item.effective != SyncActionType.skip),
        isEmpty,
      );
    },
    skip: enabled
        ? false
        : 'set POLTERGEIST_BRIDGE_SSHD, _USER, and _PASSWORD to run',
  );
}

final class _Fixed implements ServerConfigSource {
  _Fixed(this.config);

  final ServerConfig config;

  @override
  Future<ServerConfig?> configFor(String serverId) async => config;
}

Future<void> _removeTree(RemoteFileSystem fs, String path) async {
  for (final entry in await fs.listDirectory(path)) {
    if (entry.isDirectory) {
      await _removeTree(fs, entry.path);
    } else {
      await fs.delete(entry);
    }
  }
  await fs.delete(await fs.stat(path, followLinks: false));
}
