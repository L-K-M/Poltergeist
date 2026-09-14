// Deterministic contract tests for the P7 scan-rate collector
// (packages/poltergeist_core/benchmark/p7_scan_rate.dart).
//
// Docker is unavailable in this environment, so the connection itself is
// exercised only by the documented real-fixture command (benchmark/README).
// Everything else is pinned here without sockets: the sampler's pipelined
// recursive walk, warmup discard, repetition identities, honest
// failure/partial output, cleanup, and mode truthfulness run against fakes
// over the production [PaneChannel]/[RemoteFileSystem] interfaces, and the
// CLI + checker are driven as real subprocesses with test-owned catalog
// inputs.

@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import '../../benchmark/p7_scan_rate.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('poltergeist-p7-');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  /// The fixture-shaped test tree: `/root` holds two files plus `a/` and
  /// `b/`; `a/` holds one file and `c/`; `b/` and `c/` hold files. Total
  /// entries: 2 + 2 + 2 + 1 + 1 = 8? — see [scanTreeSpec] for the actual
  /// counts each test builds.
  group('collectScanRateSamples', () {
    test('warmup scans are discarded; measured scans count entries', () async {
      final vfs = FakeScanVfs(scanTreeSpec(rootFiles: 2, dirFiles: 1));
      final outcome = await collectScanRateSamples(
        listDirectory: vfs.listDirectory,
        rootPath: '/root',
        warmups: 2,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(minutes: 1),
      );

      // The tree has 4 listings per scan (root + a + b + a/c); two
      // discarded warmup scans plus five measured ones.
      expect(vfs.calls, hasLength(7 * 4));
      expect(outcome.failedRepetition, isNull);
      expect(outcome.measuredScans, hasLength(5));
      expect(outcome.totalEntries, vfs.treeEntries);
      expect(outcome.directoriesScanned, 4);
      for (final sample in outcome.measuredScans) {
        expect(sample.entries, vfs.treeEntries);
        expect(sample.entriesPerSecond.isFinite, isTrue);
        expect(sample.entriesPerSecond, greaterThan(0));
      }
    });

    test('pipelines directory listings up to the readdir depth', () async {
      // Twelve sibling directories under the root: after the root listing
      // resolves, all of them are issuable at once — the pipeline must
      // reach the full depth, never exceed it, and never run serially.
      final vfs = FakeScanVfs(
        scanTreeSpec(rootFiles: 0, dirFiles: 3, directoryCount: 12),
      )..listingDelay = const Duration(milliseconds: 20);
      final outcome = await collectScanRateSamples(
        listDirectory: vfs.listDirectory,
        rootPath: '/root',
        warmups: 0,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(minutes: 1),
      );

      expect(outcome.failedRepetition, isNull);
      expect(
        vfs.maxInFlight,
        p7ReaddirDepth,
        reason: 'the scan must saturate the D9 readdir depth',
      );
    });

    test('honors a narrower caller-supplied depth bound', () async {
      final vfs = FakeScanVfs(
        scanTreeSpec(rootFiles: 0, dirFiles: 3, directoryCount: 12),
      )..listingDelay = const Duration(milliseconds: 20);
      final outcome = await collectScanRateSamples(
        listDirectory: vfs.listDirectory,
        rootPath: '/root',
        warmups: 0,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(minutes: 1),
        maxInFlightListings: 3,
      );

      expect(outcome.failedRepetition, isNull);
      expect(vfs.maxInFlight, 3);
    });

    test('counts symlinks but never descends into them', () async {
      final vfs = FakeScanVfs({
        '/root': [
          scanEntry('/root', 'real', RemoteFileType.directory),
          scanEntry('/root', 'link', RemoteFileType.symbolicLink),
          scanEntry('/root', 'file', RemoteFileType.file),
        ],
        '/root/real': [scanEntry('/root/real', 'f', RemoteFileType.file)],
        // Entries exist behind the link path; descending the symlink would
        // list them. The scan must never issue that listing.
        '/root/link': [scanEntry('/root/link', 'hidden', RemoteFileType.file)],
      });
      final outcome = await collectScanRateSamples(
        listDirectory: vfs.listDirectory,
        rootPath: '/root',
        warmups: 0,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(minutes: 1),
      );

      expect(outcome.failedRepetition, isNull);
      expect(outcome.totalEntries, 4);
      expect(outcome.directoriesScanned, 2);
      expect(vfs.calls, isNot(contains('/root/link')));
    });

    test('a failed listing aborts the run without retry', () async {
      var calls = 0;
      final outcome = await collectScanRateSamples(
        listDirectory: (path) async {
          calls++;
          if (calls > 4) {
            throw const RemoteFileException(
              kind: RemoteFileErrorKind.permissionDenied,
              operation: 'list',
              path: '/root/a',
              message: 'directory vanished mid-run',
            );
          }
          return const [];
        },
        rootPath: '/root',
        warmups: 1,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(minutes: 1),
      );

      // One listing per scan here: warmup + three measured succeed, the
      // fifth call (measured repetition 3) fails and stops the run.
      expect(calls, 5);
      expect(outcome.failedRepetition, 3);
      expect(outcome.measuredScans, hasLength(3));
      expect(outcome.failureMessage, contains('directory vanished mid-run'));
    });

    test('a wedged listing fails through the per-listing timeout', () async {
      final never = Completer<List<RemoteFileEntry>>();
      addTearDown(() {
        if (!never.isCompleted) never.complete(const []);
      });
      final outcome = await collectScanRateSamples(
        listDirectory: (path) => never.future,
        rootPath: '/root',
        warmups: 1,
        repetitions: 5,
        listingTimeout: const Duration(milliseconds: 50),
        deadline: const Duration(minutes: 1),
      );

      expect(outcome.failedRepetition, 0);
      expect(outcome.failureMessage, contains('timed out'));
    });

    test('the run deadline aborts before the next repetition', () async {
      final outcome = await collectScanRateSamples(
        listDirectory: (path) async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return const [];
        },
        rootPath: '/root',
        warmups: 1,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(milliseconds: 100),
      );

      expect(outcome.failedRepetition, isNotNull);
      expect(outcome.measuredScans.length, lessThan(5));
      expect(outcome.failureMessage, contains('deadline'));
    });

    test('the whole-run deadline caps an in-flight listing await', () async {
      // The verification probe shape: with a 50 ms whole-run budget and a
      // 5 s per-listing timeout, a 2 s listing must not be waited out —
      // the budget caps every await, and expiry is attributed as a run-
      // budget overrun, never as a per-listing timeout.
      final elapsed = Stopwatch()..start();
      const listingTimeout = Duration(seconds: 5);
      final outcome = await collectScanRateSamples(
        listDirectory: (path) async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return const [];
        },
        rootPath: '/root',
        warmups: 1,
        repetitions: 5,
        listingTimeout: listingTimeout,
        deadline: const Duration(milliseconds: 50),
      );
      elapsed.stop();

      expect(
        elapsed.elapsed,
        lessThan(const Duration(milliseconds: 600)),
        reason:
            'a 50 ms whole-run budget must bound the listing await, not '
            'wait the 2 s listing out',
      );
      expect(outcome.failedRepetition, 0);
      expect(outcome.failureMessage, contains('run deadline exceeded'));
      expect(
        outcome.failureMessage,
        isNot(contains('timed out after ${listingTimeout.inMilliseconds} ms')),
      );
    });

    test('a warmup failure reports repetition 0 with unknown entries', () async {
      final outcome = await collectScanRateSamples(
        listDirectory: (path) async => throw StateError('warmup exploded'),
        rootPath: '/root',
        warmups: 1,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(minutes: 1),
      );

      expect(outcome.failedRepetition, 0);
      expect(outcome.measuredScans, isEmpty);
      expect(outcome.totalEntries, isNull);
      expect(outcome.failureMessage, contains('warmup exploded'));
    });

    test(
      'a mid-run entry-count change fails instead of smearing counts',
      () async {
        var calls = 0;
        final outcome = await collectScanRateSamples(
          listDirectory: (path) async {
            calls++;
            // The tree appears to shrink after the warmup scan.
            return List.generate(
              calls <= 1 ? 100 : 99,
              (index) => scanEntry(path, 'entry-$index', RemoteFileType.file),
            );
          },
          rootPath: '/root',
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        );

        // The scenarioConfig axis claims one tree size for every row, so
        // a changed count must fail the run honestly at the changing scan.
        expect(outcome.failedRepetition, 0);
        expect(outcome.measuredScans, isEmpty);
        // The outcome carries the frozen identity, not the changed
        // observation: the changed count belongs only in the error text.
        expect(outcome.totalEntries, 100);
        expect(outcome.failureMessage, contains('count changed'));
        expect(outcome.failureMessage, contains('100->99'));
      },
    );

    test(
      'a delayed count change keeps frozen counts for completed scans',
      () async {
        var calls = 0;
        final outcome = await collectScanRateSamples(
          listDirectory: (path) async {
            calls++;
            // Warmup + two measured scans observe 100 entries; the third
            // measured scan observes a shrunk tree.
            return List.generate(
              calls <= 3 ? 100 : 99,
              (index) => scanEntry(path, 'entry-$index', RemoteFileType.file),
            );
          },
          rootPath: '/root',
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        );

        expect(outcome.failedRepetition, 2);
        expect(outcome.measuredScans, hasLength(2));
        expect(outcome.measuredScans.first.entries, 100);
        expect(outcome.totalEntries, 100);
        expect(outcome.failureMessage, contains('count changed'));
        expect(outcome.failureMessage, contains('100->99'));
      },
    );

    test('the entry-count guard also arms without warmups', () async {
      var calls = 0;
      final outcome = await collectScanRateSamples(
        listDirectory: (path) async {
          calls++;
          return List.generate(
            calls == 1 ? 100 : 99,
            (index) => scanEntry(path, 'entry-$index', RemoteFileType.file),
          );
        },
        rootPath: '/root',
        warmups: 0,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(minutes: 1),
      );

      expect(outcome.failedRepetition, 1);
      expect(outcome.measuredScans, hasLength(1));
      expect(outcome.totalEntries, 100);
      expect(outcome.failureMessage, contains('count changed'));
    });

    test(
      'an in-flight listing failure fails the run even with siblings '
      'still pending',
      () async {
        // Two directory listings in flight; the first-issued fails while
        // the sibling still holds a pending entry — the run must fail at
        // the failing listing without an unhandled async error and
        // without reporting the abandoned sibling's entries.
        final vfs = FakeScanVfs({
          '/root': [
            scanEntry('/root', 'a', RemoteFileType.directory),
            scanEntry('/root', 'b', RemoteFileType.directory),
          ],
          '/root/b': [scanEntry('/root/b', 'f', RemoteFileType.file)],
        });
        vfs.listingDelay = const Duration(milliseconds: 10);
        vfs.failureHook = (path) =>
            path == '/root/a' ? StateError('a broke') : null;
        final outcome = await collectScanRateSamples(
          listDirectory: vfs.listDirectory,
          rootPath: '/root',
          warmups: 0,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        );

        expect(outcome.failedRepetition, 0);
        expect(outcome.measuredScans, isEmpty);
        expect(outcome.failureMessage, contains('a broke'));
      },
    );

    test('a zero in-flight bound is rejected as an argument error', () async {
      await expectLater(
        collectScanRateSamples(
          listDirectory: (path) async => const [],
          rootPath: '/root',
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
          maxInFlightListings: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a zero-elapsed sample cannot produce a rate', () {
      expect(
        () => const P7ScanSample(
          entries: 10,
          directories: 2,
          elapsed: Duration.zero,
        ).entriesPerSecond,
        throwsStateError,
      );
      expect(
        const P7ScanSample(
          entries: 1000,
          directories: 2,
          elapsed: Duration(milliseconds: 500),
        ).entriesPerSecond,
        2000.0,
      );
    });
  });

  group('runP7Collection over a fake channel', () {
    late FakeScanChannel channel;
    late List<String> events;
    late List<FakeScanChannel> opens;

    FakeScanChannel buildChannel({Map<String, List<RemoteFileEntry>>? tree}) {
      channel = FakeScanChannel(
        rootPath: '/remote/tree',
        tree: tree ?? scanTreeSpec(rootPath: '/remote/tree'),
        events: (events = <String>[]),
      );
      return channel;
    }

    Future<P7RunResult> run({
      required String outputPath,
      Map<String, List<RemoteFileEntry>>? tree,
      Duration? listingDelay,
      Object? listingFailure,
      int listingFailureCall = 1,
      Object? canonicalFailure,
      P7FingerprintFields fingerprint = const P7FingerprintFields(
        runnerImage: 'test-image',
        arch: 'x64test',
        dartVersion: 'test-dart',
        flutterVersion: null,
        mode: 'aot',
        cpuModel: 'test-cpu',
      ),
    }) async {
      opens = <FakeScanChannel>[];
      return runP7Collection(
        config: P7CollectorConfig(
          targetPath: '/remote/tree',
          outputPath: outputPath,
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
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
        releaseServer: () async {},
      );
    }

    test('scans the tree over one retained channel and cleans up', () async {
      final output = '${tempDir.path}/results.json';
      final result = await run(outputPath: output);

      expect(result.exitCode, 0, reason: result.stderr);
      expect(
        opens,
        hasLength(1),
        reason: 'the collector must retain one channel for every scan',
      );
      // One channel, one fs; every scan lists root + each directory.
      expect(channel.fs.calls, isNotEmpty);
      for (final path in channel.fs.calls) {
        expect(path, startsWith('/remote/tree'));
      }
      expect(channel.closeCount, 1);
      expect(result.released, isTrue);
      expect(events, contains('close'));

      final document =
          jsonDecode(await File(output).readAsString()) as Map<String, Object?>;
      expect(document['schema'], 'poltergeist-d12-results-1');
      final rows = document['rows']! as List<Object?>;
      // Warmup scan excluded from rows: exactly 5 measured repetitions.
      expect(rows, hasLength(5));
      expect(rows.map((r) => (r! as Map<String, Object?>)['repetition']), [
        0,
        1,
        2,
        3,
        4,
      ]);
      for (final row in rows.cast<Map<String, Object?>>()) {
        expect(row['scenario'], 'P7');
        expect(row['status'], 'ok');
        expect(row['unit'], 'entries/s');
        // Raw scan detail accompanies every measured row.
        expect(row['entries'], channel.fs.treeEntries);
        expect(row['elapsedMs'], isA<num>());
        final value = row['value']! as num;
        expect(value.isFinite, isTrue);
        expect(
          value,
          closeTo(
            (row['entries']! as num) /
                ((row['elapsedMs']! as num) / 1000.0),
            value * 0.001,
          ),
          reason: 'value is the unclipped entries/elapsed rate',
        );
        final fingerprint = row['fingerprint']! as Map<String, Object?>;
        expect(fingerprint['mode'], 'aot');
        expect(fingerprint['scenarioConfig'], contains('/remote/tree'));
        expect(
          fingerprint['scenarioConfig'],
          contains('readdir-depth=$p7ReaddirDepth'),
        );
      }
      expect(result.stdout, contains('P7'));
      expect(result.stdout, contains('median'));
    });

    test('a wedged channel open writes a clean timeout error row', () async {
      final output = '${tempDir.path}/results.json';
      final never = Completer<FakeScanChannel>();
      addTearDown(() {
        if (!never.isCompleted) never.complete(buildChannel());
      });
      final result = await runP7Collection(
        config: P7CollectorConfig(
          targetPath: '/remote/tree',
          outputPath: output,
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
          channelOpenTimeout: const Duration(milliseconds: 50),
        ),
        fingerprint: const P7FingerprintFields(
          runnerImage: 'test-image',
          arch: 'x64test',
          dartVersion: 'test-dart',
          flutterVersion: null,
          mode: 'aot',
          cpuModel: 'test-cpu',
        ),
        openChannel: () => never.future,
        releaseServer: () async {},
      );

      expect(result.exitCode, 1);
      final document =
          jsonDecode(await File(output).readAsString()) as Map<String, Object?>;
      final row = (document['rows']! as List).single! as Map<String, Object?>;
      expect(row['scenario'], 'P7');
      expect(row['status'], 'error');
      final error = row['error']! as String;
      expect(error, contains('timed out'));
      // The budget message reports the configured timeout in
      // milliseconds, not a truncated seconds figure.
      expect(error, contains('timed out after 50 ms'));
      expect(result.released, isTrue);
    });

    test('setup time is charged against the whole-run deadline', () async {
      // A channel open slower than the whole-run budget must fail the
      // run with a run-budget error row — setup is not free time.
      final output = '${tempDir.path}/results.json';
      final result = await runP7Collection(
        config: P7CollectorConfig(
          targetPath: '/remote/tree',
          outputPath: output,
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(milliseconds: 30),
          channelOpenTimeout: const Duration(seconds: 5),
        ),
        fingerprint: const P7FingerprintFields(
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
        releaseServer: () async {},
      );

      expect(result.exitCode, 1);
      final document =
          jsonDecode(await File(output).readAsString()) as Map<String, Object?>;
      final row = (document['rows']! as List).single! as Map<String, Object?>;
      expect(row['status'], 'error');
      expect(row['error'], contains('run deadline exceeded'));
      expect(result.released, isTrue);
    });

    test('a canonicalize failure writes a single honest error row', () async {
      final output = '${tempDir.path}/results.json';
      final result = await run(
        outputPath: output,
        canonicalFailure: StateError('canonicalize broke'),
      );

      expect(result.exitCode, 1);
      final document =
          jsonDecode(await File(output).readAsString()) as Map<String, Object?>;
      final rows = document['rows']! as List<Object?>;
      expect(rows, hasLength(1));
      final row = rows.single! as Map<String, Object?>;
      expect(row['status'], 'error');
      expect(row['repetition'], 0);
      expect(row['error'], contains('canonicalize broke'));
      final fingerprint = row['fingerprint']! as Map<String, Object?>;
      expect(fingerprint['scenarioConfig'], contains('entries=unknown'));
    });

    test(
      'a mid-run listing failure writes partial rows and an error row',
      () async {
        final output = '${tempDir.path}/results.json';
        final result = await run(
          outputPath: output,
          listingFailure: const RemoteFileException(
            kind: RemoteFileErrorKind.permissionDenied,
            operation: 'list',
            path: '/remote/tree',
            message: 'permission denied by fixture',
          ),
          // The fake tree costs 4 listings per scan; the warmup scan is
          // calls 1-4 and measured scans 0-1 are calls 5-12, so call 13
          // is the first listing of measured repetition 2.
          listingFailureCall: 13,
        );

        expect(result.exitCode, 1);
        final document =
            jsonDecode(await File(output).readAsString())
                as Map<String, Object?>;
        final rows = document['rows']! as List<Object?>;
        final okRows = rows
            .where((r) => (r! as Map)['status'] == 'ok')
            .toList();
        final errorRows = rows
            .where((r) => (r! as Map)['status'] == 'error')
            .toList();
        expect(okRows, isNotEmpty);
        expect(errorRows, hasLength(1));
        final errorRow = errorRows.single! as Map<String, Object?>;
        expect(errorRow['error'], contains('permission denied by fixture'));
        expect(errorRow.containsKey('value'), isFalse);
        // Cleanup ran despite the failure.
        expect(channel.closeCount, 1);
        expect(result.released, isTrue);
      },
    );

    test(
      'partial rows keep the frozen scenarioConfig after a mid-run count '
      'change',
      () async {
        final output = '${tempDir.path}/results.json';
        final tree = scanTreeSpec(rootPath: '/remote/tree');
        final channel = FakeScanChannel(
          rootPath: '/remote/tree',
          tree: tree,
          events: events = <String>[],
        );
        // After the warmup + first two measured scans, the tree shrinks:
        // the fourth root listing (measured repetition 2) is the first
        // scan that observes the changed size, and the run fails there.
        var rootListings = 0;
        channel.fs.onRootListing = () {
          rootListings++;
          if (rootListings == 4) {
            tree['/remote/tree/b']!.removeLast();
          }
        };
        final result = await runP7Collection(
          config: P7CollectorConfig(
            targetPath: '/remote/tree',
            outputPath: output,
            warmups: 1,
            repetitions: 5,
            listingTimeout: const Duration(seconds: 5),
            deadline: const Duration(minutes: 1),
          ),
          fingerprint: const P7FingerprintFields(
            runnerImage: 'test-image',
            arch: 'x64test',
            dartVersion: 'test-dart',
            flutterVersion: null,
            mode: 'aot',
            cpuModel: 'test-cpu',
          ),
          openChannel: () async => channel,
          releaseServer: () async {},
        );

        expect(result.exitCode, 1);
        expect(result.stderr, contains('count changed'));
        final document =
            jsonDecode(await File(output).readAsString())
                as Map<String, Object?>;
        final rows = document['rows']! as List<Object?>;
        expect(rows, hasLength(3));
        final frozenEntries = channel.fs.treeEntries + 1;
        for (final row in rows.cast<Map<String, Object?>>()) {
          final fingerprint = row['fingerprint']! as Map<String, Object?>;
          // Every row — ok and error — carries the frozen identity the
          // successful scans were measured under; the changed count
          // appears only in the error row's text.
          expect(
            fingerprint['scenarioConfig'],
            contains(';entries=$frozenEntries;'),
          );
          expect(
            fingerprint['scenarioConfig'],
            isNot(contains(';entries=${frozenEntries - 1};')),
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
  });

  group('results temp ownership', () {
    Future<P7RunResult> runWithCandidates(
      String output,
      String Function(int attempt) candidateName,
    ) {
      return runP7Collection(
        config: P7CollectorConfig(
          targetPath: '/remote/tree',
          outputPath: output,
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        ),
        fingerprint: const P7FingerprintFields(
          runnerImage: 'test-image',
          arch: 'x64test',
          dartVersion: 'test-dart',
          flutterVersion: null,
          mode: 'aot',
          cpuModel: 'test-cpu',
        ),
        openChannel: () async => FakeScanChannel(
          rootPath: '/remote/tree',
          tree: scanTreeSpec(rootPath: '/remote/tree'),
          events: <String>[],
        ),
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
          } catch (_) {
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

  group('P7CollectorConfig.parse', () {
    test('a repeated flag is rejected instead of silently first-wins', () {
      expect(
        () => P7CollectorConfig.parse([
          '--output',
          'a.json',
          '--repetitions',
          '5',
          '--repetitions',
          '20',
          '--target',
          '/t',
        ]),
        throwsA(isA<P7UsageException>()),
      );
    });

    test('a flag token swallowed as a value is rejected', () {
      expect(
        () => P7CollectorConfig.parse([
          '--output',
          'a.json',
          '--target',
          '--warmups',
          '3',
        ]),
        throwsA(isA<P7UsageException>()),
      );
    });

    test('a normal invocation still parses', () {
      final config = P7CollectorConfig.parse([
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
      collectorPath = '$packageDir/benchmark/p7_scan_rate.dart';
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
        ['run', 'benchmark/p7_scan_rate.dart', ...args],
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
      final result = await runCollector(
        [
          '--output',
          '${tempDir.path}/results.json',
          '--target',
          '/remote/tree',
        ],
        absentEnvironment: {
          'POLTERGEIST_SSHD',
          'POLTERGEIST_SSHD_MODERN',
          'POLTERGEIST_SSHD_USER',
          'POLTERGEIST_SSHD_KEY',
        },
      );
      expect(result.exitCode, 2);
      final stderrText = result.stderr as String;
      for (final variable in [
        'POLTERGEIST_SSHD',
        'POLTERGEIST_SSHD_MODERN',
        'POLTERGEIST_SSHD_USER',
        'POLTERGEIST_SSHD_KEY',
      ]) {
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
      'zero warmups are rejected: the protocol requires warm scans',
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

    /// Collects through the real sampler/writer against fakes with an
    /// injected (test-owned) fingerprint, then hands the emitted file to
    /// the real check.dart CLI with a test-owned budgets catalog.
    Future<(int, String, String)> collectAndCheck({
      Duration? listingDelay,
      required bool enforce,
      bool landed = true,
    }) async {
      final output = '${tempDir.path}/results.json';
      final events = <String>[];
      final channel = FakeScanChannel(
        rootPath: '/remote/tree',
        tree: scanTreeSpec(rootPath: '/remote/tree', dirFiles: 40),
        events: events,
      )..fs.listingDelay = listingDelay;
      final collection = await runP7Collection(
        config: P7CollectorConfig(
          targetPath: '/remote/tree',
          outputPath: output,
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 30),
          deadline: const Duration(minutes: 5),
        ),
        fingerprint: const P7FingerprintFields(
          runnerImage: 'test-image',
          arch: 'x64test',
          dartVersion: 'test-dart',
          flutterVersion: null,
          mode: 'aot',
          cpuModel: 'test-cpu',
        ),
        openChannel: () async => channel,
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
            'id': 'P7',
            'tier': 'a',
            'summary': 'Sync scan rate, LAN',
            'operator': 'atLeast',
            'value': 1000,
            'unit': 'entries/s',
            'minimumRepetitions': 3,
            'landed': landed,
            if (landed)
              'calibratedScenarioConfig': rowFingerprint['scenarioConfig'],
          },
        ],
      };
      final budgetsPath = '${tempDir.path}/budgets.json';
      await File(budgetsPath).writeAsString(jsonEncode(budgets));

      final environment = Map<String, String>.of(Platform.environment)
        ..remove('BENCH_ENFORCE_A')
        ..remove('BENCH_ENFORCE_B');
      if (enforce) environment['BENCH_ENFORCE_A'] = '1';
      final checker = await Process.run(
        Platform.resolvedExecutable,
        [
          checkerPath,
          '--results',
          output,
          '--tiers',
          'a',
          '--budgets',
          budgetsPath,
        ],
        workingDirectory: repoRoot,
        environment: environment,
      );
      return (
        checker.exitCode,
        checker.stdout as String,
        checker.stderr as String,
      );
    }

    test('passes with matching test calibration', () async {
      final (exit, stdoutText, stderrText) = await collectAndCheck(
        listingDelay: Duration.zero,
        enforce: true,
      );
      expect(exit, 0, reason: stderrText);
      expect(
        stdoutText,
        contains(RegExp(r'^P7\s+a\s.*pass$', multiLine: true)),
      );
    });

    test(
      'an enforced shortfall through real collector output fails red',
      () async {
        // 4 listings per scan at 250 ms each over depth 8 ≈ 750 ms for
        // ~125 entries ≈ 170 entries/s — under the 1000 entries/s budget.
        final (exit, stdoutText, stderrText) = await collectAndCheck(
          listingDelay: const Duration(milliseconds: 250),
          enforce: true,
        );
        expect(exit, 1, reason: stderrText);
        expect(stdoutText, contains('overrun (fail: enforced)'));
      },
    );

    test('a non-enforced shortfall reports without failing the run', () async {
      final (exit, stdoutText, stderrText) = await collectAndCheck(
        listingDelay: const Duration(milliseconds: 250),
        enforce: false,
      );
      expect(exit, 0, reason: stderrText);
      expect(stdoutText, contains('overrun (notice: not enforced)'));
    });

    test(
      'unlanded P3+P7 rows in one results file both report, exit 0',
      () async {
        // The shared-file contract 08 §6 prescribes: one results file
        // carries every scenario the job ran, each with its own
        // scenarioConfig. The P7 rows below are real collector output;
        // the P3 rows are synthetic but schema-correct, mirroring the
        // checker's own committed fixture (check_cli_test).
        final output = '${tempDir.path}/results.json';
        final channel = FakeScanChannel(
          rootPath: '/remote/tree',
          tree: scanTreeSpec(rootPath: '/remote/tree'),
          events: <String>[],
        );
        final collection = await runP7Collection(
          config: P7CollectorConfig(
            targetPath: '/remote/tree',
            outputPath: output,
            warmups: 1,
            repetitions: 5,
            listingTimeout: const Duration(seconds: 30),
            deadline: const Duration(minutes: 5),
          ),
          fingerprint: const P7FingerprintFields(
            runnerImage: 'test-image',
            arch: 'x64test',
            dartVersion: 'test-dart',
            flutterVersion: null,
            mode: 'aot',
            cpuModel: 'test-cpu',
          ),
          openChannel: () async => channel,
          releaseServer: () async {},
        );
        expect(collection.exitCode, 0, reason: collection.stderr);

        final emitted =
            jsonDecode(await File(output).readAsString())
                as Map<String, Object?>;
        final p7Rows = emitted['rows']! as List<Object?>;
        expect(
          p7Rows,
          isNotEmpty,
          reason: 'collector must emit rows for the mixed-file check',
        );
        final p7Fingerprint =
            (p7Rows.first! as Map<String, Object?>)['fingerprint']!
                as Map<String, Object?>;
        // Same job-wide controlled axes, P3's own per-scenario config.
        final p3Fingerprint = {...p7Fingerprint}
          ..['scenarioConfig'] = 'p3/v1;target=/remote/tree;control=/remote/c';
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
        final combined = {
          'schema': 'poltergeist-d12-results-1',
          'rows': [...p3Rows, ...p7Rows],
        };
        final combinedPath = '${tempDir.path}/combined-results.json';
        await File(combinedPath).writeAsString(jsonEncode(combined));

        // Test-owned catalog: both scenarios present, both unlanded.
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

        final environment = Map<String, String>.of(Platform.environment)
          ..remove('BENCH_ENFORCE_A')
          ..remove('BENCH_ENFORCE_B');
        final checker = await Process.run(
          Platform.resolvedExecutable,
          [
            checkerPath,
            '--results',
            combinedPath,
            '--tiers',
            'a',
            '--budgets',
            budgetsPath,
          ],
          workingDirectory: repoRoot,
          environment: environment,
        );
        expect(checker.exitCode, 0, reason: checker.stderr as String);
        final stdoutText = checker.stdout as String;
        expect(
          stdoutText,
          contains(
            RegExp(r'^P3\s+a\s.*reported \(unlanded\)$', multiLine: true),
          ),
        );
        expect(
          stdoutText,
          contains(
            RegExp(r'^P7\s+a\s.*reported \(unlanded\)$', multiLine: true),
          ),
        );
      },
    );
  });
}

/// Builds a fixture-shaped tree: `rootFiles` files plus `a/` and `b/`
/// directories (each holding `dirFiles` files), and `a/c/` with
/// `dirFiles` files — plus `directoryCount - 3` extra `d<i>/` siblings
/// when [directoryCount] exceeds the default 3 directories.
Map<String, List<RemoteFileEntry>> scanTreeSpec({
  String rootPath = '/root',
  int rootFiles = 2,
  int dirFiles = 1,
  int directoryCount = 3,
}) {
  assert(
    directoryCount >= 3,
    'directoryCount below 3 is unsupported: the base tree always '
    'contains a/, b/, and a/c/',
  );
  final tree = <String, List<RemoteFileEntry>>{};
  void putDir(String path, int fileCount) {
    tree[path] = [
      for (var i = 0; i < fileCount; i++)
        scanEntry(path, 'file-$i', RemoteFileType.file),
    ];
  }

  final directories = <String>[
    '$rootPath/a',
    '$rootPath/b',
    '$rootPath/a/c',
    for (var i = 0; i < directoryCount - 3; i++) '$rootPath/d$i',
  ];
  tree[rootPath] = [
    for (var i = 0; i < rootFiles; i++)
      scanEntry(rootPath, 'root-file-$i', RemoteFileType.file),
    for (final dir in directories.where((d) => d != '$rootPath/a/c'))
      scanEntry(
        rootPath,
        dir.substring(dir.lastIndexOf('/') + 1),
        RemoteFileType.directory,
      ),
  ];
  // a/c is a child of a/, not of the root.
  putDir('$rootPath/a', dirFiles);
  tree['$rootPath/a']!.add(
    scanEntry('$rootPath/a', 'c', RemoteFileType.directory),
  );
  putDir('$rootPath/b', dirFiles);
  putDir('$rootPath/a/c', dirFiles);
  for (var i = 0; i < directoryCount - 3; i++) {
    putDir('$rootPath/d$i', dirFiles);
  }
  return tree;
}

RemoteFileEntry scanEntry(String parent, String name, RemoteFileType type) =>
    RemoteFileEntry(path: '$parent/$name', name: name, type: type);

/// Fake browse channel over the production interface; records lifecycle
/// events so one-channel and cleanup contracts are observable.
class FakeScanChannel implements PaneChannel {
  final String rootPath;
  final List<String> events;

  int closeCount = 0;

  FakeScanChannel({
    required this.rootPath,
    required Map<String, List<RemoteFileEntry>> tree,
    required this.events,
  }) : fs = FakeScanVfs(tree) {
    fs.events = events;
  }

  @override
  final FakeScanVfs fs;

  @override
  String get homePath => '/remote';

  @override
  Future<void> close() async {
    closeCount++;
    events.add('close');
  }

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {}
}

/// Fake VFS over an in-memory tree map: records every listing call, tracks
/// concurrent in-flight listings (the pipelining bound is observable), and
/// fails loudly on anything but canonicalize/listDirectory (08 §3.2).
class FakeScanVfs implements RemoteFileSystem {
  Map<String, List<RemoteFileEntry>> tree;
  List<String> events = [];

  FakeScanVfs(this.tree);

  Duration? listingDelay;
  Object? listingFailure;
  int listingFailureCall = 1;
  Object? canonicalFailure;

  /// Per-listing failure override; takes precedence over listingFailure.
  Object? Function(String path)? failureHook;

  /// Runs after each successful root listing (count-change injection).
  void Function()? onRootListing;

  final List<String> calls = [];
  int inFlight = 0;
  int maxInFlight = 0;

  int get treeEntries =>
      tree.values.fold(0, (sum, children) => sum + children.length);

  @override
  Future<String> canonicalize(String path) async {
    final failure = canonicalFailure;
    if (failure != null) throw failure;
    return path;
  }

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    events.add('list:$path');
    calls.add(path);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      final delay = listingDelay;
      if (delay != null && delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      final hooked = failureHook?.call(path);
      if (hooked != null) throw hooked;
      final failure = listingFailure;
      if (failure != null && calls.length >= listingFailureCall) {
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
      if (path == rootPathOf(tree)) {
        onRootListing?.call();
      }
      return children;
    } finally {
      inFlight--;
    }
  }

  // The root is whichever key is not itself a child path — the fake knows
  // it as the one listing callers pass as --target; tests name it via the
  // channel. A null root is fine: the hook just never fires.
  String? rootPathOf(Map<String, List<RemoteFileEntry>> tree) {
    final childPaths = <String>{
      for (final children in tree.values)
        for (final child in children) child.path,
    };
    for (final key in tree.keys) {
      if (!childPaths.contains(key)) return key;
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeScanVfs does not implement ${invocation.memberName}; it only '
    'fakes the Vfs methods used by this benchmark.',
  );
}
