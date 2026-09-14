// D12 P7 collector — sync scan rate (sustained bulk listing throughput)
// on one retained browse channel (02 §12's P7 row, 08 §6 tier A; the
// scenario gates at M8 per 07 §3.4 — this lands the collector surface
// only, P7 stays unlanded in budgets.json).
//
// Protocol (fixed by the plan, never improvised here):
//  * one browse channel from the production pool stays open for the whole
//    run; every repetition recursively scans the target tree through that
//    same channel with up to 8 outstanding listDirectory calls — the
//    pipelined-readdir scan of 05 §3 at D9's frozen depth;
//  * symlinks are counted as entries but never descended (05 §3: never
//    followed — the loop and escape-the-tree hazards);
//  * authentication, channel setup, and canonicalization happen before
//    any timed scan;
//  * a stated number of warmup scans runs first and is discarded;
//  * at least `--repetitions` (>= 5) measured scans emit one results row
//    each: the entry count, the directories scanned, the elapsed wall
//    clock, and the unclipped entries/second rate;
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
// here. The collector never writes anything on the server side: the
// caller supplies one existing directory tree and only `listDirectory`
// and `canonicalize` are issued against it.
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

const p7ScenarioId = 'P7';
const p7ResultsSchemaId = p3ResultsSchemaId;

/// The scan's pipelining bound: 05 §3's eight outstanding `listDirectory`
/// calls over one channel (D9's frozen remote readdir depth). It is a
/// scenarioConfig axis, never a flag: depth changes the measured surface,
/// so a different depth is a different scenario, recorded and calibrated.
const p7ReaddirDepth = 8;

/// 02 §12 / budgets.json: P7's repetition floor. The CLI refuses smaller
/// runs because the checker would fail them as incomplete measurements.
const p7MinimumMeasuredRepetitions = 5;
const p7DefaultWarmups = 2;
const p7DefaultMeasuredRepetitions = 5;

/// Bounds for the untimed phases; the measured scans additionally respect
/// [P7CollectorConfig.deadline] as a whole-run budget (no unbounded retry,
/// no unbounded wait). The budget caps each listing await; it stops the
/// wait, not the underlying VFS IO (no cancellation exists in the pinned
/// interface — open item 12), and cleanup retires the channel boundedly.
const p7OpenChannelTimeout = Duration(seconds: 60);
const p7TeardownTimeout = Duration(seconds: 30);
const p7DefaultListingTimeout = Duration(seconds: 30);
const p7DefaultDeadline = Duration(minutes: 10);

/// The committed fixture host key (08 §5 pin-store isolation: every
/// non-TOFU suite pre-seeds this key so a healthy fixture never prompts).
const p7DefaultHostKeyPubPath =
    'test/integration/keys/ssh_host_ed25519_key.pub';

/// The scenario-agnostic shapes below are the P3 collector's public
/// helpers under P7-scoped names — the fingerprint axes, the usage
/// failure, and the help marker are one contract shared by every tier-A
/// collector, so they are aliased here rather than copied.
typedef P7FingerprintFields = P3FingerprintFields;
typedef P7UsageException = P3UsageException;
typedef P7HelpRequested = P3HelpRequested;

const _usageText =
    '''
Usage: dart run benchmark/p7_scan_rate.dart \\
    --output FILE --target PATH [options]

Collects D12 P7 samples (sync scan rate — sustained bulk listing
throughput in entries/second, 02 §12 / 08 §6): each measured repetition
recursively scans the target tree over one retained browse channel with
up to $p7ReaddirDepth outstanding listDirectory calls, after discarded
warmup scans. Results match the poltergeist-d12-results-1 schema consumed
by test/benchmarks/check.dart.

Options:
  --output <path>      results file to write (required, atomic write)
  --target <path>      existing remote directory tree to scan (required)
  --warmups <n>        discarded warmup scans, >= 1 (default 2)
  --repetitions <n>    measured scans, >= 5 (default 5)
  --host-key-pub <p>   fixture host public key (default
                       $p7DefaultHostKeyPubPath, resolved from the repo
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

/// One measured scan: the recursive walk counted [entries] entries across
/// [directories] directory listings in [elapsed] wall time.
/// [entriesPerSecond] is the P7 value — unclipped, exactly as measured.
final class P7ScanSample {
  final int entries;
  final int directories;
  final Duration elapsed;

  const P7ScanSample({
    required this.entries,
    required this.directories,
    required this.elapsed,
  });

  double get entriesPerSecond {
    final micros = elapsed.inMicroseconds;
    if (micros <= 0) {
      throw StateError(
        'P7ScanSample.elapsed must be positive to compute a rate',
      );
    }
    return entries * Duration.microsecondsPerSecond / micros;
  }
}

/// What a collection run observed. [failedRepetition] is null on success;
/// on failure it is the measured repetition index that failed (0 when the
/// failure preceded the first measured scan, e.g. during warmup or setup).
/// Entry counts are null when they were never observed.
final class P7RunOutcome {
  final List<P7ScanSample> measuredScans;
  final int? failedRepetition;
  final String? failureMessage;
  final int? totalEntries;
  final int? directoriesScanned;

  const P7RunOutcome({
    required this.measuredScans,
    required this.failedRepetition,
    required this.failureMessage,
    required this.totalEntries,
    required this.directoriesScanned,
  });

  bool get completed => failedRepetition == null;
}

/// Parsed CLI arguments.
final class P7CollectorConfig {
  final String targetPath;
  final String outputPath;
  final int warmups;
  final int repetitions;
  final Duration listingTimeout;
  final Duration deadline;
  final Duration channelOpenTimeout;
  final String? hostKeyPubPath;

  const P7CollectorConfig({
    required this.targetPath,
    required this.outputPath,
    this.warmups = p7DefaultWarmups,
    this.repetitions = p7DefaultMeasuredRepetitions,
    this.listingTimeout = p7DefaultListingTimeout,
    this.deadline = p7DefaultDeadline,
    this.channelOpenTimeout = p7OpenChannelTimeout,
    this.hostKeyPubPath,
  });

  /// Parses and validates, rejecting anything unrecognized: a measurement
  /// tool must not silently drop a mistyped flag — an operator asking for
  /// 20 repetitions must never get 5 without an error (the >= 5 floor
  /// would hide the typo).
  static P7CollectorConfig parse(List<String> arguments) {
    String? flagValue(String flag) {
      final index = arguments.indexOf(flag);
      if (index == -1) return null;
      if (arguments.lastIndexOf(flag) != index) {
        throw P7UsageException('$flag was passed more than once.');
      }
      if (index + 1 >= arguments.length) {
        throw P7UsageException('$flag requires a value.');
      }
      final value = arguments[index + 1];
      if (value.startsWith('-')) {
        throw P7UsageException(
          '$flag requires a value; "$value" looks like an option; '
          'see --help.',
        );
      }
      return value;
    }

    if (arguments.any((argument) => argument == '-h' || argument == '--help')) {
      throw const P7HelpRequested();
    }

    const knownFlags = {
      '--output',
      '--target',
      '--warmups',
      '--repetitions',
      '--host-key-pub',
    };
    for (final argument in arguments) {
      if (argument.startsWith('-') && !knownFlags.contains(argument)) {
        throw P7UsageException(
          'unknown option "$argument" (or a value starting with "-"); '
          'see --help.',
        );
      }
    }

    final outputPath = flagValue('--output');
    if (outputPath == null || outputPath.isEmpty) {
      throw const P7UsageException('--output is required.');
    }
    final targetPath = flagValue('--target');
    if (targetPath == null || targetPath.isEmpty) {
      throw const P7UsageException('--target is required.');
    }

    int positiveInt(String flag, int fallback, int minimum) {
      final raw = flagValue(flag);
      if (raw == null) return fallback;
      final parsed = int.tryParse(raw);
      if (parsed == null || parsed < minimum) {
        throw P7UsageException(
          '$flag must be an integer >= $minimum (got "$raw").',
        );
      }
      return parsed;
    }

    return P7CollectorConfig(
      targetPath: targetPath,
      outputPath: outputPath,
      warmups: positiveInt('--warmups', p7DefaultWarmups, 1),
      repetitions: positiveInt(
        '--repetitions',
        p7DefaultMeasuredRepetitions,
        p7MinimumMeasuredRepetitions,
      ),
      hostKeyPubPath: flagValue('--host-key-pub'),
    );
  }
}

/// Terminal outcome of one collection run for [p7Main] to print and exit
/// with; [released] reports whether the injected server-release step ran.
final class P7RunResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool released;

  const P7RunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.released,
  });
}

// --- Sampler ---------------------------------------------------------------

/// Whole-run-budget expiry inside a listing await — distinct from a
/// per-listing [TimeoutException] so failures attribute honestly.
class _RunBudgetExceeded implements Exception {
  final String message;

  const _RunBudgetExceeded(this.message);

  @override
  String toString() => message;
}

/// One resolved directory listing inside the scan pump: never throws, so
/// a scan aborted mid-pipeline leaves no unhandled async errors behind
/// (the abandoned siblings' listings may still finish engine-side — the
/// deadline stops the wait, never the underlying VFS IO).
sealed class _ListingOutcome {
  const _ListingOutcome();
}

final class _ListingDone extends _ListingOutcome {
  final List<RemoteFileEntry> children;

  const _ListingDone(this.children);
}

final class _ListingError extends _ListingOutcome {
  final Object error;

  const _ListingError(this.error);
}

/// Runs the fixed warmup/measured protocol over the listing closure and
/// returns the raw scan samples plus an honest failure report. No retry:
/// the first failing listing ends the run at its repetition index. Every
/// directory listing is issued under a cap of the per-listing timeout and
/// the remaining whole-run budget, and the pipeline's drain await is
/// capped at the remaining budget too — an issued listing is never waited
/// out past the deadline, and whole-run expiry is attributed as a
/// run-budget overrun, never as a per-listing timeout.
Future<P7RunOutcome> collectScanRateSamples({
  required Future<List<RemoteFileEntry>> Function(String path)
  listDirectory,
  required String rootPath,
  required int warmups,
  required int repetitions,
  required Duration listingTimeout,
  required Duration deadline,
  int maxInFlightListings = p7ReaddirDepth,
}) async {
  if (maxInFlightListings < 1) {
    throw ArgumentError.value(
      maxInFlightListings,
      'maxInFlightListings',
      'must allow at least one listing in flight',
    );
  }
  final runClock = Stopwatch()..start();
  final samples = <P7ScanSample>[];
  int? observedEntries;
  int? observedDirectories;

  // The tree size frozen after warmups — the identity every measured
  // row's fingerprint claims. The CLI rejects --warmups 0, but direct
  // callers may pass it; with zero warmups the freeze observes nothing,
  // so arming defers to the first measured scan instead of never firing.
  int? expectedEntries;
  int? expectedDirectories;
  var identityArmed = false;

  P7RunOutcome fail(int repetition, String message) => P7RunOutcome(
    measuredScans: samples,
    failedRepetition: repetition,
    failureMessage: message,
    // Once the run's identity is frozen, every row — including the
    // error row of a partial failure — carries the frozen counts: the
    // rows describe the scans that were measured, and a later changed
    // observation belongs only in the error text, never in the config
    // the completed rows claim.
    totalEntries: identityArmed ? expectedEntries : observedEntries,
    directoriesScanned: identityArmed
        ? expectedDirectories
        : observedDirectories,
  );

  // The whole-run budget must bound every await, not just the gaps
  // between scans: Future.timeout stops the WAIT, never the underlying
  // VFS IO (the pinned interface offers no cancellation — open item 12),
  // so expiry means the collector reports, stops waiting, and tears the
  // channel down inside the bounded cleanup while the wedged listing's
  // IO may still finish engine-side.
  Duration remainingBudget() => deadline - runClock.elapsed;

  Future<List<RemoteFileEntry>> boundedListing(String path, String label) {
    final remaining = remainingBudget();
    if (remaining <= Duration.zero) {
      throw _RunBudgetExceeded(
        'run deadline exceeded before listing $path of $label',
      );
    }
    final cap = listingTimeout < remaining ? listingTimeout : remaining;
    final runBudgetBinds = remaining <= listingTimeout;
    return listDirectory(path).timeout(
      cap,
      onTimeout: () {
        if (runBudgetBinds) {
          throw _RunBudgetExceeded(
            'run deadline exceeded while listing $path of $label '
            '(${runClock.elapsed.inMilliseconds} ms elapsed of a '
            '${deadline.inMilliseconds} ms whole-run budget)',
          );
        }
        throw TimeoutException('listing $path', listingTimeout);
      },
    );
  }

  /// One recursive scan of [rootPath]: a breadth-first walk keeping at
  /// most [maxInFlightListings] listings outstanding, counting every
  /// entry and descending only into real directories — symlink entries
  /// are counted, never followed (05 §3).
  Future<({int entries, int directories})> scanOnce(String label) async {
    final pending = Queue<String>()..add(rootPath);
    final inFlight = <({String path, Future<_ListingOutcome> outcome})>[];
    var entries = 0;
    var directories = 0;

    Future<_ListingOutcome> listOne(String path) async {
      try {
        return _ListingDone(await boundedListing(path, label));
      } catch (error) {
        return _ListingError(error);
      }
    }

    while (pending.isNotEmpty || inFlight.isNotEmpty) {
      while (pending.isNotEmpty && inFlight.length < maxInFlightListings) {
        final path = pending.removeFirst();
        inFlight.add((path: path, outcome: listOne(path)));
      }
      final oldest = inFlight.removeAt(0);
      // The drain await is budget-capped as well: a listing issued while
      // budget remained must not be waited out past the deadline once it
      // is the oldest outstanding call.
      final remaining = remainingBudget();
      if (remaining <= Duration.zero) {
        throw _RunBudgetExceeded(
          'run deadline exceeded before the listing of ${oldest.path} '
          'in $label could be awaited',
        );
      }
      final outcome = await oldest.outcome.timeout(
        remaining,
        onTimeout: () => _ListingError(
          _RunBudgetExceeded(
            'run deadline exceeded while awaiting the listing of '
            '${oldest.path} in $label (${runClock.elapsed.inMilliseconds} '
            'ms elapsed of a ${deadline.inMilliseconds} ms whole-run '
            'budget)',
          ),
        ),
      );
      switch (outcome) {
        case _ListingDone(:final children):
          directories++;
          entries += children.length;
          for (final child in children) {
            if (child.isDirectory) {
              pending.add(child.path);
            }
          }
        case _ListingError(:final error):
          throw error;
      }
    }
    return (entries: entries, directories: directories);
  }

  Future<P7ScanSample> runScan(String label) async {
    final scanWatch = Stopwatch()..start();
    final scan = await scanOnce(label);
    final elapsed = scanWatch.elapsed;

    observedEntries = scan.entries;
    observedDirectories = scan.directories;

    // The results schema requires every row to carry one fingerprint,
    // and entry counts are a fingerprint axis: a tree that changes size
    // mid-run cannot be represented honestly, so the run fails at the
    // changing scan instead of smearing one count across every row.
    if (identityArmed) {
      expectedEntries ??= observedEntries;
      expectedDirectories ??= observedDirectories;
    }
    if (expectedEntries != null &&
        (expectedEntries != observedEntries ||
            expectedDirectories != observedDirectories)) {
      throw StateError(
        'entry count changed mid-run: entries '
        '${expectedEntries ?? '?'}->${observedEntries ?? '?'} / '
        'directories '
        '${expectedDirectories ?? '?'}->${observedDirectories ?? '?'}',
      );
    }

    if (elapsed <= Duration.zero) {
      throw StateError(
        'scan of $label completed in zero elapsed time — no honest '
        'entries/s rate can be reported',
      );
    }
    return P7ScanSample(
      entries: scan.entries,
      directories: scan.directories,
      elapsed: elapsed,
    );
  }

  for (var warmup = 0; warmup < warmups; warmup++) {
    if (runClock.elapsed >= deadline) {
      return fail(0, 'run deadline exceeded before warmup scan $warmup');
    }
    try {
      await runScan('warmup scan $warmup');
    } on _RunBudgetExceeded catch (error) {
      return fail(0, error.message);
    } on TimeoutException catch (error) {
      return fail(
        0,
        'warmup scan $warmup ${error.message} timed out after '
        '${listingTimeout.inMilliseconds} ms',
      );
    } catch (error) {
      return fail(0, 'warmup scan $warmup failed: ${_describe(error)}');
    }
  }

  // Freeze the observed tree size as the run's scenario identity; the
  // guard above arms even when no warmup scan ran.
  expectedEntries = observedEntries;
  expectedDirectories = observedDirectories;
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
      samples.add(await runScan('repetition $repetition'));
    } on _RunBudgetExceeded catch (error) {
      return fail(repetition, error.message);
    } on TimeoutException catch (error) {
      return fail(
        repetition,
        'repetition $repetition ${error.message} timed out after '
        '${listingTimeout.inMilliseconds} ms',
      );
    } catch (error) {
      return fail(
        repetition,
        'repetition $repetition failed: ${_describe(error)}',
      );
    }
  }

  return P7RunOutcome(
    measuredScans: samples,
    failedRepetition: null,
    failureMessage: null,
    totalEntries: observedEntries,
    directoriesScanned: observedDirectories,
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

// --- Mid-level collection over a browse channel ----------------------------

/// Collects P7 through [openChannel] (called once: every scan of the run
/// shares that one retained channel) and releases it via [releaseServer]
/// on every exit path. Measurement failures still write the results file
/// with the completed rows plus one honest error row; usage failures
/// write nothing.
Future<P7RunResult> runP7Collection({
  required P7CollectorConfig config,
  required P7FingerprintFields fingerprint,
  required Future<PaneChannel> Function() openChannel,
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

  // The collect() body returns only an exit code; the P7RunResult is
  // built once, AFTER the finally-bound cleanup, so `released` reflects
  // reality instead of a value captured before cleanup ran.
  Future<int> collect() async {
    // Failure before any scan: one error row, entry counts unknown — the
    // requested (not canonical) path is the honest scenario provenance.
    Future<int> failBeforeScan(String context, Object error) async {
      final message = '$context failed: ${_describe(error)}';
      await _writeResultsOrReport(
        config,
        stderrBuffer,
        buildP7ResultsDocument(
          fingerprint: fingerprint,
          rootPath: config.targetPath,
          warmups: config.warmups,
          requestedRepetitions: config.repetitions,
          totalEntries: null,
          directoriesScanned: null,
          rows: [
            _errorRowJson(
              repetition: 0,
              error: message,
              fingerprint: fingerprint,
              rootPath: config.targetPath,
              warmups: config.warmups,
              repetitions: config.repetitions,
              totalEntries: null,
              directoriesScanned: null,
            ),
          ],
        ),
        tempCandidateName: tempCandidateName,
      );
      stderrBuffer.writeln('P7 collection failed: $message');
      return 1;
    }

    // The stated whole-run budget covers setup too. Channel open and
    // canonicalize are bounded by their own timeouts and charged
    // against config.deadline, so slow setup consumes the scan budget
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
      return failBeforeScan('browse channel open', error);
    }
    channel = openedChannel;

    final String canonicalTarget;
    try {
      canonicalTarget = await openedChannel.fs
          .canonicalize(config.targetPath)
          .timeout(config.listingTimeout);
    } catch (error) {
      return failBeforeScan('canonicalizing the target path', error);
    }

    final outcome = await collectScanRateSamples(
      listDirectory: openedChannel.fs.listDirectory,
      // The scan walks the requested path while the fingerprint axis
      // carries canonicalTarget — the P3 pairing: rows describe the
      // canonical identity, the measurement surface is what the
      // operator named.
      rootPath: config.targetPath,
      warmups: config.warmups,
      repetitions: config.repetitions,
      listingTimeout: config.listingTimeout,
      deadline: config.deadline - setupWatch.elapsed,
    );

    final rows = <Map<String, Object?>>[
      for (var index = 0; index < outcome.measuredScans.length; index++)
        _okRowJson(
          repetition: index,
          sample: outcome.measuredScans[index],
          fingerprint: fingerprint,
          rootPath: canonicalTarget,
          warmups: config.warmups,
          repetitions: config.repetitions,
          totalEntries: outcome.totalEntries,
          directoriesScanned: outcome.directoriesScanned,
        ),
      if (!outcome.completed)
        _errorRowJson(
          repetition: outcome.failedRepetition!,
          error: outcome.failureMessage!,
          fingerprint: fingerprint,
          rootPath: canonicalTarget,
          warmups: config.warmups,
          repetitions: config.repetitions,
          totalEntries: outcome.totalEntries,
          directoriesScanned: outcome.directoriesScanned,
        ),
    ];

    final writeError = await _writeResultsOrReport(
      config,
      stderrBuffer,
      buildP7ResultsDocument(
        fingerprint: fingerprint,
        rootPath: canonicalTarget,
        warmups: config.warmups,
        requestedRepetitions: config.repetitions,
        totalEntries: outcome.totalEntries,
        directoriesScanned: outcome.directoriesScanned,
        rows: rows,
      ),
      tempCandidateName: tempCandidateName,
    );
    if (writeError != null) {
      return 74;
    }

    if (outcome.completed) {
      final median = medianOf([
        for (final sample in outcome.measuredScans) sample.entriesPerSecond,
      ]);
      stdoutBuffer.writeln(
        'P7 scan rate: median ${_formatRate(median)} entries/s '
        '(target ${outcome.totalEntries} entries across '
        '${outcome.directoriesScanned} directories; '
        '${outcome.measuredScans.length} measured scans, '
        '${config.warmups} warmup scans discarded; '
        'mode ${fingerprint.mode})',
      );
      stdoutBuffer.writeln('results: ${config.outputPath}');
      return 0;
    }

    stderrBuffer.writeln(
      'P7 collection failed: ${outcome.failureMessage} '
      '(${outcome.measuredScans.length} of ${config.repetitions} measured '
      'scans completed; partial results written)',
    );
    return 1;
  }

  var exitCode = 1;
  try {
    exitCode = await collect();
  } catch (error, stackTrace) {
    // Keep buffered diagnostics (including the teardown warnings the
    // finally block below writes) reachable: p7Main cannot flush these
    // buffers on its unexpected-failure path.
    stderrBuffer
      ..writeln('unexpected P7 collection failure: $error')
      ..writeln('$stackTrace');
  } finally {
    // Bounded cleanup on every path; teardown problems are reported, not
    // swallowed, but never mask the measurement outcome.
    final channelToClose = channel;
    if (channelToClose != null) {
      try {
        await channelToClose.close().timeout(p7TeardownTimeout);
      } catch (error) {
        stderrBuffer.writeln(
          'warning: browse channel close failed: ${_describe(error)}',
        );
      }
    }
    try {
      await releaseServer().timeout(p7TeardownTimeout);
      released = true;
    } catch (error) {
      stderrBuffer.writeln(
        'warning: server release failed: ${_describe(error)}',
      );
    }
  }
  return P7RunResult(
    exitCode: exitCode,
    stdout: stdoutBuffer.toString(),
    stderr: stderrBuffer.toString(),
    released: released,
  );
}

// --- Results document ------------------------------------------------------

/// The scenarioConfig axis: everything a later calibration must pin for
/// these numbers to be comparable. Entry and directory counts are part of
/// the config — a tree that changed size or shape is a different
/// scenario, surfaced as drift rather than a silent comparison.
String buildP7ScenarioConfig({
  required String rootPath,
  required int? totalEntries,
  required int? directoriesScanned,
  required int warmups,
  required int repetitions,
}) {
  String countWord(int? count) => count?.toString() ?? 'unknown';
  return 'p7/v1'
      ';root=$rootPath'
      ';entries=${countWord(totalEntries)}'
      ';directories=${countWord(directoriesScanned)}'
      ';warmups=$warmups'
      ';repetitions=$repetitions'
      ';readdir-depth=$p7ReaddirDepth'
      ';traversal=recursive-pipelined-one-channel';
}

Map<String, Object?> buildP7ResultsDocument({
  required P7FingerprintFields fingerprint,
  required String rootPath,
  required int warmups,
  required int requestedRepetitions,
  required int? totalEntries,
  required int? directoriesScanned,
  required List<Map<String, Object?>> rows,
}) => {
  'schema': p7ResultsSchemaId,
  'rows': rows,
  'provenance': {
    'scenario': p7ScenarioId,
    'generatedUtc': DateTime.now().toUtc().toIso8601String(),
    'scanProtocol':
        'recursive listDirectory walk over one retained browse channel '
        'with at most $p7ReaddirDepth outstanding calls; symlinks '
        'counted, never descended; authentication/setup excluded; '
        'entries/s rate unclipped',
    'warmupsDiscarded': warmups,
    'measuredRepetitionsRequested': requestedRepetitions,
    'measuredRepetitionsCompleted': rows
        .where((row) => row['status'] == 'ok')
        .length,
    'canonicalRoot': rootPath,
    'totalEntries': totalEntries,
    'directoriesScanned': directoriesScanned,
  },
};

Map<String, Object?> _okRowJson({
  required int repetition,
  required P7ScanSample sample,
  required P7FingerprintFields fingerprint,
  required String rootPath,
  required int warmups,
  required int repetitions,
  required int? totalEntries,
  required int? directoriesScanned,
}) => {
  'scenario': p7ScenarioId,
  'repetition': repetition,
  'status': 'ok',
  'value': sample.entriesPerSecond,
  'unit': 'entries/s',
  // Raw scan detail: the audit trail behind each rate.
  'entries': sample.entries,
  'directories': sample.directories,
  'elapsedMs': sample.elapsed.inMicroseconds / 1000.0,
  'fingerprint': fingerprint.toJson(
    buildP7ScenarioConfig(
      rootPath: rootPath,
      totalEntries: totalEntries,
      directoriesScanned: directoriesScanned,
      warmups: warmups,
      repetitions: repetitions,
    ),
  ),
};

Map<String, Object?> _errorRowJson({
  required int repetition,
  required String error,
  required P7FingerprintFields fingerprint,
  required String rootPath,
  required int warmups,
  required int repetitions,
  required int? totalEntries,
  required int? directoriesScanned,
}) => {
  'scenario': p7ScenarioId,
  'repetition': repetition,
  'status': 'error',
  'error': error,
  'fingerprint': fingerprint.toJson(
    buildP7ScenarioConfig(
      rootPath: rootPath,
      totalEntries: totalEntries,
      directoriesScanned: directoriesScanned,
      warmups: warmups,
      repetitions: repetitions,
    ),
  ),
};

/// Upper bound on owned-temp acquisition attempts. Each default name
/// embeds the pid, a microsecond timestamp, and the attempt, so
/// collisions are practically impossible; the bound exists only to fail
/// closed instead of looping when a test seam (or an adversarial local
/// actor) keeps claiming names.
const p7TempNameAttempts = 5;

/// Platform "name already exists" codes for an exclusive create: POSIX
/// EEXIST plus Windows ERROR_FILE_EXISTS (80), which File.create's
/// exclusive CREATE_NEW surfaces (183 is kept defensively for other
/// Windows create paths). Any other code rethrows and surfaces rather than
/// silently retrying, which is the safe direction (EACCES, ENOENT, ENOSPC
/// are persistent conditions a different timestamped name cannot fix).
const p7NameExistsErrorCodes = {17, 80, 183};

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
  P7CollectorConfig config,
  StringBuffer stderrBuffer,
  Map<String, Object?> document, {
  String Function(int attempt)? tempCandidateName,
}) async {
  File? ownedTemp;
  try {
    for (var attempt = 1; attempt <= p7TempNameAttempts; attempt++) {
      final candidate =
          tempCandidateName?.call(attempt) ??
          '${config.outputPath}.p7-$pid-${DateTime.now().microsecondsSinceEpoch}'
              '-$attempt.tmp';
      final temporary = File(candidate);
      try {
        // O_CREAT|O_EXCL semantics: exists()-then-write has a check-to-
        // write gap, and exists() follows symlinks, so a name planted in
        // the gap would be followed.
        await temporary.create(exclusive: true);
      } on FileSystemException catch (error) {
        if (!p7NameExistsErrorCodes.contains(error.osError?.errorCode)) {
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
      '$p7TempNameAttempts name collisions beside',
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

String _formatRate(double value) => value == value.roundToDouble()
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
/// pool wiring, and drives [runP7Collection]. Returns the process exit
/// code instead of exiting so tests can call it in-process.
Future<int> p7Main(
  List<String> arguments, {
  required void Function(String) writeStdout,
  required void Function(String) writeStderr,
  required Map<String, String> environment,
}) async {
  final P7CollectorConfig config;
  try {
    config = P7CollectorConfig.parse(arguments);
  } on P7HelpRequested {
    writeStdout(_usageText);
    return 0;
  } on P7UsageException catch (error) {
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

  final hostKeyPubPath = config.hostKeyPubPath ?? p7DefaultHostKeyPubPath;
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

  final fingerprint = P7FingerprintFields(
    runnerImage: (env['POLTERGEIST_BENCH_RUNNER_IMAGE']?.isEmpty ?? true)
        ? 'local'
        : env['POLTERGEIST_BENCH_RUNNER_IMAGE']!,
    arch: _vmArch(),
    dartVersion: Platform.version,
    flutterVersion: null,
    mode: detectRunMode(),
    cpuModel: await _cpuModel(env),
  );

  // Production pool wiring over the committed fixture pin (08 §5): a
  // healthy fixture never prompts; any host-key review is a failure.
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
    id: 'p7-collector',
    label: 'p7-collector',
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

  final transcript = <String>[];
  const transcriptTail = 20;
  final transcriptSubscription = manager.connectLog.listen((line) {
    transcript.add(line.line);
    if (transcript.length > transcriptTail) {
      transcript.removeRange(0, transcript.length - transcriptTail);
    }
  });

  try {
    final result = await runP7Collection(
      config: config,
      fingerprint: fingerprint,
      openChannel: () =>
          manager.openBrowseChannel(server.id, paneTabId: 'p7-collector'),
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
    // runP7Collection catches its own error paths; anything reaching here
    // is an unexpected failure that still deserves the stack trace and
    // transcript tail alongside a structured nonzero exit.
    writeStderr('P7 collection failed unexpectedly: $error');
    writeStderr('$stackTrace');
    if (transcript.isNotEmpty) {
      writeStderr('connect transcript tail:\n  ${transcript.join('\n  ')}');
    }
    return 1;
  } finally {
    await transcriptSubscription.cancel();
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
  exitCode = await p7Main(
    arguments,
    writeStdout: stdout.writeln,
    writeStderr: stderr.writeln,
    environment: Platform.environment,
  );
}
