import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_core/src/transfer/bounded_transfer_sink.dart';
import 'package:test/test.dart';

import '../transfer/transfer_fakes.dart';
import 'engine_bridge_harness.dart';

List<int> _bytes(int length) => List<int>.generate(length, (i) => i % 251);

void main() {
  late FakeTreeFileSystem remote;
  late BridgeHarness harness;

  setUp(() {
    remote = FakeTreeFileSystem()
      ..addDirectory('/srv')
      ..addFile('/srv/a.txt', utf8.encode('alpha'), mode: 0x1A4)
      ..addFile('/srv/big.bin', _bytes(600 * 1024));
    harness = BridgeHarness({'srv': remote});
  });

  tearDown(() => harness.dispose());

  group('leases', () {
    test('a lease carries its config, so no browse is needed first', () async {
      final lease = await harness.connections.leaseTransferChannel('srv');
      expect(harness.resolveCalls, ['srv']);
      expect(await lease.fs.listDirectory('/srv'), hasLength(2));
      await lease.release();
      // Release belongs to the borrower: a second call is a no-op.
      await lease.release();
    });

    test('a released lease refuses typed as disconnected', () async {
      final lease = await harness.connections.leaseTransferChannel('srv');
      final fs = lease.fs;
      await lease.release();
      await expectLater(
        fs.stat('/srv/a.txt'),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.disconnected,
          ),
        ),
      );
    });

    test('a disconnect retires the id\'s leases engine-side', () async {
      final lease = await harness.connections.leaseTransferChannel('srv');
      await harness.connections.disconnectServer('srv');
      await expectLater(
        lease.fs.listDirectory('/srv'),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.disconnected,
          ),
        ),
      );
      await lease.release();
      // A fresh lease reconnects.
      final again = await harness.connections.leaseTransferChannel('srv');
      expect(await again.fs.stat('/srv/a.txt'), isA<RemoteFileEntry>());
      await again.release();
    });

    test('the pool blocks a lease past its per-server capacity', () async {
      // PoolPolicy: 2 transports × 4 transfer channels = 8 leases.
      final held = [
        for (var i = 0; i < 8; i++)
          await harness.connections.leaseTransferChannel('srv'),
      ];
      var granted = false;
      final ninth = harness.connections.leaseTransferChannel('srv').then((
        lease,
      ) {
        granted = true;
        return lease;
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(granted, isFalse);
      await held.first.release();
      final lease = await ninth.timeout(const Duration(seconds: 5));
      expect(granted, isTrue);
      for (final other in [...held.skip(1), lease]) {
        await other.release();
      }
    });

    test(
      'a config-less lease rides the config its browse open supplied',
      () async {
        await harness.dispose();
        harness = BridgeHarness({'srv': remote}, withConfigs: false);
        // No browse open yet: nothing to dial, refused typed.
        await expectLater(
          harness.connections.leaseTransferChannel('srv'),
          throwsA(
            isA<RemoteFileException>()
                .having((e) => e.kind, 'kind', RemoteFileErrorKind.other)
                .having(
                  (e) => e.operation,
                  'operation',
                  'lease transfer channel',
                ),
          ),
        );
        // A Quick Connect tab opened it: the lease reuses that config.
        final channel = await harness.client.openBrowseChannel(
          serverId: 'srv',
          paneTabId: 'tab',
          config: bridgeConfig('srv'),
        );
        final lease = await harness.connections.leaseTransferChannel('srv');
        expect(await lease.fs.stat('/srv/a.txt'), isA<RemoteFileEntry>());
        await lease.release();
        await channel.close();
      },
    );

    test('a release waits for the lease\'s in-flight operations', () async {
      final gate = Completer<void>();
      remote.downloadGate = (_) => gate;
      final lease = await harness.connections.leaseTransferChannel('srv');
      final sink = CollectingSink();
      final download = lease.fs.download('/srv/a.txt', sink);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      var released = false;
      final release = lease.release().then((_) => released = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // The channel is still in use: it must not go back to the pool yet.
      expect(released, isFalse);
      expect(harness.host.bridgeCounts.leases, 0);
      gate.complete();
      await download;
      await release;
      expect(released, isTrue);
      expect(sink.received, 'alpha'.codeUnits);
    });

    test('engine death fails lease operations disconnected', () async {
      final lease = await harness.connections.leaseTransferChannel('srv');
      await harness.client.shutdown();
      await expectLater(
        lease.fs.stat('/srv/a.txt'),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.disconnected,
          ),
        ),
      );
      // Releasing into a dead engine completes quietly.
      await lease.release();
    });
  });

  group('VFS operations', () {
    late TransferChannelLease lease;
    late RemoteFileSystem fs;

    setUp(() async {
      lease = await harness.connections.leaseTransferChannel('srv');
      fs = lease.fs;
    });

    tearDown(() => lease.release());

    test('metadata calls round-trip against the engine-side VFS', () async {
      expect(await fs.canonicalize('/srv'), '/srv');
      final entry = await fs.stat('/srv/a.txt', followLinks: false);
      expect(entry.size, 5);
      expect(entry.mode, 0x1A4);
      await fs.createDirectory('/srv/new');
      expect(remote.entryAt('/srv/new')?.isDirectory, isTrue);
      await fs.setMode('/srv/a.txt', 0x180);
      expect(remote.setModeCalls, 1);
      final when = DateTime.utc(2024, 1, 2, 3, 4, 5);
      await fs.setTimes('/srv/a.txt', modifiedAt: when);
      expect(remote.mtimes['/srv/a.txt'], when);
      await fs.rename('/srv/a.txt', '/srv/b.txt');
      expect(remote.entryAt('/srv/b.txt'), isNotNull);
      await fs.delete(remote.entryAt('/srv/b.txt')!);
      expect(remote.entryAt('/srv/b.txt'), isNull);
    });

    test('typed failures keep their kind, operation, and path', () async {
      await expectLater(
        fs.stat('/srv/missing'),
        throwsA(
          isA<RemoteFileException>()
              .having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)
              .having((e) => e.path, 'path', '/srv/missing'),
        ),
      );
      await expectLater(
        fs.createDirectory('/srv'),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
    });

    test('an out-of-range mode is refused engine-side, typed', () async {
      await expectLater(
        fs.setMode('/srv/a.txt', 0x1000),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.unsupported,
          ),
        ),
      );
      expect(remote.setModeCalls, 0);
    });

    test('an empty file is created through the VFS upload', () async {
      final proxy = fs as EngineRemoteFileSystem;
      final entry = await proxy.createEmptyFile('/srv/empty.txt');
      expect(entry.size, 0);
      expect(remote.fileBytes['/srv/empty.txt'], isEmpty);
      await expectLater(
        proxy.createEmptyFile('/srv/empty.txt'),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
    });

    test('a content digest hashes engine-side with no byte crossing', () async {
      final entry = await remoteContentDigest(fs, '/srv/big.bin');
      expect(
        entry.contentSha256,
        sha256.convert(remote.fileBytes['/srv/big.bin']!).toString(),
      );
      expect(remote.downloadCalls, 1);
    });
  });

  group('download stream', () {
    test('bytes arrive whole and in order, with progress', () async {
      final lease = await harness.connections.leaseTransferChannel('srv');
      final sink = CollectingSink();
      final progress = <int>[];
      final entry = await lease.fs.download(
        '/srv/big.bin',
        sink,
        onProgress: (transferred, _) => progress.add(transferred),
      );
      expect(sink.received, remote.fileBytes['/srv/big.bin']);
      expect(entry.size, 600 * 1024);
      expect(progress.last, 600 * 1024);
      await lease.release();
    });

    test('a window above the batch cap still streams', () async {
      // Regression: a window over 1 MiB (quarter > the 256 KiB batch cap)
      // re-assigned a late final and failed every download engine-side.
      await harness.dispose();
      harness = BridgeHarness({'srv': remote}, windowBytes: 4 * 1024 * 1024);
      final lease = await harness.connections.leaseTransferChannel('srv');
      final sink = CollectingSink();
      await lease.fs.download('/srv/big.bin', sink);
      expect(sink.received, remote.fileBytes['/srv/big.bin']);
      await lease.release();
    });

    test('a stalled consumer bounds engine-side reads to the window', () async {
      await harness.dispose();
      remote.downloadChunkSize = 8 * 1024;
      harness = BridgeHarness({'srv': remote}, windowBytes: 64 * 1024);
      final probe = PipeProbe();
      remote.pipeProbe = probe;
      final lease = await harness.connections.leaseTransferChannel('srv');
      final sink = GatedSink();
      final download = lease.fs.download('/srv/big.bin', sink);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Nothing consumed yet: the VFS read at most one window plus the
      // batch it is parked on.
      expect(remote.fileBytes['/srv/big.bin']!.length, 600 * 1024);
      expect(probe.peak, lessThanOrEqualTo(64 * 1024 + 16 * 1024 + 8 * 1024));
      sink.open.complete();
      await download;
      expect(sink.received, remote.fileBytes['/srv/big.bin']);
      await lease.release();
    });

    test(
      'cancellation unwinds the engine read and answers cancelled',
      () async {
        final gate = Completer<void>();
        remote.downloadGate = (_) => gate;
        final lease = await harness.connections.leaseTransferChannel('srv');
        final token = RemoteTransferCancellation();
        final download = lease.fs.download(
          '/srv/big.bin',
          CollectingSink(),
          cancellation: token,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        token.cancel();
        gate.complete();
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
        // The lease is healthy afterwards.
        expect(await lease.fs.stat('/srv/a.txt'), isA<RemoteFileEntry>());
        await lease.release();
      },
    );

    test('a sink failure is wrapped like the adapter wraps it', () async {
      final lease = await harness.connections.leaseTransferChannel('srv');
      final sink = GatedSink()
        ..failWith = StateError(
          'The file is larger than the 5-byte editor limit.',
        );
      sink.open.complete();
      await expectLater(
        lease.fs.download('/srv/big.bin', sink),
        throwsA(
          isA<RemoteFileException>()
              .having((e) => e.kind, 'kind', RemoteFileErrorKind.other)
              .having(
                (e) => e.message,
                'message',
                endsWith('5-byte editor limit.'),
              )
              .having((e) => e.cause, 'cause', isA<StateError>()),
        ),
      );
      await lease.release();
    });

    test('an engine-side read failure keeps its kind', () async {
      remote.downloadFailure = (_) => const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'download',
        message: 'socket gone',
      );
      final lease = await harness.connections.leaseTransferChannel('srv');
      await expectLater(
        lease.fs.download('/srv/big.bin', CollectingSink()),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.disconnected,
          ),
        ),
      );
      await lease.release();
    });

    test('a pipe sink sees the source failure as the source error', () async {
      remote.downloadFailure = (_) => const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'download',
        message: 'denied',
      );
      final lease = await harness.connections.leaseTransferChannel('srv');
      final controller = StreamController<List<int>>();
      final sink = BoundedTransferSink(controller, maxBufferedBytes: 1024);
      final drained = sink.stream.drain<void>().catchError((Object _) {});
      await expectLater(
        lease.fs.download('/srv/a.txt', sink),
        throwsA(isA<RemoteFileException>()),
      );
      await drained;
      await lease.release();
    });
  });

  group('upload stream', () {
    test('content lands through the engine-side upload', () async {
      final lease = await harness.connections.leaseTransferChannel('srv');
      final bytes = _bytes(300 * 1024);
      final progress = <int>[];
      final entry = await lease.fs.upload(
        '/srv/up.bin',
        Stream.fromIterable([
          for (var i = 0; i < bytes.length; i += 10000)
            bytes.sublist(
              i,
              i + 10000 > bytes.length ? bytes.length : i + 10000,
            ),
        ]),
        length: bytes.length,
        onProgress: (transferred, _) => progress.add(transferred),
      );
      expect(remote.fileBytes['/srv/up.bin'], bytes);
      expect(entry.size, bytes.length);
      expect(progress.last, bytes.length);
      await lease.release();
    });

    test('a refused upload never subscribes to its content', () async {
      final lease = await harness.connections.leaseTransferChannel('srv');
      var listened = false;
      final content = StreamController<List<int>>(
        onListen: () => listened = true,
      );
      await expectLater(
        lease.fs.upload('/srv/a.txt', content.stream),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
      expect(listened, isFalse);
      await lease.release();
    });

    test('a content failure is the reported cause, nothing lands', () async {
      final lease = await harness.connections.leaseTransferChannel('srv');
      final content = StreamController<List<int>>();
      final upload = lease.fs.upload('/srv/partial.bin', content.stream);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      content.add(_bytes(1000));
      content.addError(StateError('source read failed'));
      await expectLater(
        upload,
        throwsA(
          isA<RemoteFileException>()
              .having((e) => e.message, 'message', contains('source read'))
              .having((e) => e.cause, 'cause', isA<StateError>()),
        ),
      );
      expect(remote.entryAt('/srv/partial.bin'), isNull);
      await lease.release();
    });

    test(
      'a slow engine consumer pauses the content under the window',
      () async {
        await harness.dispose();
        harness = BridgeHarness({'srv': remote}, windowBytes: 32 * 1024);
        final gate = Completer<void>();
        remote.uploadGate = (_) => gate;
        final lease = await harness.connections.leaseTransferChannel('srv');
        var produced = 0;
        final content = Stream<List<int>>.periodic(Duration.zero, (_) {
          produced += 4096;
          return _bytes(4096);
        }).take(64);
        final upload = lease.fs.upload('/srv/slow.bin', content);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // The fake upload is gated before it listens: nothing was pulled.
        expect(produced, 0);
        gate.complete();
        await upload;
        expect(remote.fileBytes['/srv/slow.bin'], hasLength(64 * 4096));
        await lease.release();
      },
    );

    test(
      'a stalled engine writer bounds the content read to the window',
      () async {
        await harness.dispose();
        harness = BridgeHarness({'srv': remote}, windowBytes: 32 * 1024);
        var gate = Completer<void>();
        remote.uploadChunkGate = (_) => gate;
        final lease = await harness.connections.leaseTransferChannel('srv');
        var produced = 0;
        Stream<List<int>> content() async* {
          for (var i = 0; i < 64; i++) {
            produced += 4096;
            yield _bytes(4096);
          }
        }

        final upload = lease.fs.upload('/srv/window.bin', content());
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // The writer holds its first chunk: the client may have at most one
        // window (plus the chunk that tipped it) outstanding.
        expect(produced, lessThanOrEqualTo(32 * 1024 + 2 * 4096));
        remote.uploadChunkGate = null;
        gate.complete();
        gate = Completer<void>()..complete();
        await upload;
        expect(remote.fileBytes['/srv/window.bin'], hasLength(64 * 4096));
        await lease.release();
      },
    );

    test('cancellation unwinds the upload and nothing lands', () async {
      final lease = await harness.connections.leaseTransferChannel('srv');
      final token = RemoteTransferCancellation();
      final content = StreamController<List<int>>();
      final upload = lease.fs.upload(
        '/srv/cancelled.bin',
        content.stream,
        cancellation: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      content.add(_bytes(100));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();
      await expectLater(
        upload,
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.cancelled,
          ),
        ),
      );
      expect(remote.entryAt('/srv/cancelled.bin'), isNull);
      await lease.release();
    });
  });

  test('late stream messages after completion are ignored', () async {
    final lease = await harness.connections.leaseTransferChannel('srv');
    final stream = harness.client.openDownloadStream(
      leaseId: 1,
      path: '/srv/a.txt',
      computeHash: false,
      windowBytes: 1024,
    );
    await stream.events.drain<void>();
    await stream.result;
    stream
      ..credit(4096)
      ..cancel()
      ..end();
    // The engine still serves: a later call answers normally.
    expect(await lease.fs.stat('/srv/a.txt'), isA<RemoteFileEntry>());
    await lease.release();
  });

  group('browse-channel targets', () {
    test('a local channel creates directories and empty files', () async {
      final root = Directory.systemTemp.createTempSync('bridge-channel-');
      addTearDown(() => root.deleteSync(recursive: true));
      final channel = await harness.client.openLocalChannel(
        rootPath: root.path,
      );
      final fs = EngineRemoteFileSystem(
        harness.client,
        ChannelTarget(channel.channelId),
      );
      await fs.createDirectory('${root.path}/folder');
      expect(Directory('${root.path}/folder').existsSync(), isTrue);
      await fs.createEmptyFile('${root.path}/file.txt');
      expect(File('${root.path}/file.txt').lengthSync(), 0);
      await expectLater(
        fs.createEmptyFile('${root.path}/file.txt'),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
      await channel.close();
      await expectLater(
        fs.createDirectory('${root.path}/late'),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.disconnected,
          ),
        ),
      );
    });

    test('byte streams refuse a channel target', () async {
      final fs = EngineRemoteFileSystem(harness.client, const ChannelTarget(9));
      await expectLater(
        fs.download('/x', CollectingSink()),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.unsupported,
          ),
        ),
      );
    });
  });

  test('the engine trash backend reads a dead engine as unavailable', () async {
    final backend = EngineTrashBackend(harness.client);
    await harness.client.shutdown();
    expect(await backend.isAvailable(), isFalse);
    await expectLater(
      backend.trash('/tmp/x'),
      throwsA(
        isA<TrashException>().having(
          (e) => e.kind,
          'kind',
          TrashErrorKind.unavailable,
        ),
      ),
    );
  });

  group('engine local trash', () {
    test(
      'availability and moves cross, failures stay TrashExceptions',
      () async {
        await harness.dispose();
        final backend = _ScriptedTrash();
        harness = BridgeHarness({
          'srv': remote,
        }, localTrash: LocalTrashService.withBackend(backend));
        expect(await harness.client.localTrashAvailable(), isTrue);
        expect(await harness.client.moveToLocalTrash('/tmp/x'), '/trash/x');
        backend.failure = const TrashException(
          kind: TrashErrorKind.failed,
          path: '/tmp/y',
          message: 'gio said no',
        );
        await expectLater(
          harness.client.moveToLocalTrash('/tmp/y'),
          throwsA(
            isA<TrashException>()
                .having((e) => e.kind, 'kind', TrashErrorKind.failed)
                .having((e) => e.path, 'path', '/tmp/y'),
          ),
        );
        expect(backend.trashed, ['/tmp/x', '/tmp/y']);
      },
    );
  });
}

class _ScriptedTrash implements LocalTrashBackend {
  final trashed = <String>[];
  TrashException? failure;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String?> trash(String path) async {
    trashed.add(path);
    final failure = this.failure;
    if (failure != null) throw failure;
    return '/trash/${path.split('/').last}';
  }
}
