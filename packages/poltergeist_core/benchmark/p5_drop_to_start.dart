// D12 P5 collector — drop → transfer starts (no upfront tree stat),
// measured over the production pool (02 §12's P5 row, 08 §6 tier A; the
// scenario gates at M4 with the transfer queue per 07 §3.4 — this lands
// the collector surface only, P5 stays unlanded in budgets.json).
//
// Protocol (fixed by the plan, never improvised here):
//  * one browse channel from the production pool stays open for the whole
//    run and serves the scan side of every drop leg; each measured
//    repetition drops the same target and runs the drop→start path the
//    queue will own at M4: ONE stat of the dropped root (classification —
//    a bare-path drop carries no type), then the lazy scan resolves the
//    first regular file with `listDirectory` calls only (listing entries
//    already carry type and size — never a per-entry stat, the "no
//    upfront tree stat" rule of 02 §12), then the transfer starts on a
//    freshly leased transfer channel;
//  * "transfer starts" = the first byte reaching the destination sink:
//    the leg wraps the sink, stamps the first delivered chunk, and cancels
//    the transfer there — start latency is the scenario, not throughput,
//    and the wait for the rest of the file (and the pinned VFS's
//    post-commit re-stats) is deliberately not measured;
//  * the stat/listing calls the leg issues inside the measured window are
//    counted and reported per row: the count must stay flat as the tree
//    grows (the two-size falsifiable form lives in the deterministic
//    test — a 1k-entry and a 50k-entry drop must issue the same stat
//    count; "O(first file), not O(tree)");
//  * authentication, channel setup, and canonicalization happen before
//    any timed leg;
//  * a stated number of warmup drops runs first and is discarded;
//  * at least `--repetitions` (>= 5) measured drops emit one results row
//    each: the unclipped drop→first-byte milliseconds plus the raw leg
//    detail (stat/listing counts, first file, first chunk size);
//  * rows match the checker's `poltergeist-d12-results-1` schema
//    (test/benchmarks/check.dart) so the same file gates CI later; the
//    fingerprint's `mode` axis is detected, never declared — a JIT run is
//    reported as `jit` and stays ineligible for tier-A budget comparison.
//
// Lifecycle ownership stays with test/integration/run.sh: invoke through
//
//   test/integration/run.sh --lifecycle-only -- <command building and
//   running this collector>
//
// so readiness, smoke, and teardown are the fixture's, not a duplicate
// here. The collector never writes anything on the server side: only
// `stat`, `listDirectory`, `canonicalize`, and `download` of the first
// file are issued against the caller-supplied existing drop target.
//
// The scenario-agnostic helpers (environment fingerprint, run-mode
// detection, checker median, results schema id, usage-failure types) are
// imported from the P3 collector — reused, not forked. The owned
// exclusive-temp results publication below mirrors the p3TempNameAttempts
// pattern faithfully (the same ownership class #105 established for the
// checker's drift state — mirrored, not refactored).
//
// Exit codes: 0 collected; 2 usage/invocation failure (actionable message,
// no results file); 1 measurement failure (partial rows plus an honest
// error row were written); 74 results-file IO failure.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';

import 'p3_listing_overhead.dart'
    show
        P3FingerprintFields,
        P3HelpRequested,
        P3UsageException,
        detectRunMode,
        medianOf,
        p3ResultsSchemaId;

// --- Scenario identity (mirrors test/benchmarks/budgets.json) ------------

const p5ScenarioId = 'P5';
const p5ResultsSchemaId = p3ResultsSchemaId;

/// 02 §12 / budgets.json: P5's repetition floor. The CLI refuses smaller
/// runs because the checker would fail them as incomplete measurements.
/// budgets.json's spec-mirrored P5 floor is 3 (08 §6's generic floor; M4
/// names none); the collector enforces the stricter 5, matching P3/P7.
const p5MinimumMeasuredRepetitions = 5;
const p5DefaultWarmups = 2;
const p5DefaultMeasuredRepetitions = 5;

/// Bounds for the untimed phases; the measured legs additionally respect
/// [P5CollectorConfig.deadline] as a whole-run budget (no unbounded retry,
/// no unbounded wait). The budget caps each filesystem await; it stops
/// the wait, not the underlying VFS IO (no cancellation exists for
/// listings in the pinned interface — open item 12), and cleanup retires
/// the channel boundedly.
const p5OpenChannelTimeout = Duration(seconds: 60);
const p5TeardownTimeout = Duration(seconds: 30);
const p5DefaultOperationTimeout = Duration(seconds: 30);
const p5DefaultDeadline = Duration(minutes: 10);

/// The committed fixture host key (08 §5 pin-store isolation: every
/// non-TOFU suite pre-seeds this key so a healthy fixture never prompts).
const p5DefaultHostKeyPubPath =
    'test/integration/keys/ssh_host_ed25519_key.pub';

/// The scenario-agnostic shapes below are the P3 collector's public
/// helpers under P5-scoped names — the fingerprint axes, the usage
/// failure, and the help marker are one contract shared by every tier-A
/// collector, so they are aliased here rather than copied.
typedef P5FingerprintFields = P3FingerprintFields;
typedef P5UsageException = P3UsageException;
typedef P5HelpRequested = P3HelpRequested;

const _usageText =
    '''
Usage: dart run benchmark/p5_drop_to_start.dart \\
    --output FILE --target PATH [options]

Collects D12 P5 samples (drop → transfer starts, 02 §12 / 08 §6): each
measured repetition drops the target onto the drop→start path — one
classification stat of the dropped root, a lazy listing-only scan to the
first regular file, then a transfer-channel lease and a download measured
to the first delivered byte (the leg cancels there; the rest of the file
is not waited out). Warmup drops are discarded. Results match the
poltergeist-d12-results-1 schema consumed by test/benchmarks/check.dart.

Options:
  --output <path>      results file to write (required, atomic write)
  --target <path>      existing remote path to drop: a directory tree or
                       a single file (required)
  --warmups <n>        discarded warmup drops, >= 1 (default 2)
  --repetitions <n>    measured drops, >= 5 (default 5)
  --host-key-pub <p>   fixture host public key (default
                       $p5DefaultHostKeyPubPath, resolved from the repo
                       root; test/integration/run.sh cds there)
  -h, --help           print this usage

Environment (exported by test/integration/run.sh --lifecycle-only):
  POLTERGEIST_SSHD            fixture host (must be IPv4 loopback)
  POLTERGEIST_SSHD_MODERN     sshd-modern port
  POLTERGEIST_SSHD_USER       fixture username
  POLTERGEIST_SSHD_KEY        path to the per-run user private key
  POLTERGEIST_BENCH_RUNNER_IMAGE  optional fingerprint axis override
  POLTERGEIST_BENCH_CPU_MODEL     optional fingerprint axis override''';

// --- Shared types ---------------------------------------------------------

/// One measured drop→start leg. [dropToFirstByte] is the P5 value —
/// unclipped, exactly as measured. [statCalls] and [listingCalls] count
/// the filesystem calls this leg issued inside the measured window; they
/// are the structural half of the scenario — flat versus tree size.
final class P5DropSample {
  final Duration dropToFirstByte;

  /// Drop → the transfer call settling (first byte plus the cancel/drain
  /// unwind) — audit detail, never the reported value.
  final Duration legSettled;
  final int statCalls;
  final int listingCalls;

  /// Entries in the dropped root's own listing; null for a file drop.
  final int? rootEntries;
  final String firstFilePath;
  final int firstChunkBytes;

  const P5DropSample({
    required this.dropToFirstByte,
    required this.legSettled,
    required this.statCalls,
    required this.listingCalls,
    required this.rootEntries,
    required this.firstFilePath,
    required this.firstChunkBytes,
  });

  double get dropToFirstByteMs => dropToFirstByte.inMicroseconds / 1000.0;
  double get legSettledMs => legSettled.inMicroseconds / 1000.0;
}

/// What a collection run observed. [failedRepetition] is null on success;
/// on failure it is the measured repetition index that failed (0 when the
/// failure preceded the first measured drop, e.g. during warmup or setup).
/// The remaining fields are the run's frozen scenario identity — null
/// when never observed.
final class P5RunOutcome {
  final List<P5DropSample> measuredDrops;
  final int? failedRepetition;
  final String? failureMessage;
  final String? droppedKind;
  final int? rootEntries;
  final String? firstFilePath;
  final int? statCalls;
  final int? listingCalls;

  const P5RunOutcome({
    required this.measuredDrops,
    required this.failedRepetition,
    required this.failureMessage,
    required this.droppedKind,
    required this.rootEntries,
    required this.firstFilePath,
    required this.statCalls,
    required this.listingCalls,
  });

  bool get completed => failedRepetition == null;
}

/// Parsed CLI arguments.
final class P5CollectorConfig {
  final String targetPath;
  final String outputPath;
  final int warmups;
  final int repetitions;
  final Duration operationTimeout;
  final Duration deadline;
  final Duration channelOpenTimeout;
  final String? hostKeyPubPath;

  const P5CollectorConfig({
    required this.targetPath,
    required this.outputPath,
    this.warmups = p5DefaultWarmups,
    this.repetitions = p5DefaultMeasuredRepetitions,
    this.operationTimeout = p5DefaultOperationTimeout,
    this.deadline = p5DefaultDeadline,
    this.channelOpenTimeout = p5OpenChannelTimeout,
    this.hostKeyPubPath,
  });

  /// Parses and validates, rejecting anything unrecognized: a measurement
  /// tool must not silently drop a mistyped flag — an operator asking for
  /// 20 repetitions must never get 5 without an error (the >= 5 floor
  /// would hide the typo).
  static P5CollectorConfig parse(List<String> arguments) {
    String? flagValue(String flag) {
      final index = arguments.indexOf(flag);
      if (index == -1) return null;
      if (arguments.lastIndexOf(flag) != index) {
        throw P5UsageException('$flag was passed more than once.');
      }
      if (index + 1 >= arguments.length) {
        throw P5UsageException('$flag requires a value.');
      }
      final value = arguments[index + 1];
      if (value.startsWith('-')) {
        throw P5UsageException(
          '$flag requires a value; "$value" looks like an option; '
          'see --help.',
        );
      }
      if (value.isEmpty) {
        throw P5UsageException('$flag requires a non-empty value.');
      }
      return value;
    }

    if (arguments.any((argument) => argument == '-h' || argument == '--help')) {
      throw const P5HelpRequested();
    }

    const knownFlags = {
      '--output',
      '--target',
      '--warmups',
      '--repetitions',
      '--host-key-pub',
    };
    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      if (argument.startsWith('-')) {
        if (!knownFlags.contains(argument)) {
          throw P5UsageException(
            'unknown option "$argument" (or a value starting with "-"); '
            'see --help.',
          );
        }
        continue;
      }
      // A positional token that does not immediately follow a known flag
      // is a dropped flag's value or a stray path — reject it instead of
      // silently running with defaults (the typo guard the doc comment
      // promises).
      final isFlagValue = i > 0 && knownFlags.contains(arguments[i - 1]);
      if (!isFlagValue) {
        throw P5UsageException(
          'unexpected positional argument "$argument"; see --help.',
        );
      }
    }

    final outputPath = flagValue('--output');
    if (outputPath == null || outputPath.isEmpty) {
      throw const P5UsageException('--output is required.');
    }
    final targetPath = flagValue('--target');
    if (targetPath == null || targetPath.isEmpty) {
      throw const P5UsageException('--target is required.');
    }

    int positiveInt(String flag, int fallback, int minimum) {
      final raw = flagValue(flag);
      if (raw == null) return fallback;
      final parsed = int.tryParse(raw);
      if (parsed == null || parsed < minimum) {
        throw P5UsageException(
          '$flag must be an integer >= $minimum (got "$raw").',
        );
      }
      return parsed;
    }

    return P5CollectorConfig(
      targetPath: targetPath,
      outputPath: outputPath,
      warmups: positiveInt('--warmups', p5DefaultWarmups, 1),
      repetitions: positiveInt(
        '--repetitions',
        p5DefaultMeasuredRepetitions,
        p5MinimumMeasuredRepetitions,
      ),
      hostKeyPubPath: flagValue('--host-key-pub'),
    );
  }
}

/// Terminal outcome of one collection run for [p5Main] to print and exit
/// with; [released] reports whether the injected server-release step ran.
final class P5RunResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool released;

  const P5RunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.released,
  });
}

// --- Sampler ---------------------------------------------------------------

/// Whole-run-budget expiry inside a filesystem await — distinct from a
/// per-operation [TimeoutException] so failures attribute honestly.
class _RunBudgetExceeded implements Exception {
  final String message;

  const _RunBudgetExceeded(this.message);

  @override
  String toString() => message;
}

/// The destination of a measured transfer: records the first delivered
/// chunk (the "transfer starts" signal) and discards bytes — the leg
/// measures latency to first byte, never writes anything to disk.
final class _FirstByteSink implements StreamSink<List<int>> {
  final void Function(int chunkBytes) onFirstChunk;

  var _chunkCount = 0;
  var _closed = false;
  final _done = Completer<void>();

  /// A writer-side failure reported through the StreamSink protocol's
  /// error channel. Surfaced by the leg when no byte ever arrived —
  /// without it, a downloader that reports via `addError` and then
  /// completes normally would be misattributed as the empty-file case.
  Object? sinkError;
  StackTrace? sinkStackTrace;

  _FirstByteSink({required this.onFirstChunk});

  @override
  void add(List<int> data) {
    if (_closed) {
      throw StateError('cannot add to a closed first-byte sink');
    }
    // Only a non-empty chunk is "the first byte": an empty leading chunk
    // (header flush, zero-length read) must not stamp the start signal.
    if (data.isNotEmpty && _chunkCount++ == 0) {
      onFirstChunk(data.length);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    // Record the error and its stack trace as an atomic pair — pairing
    // the first error with a later call's trace would mislead diagnosis.
    if (sinkError == null) {
      sinkError = error;
      sinkStackTrace = stackTrace;
    }
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    if (!_done.isCompleted) _done.complete();
    return _done.future;
  }

  @override
  Future<void> get done => _done.future;
}

/// Runs the fixed warmup/measured protocol over the drop→start leg and
/// returns the raw samples plus an honest failure report. No retry: the
/// first failing leg ends the run at its repetition index. Every
/// filesystem await is capped at the lesser of the per-operation timeout
/// and the remaining whole-run budget, and whole-run expiry is attributed
/// as a run-budget overrun, never as a per-operation timeout.
Future<P5RunOutcome> collectDropToStartSamples({
  /// Classification + lazy-scan side of the leg: `stat` of the dropped
  /// root (once, `followLinks: false` per 03 §4.2's scan semantics) and
  /// `listDirectory` while resolving the first regular file.
  required Future<RemoteFileEntry> Function(String path) stat,
  required Future<List<RemoteFileEntry>> Function(String path)
  listDirectory,

  /// The transfer-start side: `download` of the first file into the
  /// leg's counting sink. The production wiring leases a transfer channel
  /// inside this closure, so channel-acquisition queueing is inside the
  /// measured window — it is part of "transfer starts".
  required Future<RemoteFileEntry> Function(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferCancellation? cancellation,
  })
  download,
  required String droppedPath,
  required int warmups,
  required int repetitions,
  required Duration operationTimeout,
  required Duration deadline,
}) async {
  final runClock = Stopwatch()..start();
  final samples = <P5DropSample>[];
  String? observedKind;
  int? observedRootEntries;
  String? observedFirstFile;
  int? observedStatCalls;
  int? observedListingCalls;

  // The drop identity frozen after warmups — the scenario every measured
  // row's fingerprint claims (see the check inside runDrop below). The
  // CLI rejects --warmups 0, but direct callers may pass it; with zero
  // warmups the freeze observes nothing, so arming defers to the first
  // measured drop instead of never firing.
  String? expectedKind;
  int? expectedRootEntries;
  String? expectedFirstFile;
  int? expectedStatCalls;
  int? expectedListingCalls;
  var identityArmed = false;

  P5RunOutcome fail(int repetition, String message) => P5RunOutcome(
    measuredDrops: samples,
    failedRepetition: repetition,
    failureMessage: message,
    // Once the run's identity is frozen, every row — including the
    // error row of a partial failure — carries the frozen identity: the
    // rows describe the drops that were measured, and a later changed
    // observation belongs only in the error text, never in the config
    // the completed rows claim.
    droppedKind: identityArmed ? expectedKind : observedKind,
    rootEntries: identityArmed ? expectedRootEntries : observedRootEntries,
    firstFilePath: identityArmed ? expectedFirstFile : observedFirstFile,
    statCalls: identityArmed ? expectedStatCalls : observedStatCalls,
    listingCalls: identityArmed ? expectedListingCalls : observedListingCalls,
  );

  // The whole-run budget must bound every await, not just the gaps
  // between drops: Future.timeout stops the WAIT, never the underlying
  // VFS IO (the pinned interface offers no listing cancellation — open
  // item 12), so expiry means the collector reports, stops waiting, and
  // tears the channel down inside the bounded cleanup while the wedged
  // operation's IO may still finish engine-side.
  Duration remainingBudget() => deadline - runClock.elapsed;

  Future<T> boundedOperation<T>(
    Future<T> Function() operation,
    String leg,
    String label,
  ) {
    final remaining = remainingBudget();
    if (remaining <= Duration.zero) {
      throw _RunBudgetExceeded(
        'run deadline exceeded before the $leg of $label',
      );
    }
    final cap = operationTimeout < remaining ? operationTimeout : remaining;
    final runBudgetBinds = remaining <= operationTimeout;
    return operation().timeout(
      cap,
      onTimeout: () {
        if (runBudgetBinds) {
          throw _RunBudgetExceeded(
            'run deadline exceeded during the $leg of $label '
            '(${runClock.elapsed.inMilliseconds} ms elapsed of a '
            '${deadline.inMilliseconds} ms whole-run budget)',
          );
        }
        throw TimeoutException(leg, operationTimeout);
      },
    );
  }

  /// Resolves the first regular file under a dropped directory exactly as
  /// the queue's lazy scan does (03 §4.2): breadth-first in listing
  /// order, `listDirectory` only — the listing entries already carry
  /// type, so resolving the first file costs listings, never per-entry
  /// stats. Symlinks and other non-regular entries are skipped, never
  /// descended. Returns the file entry plus the dropped root's own
  /// listing size (the scenario-identity axis).
  Future<({RemoteFileEntry file, int rootEntries})> firstFileUnder(
    String rootPath,
    String label,
    void Function() onListing,
  ) async {
    final pending = Queue<String>()..add(rootPath);
    int? rootEntries;
    while (pending.isNotEmpty) {
      final directory = pending.removeFirst();
      onListing();
      final children = await boundedOperation(
        () => listDirectory(directory),
        'scan listing of $directory',
        label,
      );
      rootEntries ??= children.length;
      for (final child in children) {
        if (child.type == RemoteFileType.file) {
          return (file: child, rootEntries: rootEntries);
        }
      }
      for (final child in children) {
        if (child.isDirectory) {
          pending.add(child.path);
        }
      }
    }
    throw RemoteFileException(
      kind: RemoteFileErrorKind.notFound,
      operation: 'drop scan',
      path: rootPath,
      message: 'the dropped directory tree contains no regular file — '
          'there is nothing whose first byte could start the transfer',
    );
  }

  Future<P5DropSample> runDrop(String label) async {
    final legWatch = Stopwatch()..start();
    var statCalls = 0;
    var listingCalls = 0;

    // One stat of the dropped root classifies the drop — the only stat
    // the path is allowed to issue. A real pane drag arrives with its
    // listing entry and needs zero; the bare-path form measured here is
    // the conservative case. Either way the count is flat in tree size:
    // stat-ing the tree upfront is the failure mode 02 §12 forbids.
    statCalls++;
    final dropped = await boundedOperation(
      () => stat(droppedPath),
      'drop classification stat',
      label,
    );

    final RemoteFileEntry firstFile;
    final int? rootEntries;
    switch (dropped.type) {
      case RemoteFileType.file:
        firstFile = dropped;
        rootEntries = null;
      case RemoteFileType.directory:
        final resolved = await firstFileUnder(
          droppedPath,
          label,
          () => listingCalls++,
        );
        firstFile = resolved.file;
        rootEntries = resolved.rootEntries;
      default:
        throw RemoteFileException(
          kind: RemoteFileErrorKind.unsupported,
          operation: 'drop',
          path: droppedPath,
          message: 'a dropped ${dropped.type.name} is not transferable — '
              'the drop→start path only starts regular files '
              '(followLinks: false, per the scan semantics of 03 §4.2)',
        );
    }

    // The transfer start: first byte into the counting sink ends the
    // measurement and cancels the transfer — the rest of the file (and
    // the pinned VFS's post-commit re-stats) is not part of "starts".
    final cancellation = RemoteTransferCancellation();
    Duration? firstByteAt;
    var firstChunkBytes = 0;
    final sink = _FirstByteSink(
      onFirstChunk: (bytes) {
        firstByteAt = legWatch.elapsed;
        firstChunkBytes = bytes;
        cancellation.cancel();
      },
    );
    try {
      await boundedOperation(
        () => download(firstFile.path, sink, cancellation: cancellation),
        'first-byte transfer of ${firstFile.path}',
        label,
      );
    } on RemoteFileException catch (error) {
      // The collector's own first-byte cancellation is the expected leg
      // end; a cancellation observed before any byte, or any other
      // failure, is an honest leg failure.
      if (error.kind != RemoteFileErrorKind.cancelled ||
          firstByteAt == null) {
        rethrow;
      }
    }
    final elapsed = firstByteAt;
    if (elapsed == null) {
      // A writer that reported its failure through the sink protocol and
      // then completed normally surfaces that failure, not the
      // empty-file diagnosis.
      final sinkError = sink.sinkError;
      if (sinkError != null) {
        Error.throwWithStackTrace(
          sinkError,
          sink.sinkStackTrace ?? StackTrace.current,
        );
      }
      // An empty first file completes without a byte ever flowing — the
      // scenario is genuinely unobservable on it, so the leg fails
      // honestly instead of reporting the full-download time as "start".
      throw StateError(
        'the transfer of ${firstFile.path} completed without delivering '
        'a byte — drop→start is unobservable on an empty first file',
      );
    }

    final sample = P5DropSample(
      dropToFirstByte: elapsed,
      legSettled: legWatch.elapsed,
      statCalls: statCalls,
      listingCalls: listingCalls,
      rootEntries: rootEntries,
      firstFilePath: firstFile.path,
      firstChunkBytes: firstChunkBytes,
    );

    observedKind = dropped.type.name;
    observedRootEntries = rootEntries;
    observedFirstFile = firstFile.path;
    observedStatCalls = statCalls;
    observedListingCalls = listingCalls;

    // The results schema requires every row to carry one fingerprint,
    // and the drop identity is a fingerprint axis: a tree that changes
    // under the run — a resized root listing, a different first file, a
    // shifted scan descent — cannot be represented honestly, so the run
    // fails at the changing drop instead of smearing one identity across
    // every row. The issued call counts are part of that identity: the
    // structural claim (flat versus tree size) must hold per row, not
    // just in the test fixture.
    if (identityArmed) {
      expectedKind ??= observedKind;
      expectedRootEntries ??= observedRootEntries;
      expectedFirstFile ??= observedFirstFile;
      expectedStatCalls ??= observedStatCalls;
      expectedListingCalls ??= observedListingCalls;
    }
    if (expectedKind != null &&
        (expectedKind != observedKind ||
            expectedRootEntries != observedRootEntries ||
            expectedFirstFile != observedFirstFile ||
            expectedStatCalls != observedStatCalls ||
            expectedListingCalls != observedListingCalls)) {
      throw StateError(
        'drop identity changed mid-run: kind '
        '${expectedKind ?? '?'}->${observedKind ?? '?'} / root entries '
        '${expectedRootEntries ?? '?'}->${observedRootEntries ?? '?'} / '
        'first file ${expectedFirstFile ?? '?'}->'
        '${observedFirstFile ?? '?'} / stat calls '
        '${expectedStatCalls ?? '?'}->${observedStatCalls ?? '?'} / '
        'listing calls '
        '${expectedListingCalls ?? '?'}->${observedListingCalls ?? '?'}',
      );
    }

    return sample;
  }

  for (var warmup = 0; warmup < warmups; warmup++) {
    if (runClock.elapsed >= deadline) {
      return fail(0, 'run deadline exceeded before warmup drop $warmup');
    }
    try {
      await runDrop('warmup drop $warmup');
    } on _RunBudgetExceeded catch (error) {
      return fail(0, error.message);
    } on TimeoutException catch (error) {
      return fail(
        0,
        'warmup drop $warmup ${error.message} timed out after '
        '${operationTimeout.inMilliseconds} ms',
      );
    } catch (error) {
      return fail(0, 'warmup drop $warmup failed: ${_describe(error)}');
    }
  }

  // Freeze the observed drop identity as the run's scenario identity;
  // the guard above arms even when no warmup drop ran.
  expectedKind = observedKind;
  expectedRootEntries = observedRootEntries;
  expectedFirstFile = observedFirstFile;
  expectedStatCalls = observedStatCalls;
  expectedListingCalls = observedListingCalls;
  identityArmed = true;

  for (var repetition = 0; repetition < repetitions; repetition++) {
    if (runClock.elapsed >= deadline) {
      return fail(
        repetition,
        'run deadline exceeded before repetition $repetition '
        '(${samples.length} completed)',
      );
    }
    try {
      samples.add(await runDrop('repetition $repetition'));
    } on _RunBudgetExceeded catch (error) {
      return fail(repetition, error.message);
    } on TimeoutException catch (error) {
      return fail(
        repetition,
        'repetition $repetition ${error.message} timed out after '
        '${operationTimeout.inMilliseconds} ms',
      );
    } catch (error) {
      return fail(
        repetition,
        'repetition $repetition failed: ${_describe(error)}',
      );
    }
  }

  return P5RunOutcome(
    measuredDrops: samples,
    failedRepetition: null,
    failureMessage: null,
    droppedKind: observedKind,
    rootEntries: observedRootEntries,
    firstFilePath: observedFirstFile,
    statCalls: observedStatCalls,
    listingCalls: observedListingCalls,
  );
}

String _describe(Object error) {
  if (error is RemoteFileException) {
    final path = error.path == null ? '' : ', path: ${error.path}';
    return '${error.message} '
        '(kind: ${error.kind.name}, operation: ${error.operation}$path)';
  }
  return error.toString();
}

// --- Mid-level collection over a browse channel ---------------------------

/// Collects P5 through [openChannel] (called once: the scan side of every
/// drop leg shares that one retained browse channel) and [leaseChannel]
/// (called once per drop leg: the transfer start acquires a real transfer
/// lease inside the measured window) and releases the server via
/// [releaseServer] on every exit path. Measurement failures still write
/// the results file with the completed rows plus one honest error row;
/// usage failures write nothing.
Future<P5RunResult> runP5Collection({
  required P5CollectorConfig config,
  required P5FingerprintFields fingerprint,
  required Future<PaneChannel> Function() openChannel,
  required Future<TransferChannelLease> Function() leaseChannel,
  required Future<void> Function() releaseServer,

  /// Test seam for temp-name ownership: builds the owned-temporary
  /// candidate for a 1-based attempt. Production leaves it null and uses
  /// the default candidate builder; tests inject colliding names.
  String Function(int attempt)? tempCandidateName,
}) async {
  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  var released = false;
  PaneChannel? channel;

  // The collect() body returns only an exit code; the P5RunResult is
  // built once, AFTER the finally-bound cleanup, so `released` reflects
  // reality instead of a value captured before cleanup ran.
  Future<int> collect() async {
    // Failure before any drop: one error row, identity unknown — the
    // requested (not canonical) path is the honest scenario provenance.
    Future<int> failBeforeDrop(String context, Object error) async {
      final message = '$context failed: ${_describe(error)}';
      final writeError = await _writeResultsOrReport(
        config,
        stderrBuffer,
        buildP5ResultsDocument(
          fingerprint: fingerprint,
          dropPath: config.targetPath,
          warmups: config.warmups,
          requestedRepetitions: config.repetitions,
          outcome: null,
          rows: [
            _errorRowJson(
              repetition: 0,
              error: message,
              fingerprint: fingerprint,
              dropPath: config.targetPath,
              warmups: config.warmups,
              repetitions: config.repetitions,
              outcome: null,
            ),
          ],
        ),
        tempCandidateName: tempCandidateName,
      );
      stderrBuffer.writeln('P5 collection failed: $message');
      // An unpublishable results file is EX_IOERR (74) on this path too,
      // matching the main write below.
      return writeError == null ? 1 : 74;
    }

    // The stated whole-run budget covers setup too. Channel open and
    // canonicalize are bounded by their own timeouts and charged
    // against config.deadline, so slow setup consumes the drop budget
    // rather than extending it.
    final setupWatch = Stopwatch()..start();

    final PaneChannel openedChannel;
    try {
      openedChannel = await openChannel().timeout(
        config.channelOpenTimeout,
        onTimeout: () => throw TimeoutException(
          'timed out after ${config.channelOpenTimeout.inMilliseconds} ms',
          config.channelOpenTimeout,
        ),
      );
    } catch (error) {
      return failBeforeDrop('browse channel open', error);
    }
    channel = openedChannel;

    final String canonicalDrop;
    try {
      canonicalDrop = await openedChannel.fs
          .canonicalize(config.targetPath)
          .timeout(config.operationTimeout);
    } catch (error) {
      return failBeforeDrop('canonicalizing the drop target', error);
    }

    final outcome = await collectDropToStartSamples(
      stat: (path) => openedChannel.fs.stat(path, followLinks: false),
      listDirectory: openedChannel.fs.listDirectory,
      // Each drop leg's transfer start leases a real transfer channel
      // inside the measured window: queueing for the lease is part of
      // "transfer starts". A lease abandoned by a run-budget cut is
      // released here when it settles and is force-released by
      // releaseServer (disconnect) if it never does.
      download: (path, destination, {cancellation}) async {
        final lease = await leaseChannel();
        try {
          return await lease.fs.download(
            path,
            destination,
            computeHash: false,
            cancellation: cancellation,
          );
        } finally {
          await lease.release();
        }
      },
      // The legs drop the requested path while the fingerprint axis
      // carries canonicalDrop — the P3/P7 pairing: rows describe the
      // canonical identity, the measurement surface is what the
      // operator named.
      droppedPath: config.targetPath,
      warmups: config.warmups,
      repetitions: config.repetitions,
      operationTimeout: config.operationTimeout,
      deadline: config.deadline - setupWatch.elapsed,
    );

    final rows = <Map<String, Object?>>[
      for (var index = 0; index < outcome.measuredDrops.length; index++)
        _okRowJson(
          repetition: index,
          sample: outcome.measuredDrops[index],
          fingerprint: fingerprint,
          dropPath: canonicalDrop,
          warmups: config.warmups,
          repetitions: config.repetitions,
          outcome: outcome,
        ),
      if (!outcome.completed)
        _errorRowJson(
          repetition: outcome.failedRepetition!,
          error: outcome.failureMessage!,
          fingerprint: fingerprint,
          dropPath: canonicalDrop,
          warmups: config.warmups,
          repetitions: config.repetitions,
          outcome: outcome,
        ),
    ];

    final writeError = await _writeResultsOrReport(
      config,
      stderrBuffer,
      buildP5ResultsDocument(
        fingerprint: fingerprint,
        dropPath: canonicalDrop,
        warmups: config.warmups,
        requestedRepetitions: config.repetitions,
        outcome: outcome,
        rows: rows,
      ),
      tempCandidateName: tempCandidateName,
    );
    if (writeError != null) {
      return 74;
    }

    if (outcome.completed) {
      final median = medianOf([
        for (final sample in outcome.measuredDrops) sample.dropToFirstByteMs,
      ]);
      stdoutBuffer.writeln(
        'P5 drop→start: median ${_formatMs(median)} ms '
        '(dropped ${outcome.droppedKind} → ${outcome.firstFilePath}; '
        '${outcome.statCalls} stat + ${outcome.listingCalls} listing '
        'calls per drop; ${outcome.measuredDrops.length} measured drops, '
        '${config.warmups} warmup drops discarded; '
        'mode ${fingerprint.mode})',
      );
      stdoutBuffer.writeln('results: ${config.outputPath}');
      return 0;
    }

    stderrBuffer.writeln(
      'P5 collection failed: ${outcome.failureMessage} '
      '(${outcome.measuredDrops.length} of ${config.repetitions} measured '
      'drops completed; partial results written)',
    );
    return 1;
  }

  var exitCode = 1;
  try {
    exitCode = await collect();
  } catch (error, stackTrace) {
    // Keep buffered diagnostics (including the teardown warnings the
    // finally block below writes) reachable: p5Main cannot flush these
    // buffers on its unexpected-failure path.
    stderrBuffer
      ..writeln('unexpected P5 collection failure: $error')
      ..writeln('$stackTrace');
  } finally {
    // Bounded cleanup on every path; teardown problems are reported, not
    // swallowed, but never mask the measurement outcome.
    final channelToClose = channel;
    if (channelToClose != null) {
      try {
        await channelToClose.close().timeout(p5TeardownTimeout);
      } catch (error) {
        stderrBuffer.writeln(
          'warning: browse channel close failed: ${_describe(error)}',
        );
      }
    }
    try {
      await releaseServer().timeout(p5TeardownTimeout);
      released = true;
    } catch (error) {
      stderrBuffer.writeln(
        'warning: server release failed: ${_describe(error)}',
      );
    }
  }
  return P5RunResult(
    exitCode: exitCode,
    stdout: stdoutBuffer.toString(),
    stderr: stderrBuffer.toString(),
    released: released,
  );
}

// --- Results document ------------------------------------------------------

/// The scenarioConfig axis: everything a later calibration must pin for
/// these numbers to be comparable. The drop identity (canonical path,
/// kind, root listing size, first file) is part of the config — a tree
/// that changed shape is a different scenario, surfaced as drift rather
/// than a silent comparison.
String buildP5ScenarioConfig({
  required String dropPath,
  required int warmups,
  required int repetitions,
  required P5RunOutcome? outcome,
}) {
  final kind = outcome?.droppedKind ?? 'unknown';
  final rootEntries = outcome?.rootEntries;
  final entryWord = rootEntries == null
      ? (kind == 'file' ? 'n/a-file-drop' : 'unknown')
      : '$rootEntries';
  return 'p5/v1'
      ';drop=$dropPath'
      ';kind=$kind'
      ';root-entries=$entryWord'
      ';first-file=${outcome?.firstFilePath ?? 'unknown'}'
      ';warmups=$warmups'
      ';repetitions=$repetitions'
      ';start=lease+first-byte'
      ';hash=off';
}

Map<String, Object?> buildP5ResultsDocument({
  required P5FingerprintFields fingerprint,
  required String dropPath,
  required int warmups,
  required int requestedRepetitions,
  required P5RunOutcome? outcome,
  required List<Map<String, Object?>> rows,
}) => {
  'schema': p5ResultsSchemaId,
  'rows': rows,
  'provenance': {
    'scenario': p5ScenarioId,
    'generatedUtc': DateTime.now().toUtc().toIso8601String(),
    'dropProtocol':
        'one stat of the dropped root (classification, followLinks: '
        'false), a breadth-first listDirectory-only scan to the first '
        'regular file, then a transfer-channel lease and a download '
        'measured to the first delivered byte — the leg cancels there; '
        'authentication/setup excluded; drop→first-byte ms unclipped',
    'structuralAssertion':
        'statCalls counts the stat operations the drop→start path issued '
        'inside the measured window (the pinned VFS\'s own per-transfer '
        'stats are a constant per file, independent of tree size); the '
        'count must stay flat as the tree grows — asserted at 1k vs 50k '
        'entries by test/benchmark/p5_drop_to_start_test.dart',
    'warmupsDiscarded': warmups,
    'measuredRepetitionsRequested': requestedRepetitions,
    'measuredRepetitionsCompleted': rows
        .where((row) => row['status'] == 'ok')
        .length,
    'canonicalDrop': dropPath,
    'droppedKind': outcome?.droppedKind,
    'rootEntries': outcome?.rootEntries,
    'firstFilePath': outcome?.firstFilePath,
    'statCallsPerDrop': outcome?.statCalls,
    'listingCallsPerDrop': outcome?.listingCalls,
  },
};

Map<String, Object?> _okRowJson({
  required int repetition,
  required P5DropSample sample,
  required P5FingerprintFields fingerprint,
  required String dropPath,
  required int warmups,
  required int repetitions,
  required P5RunOutcome outcome,
}) => {
  'scenario': p5ScenarioId,
  'repetition': repetition,
  'status': 'ok',
  'value': sample.dropToFirstByteMs,
  'unit': 'ms',
  // Raw leg detail: the audit trail behind each start latency.
  'legSettledMs': sample.legSettledMs,
  'statCalls': sample.statCalls,
  'listingCalls': sample.listingCalls,
  'rootEntries': sample.rootEntries,
  'firstFile': sample.firstFilePath,
  'firstChunkBytes': sample.firstChunkBytes,
  'fingerprint': fingerprint.toJson(
    buildP5ScenarioConfig(
      dropPath: dropPath,
      warmups: warmups,
      repetitions: repetitions,
      outcome: outcome,
    ),
  ),
};

Map<String, Object?> _errorRowJson({
  required int repetition,
  required String error,
  required P5FingerprintFields fingerprint,
  required String dropPath,
  required int warmups,
  required int repetitions,
  required P5RunOutcome? outcome,
}) => {
  'scenario': p5ScenarioId,
  'repetition': repetition,
  'status': 'error',
  'error': error,
  'fingerprint': fingerprint.toJson(
    buildP5ScenarioConfig(
      dropPath: dropPath,
      warmups: warmups,
      repetitions: repetitions,
      outcome: outcome,
    ),
  ),
};

/// Upper bound on owned-temp acquisition attempts. Each default name
/// embeds the pid, a microsecond timestamp, and the attempt, so
/// collisions are practically impossible; the bound exists only to fail
/// closed instead of looping when a test seam (or an adversarial local
/// actor) keeps claiming names.
const p5TempNameAttempts = 5;

/// Platform "name already exists" codes for an exclusive create: POSIX
/// EEXIST plus Windows ERROR_FILE_EXISTS (80), which File.create's
/// exclusive CREATE_NEW surfaces (183 is kept defensively for other
/// Windows create paths). Any other code rethrows and surfaces rather than
/// silently retrying, which is the safe direction (EACCES, ENOENT, ENOSPC
/// are persistent conditions a different timestamped name cannot fix).
const p5NameExistsErrorCodes = {17, 80, 183};

/// Atomic write through an owned unique temp file; returns null on
/// success or the IO error for the caller to report (never a silent skip).
///
/// The temp name is CLAIMED with an exclusive create before any write:
/// writeAsString truncates a preexisting file and follows a planted
/// symlink — concrete data loss (the ownership class #105 repaired for
/// the checker's drift state). A claimed-but-taken name just moves to the
/// next candidate; a foreign resource at a candidate name is never
/// written, followed, or deleted. [tempCandidateName] is the test seam
/// for deterministic collisions. This is a faithful mirror of the P3
/// collector's writer (the p3TempNameAttempts pattern), kept private so
/// each collector's publication semantics stay independently auditable.
Future<Object?> _writeResultsOrReport(
  P5CollectorConfig config,
  StringBuffer stderrBuffer,
  Map<String, Object?> document, {
  String Function(int attempt)? tempCandidateName,
}) async {
  File? ownedTemp;
  try {
    for (var attempt = 1; attempt <= p5TempNameAttempts; attempt++) {
      final candidate =
          tempCandidateName?.call(attempt) ??
          '${config.outputPath}.p5-$pid-${DateTime.now().microsecondsSinceEpoch}'
              '-$attempt.tmp';
      final temporary = File(candidate);
      try {
        // O_CREAT|O_EXCL semantics: exists()-then-write has a check-to-
        // write gap, and exists() follows symlinks, so a name planted in
        // the gap would be followed.
        await temporary.create(exclusive: true);
      } on FileSystemException catch (error) {
        if (!p5NameExistsErrorCodes.contains(error.osError?.errorCode)) {
          rethrow;
        }
        continue; // The name is foreign-held; never touch it, try the next.
      }
      ownedTemp = temporary;
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(document),
      );
      await temporary.rename(config.outputPath);
      return null;
    }
    throw FileSystemException(
      'could not acquire an owned temporary file after '
      '$p5TempNameAttempts name collisions beside',
      config.outputPath,
    );
  } catch (error) {
    stderrBuffer.writeln(
      'error: cannot write results to ${config.outputPath}: $error',
    );
    // Cleanup deletes only the temp this run claimed; cleanup failures
    // stay quiet so the write error above remains the reported outcome.
    try {
      await ownedTemp?.delete();
    } catch (_) {
      // Intentionally ignored: the reported failure is the write error.
    }
    return error;
  }
}

String _formatMs(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(3);

// --- CLI --------------------------------------------------------------------

const _requiredEnvironment = [
  'POLTERGEIST_SSHD',
  'POLTERGEIST_SSHD_MODERN',
  'POLTERGEIST_SSHD_USER',
  'POLTERGEIST_SSHD_KEY',
];

/// CLI body: parses, validates the environment, builds the production
/// pool wiring, and drives [runP5Collection]. Returns the process exit
/// code instead of exiting so tests can call it in-process.
Future<int> p5Main(
  List<String> arguments, {
  required void Function(String) writeStdout,
  required void Function(String) writeStderr,
  required Map<String, String> environment,
}) async {
  final P5CollectorConfig config;
  try {
    config = P5CollectorConfig.parse(arguments);
  } on P5HelpRequested {
    writeStdout(_usageText);
    return 0;
  } on P5UsageException catch (error) {
    writeStderr('$error\n$_usageText');
    return 2;
  }

  final env = environment;
  final missing = [
    for (final name in _requiredEnvironment)
      if ((env[name] ?? '').isEmpty) name,
  ];
  if (missing.isNotEmpty) {
    writeStderr(
      'missing required environment variables (exported by '
      'test/integration/run.sh --lifecycle-only): ${missing.join(', ')}',
    );
    return 2;
  }

  final host = env['POLTERGEIST_SSHD']!;
  if (host != InternetAddress.loopbackIPv4.address) {
    writeStderr(
      'POLTERGEIST_SSHD must be the IPv4 loopback address '
      '${InternetAddress.loopbackIPv4.address} of the 08 §5 fixture (got '
      '"$host").',
    );
    return 2;
  }
  final port = int.tryParse(env['POLTERGEIST_SSHD_MODERN']!);
  if (port == null || port <= 0 || port > 65535) {
    writeStderr(
      'POLTERGEIST_SSHD_MODERN must be a TCP port (got '
      '"${env['POLTERGEIST_SSHD_MODERN']}").',
    );
    return 2;
  }
  final username = env['POLTERGEIST_SSHD_USER']!;
  final keyPath = env['POLTERGEIST_SSHD_KEY']!;

  final String privateKey;
  try {
    privateKey = await File(keyPath).readAsString();
  } catch (error) {
    writeStderr('cannot read the user private key at $keyPath: $error');
    return 2;
  }

  final hostKeyPubPath = config.hostKeyPubPath ?? p5DefaultHostKeyPubPath;
  final List<String> publicKeyFields;
  try {
    // The first non-comment line, not the first two tokens of the file —
    // a stray comment line must not become the pinned key type.
    final keyLine = (await File(hostKeyPubPath).readAsString())
        .split('\n')
        .firstWhere(
          (line) =>
              line.trimLeft().startsWith('#') == false &&
              line.trim().isNotEmpty,
          orElse: () => '',
        );
    publicKeyFields = keyLine.trim().split(RegExp(r'\s+'));
  } catch (error) {
    writeStderr(
      'cannot read the fixture host public key at $hostKeyPubPath '
      '(pass --host-key-pub or run from the repo root): $error',
    );
    return 2;
  }
  if (publicKeyFields.length < 2) {
    writeStderr(
      'the fixture host public key at $hostKeyPubPath is not an OpenSSH '
      'public key line.',
    );
    return 2;
  }

  final fingerprint = P5FingerprintFields(
    runnerImage: (env['POLTERGEIST_BENCH_RUNNER_IMAGE']?.isEmpty ?? true)
        ? 'local'
        : env['POLTERGEIST_BENCH_RUNNER_IMAGE']!,
    arch: _vmArch(),
    dartVersion: Platform.version,
    flutterVersion: null,
    mode: detectRunMode(),
    cpuModel: await _cpuModel(env),
  );

  final transcript = <String>[];
  const transcriptTail = 20;
  StreamSubscription<ConnectLogLine>? transcriptSubscription;

  try {
    // Production pool wiring over the committed fixture pin (08 §5): a
    // healthy fixture never prompts; any host-key review is a failure.
    // Construction lives inside the try so an early throw gets the
    // structured failure path rather than escaping p5Main raw.
    final pinStore = InMemoryHostKeyStore();
    await pinStore.put(
      HostKey.fromPublicKey(
        host: host,
        port: port,
        type: publicKeyFields[0],
        publicKeyBase64: publicKeyFields[1],
        pinnedAt: 0,
      ),
    );
    final server = ServerConfig(
      id: 'p5-collector',
      label: 'p5-collector',
      host: host,
      port: port,
      username: username,
      authMethod: AuthMethod.privateKey,
      createdAt: 0,
      updatedAt: 0,
    );
    final manager = PooledConnectionManager(
      resolveServer: (_) async => server,
      resolveCredentials: (_, _) async => ResolvedCredentials(
        credentials: SshCredentials.privateKey(privateKey),
        origin: CredentialOrigin.stored,
      ),
      tofu: TofuVerifier(pinStore),
      onHostKey: (decision) async {
        writeStderr(
          'fixture presented an unreviewed host key '
          '(verdict ${decision.verdict.name}) — the pre-seeded pin does not '
          'cover this server; refusing to benchmark against it',
        );
        return false;
      },
      policy: const PoolPolicy(),
    );
    transcriptSubscription = manager.connectLog.listen((line) {
      transcript.add(line.line);
      if (transcript.length > transcriptTail) {
        transcript.removeRange(0, transcript.length - transcriptTail);
      }
    });

    final result = await runP5Collection(
      config: config,
      fingerprint: fingerprint,
      openChannel: () =>
          manager.openBrowseChannel(server.id, paneTabId: 'p5-collector'),
      leaseChannel: () => manager.leaseTransferChannel(server.id),
      releaseServer: () => manager.disconnectServer(server.id),
    );
    if (result.stdout.isNotEmpty) {
      writeStdout(result.stdout);
    }
    if (result.stderr.isNotEmpty) {
      writeStderr(result.stderr);
    }
    if (result.exitCode != 0 && transcript.isNotEmpty) {
      writeStderr('connect transcript tail:\n  ${transcript.join('\n  ')}');
    }
    return result.exitCode;
  } catch (error, stackTrace) {
    // runP5Collection catches its own error paths; anything reaching here
    // is an unexpected failure that still deserves the stack trace and
    // transcript tail alongside a structured nonzero exit.
    writeStderr('P5 collection failed unexpectedly: $error');
    writeStderr('$stackTrace');
    if (transcript.isNotEmpty) {
      writeStderr('connect transcript tail:\n  ${transcript.join('\n  ')}');
    }
    return 1;
  } finally {
    await transcriptSubscription?.cancel();
  }
}

String _vmArch() {
  final match = RegExp(r'"([^"]+)"\s*$').firstMatch(Platform.version);
  return match?.group(1) ?? 'unknown';
}

Future<String> _cpuModel(Map<String, String> env) async {
  final override = env['POLTERGEIST_BENCH_CPU_MODEL'];
  if (override != null && override.isNotEmpty) return override;
  try {
    final cpuinfo = await File('/proc/cpuinfo').readAsString();
    final match = RegExp(
      r'^model name\s*:\s*(.+)$',
      multiLine: true,
    ).firstMatch(cpuinfo);
    if (match != null) return match.group(1)!.trim();
  } on FileSystemException {
    // Not Linux (or unreadable): fall through to the honest unknown.
  }
  return 'unknown';
}

void main(List<String> arguments) async {
  exitCode = await p5Main(
    arguments,
    writeStdout: stdout.writeln,
    writeStderr: stderr.writeln,
    environment: Platform.environment,
  );
}
