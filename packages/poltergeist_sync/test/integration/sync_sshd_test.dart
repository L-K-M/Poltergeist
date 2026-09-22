@Tags(['integration'])
@Timeout(Duration(minutes: 3))
library;

// 07 §3.9 exit criterion + 05 §4/§8: the setstat-ignoring leg end to end.
// sshd-restricted runs sftp-server -P setstat,fsetstat, so a plan run
// against it must flag the destination mtime-unreliable, journal
// setstatIgnored on the affected item, and converge the NEXT diff on
// size-only equality (the user-visible notice rides those flags into the
// plan view). sshd-modern is the control: setTimes lands, and the re-diff
// converges on mtime alone. Same user/key/host-key material as the core
// integration tests; TOFU pins key on (host, port).

import 'dart:io';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

const _hostVariable = 'POLTERGEIST_SSHD';
const _modernPortVariable = 'POLTERGEIST_SSHD_MODERN';
const _restrictedPortVariable = 'POLTERGEIST_SSHD_RESTRICTED';
const _remoteRootVariable = 'POLTERGEIST_SSHD_REMOTE_ROOT';
const _modernId = 'fixture-modern';
const _restrictedId = 'fixture-restricted';

/// A stamp well inside the past: a refused setstat leaves the write
/// instant, so any surviving 2020 stamp proves the stamp landed.
final _pinnedMtime = DateTime.utc(2020, 1, 2, 3, 4, 4);

void main() {
  final environment = Platform.environment;
  final enabled =
      environment[_hostVariable] != null &&
      environment[_modernPortVariable] != null &&
      environment[_restrictedPortVariable] != null &&
      environment[_remoteRootVariable] != null &&
      environment['POLTERGEIST_SSHD_USER'] != null &&
      environment['POLTERGEIST_SSHD_KEY'] != null;

  test(
    'a refused setstat flags the destination mtime-unreliable and the '
    'next diff converges on size only',
    () async {
      await _runScenario(serviceId: _restrictedId, expectSetstatIgnored: true);
    },
    skip: enabled ? false : _skipMessage,
  );

  test(
    'a landed setstat keeps the destination mtime-reliable '
    '(sshd-modern control)',
    () async {
      await _runScenario(serviceId: _modernId, expectSetstatIgnored: false);
    },
    skip: enabled ? false : _skipMessage,
  );
}

const _skipMessage =
    'Set $_hostVariable, $_modernPortVariable, $_restrictedPortVariable, '
    '$_remoteRootVariable, POLTERGEIST_SSHD_USER, and '
    'POLTERGEIST_SSHD_KEY to enable.';

Future<void> _runScenario({
  required String serviceId,
  required bool expectSetstatIgnored,
}) async {
  final environment = Platform.environment;
  String requiredVariable(String name) =>
      environment[name] ??
      (throw StateError('The enabled fixture requires $name.'));
  final host = requiredVariable(_hostVariable);
  if (host != InternetAddress.loopbackIPv4.address) {
    throw StateError('The Docker fixture must use IPv4 loopback.');
  }
  final port = int.parse(
    requiredVariable(
      serviceId == _modernId ? _modernPortVariable : _restrictedPortVariable,
    ),
  );
  final username = requiredVariable('POLTERGEIST_SSHD_USER');
  final privateKey = await File(
    requiredVariable('POLTERGEIST_SSHD_KEY'),
  ).readAsString();
  final remoteRoot = requiredVariable(_remoteRootVariable);

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
  await store.put(
    HostKey.fromPublicKey(
      host: host,
      port: port,
      type: publicKey[0],
      publicKeyBase64: publicKey[1],
      pinnedAt: 0,
    ),
  );

  final unexpectedPrompts = <String>[];
  final manager = PooledConnectionManager(
    resolveServer: (serverId) async => ServerConfig(
      id: serverId,
      label: serverId,
      host: host,
      port: port,
      username: username,
      authMethod: AuthMethod.privateKey,
      createdAt: 0,
      updatedAt: 0,
    ),
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

  final localDir = Directory.systemTemp.createTempSync('pgst-sync-it-');
  final journalDir = Directory.systemTemp.createTempSync('pgst-sync-jr-');
  final remoteDir =
      '$remoteRoot/uploads/host/sync-it-$serviceId-'
      '${DateTime.now().millisecondsSinceEpoch}';
  addTearDown(() async {
    await manager.disconnectServer(serviceId);
    expect(unexpectedPrompts, isEmpty);
    localDir.deleteSync(recursive: true);
    journalDir.deleteSync(recursive: true);
  });

  final source = File('${localDir.path}/a.txt')
    ..writeAsStringSync('restricted-leg payload\n');
  source.setLastModifiedSync(_pinnedMtime);

  final channel = await manager.openBrowseChannel(serviceId, paneTabId: 'sync');
  final remoteFs = channel.fs;
  await remoteFs.createDirectory(remoteDir);
  addTearDown(() => _removeTree(remoteFs, remoteDir));

  const rules = SyncRuleSet();
  final pair = SyncPair(
    id: 'itest-$serviceId',
    name: 'itest $serviceId',
    left: LocalEndpoint(localDir.path),
    right: RemoteEndpoint(
      server: BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: host,
          port: port,
          username: username,
          authMethod: AuthMethod.privateKey,
        ),
      ),
      path: remoteDir,
    ),
    rules: rules,
  );

  final localFs = LocalFileSystem();
  final localScan = await TreeScanner(
    localFs,
  ).scan(localDir.path, side: SyncSide.left, rules: rules);
  final remoteScan = await TreeScanner(
    remoteFs,
  ).scan(remoteDir, side: SyncSide.right, rules: rules);
  final plan = await diffScans(left: localScan, right: remoteScan, pair: pair);
  final seeded = plan.items.singleWhere((item) => item.relativePath == 'a.txt');
  expect(seeded.effective, SyncActionType.copyLeftToRight);

  final run = await SyncExecutor(
    leftFileSystem: localFs,
    rightFileSystem: remoteFs,
    leftRoot: localScan.rootPath,
    rightRoot: remoteScan.rootPath,
    syncRunsDirectory: journalDir.path,
    deviceId: 'integration-$serviceId',
  ).run(plan, pairId: pair.id);

  final line = run.journal.items.singleWhere(
    (entry) => entry.relativePath == 'a.txt',
  );
  expect(line.outcome, SyncItemStatus.done);
  expect(line.setstatIgnored, expectSetstatIgnored);
  expect(run.mtimeUnreliableLeft, isFalse);
  expect(run.mtimeUnreliableRight, expectSetstatIgnored);

  // The durable journal agrees — the flag is on disk, not just in memory.
  final replayed = await SyncRunJournal.open(run.journal.path);
  expect(
    replayed.items.singleWhere((entry) => entry.relativePath == 'a.txt'),
    isA<SyncJournalItemLine>().having(
      (entry) => entry.setstatIgnored,
      'setstatIgnored',
      expectSetstatIgnored,
    ),
  );

  final landed = await remoteFs.stat('$remoteDir/a.txt');
  expect(
    landed.modifiedAt,
    isNotNull,
    reason: 'stat must report an mtime after the copy',
  );
  final landedSeconds = landed.modifiedAt!.millisecondsSinceEpoch ~/ 1000;
  final pinnedSeconds = _pinnedMtime.millisecondsSinceEpoch ~/ 1000;

  final localRescan = await TreeScanner(
    localFs,
  ).scan(localDir.path, side: SyncSide.left, rules: rules);
  final remoteRescan = await TreeScanner(
    remoteFs,
  ).scan(remoteDir, side: SyncSide.right, rules: rules);

  if (expectSetstatIgnored) {
    // The server really ignored setstat: the stamp never landed.
    expect(landedSeconds, isNot(pinnedSeconds));

    // Without the flag the next diff still sees the mtime divergence.
    final naive = await diffScans(
      left: localRescan,
      right: remoteRescan,
      pair: pair,
    );
    expect(
      naive.items.singleWhere((item) => item.relativePath == 'a.txt').effective,
      SyncActionType.updateLeftToRight,
    );

    // With it, 05 §4's fallback converges on size-only equality.
    final flagged = await diffScans(
      left: localRescan,
      right: remoteRescan,
      pair: pair,
      mtimeUnreliableRight: true,
    );
    final converged = flagged.items.singleWhere(
      (item) => item.relativePath == 'a.txt',
    );
    expect(converged.effective, SyncActionType.skip);
    expect(converged.reason, SyncReason.equal);
  } else {
    expect(landedSeconds, pinnedSeconds);
    final converged = await diffScans(
      left: localRescan,
      right: remoteRescan,
      pair: pair,
    );
    final item = converged.items.singleWhere(
      (entry) => entry.relativePath == 'a.txt',
    );
    expect(item.effective, SyncActionType.skip);
    expect(item.reason, SyncReason.equal);
  }

  // No explicit channel.close(): tearDown removes the remote tree
  // while the channel still lives, then disconnectServer tears it down.
}

Future<void> _removeTree(RemoteFileSystem fs, String path) async {
  try {
    for (final entry in await fs.listDirectory(path)) {
      if (entry.isDirectory) {
        await _removeTree(fs, entry.path);
      } else {
        await fs.delete(entry);
      }
    }
    await fs.delete(await fs.stat(path));
  } on RemoteFileException catch (error) {
    if (error.kind != RemoteFileErrorKind.notFound) rethrow;
  }
}
