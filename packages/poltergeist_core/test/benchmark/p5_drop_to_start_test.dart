// Deterministic contract tests for the P5 drop→start collector
// (packages/poltergeist_core/benchmark/p5_drop_to_start.dart).
//
// Docker is unavailable in this environment, so the connection itself is
// exercised only by the documented real-fixture command (benchmark/README).
// Everything else is pinned here without sockets: the sampler's drop→
// first-byte leg (one classification stat, listing-only first-file scan,
// leased transfer to first byte), warmup discard, repetition identities,
// honest failure/partial output, the owned-temp publication, and mode
// truthfulness run against fakes over the production
// [PaneChannel]/[TransferChannelLease]/[RemoteFileSystem] interfaces, and
// the CLI + checker are driven as real subprocesses with test-owned
// catalog inputs.
//
// The structural half of P5 — "no upfront tree stat" (02 §12, 08 §6) —
// is the two-size test below: a fake filesystem counts the stat calls the
// drop→start path issues between drop and first byte at 1k and 50k
// entries, and the count must stay flat ("O(first file), not O(tree)").

@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import '../../benchmark/p3_listing_overhead.dart' show medianOf;
import '../../benchmark/p5_drop_to_start.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('poltergeist-p5-');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup: a spawned subprocess may still hold a
      // handle (notably on Windows); never mask the real test outcome
      // with a cleanup error.
    }
  });

  Future<P5RunOutcome> collect(
    FakeDropVfs vfs, {
    String droppedPath = '/root',
    int warmups = 1,
    int repetitions = 5,
    Duration operationTimeout = const Duration(seconds: 5),
    Duration deadline = const Duration(minutes: 1),
  }) {
    return collectDropToStartSamples(
      stat: vfs.stat,
      listDirectory: vfs.listDirectory,
      download: vfs.download,
      droppedPath: droppedPath,
      warmups: warmups,
      repetitions: repetitions,
      operationTimeout: operationTimeout,
      deadline: deadline,
    );
  }

  group('collectDropToStartSamples', () {
    test('warmup drops are discarded; measured drops time to first byte',
        () async {
      final vfs = FakeDropVfs(tree: dropTreeSpec());
      final outcome = await collect(vfs, warmups: 2, repetitions: 5);

      expect(outcome.failedRepetition, isNull);
      expect(outcome.measuredDrops, hasLength(5));
      // Each leg: one stat of the dropped root + one root listing +
      // one download of the first file.
      expect(vfs.statCalls, 7);
      expect(vfs.listCalls, 7);
      expect(vfs.downloadCalls, 7);
      for (final sample in outcome.measuredDrops) {
        expect(sample.dropToFirstByte, greaterThan(Duration.zero));
        expect(sample.statCalls, 1);
        expect(sample.listingCalls, 1);
        expect(sample.firstFilePath, '/root/file-0');
        expect(sample.firstChunkBytes, greaterThan(0));
      }
    });

    test(
      'stat calls stay flat between 1k and 50k-entry drops',
      () async {
        // 08 §6's structural assertion, in its falsifiable two-size form:
        // the drop→start path must be O(first file), not O(tree). A path
        // that stated the tree upfront would issue ~1k vs ~50k stats;
        // the lazy scan must issue the same count at both sizes.
        final small = FakeDropVfs(tree: flatTreeSpec(1000));
        final smallOutcome = await collect(
          small,
          warmups: 1,
          repetitions: 1,
        );
        final large = FakeDropVfs(tree: flatTreeSpec(50000));
        final largeOutcome = await collect(
          large,
          warmups: 1,
          repetitions: 1,
        );

        expect(smallOutcome.failedRepetition, isNull);
        expect(largeOutcome.failedRepetition, isNull);
        expect(small.statCalls, smallOutcome.measuredDrops.length + 1);
        expect(large.statCalls, largeOutcome.measuredDrops.length + 1);
        expect(
          smallOutcome.measuredDrops.single.statCalls,
          largeOutcome.measuredDrops.single.statCalls,
          reason: 'the stat count must be identical at 1k and 50k '
              'entries — a growing count means the drop→start path '
              'walks the tree',
        );
        expect(
          smallOutcome.measuredDrops.single.listingCalls,
          largeOutcome.measuredDrops.single.listingCalls,
        );
        // The absolute shape of the accepted path: one classification
        // stat of the dropped root, one listing, one first byte — never
        // a per-entry stat.
        expect(smallOutcome.measuredDrops.single.statCalls, 1);
        expect(largeOutcome.measuredDrops.single.statCalls, 1);
      },
    );

    test('a file drop needs no listing at all', () async {
      final vfs = FakeDropVfs(
        tree: dropTreeSpec(),
        extraFiles: {'/dropped.bin': 'dropped payload'.codeUnits},
      );
      final outcome = await collect(
        vfs,
        droppedPath: '/dropped.bin',
        warmups: 1,
        repetitions: 3,
      );

      expect(outcome.failedRepetition, isNull);
      expect(outcome.droppedKind, 'file');
      expect(outcome.rootEntries, isNull);
      expect(outcome.firstFilePath, '/dropped.bin');
      for (final sample in outcome.measuredDrops) {
        expect(sample.statCalls, 1);
        expect(sample.listingCalls, 0);
      }
    });

    test(
      'a nested first file descends with listings, never extra stats',
      () async {
        // The dropped root holds only directories; the first file lives
        // at /root/a/b/leaf — the lazy scan lists three directories and
        // still issues exactly one stat.
        final vfs = FakeDropVfs(
          tree: {
            '/root': [dropEntry('/root', 'a', RemoteFileType.directory)],
            '/root/a': [dropEntry('/root/a', 'b', RemoteFileType.directory)],
            '/root/a/b': [dropEntry('/root/a/b', 'leaf', RemoteFileType.file)],
          },
        );
        final outcome = await collect(vfs, warmups: 1, repetitions: 3);

        expect(outcome.failedRepetition, isNull);
        expect(outcome.firstFilePath, '/root/a/b/leaf');
        for (final sample in outcome.measuredDrops) {
          expect(sample.statCalls, 1);
          expect(sample.listingCalls, 3);
        }
      },
    );

    test('a dropped symlink fails honestly instead of being followed',
        () async {
        final vfs = FakeDropVfs(
          tree: dropTreeSpec(),
          extraStats: {
            '/link': dropEntry('/', 'link', RemoteFileType.symbolicLink),
          },
        );
        final outcome = await collect(
          vfs,
          droppedPath: '/link',
          warmups: 1,
          repetitions: 5,
        );

        expect(outcome.failedRepetition, 0);
        expect(outcome.measuredDrops, isEmpty);
        expect(outcome.failureMessage, contains('not transferable'));
        expect(vfs.downloadCalls, 0);
      },
    );

    test('a directory tree with no regular file fails honestly', () async {
      final vfs = FakeDropVfs(
        tree: {
          '/root': [dropEntry('/root', 'empty', RemoteFileType.directory)],
          '/root/empty': const [],
        },
      );
      final outcome = await collect(vfs, warmups: 1, repetitions: 5);

      expect(outcome.failedRepetition, 0);
      expect(outcome.measuredDrops, isEmpty);
      expect(outcome.failureMessage, contains('no regular file'));
      expect(vfs.downloadCalls, 0);
    });

    test('a failed stat aborts the run without retry', () async {
      var calls = 0;
      final vfs = FakeDropVfs(tree: dropTreeSpec());
      vfs.statFailureHook = (path) {
        calls++;
        return calls > 3 ? StateError('stat broke') : null;
      };
      final outcome = await collect(vfs, warmups: 1, repetitions: 5);

      // warmup + two measured drops stat fine; the fourth (repetition 2)
      // fails and stops the run.
      expect(outcome.failedRepetition, 2);
      expect(outcome.measuredDrops, hasLength(2));
      expect(outcome.failureMessage, contains('stat broke'));
    });

    test('a wedged listing fails through the per-operation timeout',
        () async {
        final vfs = FakeDropVfs(tree: dropTreeSpec());
        vfs.listingDelay = const Duration(seconds: 30);
        final outcome = await collect(
          vfs,
          warmups: 1,
          repetitions: 5,
          operationTimeout: const Duration(milliseconds: 50),
        );

        expect(outcome.failedRepetition, 0);
        expect(outcome.failureMessage, contains('timed out'));
      },
    );

    test('the whole-run deadline caps an in-flight listing await',
        () async {
        // The verification probe shape: with a 50 ms whole-run budget and
        // a 5 s per-operation timeout, a 2 s listing must not be waited
        // out — the budget caps every await, and expiry is attributed as
        // a run-budget overrun, never as a per-operation timeout.
        final vfs = FakeDropVfs(tree: dropTreeSpec());
        vfs.listingDelay = const Duration(seconds: 2);
        final elapsed = Stopwatch()..start();
        const operationTimeout = Duration(seconds: 5);
        final outcome = await collect(
          vfs,
          warmups: 1,
          repetitions: 5,
          operationTimeout: operationTimeout,
          deadline: const Duration(milliseconds: 50),
        );
        elapsed.stop();

        expect(
          elapsed.elapsed,
          lessThan(const Duration(milliseconds: 1500)),
          reason: 'a 50 ms whole-run budget must bound the listing await, '
              'not wait the 2 s listing out',
        );
        expect(outcome.failedRepetition, 0);
        expect(outcome.failureMessage, contains('run deadline exceeded'));
        expect(
          outcome.failureMessage,
          isNot(
            contains(
              'timed out after ${operationTimeout.inMilliseconds} ms',
            ),
          ),
        );
      },
    );

    test('the run deadline aborts before the next repetition', () async {
      final vfs = FakeDropVfs(tree: dropTreeSpec());
      vfs.listingDelay = const Duration(milliseconds: 40);
      final outcome = await collect(
        vfs,
        warmups: 1,
        repetitions: 5,
        deadline: const Duration(milliseconds: 100),
      );

      expect(outcome.failedRepetition, isNotNull);
      expect(outcome.measuredDrops.length, lessThan(5));
      expect(outcome.failureMessage, contains('deadline'));
    });

    test('a warmup failure reports repetition 0 with unknown identity',
        () async {
        final vfs = FakeDropVfs(tree: dropTreeSpec());
        vfs.statFailure = StateError('warmup exploded');
        final outcome = await collect(vfs, warmups: 1, repetitions: 5);

        expect(outcome.failedRepetition, 0);
        expect(outcome.measuredDrops, isEmpty);
        expect(outcome.rootEntries, isNull);
        expect(outcome.firstFilePath, isNull);
        expect(outcome.failureMessage, contains('warmup exploded'));
      },
    );

    test(
      'a mid-run root-listing change fails instead of smearing identity',
      () async {
        final vfs = FakeDropVfs(tree: dropTreeSpec());
        var rootListings = 0;
        // The tree shrinks after the warmup drop: the first measured
        // listing observes the changed size and the run fails there.
        vfs.afterListing = (path) {
          if (path == '/root' && ++rootListings == 2) {
            vfs.tree['/root']!.removeLast();
          }
        };
        final outcome = await collect(vfs, warmups: 1, repetitions: 5);

        expect(outcome.failedRepetition, 0);
        expect(outcome.measuredDrops, isEmpty);
        // The outcome carries the frozen identity, not the changed
        // observation: the changed count belongs only in the error text.
        expect(outcome.rootEntries, vfs.tree['/root']!.length + 1);
        expect(outcome.failureMessage, contains('identity changed'));
        expect(outcome.failureMessage, contains('root entries'));
      },
    );

    test(
      'a delayed change keeps the frozen identity for completed drops',
      () async {
        final vfs = FakeDropVfs(tree: dropTreeSpec());
        var rootListings = 0;
        // Warmup + two measured drops observe the full tree; the third
        // measured drop observes a shrunk root listing.
        vfs.afterListing = (path) {
          if (path == '/root' && ++rootListings == 4) {
            vfs.tree['/root']!.removeLast();
          }
        };
        final outcome = await collect(vfs, warmups: 1, repetitions: 5);

        expect(outcome.failedRepetition, 2);
        expect(outcome.measuredDrops, hasLength(2));
        expect(outcome.rootEntries, vfs.tree['/root']!.length + 1);
        expect(outcome.failureMessage, contains('identity changed'));
      },
    );

    test('the identity guard also arms without warmups', () async {
      final vfs = FakeDropVfs(tree: dropTreeSpec());
      var rootListings = 0;
      vfs.afterListing = (path) {
        if (path == '/root' && ++rootListings == 2) {
          vfs.tree['/root']!.removeLast();
        }
      };
      final outcome = await collect(vfs, warmups: 0, repetitions: 5);

      expect(outcome.failedRepetition, 1);
      expect(outcome.measuredDrops, hasLength(1));
      expect(outcome.failureMessage, contains('identity changed'));
    });

    test(
      'a mid-run first-file change fails on the same-size listing',
      () async {
        // The root listing keeps its size but the first file is renamed
        // away mid-run: the next drop resolves a different first file,
        // which is a different scenario, not noise.
        final vfs = FakeDropVfs(
          tree: dropTreeSpec(),
          extraFiles: {'/root/zz-last': 'renamed payload'.codeUnits},
        );
        var rootListings = 0;
        vfs.afterListing = (path) {
          if (path == '/root' && ++rootListings == 2) {
            final children = vfs.tree['/root']!;
            children[0] = dropEntry('/root', 'zz-last', RemoteFileType.file);
          }
        };
        final outcome = await collect(vfs, warmups: 1, repetitions: 5);

        expect(outcome.failedRepetition, 0);
        expect(outcome.measuredDrops, isEmpty);
        expect(outcome.firstFilePath, '/root/file-0');
        expect(outcome.failureMessage, contains('identity changed'));
        expect(outcome.failureMessage, contains('first file'));
      },
    );

    test(
      'an empty first file fails instead of reporting a full download',
      () async {
        // No byte ever flows for an empty file, so drop→first-byte is
        // genuinely unobservable — the leg must fail honestly rather than
        // report the full-download time as the start latency.
        final vfs = FakeDropVfs(
          tree: {
            '/root': [dropEntry('/root', 'empty.bin', RemoteFileType.file)],
          },
          fileBytes: {'/root/empty.bin': const []},
        );
        final outcome = await collect(vfs, warmups: 1, repetitions: 5);

        expect(outcome.failedRepetition, 0);
        expect(outcome.measuredDrops, isEmpty);
        expect(outcome.failureMessage, contains('without delivering a byte'));
      },
    );

    test('a cancellation before the first byte is an honest failure',
        () async {
        // A transfer cancelled by an outside actor before any byte must
        // not masquerade as the collector's own first-byte cut.
        final vfs = FakeDropVfs(tree: dropTreeSpec());
        vfs.downloadHook = (path, sink, cancellation) async {
          throw const RemoteFileException(
            kind: RemoteFileErrorKind.cancelled,
            operation: 'download',
            path: '/root/file-0',
            message: 'Transfer cancelled.',
          );
        };
        final outcome = await collect(vfs, warmups: 1, repetitions: 5);

        expect(outcome.failedRepetition, 0);
        expect(outcome.measuredDrops, isEmpty);
        expect(outcome.failureMessage, contains('cancelled'));
      },
    );

    test(
      'an empty leading chunk does not stamp the first-byte signal',
      () async {
        // A real transfer can flush an empty chunk first (header, a
        // zero-length read); the "starts" signal must land on the first
        // NON-EMPTY chunk, not time-to-empty-chunk.
        final vfs = FakeDropVfs(tree: dropTreeSpec())
          ..downloadEmptyLeadingChunk = true;
        final outcome = await collect(vfs, warmups: 1, repetitions: 5);

        expect(outcome.failedRepetition, isNull);
        expect(outcome.measuredDrops, hasLength(5));
        for (final sample in outcome.measuredDrops) {
          expect(
            sample.firstChunkBytes,
            'payload of file-0'.length,
            reason: 'the recorded chunk must be the payload, not the '
                'empty leading chunk',
          );
        }
      },
    );

    test(
      'a writer-side sink error surfaces instead of the empty-file '
      'diagnosis',
      () async {
        // A download that reports its failure through the sink protocol
        // (addError) and then completes normally must surface that
        // failure — without it, the leg would be misdiagnosed as an
        // empty first file.
        final vfs = FakeDropVfs(tree: dropTreeSpec())
          ..downloadSinkError = StateError('writer reported via addError');
        final outcome = await collect(vfs, warmups: 1, repetitions: 5);

        expect(outcome.failedRepetition, 0);
        expect(outcome.measuredDrops, isEmpty);
        expect(
          outcome.failureMessage,
          contains('writer reported via addError'),
        );
        expect(
          outcome.failureMessage,
          isNot(contains('without delivering a byte')),
        );
      },
    );

    test(
      'a fast file completing before the cancel still reports first byte',
      () async {
        // A small file may finish before the first-byte cancellation is
        // observed by the VFS: the download returns normally with the
        // byte already recorded, and the leg still measures to the byte.
        final vfs = FakeDropVfs(tree: dropTreeSpec());
        vfs.honorCancellation = false;
        final outcome = await collect(vfs, warmups: 1, repetitions: 5);

        expect(outcome.failedRepetition, isNull);
        expect(outcome.measuredDrops, hasLength(5));
        for (final sample in outcome.measuredDrops) {
          expect(sample.firstChunkBytes, greaterThan(0));
        }
      },
    );
  });

  group('runP5Collection over a fake channel', () {
    late FakeDropChannel channel;
    late List<String> events;
    late List<FakeDropChannel> opens;
    late List<FakeTransferLease> leases;

    FakeDropChannel buildChannel({Map<String, List<RemoteFileEntry>>? tree}) {
      channel = FakeDropChannel(
        tree: tree ?? dropTreeSpec(rootPath: '/remote/tree'),
        events: (events = <String>[]),
      );
      return channel;
    }

    Future<P5RunResult> run({
      required String outputPath,
      Map<String, List<RemoteFileEntry>>? tree,
      Duration? listingDelay,
      Duration? downloadDelay,
      Object? listingFailure,
      int listingFailureCall = 1,
      Object? downloadFailure,
      int downloadFailureCall = 1,
      Object? canonicalFailure,
      Object? leaseFailure,
      int leaseFailureCall = 1,
      P5FingerprintFields fingerprint = const P5FingerprintFields(
        runnerImage: 'test-image',
        arch: 'x64test',
        dartVersion: 'test-dart',
        flutterVersion: null,
        mode: 'aot',
        cpuModel: 'test-cpu',
      ),
    }) async {
      opens = <FakeDropChannel>[];
      leases = <FakeTransferLease>[];
      var leaseCalls = 0;
      return runP5Collection(
        config: P5CollectorConfig(
          targetPath: '/remote/tree',
          outputPath: outputPath,
          warmups: 1,
          repetitions: 5,
          operationTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        ),
        fingerprint: fingerprint,
        openChannel: () async {
          final opened = buildChannel(tree: tree)
            ..fs.listingDelay = listingDelay
            ..fs.listingFailure = listingFailure
            ..fs.listingFailureCall =
                listingFailure == null ? 1 : listingFailureCall
            ..fs.canonicalFailure = canonicalFailure;
          opens.add(opened);
          return opened;
        },
        // The download knobs live on the lease's own fs (see
        // leaseChannel), not the retained browse channel.
        leaseChannel: () async {
          leaseCalls++;
          if (leaseFailure != null && leaseCalls >= leaseFailureCall) {
            throw leaseFailure;
          }
          // Production hands each lease its own VFS handle; the fake
          // mirrors that with a fresh instance over the same tree so the
          // browse channel's scan calls stay distinguishable from the
          // leased channel's transfer calls.
          final leaseFs = FakeDropVfs(
            tree: channel.fs.tree,
            fileBytes: channel.fs.fileBytes,
          )..downloadDelay = downloadDelay;
          if (downloadFailure != null && leaseCalls == downloadFailureCall) {
            leaseFs.downloadFailure = downloadFailure;
          }
          final lease = FakeTransferLease(fs: leaseFs);
          leases.add(lease);
          return lease;
        },
        releaseServer: () async {},
      );
    }

    test(
      'drops over one browse channel, one lease per leg, cleans up',
      () async {
        final output = '${tempDir.path}/results.json';
        final result = await run(outputPath: output);

        expect(result.exitCode, 0, reason: result.stderr);
        expect(
          opens,
          hasLength(1),
          reason: 'the collector must retain one browse channel for '
              'every drop leg',
        );
        for (final call in channel.fs.calls) {
          expect(call, isNot(startsWith('download:')),
              reason: 'the browse channel only scans; the transfer leg '
                  'runs on the leased channel fs');
        }
        // 1 warmup + 5 measured drops lease a transfer channel each;
        // every lease is released.
        expect(leases, hasLength(6));
        for (final lease in leases) {
          expect(lease.releaseCount, 1);
          expect(
            lease.fs.calls.where((c) => c.startsWith('download:')),
            hasLength(1),
          );
        }
        expect(channel.closeCount, 1);
        expect(channel.reportedFailures, isEmpty);
        for (final lease in leases) {
          expect(lease.reportedFailures, isEmpty);
        }
        expect(result.released, isTrue);
        expect(events, contains('close'));

        final document =
            jsonDecode(await File(output).readAsString())
                as Map<String, Object?>;
        expect(document['schema'], 'poltergeist-d12-results-1');
        final rows = document['rows']! as List<Object?>;
        // Warmup drop excluded from rows: exactly 5 measured repetitions.
        expect(rows, hasLength(5));
        expect(rows.map((r) => (r! as Map<String, Object?>)['repetition']),
            [0, 1, 2, 3, 4]);
        for (final row in rows.cast<Map<String, Object?>>()) {
          expect(row['scenario'], 'P5');
          expect(row['status'], 'ok');
          expect(row['unit'], 'ms');
          // Raw leg detail accompanies every measured row.
          expect(row['statCalls'], 1);
          expect(row['listingCalls'], 1);
          expect(row['firstFile'], '/remote/tree/file-0');
          expect(row['firstChunkBytes'], isA<num>());
          expect(row['legSettledMs'], isA<num>());
          final value = row['value']! as num;
          expect(value.isFinite, isTrue);
          expect(value, greaterThan(0));
          final fingerprint =
              row['fingerprint']! as Map<String, Object?>;
          expect(fingerprint['mode'], 'aot');
          expect(
            fingerprint['scenarioConfig'],
            contains('drop=/remote/tree'),
          );
          expect(
            fingerprint['scenarioConfig'],
            contains('kind=directory'),
          );
        }
        final provenance = document['provenance']! as Map<String, Object?>;
        expect(provenance['statCallsPerDrop'], 1);
        expect(provenance['listingCallsPerDrop'], 1);
        expect(result.stdout, contains('P5'));
        expect(result.stdout, contains('median'));
      },
    );

    test('stdout median matches the checker definition of the rows',
        () async {
        final output = '${tempDir.path}/results.json';
        final result = await run(outputPath: output);
        expect(result.exitCode, 0, reason: result.stderr);

        final document =
            jsonDecode(await File(output).readAsString())
                as Map<String, Object?>;
        final values = [
          for (final row in document['rows']! as List<Object?>)
            ((row! as Map<String, Object?>)['value']! as num).toDouble(),
        ];
        final median = medianOf(values);
        final formatted = median == median.roundToDouble()
            ? median.toInt().toString()
            : median.toStringAsFixed(3);
        expect(result.stdout, contains('median $formatted ms'));
      },
    );

    test('a wedged channel open writes a clean timeout error row',
        () async {
        final output = '${tempDir.path}/results.json';
        final never = Completer<FakeDropChannel>();
        addTearDown(() {
          if (!never.isCompleted) never.complete(buildChannel());
        });
        final result = await runP5Collection(
          config: P5CollectorConfig(
            targetPath: '/remote/tree',
            outputPath: output,
            warmups: 1,
            repetitions: 5,
            operationTimeout: const Duration(seconds: 5),
            deadline: const Duration(minutes: 1),
            channelOpenTimeout: const Duration(milliseconds: 50),
          ),
          fingerprint: const P5FingerprintFields(
            runnerImage: 'test-image',
            arch: 'x64test',
            dartVersion: 'test-dart',
            flutterVersion: null,
            mode: 'aot',
            cpuModel: 'test-cpu',
          ),
          openChannel: () => never.future,
          leaseChannel: () async => FakeTransferLease(fs: channel.fs),
          releaseServer: () async {},
        );

        expect(result.exitCode, 1);
        final document =
            jsonDecode(await File(output).readAsString())
                as Map<String, Object?>;
        final row =
            (document['rows']! as List).single! as Map<String, Object?>;
        expect(row['scenario'], 'P5');
        expect(row['status'], 'error');
        final error = row['error']! as String;
        expect(error, contains('timed out'));
        // The budget message reports the configured timeout in
        // milliseconds, not a truncated seconds figure.
        expect(error, contains('timed out after 50 ms'));
        expect(result.released, isTrue);
      },
    );

    test('setup time is charged against the whole-run deadline', () async {
      // A channel open slower than the whole-run budget must fail the
      // run with a run-budget error row — setup is not free time.
      final output = '${tempDir.path}/results.json';
      final result = await runP5Collection(
        config: P5CollectorConfig(
          targetPath: '/remote/tree',
          outputPath: output,
          warmups: 1,
          repetitions: 5,
          operationTimeout: const Duration(seconds: 5),
          deadline: const Duration(milliseconds: 30),
          channelOpenTimeout: const Duration(seconds: 5),
        ),
        fingerprint: const P5FingerprintFields(
          runnerImage: 'test-image',
          arch: 'x64test',
          dartVersion: 'test-dart',
          flutterVersion: null,
          mode: 'aot',
          cpuModel: 'test-cpu',
        ),
        openChannel: () async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return buildChannel();
        },
        leaseChannel: () async => FakeTransferLease(fs: channel.fs),
        releaseServer: () async {},
      );

      expect(result.exitCode, 1);
      final document =
          jsonDecode(await File(output).readAsString())
              as Map<String, Object?>;
      final row =
          (document['rows']! as List).single! as Map<String, Object?>;
      expect(row['status'], 'error');
      expect(row['error'], contains('run deadline exceeded'));
      expect(result.released, isTrue);
    });

    test(
      'an unpublishable results file on a pre-drop failure exits 74',
      () async {
        // The exit-code contract is uniform: results-write IO failure is
        // EX_IOERR on the pre-drop path too, not masked as a generic
        // measurement failure.
        final foreign = File('${tempDir.path}/foreign');
        await foreign.writeAsString('foreign payload');
        final channel = FakeDropChannel(
          tree: dropTreeSpec(rootPath: '/remote/tree'),
          events: events = <String>[],
        )..fs.canonicalFailure = StateError('canonicalize broke');
        final result = await runP5Collection(
          config: P5CollectorConfig(
            targetPath: '/remote/tree',
            outputPath: '${tempDir.path}/results.json',
            warmups: 1,
            repetitions: 5,
            operationTimeout: const Duration(seconds: 5),
            deadline: const Duration(minutes: 1),
          ),
          fingerprint: const P5FingerprintFields(
            runnerImage: 'test-image',
            arch: 'x64test',
            dartVersion: 'test-dart',
            flutterVersion: null,
            mode: 'aot',
            cpuModel: 'test-cpu',
          ),
          openChannel: () async => channel,
          leaseChannel: () async => FakeTransferLease(fs: channel.fs),
          releaseServer: () async {},
          tempCandidateName: (_) => foreign.path,
        );

        expect(result.exitCode, 74);
        expect(result.stderr, contains('cannot write results'));
        expect(await foreign.readAsString(), 'foreign payload');
        expect(
          await File('${tempDir.path}/results.json').exists(),
          isFalse,
        );
      },
    );

    test('a canonicalize failure writes a single honest error row',
        () async {
        final output = '${tempDir.path}/results.json';
        final result = await run(
          outputPath: output,
          canonicalFailure: StateError('canonicalize broke'),
        );

        expect(result.exitCode, 1);
        final document =
            jsonDecode(await File(output).readAsString())
                as Map<String, Object?>;
        final rows = document['rows']! as List<Object?>;
        expect(rows, hasLength(1));
        final row = rows.single! as Map<String, Object?>;
        expect(row['status'], 'error');
        expect(row['repetition'], 0);
        expect(row['error'], contains('canonicalize broke'));
        final fingerprint =
            row['fingerprint']! as Map<String, Object?>;
        expect(
          fingerprint['scenarioConfig'],
          contains('root-entries=unknown'),
        );
      },
    );

    test('a lease failure inside a leg writes partial rows and an error '
        'row', () async {
        final output = '${tempDir.path}/results.json';
        final result = await run(
          outputPath: output,
          leaseFailure: StateError('no transfer channel free'),
          // 1 warmup + 2 measured drops lease fine; the fourth lease
          // (measured repetition 2) fails and ends the run.
          leaseFailureCall: 4,
        );

        expect(result.exitCode, 1);
        final document =
            jsonDecode(await File(output).readAsString())
                as Map<String, Object?>;
        final rows = document['rows']! as List<Object?>;
        final okRows =
            rows.where((r) => (r! as Map)['status'] == 'ok').toList();
        final errorRows =
            rows.where((r) => (r! as Map)['status'] == 'error').toList();
        expect(okRows, hasLength(2));
        expect(errorRows, hasLength(1));
        final errorRow = errorRows.single! as Map<String, Object?>;
        expect(errorRow['error'], contains('no transfer channel free'));
        expect(errorRow.containsKey('value'), isFalse);
        // Cleanup ran despite the failure.
        expect(channel.closeCount, 1);
        expect(result.released, isTrue);
      },
    );

    test('a mid-run download failure writes partial rows and an error row',
        () async {
        final output = '${tempDir.path}/results.json';
        final result = await run(
          outputPath: output,
          downloadFailure: const RemoteFileException(
            kind: RemoteFileErrorKind.permissionDenied,
            operation: 'download',
            path: '/remote/tree/file-0',
            message: 'permission denied by fixture',
          ),
          // 1 warmup + 2 measured drops download fine; the fourth
          // download (measured repetition 2) fails.
          downloadFailureCall: 4,
        );

        expect(result.exitCode, 1);
        final document =
            jsonDecode(await File(output).readAsString())
                as Map<String, Object?>;
        final rows = document['rows']! as List<Object?>;
        final okRows =
            rows.where((r) => (r! as Map)['status'] == 'ok').toList();
        final errorRows =
            rows.where((r) => (r! as Map)['status'] == 'error').toList();
        expect(okRows, hasLength(2));
        expect(errorRows, hasLength(1));
        final errorRow = errorRows.single! as Map<String, Object?>;
        expect(errorRow['error'], contains('permission denied by fixture'));
        expect(channel.closeCount, 1);
        expect(result.released, isTrue);
      },
    );

    test(
      'partial rows keep the frozen scenarioConfig after a mid-run '
      'change',
      () async {
        final output = '${tempDir.path}/results.json';
        final tree = dropTreeSpec(rootPath: '/remote/tree');
        final channel = FakeDropChannel(
          tree: tree,
          events: events = <String>[],
        );
        // After the warmup + first two measured drops, the tree shrinks:
        // the fourth root listing (measured repetition 2) observes the
        // changed size, and the run fails there.
        var rootListings = 0;
        channel.fs.afterListing = (path) {
          if (path == '/remote/tree' && ++rootListings == 4) {
            tree['/remote/tree']!.removeLast();
          }
        };
        final result = await runP5Collection(
          config: P5CollectorConfig(
            targetPath: '/remote/tree',
            outputPath: output,
            warmups: 1,
            repetitions: 5,
            operationTimeout: const Duration(seconds: 5),
            deadline: const Duration(minutes: 1),
          ),
          fingerprint: const P5FingerprintFields(
            runnerImage: 'test-image',
            arch: 'x64test',
            dartVersion: 'test-dart',
            flutterVersion: null,
            mode: 'aot',
            cpuModel: 'test-cpu',
          ),
          openChannel: () async => channel,
          leaseChannel: () async => FakeTransferLease(fs: channel.fs),
          releaseServer: () async {},
        );

        expect(result.exitCode, 1);
        expect(result.stderr, contains('identity changed'));
        final document =
            jsonDecode(await File(output).readAsString())
                as Map<String, Object?>;
        final rows = document['rows']! as List<Object?>;
        expect(rows, hasLength(3));
        final frozenEntries = tree['/remote/tree']!.length + 1;
        for (final row in rows.cast<Map<String, Object?>>()) {
          final fingerprint =
              row['fingerprint']! as Map<String, Object?>;
          // Every row — ok and error — carries the frozen identity the
          // successful drops were measured under; the changed count
          // appears only in the error row's text.
          expect(
            fingerprint['scenarioConfig'],
            contains(';root-entries=$frozenEntries;'),
          );
          expect(
            fingerprint['scenarioConfig'],
            isNot(contains(';root-entries=${frozenEntries - 1};')),
          );
        }
        final errorRow = rows.last! as Map<String, Object?>;
        expect(errorRow['status'], 'error');
        expect(
          errorRow['error'],
          contains('$frozenEntries->${frozenEntries - 1}'),
        );
      },
    );

    test('a file drop reports kind=file and no root listing', () async {
      final output = '${tempDir.path}/results.json';
      final channel = FakeDropChannel(
        tree: dropTreeSpec(rootPath: '/remote/tree'),
        events: events = <String>[],
        extraFiles: {
          '/remote/one.bin': 'single file payload'.codeUnits,
        },
      );
      final result = await runP5Collection(
        config: P5CollectorConfig(
          targetPath: '/remote/one.bin',
          outputPath: output,
          warmups: 1,
          repetitions: 5,
          operationTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        ),
        fingerprint: const P5FingerprintFields(
          runnerImage: 'test-image',
          arch: 'x64test',
          dartVersion: 'test-dart',
          flutterVersion: null,
          mode: 'aot',
          cpuModel: 'test-cpu',
        ),
        openChannel: () async => channel,
        leaseChannel: () async => FakeTransferLease(fs: channel.fs),
        releaseServer: () async {},
      );

      expect(result.exitCode, 0, reason: result.stderr);
      final document =
          jsonDecode(await File(output).readAsString())
              as Map<String, Object?>;
      final row =
          (document['rows']! as List).first! as Map<String, Object?>;
      expect(row['statCalls'], 1);
      expect(row['listingCalls'], 0);
      final fingerprint = row['fingerprint']! as Map<String, Object?>;
      expect(fingerprint['scenarioConfig'], contains('kind=file'));
      expect(
        fingerprint['scenarioConfig'],
        contains('root-entries=n/a-file-drop'),
      );
    });
  });

  group('results temp ownership', () {
    Future<P5RunResult> runWithCandidates(
      String output,
      String Function(int attempt) candidateName,
    ) {
      final channel = FakeDropChannel(
        tree: dropTreeSpec(rootPath: '/remote/tree'),
        events: <String>[],
      );
      return runP5Collection(
        config: P5CollectorConfig(
          targetPath: '/remote/tree',
          outputPath: output,
          warmups: 1,
          repetitions: 5,
          operationTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        ),
        fingerprint: const P5FingerprintFields(
          runnerImage: 'test-image',
          arch: 'x64test',
          dartVersion: 'test-dart',
          flutterVersion: null,
          mode: 'aot',
          cpuModel: 'test-cpu',
        ),
        openChannel: () async => channel,
        leaseChannel: () async => FakeTransferLease(fs: channel.fs),
        releaseServer: () async {},
        tempCandidateName: candidateName,
      );
    }

    test(
      'a preexisting file at a candidate name is never overwritten',
      () async {
        final output = '${tempDir.path}/results.json';
        final foreign = File('${tempDir.path}/foreign');
        await foreign.writeAsString('foreign payload');
        var attemptsSeen = 0;

        final result = await runWithCandidates(output, (attempt) {
          attemptsSeen++;
          // The first candidate collides with a foreign regular file; the
          // second must be a fresh, claimable name.
          return attempt == 1 ? foreign.path : '$output.owned-$attempt.tmp';
        });

        expect(result.exitCode, 0, reason: result.stderr);
        expect(
          attemptsSeen,
          greaterThanOrEqualTo(2),
          reason:
              'the foreign-name collision and retry must be exercised, '
              'not assumed through the attempt numbering',
        );
        expect(
          await foreign.readAsString(),
          'foreign payload',
          reason:
              'a foreign file at a candidate name must never be '
              'truncated',
        );
        expect(
          await File(output).exists(),
          isTrue,
          reason: 'the write must claim a different owned name and publish',
        );
        expect(
          await File('$output.owned-2.tmp').exists(),
          isFalse,
          reason: 'the owned temp is renamed away, not left behind',
        );
      },
    );

    test(
      'a preexisting symlink at a candidate name is never followed',
      () async {
        final canCreateSymlinks = await () async {
          try {
            final probeLink = Link('${tempDir.path}/probe-link');
            await probeLink.create(
              '${tempDir.path}/probe-target',
              recursive: false,
            );
            await probeLink.delete();
            return true;
          } on FileSystemException {
            return false;
          }
        }();
        if (!canCreateSymlinks) {
          markTestSkipped(
            'symlink creation unavailable on this platform/privilege '
            '(Windows privilege probing per STATUS open item 1)',
          );
          return;
        }

        final output = '${tempDir.path}/results.json';
        final sentinel = File('${tempDir.path}/sentinel');
        await sentinel.writeAsString('sentinel payload');
        final planted = Link('${tempDir.path}/planted.tmp');
        await planted.create(sentinel.path);
        var attemptsSeen = 0;

        final result = await runWithCandidates(output, (attempt) {
          attemptsSeen++;
          return attempt == 1 ? planted.path : '$output.owned-$attempt.tmp';
        });

        expect(result.exitCode, 0, reason: result.stderr);
        expect(
          attemptsSeen,
          greaterThanOrEqualTo(2),
          reason: 'the planted-symlink collision and retry must be exercised',
        );
        expect(
          await sentinel.readAsString(),
          'sentinel payload',
          reason:
              'following the planted symlink would truncate the '
              'sentinel — concrete data loss',
        );
        expect(
          await FileSystemEntity.type(planted.path, followLinks: false),
          FileSystemEntityType.link,
        );
        expect(await File(output).exists(), isTrue);
      },
    );

    test(
      'exhausted candidates fail closed without touching foreign files',
      () async {
        final output = '${tempDir.path}/results.json';
        final foreign = File('${tempDir.path}/foreign');
        await foreign.writeAsString('foreign payload');

        final result = await runWithCandidates(
          output,
          (attempt) => foreign.path, // every candidate collides
        );

        expect(result.exitCode, 74);
        expect(result.stderr, contains('cannot write results'));
        expect(await foreign.readAsString(), 'foreign payload');
        expect(await File(output).exists(), isFalse);
      },
    );
  });

  group('P5CollectorConfig.parse', () {
    test('a repeated flag is rejected instead of silently first-wins', () {
      expect(
        () => P5CollectorConfig.parse([
          '--output',
          'a.json',
          '--repetitions',
          '5',
          '--repetitions',
          '20',
          '--target',
          '/t',
        ]),
        throwsA(isA<P5UsageException>()),
      );
    });

    test('a flag token swallowed as a value is rejected', () {
      expect(
        () => P5CollectorConfig.parse([
          '--output',
          'a.json',
          '--target',
          '--warmups',
          '3',
        ]),
        throwsA(isA<P5UsageException>()),
      );
    });

    test('a normal invocation still parses', () {
      final config = P5CollectorConfig.parse([
        '--output',
        'a.json',
        '--target',
        '/t',
        '--repetitions',
        '7',
      ]);
      expect(config.repetitions, 7);
      expect(config.targetPath, '/t');
    });

    test('a positional argument is rejected, not silently dropped', () {
      // The typo the doc comment promises can never slip through:
      // a missing '--' prefix would otherwise run with the default 5
      // repetitions.
      expect(
        () => P5CollectorConfig.parse([
          '--output',
          'a.json',
          '--target',
          '/t',
          'repetitions',
          '20',
        ]),
        throwsA(isA<P5UsageException>()),
      );
      expect(
        () => P5CollectorConfig.parse([
          '--output',
          'a.json',
          '--target',
          '/t',
          'stray-path',
        ]),
        throwsA(isA<P5UsageException>()),
      );
    });

    test('an empty flag value is rejected for every flag', () {
      expect(
        () => P5CollectorConfig.parse([
          '--output',
          'a.json',
          '--target',
          '/t',
          '--host-key-pub',
          '',
        ]),
        throwsA(isA<P5UsageException>()),
      );
    });
  });

  group('CLI contract (subprocess)', () {
    late String packageDir;
    late String collectorPath;

    setUpAll(() async {
      final packageUri = await Isolate.resolvePackageUri(
        Uri.parse('package:poltergeist_core/poltergeist_core.dart'),
      );
      expect(
        packageUri,
        isNotNull,
        reason: 'core package must be resolvable for CLI subprocess tests',
      );
      final packageRoot = packageUri!
          .resolve('../')
          .toFilePath(); // packages/poltergeist_core
      packageDir = packageRoot;
      collectorPath = '$packageDir/benchmark/p5_drop_to_start.dart';
      expect(
        await File(collectorPath).exists(),
        isTrue,
        reason: 'collector entrypoint must exist',
      );
    });

    Future<ProcessResult> runCollector(
      List<String> args, {
      Map<String, String> environment = const {},
      Set<String> absentEnvironment = const {},
    }) async {
      final env = Map<String, String>.of(Platform.environment)
        ..addAll(environment)
        ..removeWhere((name, _) => absentEnvironment.contains(name));
      return Process.run(
        Platform.resolvedExecutable,
        ['run', 'benchmark/p5_drop_to_start.dart', ...args],
        workingDirectory: packageDir,
        environment: env,
      );
    }

    test('help exits 0 with usage', () async {
      final result = await runCollector(['--help']);
      expect(result.exitCode, 0);
      expect(result.stdout as String, contains('Usage'));
      expect(result.stderr as String, isEmpty);
    });

    test('missing --output is an actionable usage failure', () async {
      final result = await runCollector(['--target', '/a']);
      expect(result.exitCode, 2);
      expect(result.stderr as String, contains('--output'));
    });

    test('missing --target is an actionable usage failure', () async {
      final result = await runCollector([
        '--output',
        '${tempDir.path}/results.json',
      ]);
      expect(result.exitCode, 2);
      expect(result.stderr as String, contains('--target'));
    });

    test('missing fixture env names every absent variable', () async {
      const fixtureEnvNames = {
        'POLTERGEIST_SSHD',
        'POLTERGEIST_SSHD_MODERN',
        'POLTERGEIST_SSHD_USER',
        'POLTERGEIST_SSHD_KEY',
      };
      final result = await runCollector(
        [
          '--output',
          '${tempDir.path}/results.json',
          '--target',
          '/remote/tree',
        ],
        absentEnvironment: fixtureEnvNames,
      );
      expect(result.exitCode, 2);
      final stderrText = result.stderr as String;
      for (final variable in fixtureEnvNames) {
        expect(stderrText, contains(variable));
      }
      expect(await File('${tempDir.path}/results.json').exists(), isFalse);
    });

    test('a non-loopback fixture host is rejected before connecting', () async {
      final result = await runCollector(
        [
          '--output',
          '${tempDir.path}/results.json',
          '--target',
          '/remote/tree',
        ],
        environment: {
          'POLTERGEIST_SSHD': '192.0.2.1',
          'POLTERGEIST_SSHD_MODERN': '2201',
          'POLTERGEIST_SSHD_USER': 'poltergeist',
          'POLTERGEIST_SSHD_KEY': '${tempDir.path}/missing-key',
        },
      );
      expect(result.exitCode, 2);
      expect(result.stderr as String, contains('loopback'));
    });

    test('repetitions below the checker floor are rejected', () async {
      final bad = await runCollector(
        [
          '--output',
          '${tempDir.path}/results.json',
          '--target',
          '/a',
          '--repetitions',
          '4',
        ],
        environment: {
          'POLTERGEIST_SSHD': '127.0.0.1',
          'POLTERGEIST_SSHD_MODERN': '2201',
          'POLTERGEIST_SSHD_USER': 'poltergeist',
          'POLTERGEIST_SSHD_KEY': '${tempDir.path}/missing-key',
        },
      );
      expect(bad.exitCode, 2);
      expect(bad.stderr as String, contains('repetitions'));
    });

    test('an unknown flag is rejected instead of silently ignored', () async {
      final result = await runCollector([
        '--output',
        '${tempDir.path}/results.json',
        '--target',
        '/a',
        '--repetition', // typo: the trailing s is missing
        '10',
      ]);
      expect(result.exitCode, 2);
      expect(result.stderr as String, contains('--repetition'));
      expect(result.stderr as String, contains('unknown option'));
    });

    test(
      'zero warmups are rejected: the protocol requires warm drops',
      () async {
        final result = await runCollector([
          '--output',
          '${tempDir.path}/results.json',
          '--target',
          '/a',
          '--warmups',
          '0',
        ]);
        expect(result.exitCode, 2);
        expect(result.stderr as String, contains('--warmups'));
      },
    );
  });

  group('real checker CLI against collector output', () {
    late String repoRoot;
    late String checkerPath;

    setUpAll(() async {
      final packageUri = await Isolate.resolvePackageUri(
        Uri.parse('package:poltergeist_core/poltergeist_core.dart'),
      );
      repoRoot = packageUri!.resolve('../../../').toFilePath();
      checkerPath = '$repoRoot/test/benchmarks/check.dart';
      expect(await File(checkerPath).exists(), isTrue);
    });

    /// Runs the real check.dart CLI as a subprocess with the ambient
    /// enforcement flags scrubbed — one place owns the flag/env wiring
    /// so the mixed-file test below cannot drift.
    Future<(int, String, String)> runCheckerCli({
      required String resultsPath,
      required String budgetsPath,
      bool enforceA = false,
    }) async {
      final env = Map<String, String>.of(Platform.environment)
        ..remove('BENCH_ENFORCE_A')
        ..remove('BENCH_ENFORCE_B');
      if (enforceA) env['BENCH_ENFORCE_A'] = '1';
      final checker = await Process.run(
        Platform.resolvedExecutable,
        [
          checkerPath,
          '--results',
          resultsPath,
          '--tiers',
          'a',
          '--budgets',
          budgetsPath,
        ],
        workingDirectory: repoRoot,
        environment: env,
      );
      return (
        checker.exitCode,
        checker.stdout as String,
        checker.stderr as String,
      );
    }

    /// Collects through the real sampler/writer against fakes with an
    /// injected (test-owned) fingerprint, then hands the emitted file to
    /// the real check.dart CLI with a test-owned budgets catalog.
    Future<(int, String, String)> collectAndCheck({
      Duration? downloadDelay,
      required bool enforce,
      bool landed = true,
    }) async {
      final output = '${tempDir.path}/results.json';
      final events = <String>[];
      final channel = FakeDropChannel(
        tree: dropTreeSpec(rootPath: '/remote/tree', rootFiles: 40),
        events: events,
      )..fs.downloadDelay = downloadDelay;
      final collection = await runP5Collection(
        config: P5CollectorConfig(
          targetPath: '/remote/tree',
          outputPath: output,
          warmups: 1,
          repetitions: 5,
          operationTimeout: const Duration(seconds: 30),
          deadline: const Duration(minutes: 5),
        ),
        fingerprint: const P5FingerprintFields(
          runnerImage: 'test-image',
          arch: 'x64test',
          dartVersion: 'test-dart',
          flutterVersion: null,
          mode: 'aot',
          cpuModel: 'test-cpu',
        ),
        openChannel: () async => channel,
        leaseChannel: () async => FakeTransferLease(fs: channel.fs),
        releaseServer: () async {},
      );
      expect(collection.exitCode, 0, reason: collection.stderr);
      expect(events, contains('close'));

      // Derive the test-owned calibration from the emitted fingerprint so
      // every common controlled axis matches by construction. The config
      // axis lives at its schema-2 home: the scenario's own
      // calibratedScenarioConfig, never a job-wide fingerprint claim.
      final emitted =
          jsonDecode(await File(output).readAsString()) as Map<String, Object?>;
      final emittedRows = emitted['rows']! as List;
      expect(
        emittedRows,
        isNotEmpty,
        reason: 'collector must emit rows for calibration to be derived',
      );
      final firstRow = emittedRows.first! as Map<String, Object?>;
      final rowFingerprint = firstRow['fingerprint']! as Map<String, Object?>;
      final calibration = {...rowFingerprint}..remove('scenarioConfig');
      final budgets = {
        'schema': 'poltergeist-d12-budgets-2',
        'calibratedFingerprint': calibration,
        'scenarios': [
          {
            'id': 'P5',
            'tier': 'a',
            'summary': 'Drop to transfer start (no upfront tree stat)',
            'operator': 'lessThan',
            'value': 500,
            'unit': 'ms',
            'minimumRepetitions': 3,
            'landed': landed,
            if (landed)
              'calibratedScenarioConfig': rowFingerprint['scenarioConfig'],
          },
        ],
      };
      final budgetsPath = '${tempDir.path}/budgets.json';
      await File(budgetsPath).writeAsString(jsonEncode(budgets));

      return runCheckerCli(
        resultsPath: output,
        budgetsPath: budgetsPath,
        enforceA: enforce,
      );
    }

    test('passes with matching test calibration', () async {
      final (exit, stdoutText, stderrText) = await collectAndCheck(
        downloadDelay: Duration.zero,
        enforce: true,
      );
      expect(exit, 0, reason: stderrText);
      expect(
        stdoutText,
        contains(RegExp(r'^P5\s+a\s.*pass$', multiLine: true)),
      );
    });

    test(
      'an enforced overrun through real collector output fails red',
      () async {
        // A 600 ms first-byte delay per drop over the 500 ms budget.
        final (exit, stdoutText, stderrText) = await collectAndCheck(
          downloadDelay: const Duration(milliseconds: 600),
          enforce: true,
        );
        expect(exit, 1, reason: stderrText);
        expect(stdoutText, contains('overrun (fail: enforced)'));
      },
    );

    test('a non-enforced overrun reports without failing the run', () async {
      final (exit, stdoutText, stderrText) = await collectAndCheck(
        downloadDelay: const Duration(milliseconds: 600),
        enforce: false,
      );
      expect(exit, 0, reason: stderrText);
      expect(stdoutText, contains('overrun (notice: not enforced)'));
    });

    test(
      'unlanded P3+P5+P7 rows in one results file all report, exit 0',
      () async {
        // The shared-file contract 08 §6 prescribes: one results file
        // carries every scenario the job ran, each with its own
        // scenarioConfig. The P5 rows below are real collector output;
        // the P3/P7 rows are synthetic but schema-correct, mirroring the
        // checker's own committed fixture (check_cli_test).
        final output = '${tempDir.path}/results.json';
        final channel = FakeDropChannel(
          tree: dropTreeSpec(rootPath: '/remote/tree'),
          events: <String>[],
        );
        final collection = await runP5Collection(
          config: P5CollectorConfig(
            targetPath: '/remote/tree',
            outputPath: output,
            warmups: 1,
            repetitions: 5,
            operationTimeout: const Duration(seconds: 30),
            deadline: const Duration(minutes: 5),
          ),
          fingerprint: const P5FingerprintFields(
            runnerImage: 'test-image',
            arch: 'x64test',
            dartVersion: 'test-dart',
            flutterVersion: null,
            mode: 'aot',
            cpuModel: 'test-cpu',
          ),
          openChannel: () async => channel,
          leaseChannel: () async => FakeTransferLease(fs: channel.fs),
          releaseServer: () async {},
        );
        expect(collection.exitCode, 0, reason: collection.stderr);

        final emitted =
            jsonDecode(await File(output).readAsString())
                as Map<String, Object?>;
        final p5Rows = emitted['rows']! as List<Object?>;
        expect(
          p5Rows,
          isNotEmpty,
          reason: 'collector must emit rows for the mixed-file check',
        );
        final p5Fingerprint =
            (p5Rows.first! as Map<String, Object?>)['fingerprint']!
                as Map<String, Object?>;
        // Same job-wide controlled axes, each scenario's own per-scenario
        // config.
        final p3Fingerprint = {...p5Fingerprint}
          ..['scenarioConfig'] =
              'p3/v1;target=/remote/tree;control=/remote/c';
        final p7Fingerprint = {...p5Fingerprint}
          ..['scenarioConfig'] =
              'p7/v1;root=/remote/tree;entries=8;directories=4';
        final p3Rows = [
          for (var i = 0; i < 5; i++)
            {
              'scenario': 'P3',
              'repetition': i,
              'status': 'ok',
              'value': 40.0,
              'unit': 'ms',
              'fingerprint': p3Fingerprint,
            },
        ];
        final p7Rows = [
          for (var i = 0; i < 5; i++)
            {
              'scenario': 'P7',
              'repetition': i,
              'status': 'ok',
              'value': 1200.0,
              'unit': 'entries/s',
              'fingerprint': p7Fingerprint,
            },
        ];
        final combined = {
          'schema': 'poltergeist-d12-results-1',
          'rows': [...p3Rows, ...p5Rows, ...p7Rows],
        };
        final combinedPath = '${tempDir.path}/combined-results.json';
        await File(combinedPath).writeAsString(jsonEncode(combined));

        // Test-owned catalog: all three scenarios present, all unlanded.
        final budgets = {
          'schema': 'poltergeist-d12-budgets-2',
          'calibratedFingerprint': null,
          'scenarios': [
            {
              'id': 'P3',
              'tier': 'a',
              'summary': 'Remote listing overhead over network time',
              'operator': 'lessThan',
              'value': 50,
              'unit': 'ms',
              'minimumRepetitions': 5,
              'landed': false,
            },
            {
              'id': 'P5',
              'tier': 'a',
              'summary':
                  'Drop to transfer start (no upfront tree stat)',
              'operator': 'lessThan',
              'value': 500,
              'unit': 'ms',
              'minimumRepetitions': 3,
              'landed': false,
            },
            {
              'id': 'P7',
              'tier': 'a',
              'summary': 'Sync scan rate, LAN',
              'operator': 'atLeast',
              'value': 1000,
              'unit': 'entries/s',
              'minimumRepetitions': 3,
              'landed': false,
            },
          ],
        };
        final budgetsPath = '${tempDir.path}/budgets.json';
        await File(budgetsPath).writeAsString(jsonEncode(budgets));

        final (exit, stdoutText, stderrText) = await runCheckerCli(
          resultsPath: combinedPath,
          budgetsPath: budgetsPath,
        );
        expect(exit, 0, reason: stderrText);
        for (final scenario in ['P3', 'P5', 'P7']) {
          expect(
            stdoutText,
            contains(
              RegExp(
                '^${RegExp.escape(scenario)}\\s+a\\s.*'
                'reported \\(unlanded\\)\$',
                multiLine: true,
              ),
            ),
          );
        }
      },
    );
  });
}

/// The standard fixture-shaped tree: [rootFiles] files plus `a/` and `b/`
/// directories (each holding [dirFiles] files) and `a/c/` with
/// [dirFiles] files.
Map<String, List<RemoteFileEntry>> dropTreeSpec({
  String rootPath = '/root',
  int rootFiles = 8,
  int dirFiles = 1,
}) {
  final tree = <String, List<RemoteFileEntry>>{
    rootPath: [
      for (var i = 0; i < rootFiles; i++)
        dropEntry(rootPath, 'file-$i', RemoteFileType.file),
      dropEntry(rootPath, 'a', RemoteFileType.directory),
      dropEntry(rootPath, 'b', RemoteFileType.directory),
    ],
    '$rootPath/a': [
      dropEntry('$rootPath/a', 'c', RemoteFileType.directory),
      for (var i = 0; i < dirFiles; i++)
        dropEntry('$rootPath/a', 'file-$i', RemoteFileType.file),
    ],
    '$rootPath/b': [
      for (var i = 0; i < dirFiles; i++)
        dropEntry('$rootPath/b', 'file-$i', RemoteFileType.file),
    ],
    '$rootPath/a/c': [
      for (var i = 0; i < dirFiles; i++)
        dropEntry('$rootPath/a/c', 'file-$i', RemoteFileType.file),
    ],
  };
  return tree;
}

/// A flat tree of [entries] files directly under `/root` — the two-size
/// fixture for the flat-stat-count structural assertion.
Map<String, List<RemoteFileEntry>> flatTreeSpec(int entries) => {
  '/root': [
    for (var i = 0; i < entries; i++)
      dropEntry('/root', 'entry-$i', RemoteFileType.file),
  ],
};

RemoteFileEntry dropEntry(String parent, String name, RemoteFileType type) =>
    RemoteFileEntry(path: '$parent/$name', name: name, type: type);

/// Fake browse channel over the production interface; records lifecycle
/// events so one-channel and cleanup contracts are observable.
class FakeDropChannel implements PaneChannel {
  final List<String> events;

  int closeCount = 0;

  /// Failure callbacks the collector reports — a clean run must leave
  /// this empty.
  final List<RemoteFileException> reportedFailures = [];

  FakeDropChannel({
    required Map<String, List<RemoteFileEntry>> tree,
    required this.events,
    Map<String, List<int>> extraFiles = const {},
  }) : fs = FakeDropVfs(tree: tree, extraFiles: extraFiles) {
    fs.events = events;
  }

  @override
  final FakeDropVfs fs;

  @override
  String get homePath => '/remote';

  @override
  Future<void> close() async {
    closeCount++;
    events.add('close');
  }

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {
    reportedFailures.add(error);
  }
}

/// Fake transfer-channel lease over the production interface; counts
/// releases so the per-leg lease/release contract is observable.
class FakeTransferLease implements TransferChannelLease {
  int releaseCount = 0;

  /// Failure callbacks the collector reports — a clean run must leave
  /// this empty.
  final List<RemoteFileException> reportedFailures = [];

  FakeTransferLease({required this.fs});

  @override
  final FakeDropVfs fs;

  @override
  Future<void> release() async {
    releaseCount++;
  }

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {
    reportedFailures.add(error);
  }
}

/// Fake VFS over an in-memory tree map: counts every stat/list/download
/// call (the seam behind the flat-stat structural assertion), and fails
/// loudly on anything else (08 §3.2).
class FakeDropVfs implements RemoteFileSystem {
  final Map<String, List<RemoteFileEntry>> tree;
  final Map<String, List<int>> fileBytes;
  List<String> events = [];

  FakeDropVfs({
    required this.tree,
    Map<String, List<int>>? fileBytes,
    Map<String, List<int>> extraFiles = const {},
    this.extraStats = const {},
  }) : fileBytes = fileBytes ?? _defaultFileBytes(tree, extraFiles);

  static Map<String, List<int>> _defaultFileBytes(
    Map<String, List<RemoteFileEntry>> tree,
    Map<String, List<int>> extraFiles,
  ) => {
    for (final children in tree.values)
      for (final child in children)
        if (child.type == RemoteFileType.file)
          child.path: 'payload of ${child.name}'.codeUnits,
    ...extraFiles,
  };

  /// Stat answers for paths that live outside [tree]/[fileBytes] (e.g. a
  /// dropped symlink).
  final Map<String, RemoteFileEntry> extraStats;

  Duration? listingDelay;
  Duration? downloadDelay;
  Object? statFailure;
  Object? Function(String path)? statFailureHook;
  Object? listingFailure;
  int listingFailureCall = 1;
  Object? downloadFailure;
  int downloadFailureCall = 1;
  Object? canonicalFailure;

  /// Runs after each successful listing (mid-run identity-change
  /// injection).
  void Function(String path)? afterListing;

  /// Replaces the canned download path entirely when set (used to inject
  /// a cancellation before any byte arrives).
  Future<RemoteFileEntry> Function(
    String path,
    StreamSink<List<int>> destination,
    RemoteTransferCancellation? cancellation,
  )? downloadHook;

  /// Delivers an empty leading chunk before the payload — a real
  /// transfer can flush a header or a zero-length read first, and the
  /// first-byte signal must not stamp on it.
  bool downloadEmptyLeadingChunk = false;

  /// Reports a failure through the sink protocol (`destination.addError`)
  /// and then completes normally — the leg must surface this error, not
  /// misattribute it as the empty-file case.
  Object? downloadSinkError;

  /// When false the fake completes the download without observing the
  /// collector's first-byte cancellation — a small file can finish before
  /// the cancel lands.
  bool honorCancellation = true;

  final List<String> calls = [];
  int statCalls = 0;
  int listCalls = 0;
  int downloadCalls = 0;

  int get treeEntries =>
      tree.values.fold(0, (sum, children) => sum + children.length);

  @override
  Future<String> canonicalize(String path) async {
    final failure = canonicalFailure;
    if (failure != null) throw failure;
    return path;
  }

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    statCalls++;
    calls.add('stat:$path');
    final hooked = statFailureHook?.call(path);
    if (hooked != null) throw hooked;
    final failure = statFailure;
    if (failure != null) throw failure;
    final extra = extraStats[path];
    if (extra != null) return extra;
    if (tree.containsKey(path)) {
      return dropEntry(
        remoteParent(path),
        remoteBasename(path),
        RemoteFileType.directory,
      );
    }
    for (final children in tree.values) {
      for (final child in children) {
        if (child.path == path) return child;
      }
    }
    final bytes = fileBytes[path];
    if (bytes != null) {
      return RemoteFileEntry(
        path: path,
        name: remoteBasename(path),
        type: RemoteFileType.file,
        size: bytes.length,
      );
    }
    throw RemoteFileException(
      kind: RemoteFileErrorKind.notFound,
      operation: 'stat',
      path: path,
      message: 'no such path: $path',
    );
  }

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    listCalls++;
    calls.add('list:$path');
    final delay = listingDelay;
    if (delay != null && delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final failure = listingFailure;
    if (failure != null && listCalls >= listingFailureCall) {
      throw failure;
    }
    final children = tree[path];
    if (children == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'list',
        path: path,
        message: 'no such directory: $path',
      );
    }
    afterListing?.call(path);
    return children;
  }

  /// Caller owns [destination] (the pinned contract: download streams
  /// into the caller's sink and never closes or completes it), so the
  /// fake adds bytes and returns — no close, no done await.
  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    bool computeHash = true,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
  }) async {
    downloadCalls++;
    calls.add('download:$path');
    final hook = downloadHook;
    if (hook != null) {
      return hook(path, destination, cancellation);
    }
    final delay = downloadDelay;
    if (delay != null && delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    final failure = downloadFailure;
    if (failure != null && downloadCalls >= downloadFailureCall) {
      throw failure;
    }
    final bytes = fileBytes[path];
    if (bytes == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'download',
        path: path,
        message: 'no such file: $path',
      );
    }
    // A token already cancelled at entry aborts before any byte —
    // matching a real backend's pre-flight cancellation check.
    if (honorCancellation && (cancellation?.isCancelled ?? false)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.cancelled,
        operation: 'download',
        path: path,
        message: 'Transfer cancelled.',
      );
    }
    final sinkError = downloadSinkError;
    if (sinkError != null) {
      // A writer that reports through the sink protocol and returns
      // normally — no byte is delivered.
      destination.addError(sinkError);
      return RemoteFileEntry(
        path: path,
        name: remoteBasename(path),
        type: RemoteFileType.file,
        size: 0,
      );
    }
    if (downloadEmptyLeadingChunk) {
      destination.add(const []);
    }
    if (bytes.isNotEmpty) {
      destination.add(bytes);
      onProgress?.call(bytes.length, bytes.length);
    }
    if (honorCancellation && (cancellation?.isCancelled ?? false)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.cancelled,
        operation: 'download',
        path: path,
        message: 'Transfer cancelled.',
      );
    }
    return RemoteFileEntry(
      path: path,
      name: remoteBasename(path),
      type: RemoteFileType.file,
      size: bytes.length,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeDropVfs does not implement ${invocation.memberName}; it only '
    'fakes the Vfs methods used by this benchmark.',
  );
}
