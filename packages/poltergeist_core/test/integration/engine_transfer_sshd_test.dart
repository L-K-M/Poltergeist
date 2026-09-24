@Tags(['integration'])
@Timeout(Duration(minutes: 3))
library;

// The bridged transfer lease (protocol v13, STATUS item 23) against a
// real OpenSSH server: a spawned engine isolate with the production
// opener, the production EngineConnectionManager proxy, and the
// production TransferQueue on this isolate — upload, download,
// remote→remote, digest, cancel, and delete over genuine SFTP channels,
// with the first connect's prompts answered like the app's coordinator
// would (the host key before any credential — 02 §10's ordering).
//
// Env-gated: POLTERGEIST_BRIDGE_SSHD=host:port plus
// POLTERGEIST_BRIDGE_SSHD_USER and POLTERGEIST_BRIDGE_SSHD_PASSWORD
// (password auth; the host key is accepted on first use). Optional
// POLTERGEIST_BRIDGE_SSHD_ROOT picks the remote scratch parent (default:
// the login home). Example:
//   POLTERGEIST_BRIDGE_SSHD=127.0.0.1:2222 \
//   POLTERGEIST_BRIDGE_SSHD_USER=demo \
//   POLTERGEIST_BRIDGE_SSHD_PASSWORD=poltergeist \
//   dart test packages/poltergeist_core/test/integration/engine_transfer_sshd_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

void main() {
  final environment = Platform.environment;
  final address = environment['POLTERGEIST_BRIDGE_SSHD'];
  final username = environment['POLTERGEIST_BRIDGE_SSHD_USER'];
  final password = environment['POLTERGEIST_BRIDGE_SSHD_PASSWORD'];
  final enabled = address != null && username != null && password != null;
  final skip = enabled
      ? false
      : 'set POLTERGEIST_BRIDGE_SSHD, _USER, and _PASSWORD to run';

  late EngineClient client;
  late EngineConnectionManager connections;
  late TransferQueue queue;
  late Directory local;
  late String remoteRoot;
  late StreamSubscription<EnginePromptEvent> prompts;
  final promptKinds = <EnginePromptKind>[];
  const serverId = 'bridge-sshd';

  setUpAll(() async {
    if (!enabled) return;
    final separator = address.lastIndexOf(':');
    final config = ServerConfig(
      id: serverId,
      label: 'bridge sshd',
      host: address.substring(0, separator),
      port: int.parse(address.substring(separator + 1)),
      username: username,
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    client = await EngineClient.spawn(const EngineConfig());
    prompts = client.prompts.listen((prompt) {
      promptKinds.add(prompt.kind);
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
    connections = EngineConnectionManager(
      client,
      configs: _FixedConfig(config),
    );
    queue = TransferQueue(connections: connections);
    local = Directory(
      (await Directory.systemTemp.createTemp(
        'bridge-sshd-',
      )).resolveSymbolicLinksSync(),
    );

    final lease = await connections.leaseTransferChannel(serverId);
    try {
      final parent =
          environment['POLTERGEIST_BRIDGE_SSHD_ROOT'] ??
          await lease.fs.canonicalize('.');
      remoteRoot =
          '$parent/poltergeist-bridge-${DateTime.now().microsecondsSinceEpoch}';
      await lease.fs.createDirectory(remoteRoot);
    } finally {
      await lease.release();
    }
  });

  tearDownAll(() async {
    if (!enabled) return;
    try {
      final task = await queue.enqueueDelete(
        DeleteRequest(
          source: const ServerFsLocation(serverId),
          rootPaths: [remoteRoot],
          disposition: DeleteDisposition.permanent,
          confirmed: true,
        ),
      );
      await _settle(task);
    } finally {
      await queue.dispose();
      await prompts.cancel();
      await client.shutdown();
      await local.delete(recursive: true);
    }
  });

  TransferTaskSpec copy({
    required FsLocation source,
    required FsLocation destination,
    required List<String> roots,
    required String into,
  }) => TransferTaskSpec(
    source: source,
    destination: destination,
    rootPaths: roots,
    destinationDir: into,
    policy: ResolvedConflictPolicy(
      files: ConflictResolution.replace,
      folders: ConflictResolution.merge,
    ),
  );

  test('the first connect asks for the host key before credentials', () {
    expect(promptKinds.take(2), [
      EnginePromptKind.hostKeyFirstUse,
      EnginePromptKind.credentialNeeded,
    ]);
  }, skip: skip);

  test(
    'a folder uploads, downloads back, and copies remote→remote intact',
    () async {
      final random = Random(7);
      final tree = Directory('${local.path}/tree/sub')
        ..createSync(recursive: true);
      final files = <String, List<int>>{
        'tree/small.txt': 'hello over the bridge'.codeUnits,
        'tree/sub/big.bin': List.generate(3 * 1024 * 1024 + 17, (_) {
          return random.nextInt(256);
        }),
        'tree/empty.dat': const [],
      };
      for (final MapEntry(:key, :value) in files.entries) {
        File('${local.path}/$key').writeAsBytesSync(value);
      }
      expect(tree.existsSync(), isTrue);

      final up = queue.enqueue(
        copy(
          source: const LocalFsLocation(),
          destination: const ServerFsLocation(serverId),
          roots: ['${local.path}/tree'],
          into: remoteRoot,
        ),
      );
      await _settle(up);
      expect(up.state, TransferTaskState.completed, reason: up.error);

      final lease = await connections.leaseTransferChannel(serverId);
      try {
        final big = await remoteContentDigest(
          lease.fs,
          '$remoteRoot/tree/sub/big.bin',
        );
        expect(
          big.contentSha256,
          sha256.convert(files['tree/sub/big.bin']!).toString(),
        );
        expect(big.size, files['tree/sub/big.bin']!.length);
      } finally {
        await lease.release();
      }

      final back = Directory('${local.path}/back')..createSync();
      final down = queue.enqueue(
        copy(
          source: const ServerFsLocation(serverId),
          destination: const LocalFsLocation(),
          roots: ['$remoteRoot/tree'],
          into: back.path,
        ),
      );
      await _settle(down);
      expect(down.state, TransferTaskState.completed, reason: down.error);
      for (final MapEntry(:key, :value) in files.entries) {
        expect(File('${back.path}/$key').readAsBytesSync(), value, reason: key);
      }

      final lease2 = await connections.leaseTransferChannel(serverId);
      try {
        await lease2.fs.createDirectory('$remoteRoot/copy');
      } finally {
        await lease2.release();
      }
      final r2r = queue.enqueue(
        copy(
          source: const ServerFsLocation(serverId),
          destination: const ServerFsLocation(serverId),
          roots: ['$remoteRoot/tree'],
          into: '$remoteRoot/copy',
        ),
      );
      await _settle(r2r);
      expect(r2r.state, TransferTaskState.completed, reason: r2r.error);
      final lease3 = await connections.leaseTransferChannel(serverId);
      try {
        final copied = await remoteContentDigest(
          lease3.fs,
          '$remoteRoot/copy/tree/sub/big.bin',
        );
        expect(
          copied.contentSha256,
          sha256.convert(files['tree/sub/big.bin']!).toString(),
        );
      } finally {
        await lease3.release();
      }
    },
    skip: skip,
  );

  test(
    'a managed checkout downloads, edits, and saves back under CAS',
    () async {
      final store = ManagedRemoteFileStore(
        indexFile: File('${local.path}/checkout/index.json'),
        checkoutRoot: Directory('${local.path}/checkout/files'),
      );
      final manager = CheckoutManager(
        store: store,
        connections: connections,
        queue: queue,
      );
      await manager.start();
      try {
        final lease = await connections.leaseTransferChannel(serverId);
        final RemoteFileEntry entry;
        try {
          entry = await lease.fs.stat('$remoteRoot/tree/small.txt');
        } finally {
          await lease.release();
        }
        final record = await manager.checkout(serverId: serverId, entry: entry);
        expect(
          await manager.localFile(record).readAsString(),
          'hello over the bridge',
        );
        expect(
          record.remoteSnapshot.contentSha256,
          sha256.convert('hello over the bridge'.codeUnits).toString(),
        );
        await manager
            .localFile(record)
            .writeAsString('edited through the bridge');
        expect(await manager.uploadLocalCopy(record), isTrue);

        final check = await connections.leaseTransferChannel(serverId);
        try {
          final digest = await remoteContentDigest(
            check.fs,
            '$remoteRoot/tree/small.txt',
          );
          expect(
            digest.contentSha256,
            sha256.convert('edited through the bridge'.codeUnits).toString(),
          );
          // Put the fixture back for the later tests.
          await check.fs.upload(
            '$remoteRoot/tree/small.txt',
            Stream.value('hello over the bridge'.codeUnits),
            overwrite: true,
          );
        } finally {
          await check.release();
        }
        await manager.discard(record);
      } finally {
        await manager.dispose();
        await store.close();
      }
    },
    skip: skip,
  );

  test('a preview produce lands the remote bytes locally', () async {
    final producer = QueuePreviewProducer(queue);
    final destination = '${local.path}/preview.bin';
    final ticket = producer.start(
      PreviewProduceSpec(
        serverId: serverId,
        remotePath: '$remoteRoot/tree/sub/big.bin',
        destinationPath: destination,
      ),
    );
    final entry = await ticket.result.timeout(const Duration(minutes: 1));
    expect(File(destination).lengthSync(), entry.size);
    expect(entry.size, 3 * 1024 * 1024 + 17);
  }, skip: skip);

  test('a cancelled download unwinds and the lease still serves', () async {
    final lease = await connections.leaseTransferChannel(serverId);
    try {
      final sink = _SlowSink();
      final token = RemoteTransferCancellation();
      final download = lease.fs.download(
        '$remoteRoot/tree/sub/big.bin',
        sink,
        cancellation: token,
      );
      await sink.firstChunk.future;
      token.cancel();
      await expectLater(
        download,
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.cancelled,
          ),
        ),
      );
      expect(
        (await lease.fs.stat('$remoteRoot/tree/small.txt')).size,
        'hello over the bridge'.length,
      );
    } finally {
      await lease.release();
    }
  }, skip: skip);

  test('an existing target refuses an upload without overwrite', () async {
    final lease = await connections.leaseTransferChannel(serverId);
    try {
      await expectLater(
        lease.fs.upload(
          '$remoteRoot/tree/small.txt',
          Stream.value('x'.codeUnits),
        ),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
    } finally {
      await lease.release();
    }
  }, skip: skip);
}

Future<void> _settle(TransferTask task) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (!task.isTerminal && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  if (!task.isTerminal) fail('task ${task.id} never settled');
}

final class _FixedConfig implements ServerConfigSource {
  _FixedConfig(this.config);

  final ServerConfig config;

  @override
  Future<ServerConfig?> configFor(String serverId) async => config;
}

/// Accepts one chunk, then stalls — the consumer a cancel must unwind.
final class _SlowSink implements StreamSink<List<int>> {
  final Completer<void> firstChunk = Completer<void>();
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final _ in stream) {
      if (!firstChunk.isCompleted) firstChunk.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
