// Deterministic contract tests for the P3 listing-overhead collector
// (packages/poltergeist_core/benchmark/p3_listing_overhead.dart).
//
// Docker is unavailable in this environment, so the connection itself is
// exercised only by the documented real-fixture command (benchmark/README).
// Everything else is pinned here without sockets: the sampler's pairing,
// ordering, warmup discard, repetition identities, honest failure/partial
// output, cleanup, and mode truthfulness run against fakes over the
// production [PaneChannel]/[RemoteFileSystem] interfaces, and the CLI +
// checker are driven as real subprocesses with test-owned catalog inputs.

@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import '../../benchmark/p3_listing_overhead.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('poltergeist-p3-');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('collectListingOverheadPairs', () {
    test('pairs control with target, warmups discarded', () async {
      final calls = <String>[];
      final outcome = await collectListingOverheadPairs(
        listControl: () async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          calls.add('control');
          return 2;
        },
        listTarget: () async {
          calls.add('target');
          return 10000;
        },
        warmups: 2,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(minutes: 1),
      );

      // 2 warmup pairs + 5 measured pairs, control always first.
      expect(calls, hasLength(14));
      for (var pair = 0; pair < 7; pair++) {
        expect(calls.sublist(2 * pair, 2 * pair + 2), ['control', 'target']);
      }
      expect(outcome.failedRepetition, isNull);
      expect(outcome.measuredPairs, hasLength(5));
      expect(outcome.controlEntries, 2);
      expect(outcome.targetEntries, 10000);
    });

    test('difference keeps negative values unclipped', () async {
      // A control listing slower than the target must produce a negative
      // overhead — never a clipped zero.
      final outcome = await collectListingOverheadPairs(
        listControl: () async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return 2;
        },
        listTarget: () async => 10000,
        warmups: 1,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(minutes: 1),
      );

      expect(outcome.measuredPairs, isNotEmpty);
      for (final pair in outcome.measuredPairs) {
        expect(pair.differenceMs, lessThan(0));
      }
    });

    test('a failed measurement aborts without retry', () async {
      var measuredStarted = 0;
      final outcome = await collectListingOverheadPairs(
        listControl: () async => 2,
        listTarget: () async {
          measuredStarted++;
          // Warmup + three measured pairs succeed; the fifth call (measured
          // repetition 3) fails and the run must stop there — no retry.
          if (measuredStarted > 4) {
            throw const RemoteFileException(
              kind: RemoteFileErrorKind.notFound,
              operation: 'list',
              path: '/gone',
              message: 'target vanished mid-run',
            );
          }
          return 10000;
        },
        warmups: 1,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(minutes: 1),
      );

      // Warmup pair + three measured pairs, then the failure stops the run.
      expect(measuredStarted, 5);
      expect(outcome.failedRepetition, 3);
      expect(outcome.measuredPairs, hasLength(3));
      expect(outcome.failureMessage, contains('target vanished mid-run'));
    });

    test('a wedged listing fails through the per-listing timeout', () async {
      final never = Completer<int>();
      addTearDown(() {
        if (!never.isCompleted) never.complete(0);
      });
      final outcome = await collectListingOverheadPairs(
        listControl: () async => 2,
        listTarget: () => never.future,
        warmups: 1,
        repetitions: 5,
        listingTimeout: const Duration(milliseconds: 50),
        deadline: const Duration(minutes: 1),
      );

      expect(outcome.failedRepetition, 0);
      expect(outcome.failureMessage, contains('timed out'));
    });

    test('the run deadline aborts before the next repetition', () async {
      final outcome = await collectListingOverheadPairs(
        listControl: () async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return 2;
        },
        listTarget: () async => 10000,
        warmups: 1,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(milliseconds: 100),
      );

      expect(outcome.failedRepetition, isNotNull);
      expect(outcome.measuredPairs.length, lessThan(5));
      expect(outcome.failureMessage, contains('deadline'));
    });

    test('the whole-run deadline caps an in-flight listing await', () async {
      // The verification probe: with a 50 ms whole-run budget and a 5 s
      // per-listing timeout, a 2 s control listing must not be waited
      // out — pre-fix the sampler returned after 2018 ms and only then
      // reported the deadline. The budget caps every await.
      final elapsed = Stopwatch()..start();
      final outcome = await collectListingOverheadPairs(
        listControl: () async {
          await Future<void>.delayed(const Duration(seconds: 2));
          return 2;
        },
        listTarget: () async => 10000,
        warmups: 1,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(milliseconds: 50),
      );
      elapsed.stop();

      expect(
        elapsed.elapsed,
        lessThan(const Duration(milliseconds: 600)),
        reason:
            'a 50 ms whole-run budget must bound the control await, not '
            'wait the 2 s listing out',
      );
      expect(outcome.failedRepetition, 0);
      expect(outcome.failureMessage, contains('run deadline exceeded'));
      expect(outcome.failureMessage, contains('control listing'));
      // Whole-run expiry is attributed distinctly from a per-listing
      // timeout: no 5 s per-listing wording may appear.
      expect(
        outcome.failureMessage,
        isNot(contains('timed out after ${5 * 1000} ms')),
      );
    });

    test(
      'a deadline consumed by the target leg is attributed distinctly',
      () async {
        final never = Completer<int>();
        addTearDown(() {
          if (!never.isCompleted) never.complete(10000);
        });
        final outcome = await collectListingOverheadPairs(
          listControl: () async => 2,
          listTarget: () => never.future,
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(milliseconds: 80),
        );

        expect(outcome.failedRepetition, 0);
        expect(outcome.failureMessage, contains('run deadline exceeded'));
        expect(outcome.failureMessage, contains('target listing'));
        expect(
          outcome.failureMessage,
          isNot(contains('timed out after ${5 * 1000} ms')),
        );
      },
    );

    test(
      'a warmup failure reports repetition 0 with unknown entries',
      () async {
        final outcome = await collectListingOverheadPairs(
          listControl: () async => 2,
          listTarget: () async => throw StateError('warmup exploded'),
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        );

        expect(outcome.failedRepetition, 0);
        expect(outcome.measuredPairs, isEmpty);
        expect(outcome.targetEntries, isNull);
        expect(outcome.failureMessage, contains('warmup exploded'));
      },
    );

    test(
      'a mid-run entry-count change fails instead of smearing counts',
      () async {
        var targetCalls = 0;
        final outcome = await collectListingOverheadPairs(
          listControl: () async => 2,
          listTarget: () async {
            targetCalls++;
            // The tree appears to shrink after the warmup pair.
            return targetCalls <= 1 ? 10000 : 9999;
          },
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        );

        // The scenarioConfig axis claims one tree size for every row, so a
        // changed count must fail the run honestly at the changing pair.
        expect(outcome.failedRepetition, 0);
        expect(outcome.measuredPairs, isEmpty);
        // The outcome carries the frozen identity, not the changed
        // observation: the changed count belongs only in the error text.
        expect(outcome.targetEntries, 10000);
        expect(outcome.failureMessage, contains('entry count changed'));
        expect(outcome.failureMessage, contains('10000->9999'));
      },
    );

    test(
      'a delayed count change keeps frozen counts for completed pairs',
      () async {
        var targetCalls = 0;
        final outcome = await collectListingOverheadPairs(
          listControl: () async => 2,
          listTarget: () async {
            targetCalls++;
            // Warmup + two measured pairs observe 10000; the third
            // measured pair observes a shrunk tree.
            return targetCalls <= 3 ? 10000 : 9999;
          },
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        );

        expect(outcome.failedRepetition, 2);
        expect(outcome.measuredPairs, hasLength(2));
        // Every emitted row — including the error row — must carry the
        // frozen identity the successful pairs were measured under;
        // only the error text reports the observed transition.
        expect(outcome.controlEntries, 2);
        expect(outcome.targetEntries, 10000);
        expect(outcome.failureMessage, contains('entry count changed'));
        expect(outcome.failureMessage, contains('10000->9999'));
      },
    );

    test('the entry-count guard also arms without warmups', () async {
      var targetCalls = 0;
      final outcome = await collectListingOverheadPairs(
        listControl: () async => 2,
        listTarget: () async {
          targetCalls++;
          // The tree changes size between the first and second measured
          // pair; with no warmup pair the identity must freeze on the
          // first observation instead of never arming.
          return targetCalls == 1 ? 10000 : 9999;
        },
        warmups: 0,
        repetitions: 5,
        listingTimeout: const Duration(seconds: 5),
        deadline: const Duration(minutes: 1),
      );

      expect(outcome.failedRepetition, 1);
      expect(outcome.measuredPairs, hasLength(1));
      // The completed pair was measured at 10000; the identity stays
      // frozen at that size even though the failing pair saw 9999.
      expect(outcome.targetEntries, 10000);
      expect(outcome.failureMessage, contains('entry count changed'));
    });
  });

  group('medianOf', () {
    test('matches the checker median for odd and even counts', () {
      expect(medianOf([3.0, 1.0, 2.0]), 2.0);
      expect(medianOf([4.0, 1.0, 3.0, 2.0]), 2.5);
      expect(medianOf([5.0]), 5.0);
    });
  });

  group('detectRunMode', () {
    test('labels dart-source runs jit even in product mode', () {
      expect(
        detectRunMode(
          productMode: true,
          scriptUri: Uri.file('/tmp/probe.dart'),
        ),
        'jit',
      );
      expect(
        detectRunMode(
          productMode: false,
          scriptUri: Uri.file('/tmp/probe.dart'),
        ),
        'jit',
      );
      expect(
        detectRunMode(
          productMode: true,
          scriptUri: Uri.file('/tmp/probe.dill'),
        ),
        'jit',
      );
    });

    test('labels a product binary without a source script aot', () {
      expect(
        detectRunMode(
          productMode: true,
          scriptUri: Uri.file('/tmp/p3-collector'),
        ),
        'aot',
      );
    });

    test('never labels a non-product binary aot', () {
      expect(
        detectRunMode(
          productMode: false,
          scriptUri: Uri.file('/tmp/p3-collector'),
        ),
        'jit',
      );
    });
  });

  group('runP3Collection over a fake channel', () {
    late FakeBrowseChannel channel;
    late List<String> events;

    FakeBrowseChannel buildChannel({int controlEntries = 2}) {
      channel = FakeBrowseChannel(
        targetPath: '/remote/target',
        controlPath: '/remote/control',
        controlEntries: controlEntries,
        events: (events = <String>[]),
      );
      return channel;
    }

    Future<P3RunResult> run({
      required String outputPath,
      int controlEntries = 2,
      Duration? targetDelay,
      Object? targetFailure,
      int targetFailureCall = 3,
      Object? canonicalFailure,
      P3FingerprintFields fingerprint = const P3FingerprintFields(
        runnerImage: 'test-image',
        arch: 'x64test',
        dartVersion: 'test-dart',
        flutterVersion: null,
        mode: 'aot',
        cpuModel: 'test-cpu',
      ),
    }) async {
      final opens = <FakeBrowseChannel>[];
      final releases = <void>[];
      return runP3Collection(
        config: P3CollectorConfig(
          targetPath: '/remote/target',
          controlPath: '/remote/control',
          outputPath: outputPath,
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        ),
        fingerprint: fingerprint,
        openChannel: () async {
          final opened = buildChannel(controlEntries: controlEntries)
            ..targetDelay = targetDelay
            ..targetFailure = targetFailure
            ..targetFailureCall = targetFailure == null ? 1 : targetFailureCall
            ..canonicalFailure = canonicalFailure;
          opens.add(opened);
          return opened;
        },
        releaseServer: () async {
          releases.add(null);
        },
      );
    }

    test('uses one retained channel for both legs and cleans up', () async {
      final output = '${tempDir.path}/results.json';
      final result = await run(outputPath: output);

      expect(result.exitCode, 0, reason: result.stderr);
      // One channel, one fs, both legs interleaved control-first per pair.
      final listingPaths = channel.fs.listings.map((l) => l.path).toList();
      expect(listingPaths, isNotEmpty);
      for (var pair = 0; pair < listingPaths.length ~/ 2; pair++) {
        expect(listingPaths.sublist(2 * pair).take(2), [
          '/remote/control',
          '/remote/target',
        ]);
      }
      expect(channel.closeCount, 1);
      expect(result.released, isTrue);
      expect(events, contains('close'));

      final document =
          jsonDecode(await File(output).readAsString()) as Map<String, Object?>;
      expect(document['schema'], 'poltergeist-d12-results-1');
      final rows = document['rows']! as List<Object?>;
      // Warmup pair excluded from rows: exactly 5 measured repetitions.
      expect(rows, hasLength(5));
      expect(rows.map((r) => (r! as Map<String, Object?>)['repetition']), [
        0,
        1,
        2,
        3,
        4,
      ]);
      for (final row in rows.cast<Map<String, Object?>>()) {
        expect(row['scenario'], 'P3');
        expect(row['status'], 'ok');
        expect(row['unit'], 'ms');
        // Raw pair timings accompany every measured row.
        expect(row['controlMs'], isA<num>());
        expect(row['targetMs'], isA<num>());
        expect(
          (row['value']! as num) + (row['controlMs']! as num),
          closeTo(row['targetMs']! as num, 1e-9),
        );
        final fingerprint = row['fingerprint']! as Map<String, Object?>;
        expect(fingerprint['mode'], 'aot');
        expect(fingerprint['scenarioConfig'], contains('/remote/target'));
      }
      expect(result.stdout, contains('P3'));
      expect(result.stdout, contains('median'));
    });

    test('a wedged channel open writes a clean timeout error row', () async {
      final output = '${tempDir.path}/results.json';
      final never = Completer<FakeBrowseChannel>();
      addTearDown(() {
        if (!never.isCompleted) never.complete(buildChannel());
      });
      final result = await runP3Collection(
        config: P3CollectorConfig(
          targetPath: '/remote/target',
          controlPath: '/remote/control',
          outputPath: output,
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
          channelOpenTimeout: const Duration(milliseconds: 50),
        ),
        fingerprint: const P3FingerprintFields(
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
      expect(row['status'], 'error');
      final error = row['error']! as String;
      expect(error, contains('timed out'));
      // The synthetic 'deadline' placeholder must not leak into the row.
      expect(error, isNot(contains('deadline')));
      expect(result.released, isTrue);
    });

    test(
      'canonical aliasing of target and control is a usage failure',
      () async {
        final output = '${tempDir.path}/results.json';
        final result = await runCollectionAgainst(
          FakeBrowseChannel(
            targetPath: '/remote/target',
            controlPath: '/remote/./target',
            controlEntries: 2,
            events: events = <String>[],
            canonicalizer: (path) => '/remote/target',
          ),
          output: output,
        );

        expect(result.exitCode, 2);
        expect(result.stderr, contains('distinct'));
        // The channel was still opened and cleaned up.
        expect(result.released, isTrue);
        expect(
          await File(output).exists(),
          isFalse,
          reason: 'a usage failure must not write measurements',
        );
      },
    );

    test(
      'partial rows keep the frozen scenarioConfig after a mid-run count '
      'change',
      () async {
        final output = '${tempDir.path}/results.json';
        final result = await runCollectionAgainst(
          FakeBrowseChannel(
            targetPath: '/remote/target',
            controlPath: '/remote/control',
            controlEntries: 2,
            events: events = <String>[],
            // Warmup + two measured pairs at 10000 entries; the third
            // measured pair observes a shrunk tree.
            targetCounts: (call) => call <= 3 ? 10000 : 9999,
          ),
          output: output,
        );

        expect(result.exitCode, 1);
        expect(result.stderr, contains('entry count changed'));
        final document =
            jsonDecode(await File(output).readAsString())
                as Map<String, Object?>;
        final rows = document['rows']! as List<Object?>;
        expect(rows, hasLength(3));
        for (final row in rows.cast<Map<String, Object?>>()) {
          final fingerprint = row['fingerprint']! as Map<String, Object?>;
          // Every row — ok and error — carries the frozen identity the
          // successful pairs were measured under; the changed count
          // appears only in the error row's text.
          expect(
            fingerprint['scenarioConfig'],
            contains('target-entries=10000'),
          );
          expect(
            fingerprint['scenarioConfig'],
            isNot(contains('target-entries=9999')),
          );
        }
        expect(
          document['provenance']! as Map,
          containsPair('targetEntries', 10000),
        );
        final errorRow = rows.last! as Map<String, Object?>;
        expect(errorRow['status'], 'error');
        expect(errorRow['error'], contains('10000->9999'));
      },
    );

    test(
      'a mid-run listing failure writes partial rows and an error row',
      () async {
        final output = '${tempDir.path}/results.json';
        final result = await run(
          outputPath: output,
          targetFailure: const RemoteFileException(
            kind: RemoteFileErrorKind.permissionDenied,
            operation: 'list',
            path: '/remote/target',
            message: 'permission denied by fixture',
          ),
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
        expect(errorRow['repetition'], okRows.length);
        expect(errorRow['error'], contains('permission denied by fixture'));
        expect(errorRow.containsKey('value'), isFalse);
        // Cleanup ran despite the failure.
        expect(channel.closeCount, 1);
        expect(result.released, isTrue);
      },
    );

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
      // Provenance stays honest when entries were never observed.
      final fingerprint = row['fingerprint']! as Map<String, Object?>;
      expect(fingerprint['scenarioConfig'], contains('entries=unknown'));
    });
  });

  group('results temp ownership', () {
    Future<P3RunResult> runWithCandidates(
      String output,
      String Function(int attempt) candidateName,
    ) {
      return runP3Collection(
        config: P3CollectorConfig(
          targetPath: '/remote/target',
          controlPath: '/remote/control',
          outputPath: output,
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        ),
        fingerprint: const P3FingerprintFields(
          runnerImage: 'test-image',
          arch: 'x64test',
          dartVersion: 'test-dart',
          flutterVersion: null,
          mode: 'aot',
          cpuModel: 'test-cpu',
        ),
        openChannel: () async => FakeBrowseChannel(
          targetPath: '/remote/target',
          controlPath: '/remote/control',
          controlEntries: 2,
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
        // The planted symlink itself must survive untouched (type check
        // must not follow the link).
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

  group('P3CollectorConfig.parse', () {
    test('a repeated flag is rejected instead of silently first-wins', () {
      expect(
        () => P3CollectorConfig.parse([
          '--output',
          'a.json',
          '--repetitions',
          '5',
          '--repetitions',
          '20',
          '--target',
          '/t',
          '--control',
          '/c',
        ]),
        throwsA(
          isA<P3UsageException>().having(
            (error) => error.message,
            'message',
            contains('--repetitions'),
          ),
        ),
      );
    });

    test('a flag token swallowed as a value is rejected', () {
      expect(
        () => P3CollectorConfig.parse([
          '--output',
          'a.json',
          '--target',
          '--control',
          '/c',
        ]),
        throwsA(
          isA<P3UsageException>().having(
            (error) => error.message,
            'message',
            contains('--target'),
          ),
        ),
      );
    });

    test('a normal invocation still parses', () {
      final config = P3CollectorConfig.parse([
        '--output',
        'a.json',
        '--target',
        '/t',
        '--control',
        '/c',
        '--repetitions',
        '7',
      ]);
      expect(config.repetitions, 7);
      expect(config.targetPath, '/t');
      expect(config.controlPath, '/c');
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
      collectorPath = '$packageDir/benchmark/p3_listing_overhead.dart';
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
        ['run', 'benchmark/p3_listing_overhead.dart', ...args],
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
      final result = await runCollector(['--target', '/a', '--control', '/b']);
      expect(result.exitCode, 2);
      expect(result.stderr as String, contains('--output'));
    });

    test('missing fixture env names every absent variable', () async {
      final result = await runCollector(
        [
          '--output',
          '${tempDir.path}/results.json',
          '--target',
          '/remote/target',
          '--control',
          '/remote/control',
        ],
        // Truly absent (not merely empty): the collector treats both the
        // same, but the test claims absence, so remove the variables.
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

    test(
      'identical raw target and control paths are rejected pre-connect',
      () async {
        final result = await runCollector(
          [
            '--output',
            '${tempDir.path}/results.json',
            '--target',
            '/remote/same',
            '--control',
            '/remote/same',
            '--host-key-pub',
            '${tempDir.path}/missing.pub',
          ],
          environment: {
            'POLTERGEIST_SSHD': '127.0.0.1',
            'POLTERGEIST_SSHD_MODERN': '2201',
            'POLTERGEIST_SSHD_USER': 'poltergeist',
            'POLTERGEIST_SSHD_KEY': '${tempDir.path}/missing-key',
          },
        );
        expect(result.exitCode, 2);
        expect(result.stderr as String, contains('distinct'));
        // The invocation is invalid before any credential file is read
        // (the usage text mentions the key variable; no read error may).
        expect(
          result.stderr as String,
          isNot(contains('cannot read the user private key')),
        );
      },
    );

    test('repetitions below the checker floor are rejected', () async {
      final result = await runCollector(['--help']);
      expect(result.exitCode, 0); // sanity: parser runs

      final bad = await runCollector(
        [
          '--output',
          '${tempDir.path}/results.json',
          '--target',
          '/a',
          '--control',
          '/b',
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
        '--control',
        '/b',
        '--repetition', // typo: the trailing s is missing
        '10',
      ]);
      expect(result.exitCode, 2);
      expect(result.stderr as String, contains('--repetition'));
      expect(result.stderr as String, contains('unknown option'));
    });

    test('a duplicated flag is rejected naming the flag', () async {
      final result = await runCollector([
        '--output',
        '${tempDir.path}/results.json',
        '--target',
        '/a',
        '--control',
        '/b',
        '--repetitions',
        '5',
        '--repetitions',
        '7',
      ]);
      expect(result.exitCode, 2);
      expect(result.stderr as String, contains('more than once'));
      expect(result.stderr as String, contains('--repetitions'));
    });

    test('a flag token where a value belongs is rejected', () async {
      final result = await runCollector([
        '--output',
        '${tempDir.path}/results.json',
        '--target',
        '--control',
        '/b',
      ]);
      expect(result.exitCode, 2);
      expect(result.stderr as String, contains('looks like an option'));
      expect(result.stderr as String, contains('--target'));
    });

    test(
      'zero warmups are rejected: the protocol requires warm pairs',
      () async {
        final result = await runCollector([
          '--output',
          '${tempDir.path}/results.json',
          '--target',
          '/a',
          '--control',
          '/b',
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
      required Duration targetDelay,
      required bool enforce,
    }) async {
      final output = '${tempDir.path}/results.json';
      final events = <String>[];
      final channel = FakeBrowseChannel(
        targetPath: '/remote/target',
        controlPath: '/remote/control',
        controlEntries: 2,
        events: events,
      )..targetDelay = targetDelay;
      final collection = await runP3Collection(
        config: P3CollectorConfig(
          targetPath: '/remote/target',
          controlPath: '/remote/control',
          outputPath: output,
          warmups: 1,
          repetitions: 5,
          listingTimeout: const Duration(seconds: 5),
          deadline: const Duration(minutes: 1),
        ),
        fingerprint: const P3FingerprintFields(
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
      // The checker path closes its channel like every other path.
      expect(events, contains('close'));

      // Derive the test-owned calibration from the emitted fingerprint so
      // every common controlled axis matches by construction. The config
      // axis moves to its schema-2 home: the scenario's own
      // calibratedScenarioConfig, never a job-wide fingerprint claim.
      final emitted =
          jsonDecode(await File(output).readAsString()) as Map<String, Object?>;
      final firstRow =
          (emitted['rows']! as List).first! as Map<String, Object?>;
      final rowFingerprint = firstRow['fingerprint']! as Map<String, Object?>;
      final calibration = {...rowFingerprint}
        ..remove('scenarioConfig');
      final budgets = {
        'schema': 'poltergeist-d12-budgets-2',
        'calibratedFingerprint': calibration,
        'scenarios': [
          {
            'id': 'P3',
            'tier': 'a',
            'summary': 'Remote listing overhead over network time',
            'operator': 'lessThan',
            'value': 50,
            'unit': 'ms',
            'minimumRepetitions': 5,
            'landed': true,
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
        targetDelay: Duration.zero,
        enforce: true,
      );
      expect(exit, 0, reason: stderrText);
      expect(
        stdoutText,
        contains(RegExp(r'^P3\s+a\s.*pass$', multiLine: true)),
      );
    });

    test(
      'an enforced overrun through real collector output fails red',
      () async {
        final (exit, stdoutText, stderrText) = await collectAndCheck(
          targetDelay: const Duration(milliseconds: 120),
          enforce: true,
        );
        expect(exit, 1, reason: stderrText);
        expect(stdoutText, contains('overrun (fail: enforced)'));
      },
    );

    test('a non-enforced overrun reports without failing the run', () async {
      final (exit, stdoutText, stderrText) = await collectAndCheck(
        targetDelay: const Duration(milliseconds: 120),
        enforce: false,
      );
      expect(exit, 0, reason: stderrText);
      expect(stdoutText, contains('overrun (notice: not enforced)'));
    });
  });
}

/// Fake browse channel over the production interface: records listings and
/// lifecycle events so ordering, one-channel, and cleanup contracts are
/// observable without sockets.
class FakeBrowseChannel implements PaneChannel {
  final String targetPath;
  final String controlPath;
  final int controlEntries;
  final List<String> events;
  final String Function(String path)? canonicalizer;

  Duration? targetDelay;
  Object? targetFailure;
  Object? canonicalFailure;

  /// Optional per-call (1-based, warmups included) target entry count;
  /// null keeps the fixed 10000-entry tree. Tests use it to observe a
  /// changed tree size mid-run (the identity-guard path).
  int Function(int call)? targetCounts;

  /// 1-based target-listing call index (warmups included) on which
  /// [targetFailure] throws; 1 makes every target listing fail.
  int targetFailureCall = 1;

  int closeCount = 0;

  FakeBrowseChannel({
    required this.targetPath,
    required this.controlPath,
    required this.controlEntries,
    required this.events,
    this.canonicalizer,
    this.targetCounts,
  }) {
    fs.targetPath = targetPath;
    fs.controlPath = controlPath;
    fs.controlEntries = controlEntries;
    fs.events = events;
    fs.canonicalizer = canonicalizer;
    fs.canonicalFailureReader = () => canonicalFailure;
    fs.targetDelayReader = () => targetDelay;
    fs.targetFailureReader = () => targetFailure;
    fs.targetFailureCallReader = () => targetFailureCall;
    // Closes over the mutable knob so post-construction changes apply.
    fs.targetEntryCount = (call) => targetCounts?.call(call) ?? 10000;
  }

  @override
  final FakeListingVfs fs = FakeListingVfs();

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

/// Fake VFS implementing exactly the two operations the collector uses;
/// anything else fails loudly like the pool stubs (08 §3.2).
class FakeListingVfs implements RemoteFileSystem {
  late String targetPath;
  late String controlPath;
  late int controlEntries;
  late List<String> events;
  // Constructor-wired closures (late = a wiring bug fails loudly at first
  // use instead of silently defaulting); the return values stay nullable —
  // that is the optional-knob part.
  late String Function(String path)? canonicalizer;
  late Object? Function() canonicalFailureReader;
  late Duration? Function() targetDelayReader;
  late Object? Function() targetFailureReader;
  late int Function() targetFailureCallReader;
  late int Function(int call) targetEntryCount;

  final List<({String path, int seq})> listings = [];
  int _seq = 0;
  int _targetCalls = 0;

  @override
  Future<String> canonicalize(String path) async {
    final failure = canonicalFailureReader();
    if (failure != null) throw failure;
    final override = canonicalizer;
    if (override != null) return override(path);
    return path;
  }

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    // Records every attempt (including delayed, failed, and timed-out
    // listings); `listings` below records only successful completions.
    // The failure threshold counts target listings from the very first
    // warmup call, by design — one fake serves the whole run.
    events.add('list:$path');
    final delay = path == targetPath ? targetDelayReader() : null;
    if (delay != null && delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (path == targetPath) {
      _targetCalls++;
      final failure = targetFailureReader();
      if (failure != null && _targetCalls >= targetFailureCallReader()) {
        throw failure;
      }
    }
    listings.add((path: path, seq: _seq++));
    final count = path == targetPath
        ? targetEntryCount(_targetCalls)
        : controlEntries;
    return List.generate(count, (index) => _entry(path, index));
  }

  RemoteFileEntry _entry(String parent, int index) => RemoteFileEntry(
    path: '$parent/entry-$index',
    name: 'entry-$index',
    type: RemoteFileType.file,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeListingVfs only implements canonicalize/listDirectory, got '
    '${invocation.memberName}.',
  );
}

/// Runs [runP3Collection] against a prebuilt [channel] with default config.
Future<P3RunResult> runCollectionAgainst(
  FakeBrowseChannel channel, {
  required String output,
}) {
  return runP3Collection(
    config: P3CollectorConfig(
      targetPath: channel.targetPath,
      controlPath: channel.controlPath,
      outputPath: output,
      warmups: 1,
      repetitions: 5,
      listingTimeout: const Duration(seconds: 5),
      deadline: const Duration(minutes: 1),
    ),
    fingerprint: const P3FingerprintFields(
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
}
