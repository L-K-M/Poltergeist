// D12 P3 collector — remote listing overhead on one retained connection
// (07 §3.4 exit criteria, 08 §6 tier A).
//
// Protocol (fixed by the plan, never improvised here):
//  * one browse channel from the production pool stays open for the whole
//    run; every pair lists the control directory and then the target tree
//    through that same channel, so the difference
//    `target listing - control listing` cancels network + crypto latency
//    and isolates per-entry listing overhead (08 §6: a same-connection
//    difference, never a single-run absolute wall clock);
//  * authentication, channel setup, and canonicalization happen before
//    any timed pair;
//  * a stated number of warmup pairs runs first and is discarded;
//  * at least `--repetitions` (>= 5) measured pairs emit one results row
//    each: the raw pair timings plus the unclipped difference (a negative
//    difference is a valid measurement, never clamped to zero);
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
// here. The collector never writes anything on the server side: caller
// supplies two existing, distinct directories and only `listDirectory`
// and `canonicalize` are issued against them.
//
// Exit codes: 0 collected; 2 usage/invocation failure (actionable message,
// no results file); 1 measurement failure (partial rows plus an honest
// error row were written); 74 results-file IO failure.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';

// --- Scenario identity (mirrors test/benchmarks/budgets.json) ------------

const p3ScenarioId = 'P3';
const p3ResultsSchemaId = 'poltergeist-d12-results-1';

/// 02 §12 / budgets.json: P3's repetition floor. The CLI refuses smaller
/// runs because the checker would fail them as incomplete measurements.
const p3MinimumMeasuredRepetitions = 5;
const p3DefaultWarmups = 2;
const p3DefaultMeasuredRepetitions = 5;

/// Bounds for the untimed phases; the measured pairs additionally respect
/// [P3CollectorConfig.deadline] as a whole-run budget (no unbounded retry,
/// no unbounded wait).
const p3OpenChannelTimeout = Duration(seconds: 60);
const p3TeardownTimeout = Duration(seconds: 30);
const p3DefaultListingTimeout = Duration(seconds: 30);
const p3DefaultDeadline = Duration(minutes: 10);

/// The committed fixture host key (08 §5 pin-store isolation: every
/// non-TOFU suite pre-seeds this key so a healthy fixture never prompts).
const p3DefaultHostKeyPubPath =
    'test/integration/keys/ssh_host_ed25519_key.pub';

const _usageText =
    '''
Usage: dart run benchmark/p3_listing_overhead.dart \\
    --output FILE --target PATH --control PATH [options]

Collects D12 P3 samples (remote listing overhead, 07 §3.4 / 08 §6) as
paired same-connection listings: target tree minus a minimal control
directory, both over one retained browse channel, warmups discarded.
Results match the poltergeist-d12-results-1 schema consumed by
test/benchmarks/check.dart.

Options:
  --output <path>      results file to write (required, atomic write)
  --target <path>      existing remote directory to measure (required)
  --control <path>     existing minimal remote directory (required; must
                       canonicalize to a path distinct from --target)
  --warmups <n>        discarded warmup pairs, >= 1 (default 2)
  --repetitions <n>    measured pairs, >= 5 (default 5)
  --host-key-pub <p>   fixture host public key (default
                       $p3DefaultHostKeyPubPath, resolved from the repo
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

/// An invalid invocation: actionable message, no results file, exit 2.
class P3UsageException implements Exception {
  final String message;

  const P3UsageException(this.message);

  @override
  String toString() => message;
}

/// Raw timings of one measured pair. [differenceMs] is the P3 value:
/// target minus control, unclipped — noise can legitimately make it
/// negative and clamping would hide exactly that.
final class P3PairTimings {
  final Duration control;
  final Duration target;

  const P3PairTimings({required this.control, required this.target});

  double get differenceMs => (target - control).inMicroseconds / 1000.0;
  double get controlMs => control.inMicroseconds / 1000.0;
  double get targetMs => target.inMicroseconds / 1000.0;
}

/// What a collection run observed. [failedRepetition] is null on success;
/// on failure it is the measured repetition index that failed (0 when the
/// failure preceded the first measured pair, e.g. during warmup or setup).
/// Entry counts are null when they were never observed.
final class P3RunOutcome {
  final List<P3PairTimings> measuredPairs;
  final int? failedRepetition;
  final String? failureMessage;
  final int? controlEntries;
  final int? targetEntries;

  const P3RunOutcome({
    required this.measuredPairs,
    required this.failedRepetition,
    required this.failureMessage,
    required this.controlEntries,
    required this.targetEntries,
  });

  bool get completed => failedRepetition == null;
}

/// The environment fingerprint axes the results schema carries per row.
/// [mode] must come from [detectRunMode] (or a test fixture) — never a
/// wish: a JIT process reporting `aot` is the failure mode 08 §6 exists
/// to prevent.
final class P3FingerprintFields {
  final String runnerImage;
  final String arch;
  final String dartVersion;
  final String? flutterVersion;
  final String mode;
  final String cpuModel;

  const P3FingerprintFields({
    required this.runnerImage,
    required this.arch,
    required this.dartVersion,
    required this.flutterVersion,
    required this.mode,
    required this.cpuModel,
  });

  Map<String, Object?> toJson(String scenarioConfig) => {
    'runnerImage': runnerImage,
    'arch': arch,
    'dartVersion': dartVersion,
    'flutterVersion': flutterVersion,
    'mode': mode,
    'cpuModel': cpuModel,
    'scenarioConfig': scenarioConfig,
  };
}

/// Parsed CLI arguments.
final class P3CollectorConfig {
  final String targetPath;
  final String controlPath;
  final String outputPath;
  final int warmups;
  final int repetitions;
  final Duration listingTimeout;
  final Duration deadline;
  final Duration channelOpenTimeout;
  final String? hostKeyPubPath;

  const P3CollectorConfig({
    required this.targetPath,
    required this.controlPath,
    required this.outputPath,
    this.warmups = p3DefaultWarmups,
    this.repetitions = p3DefaultMeasuredRepetitions,
    this.listingTimeout = p3DefaultListingTimeout,
    this.deadline = p3DefaultDeadline,
    this.channelOpenTimeout = p3OpenChannelTimeout,
    this.hostKeyPubPath,
  });

  /// Parses and validates. Distinctness of the raw paths is enforced here
  /// so an aliasing invocation fails before any credential is read or any
  /// connection is opened; the canonical forms are re-checked against each
  /// other after connecting (symlinks and `.`/`..` segments can alias
  /// lexically different paths on the server).
  static P3CollectorConfig parse(List<String> arguments) {
    String? flagValue(String flag) {
      final index = arguments.indexOf(flag);
      if (index == -1) return null;
      if (index + 1 >= arguments.length) {
        throw P3UsageException('$flag requires a value.');
      }
      return arguments[index + 1];
    }

    if (arguments.any((argument) => argument == '-h' || argument == '--help')) {
      throw const P3HelpRequested();
    }

    // A measurement tool must not silently drop a mistyped flag: an
    // operator asking for 20 repetitions must never get 5 without an
    // error (the >= 5 floor would hide the typo).
    const knownFlags = {
      '--output',
      '--target',
      '--control',
      '--warmups',
      '--repetitions',
      '--host-key-pub',
    };
    for (final argument in arguments) {
      if (argument.startsWith('-') && !knownFlags.contains(argument)) {
        throw P3UsageException(
          'unknown option "$argument" (or a value starting with "-"); '
          'see --help.',
        );
      }
    }

    final outputPath = flagValue('--output');
    if (outputPath == null || outputPath.isEmpty) {
      throw const P3UsageException('--output is required.');
    }
    final targetPath = flagValue('--target');
    if (targetPath == null || targetPath.isEmpty) {
      throw const P3UsageException('--target is required.');
    }
    final controlPath = flagValue('--control');
    if (controlPath == null || controlPath.isEmpty) {
      throw const P3UsageException('--control is required.');
    }
    if (targetPath == controlPath) {
      throw P3UsageException(
        '--target and --control must be distinct paths (both are '
        '"$targetPath"); the control listing only cancels latency when it '
        'is a different, minimal directory.',
      );
    }

    int positiveInt(String flag, int fallback, int minimum) {
      final raw = flagValue(flag);
      if (raw == null) return fallback;
      final parsed = int.tryParse(raw);
      if (parsed == null || parsed < minimum) {
        throw P3UsageException(
          '$flag must be an integer >= $minimum (got "$raw").',
        );
      }
      return parsed;
    }

    return P3CollectorConfig(
      targetPath: targetPath,
      controlPath: controlPath,
      outputPath: outputPath,
      warmups: positiveInt('--warmups', p3DefaultWarmups, 1),
      repetitions: positiveInt(
        '--repetitions',
        p3DefaultMeasuredRepetitions,
        p3MinimumMeasuredRepetitions,
      ),
      hostKeyPubPath: flagValue('--host-key-pub'),
    );
  }
}

/// --help: parsed like a usage exception but exits 0 printing usage.
class P3HelpRequested implements Exception {
  const P3HelpRequested();
}

/// Terminal outcome of one collection run for [p3Main] to print and exit
/// with; [released] reports whether the injected server-release step ran.
final class P3RunResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool released;

  const P3RunResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.released,
  });
}

// --- Sampler ---------------------------------------------------------------

/// Runs the fixed warmup/measured protocol over the two listing closures
/// and returns the raw pairs plus an honest failure report. No retry: the
/// first failing listing ends the run at its repetition index.
Future<P3RunOutcome> collectListingOverheadPairs({
  required Future<int> Function() listControl,
  required Future<int> Function() listTarget,
  required int warmups,
  required int repetitions,
  required Duration listingTimeout,
  required Duration deadline,
}) async {
  final runClock = Stopwatch()..start();
  final pairs = <P3PairTimings>[];
  int? controlEntries;
  int? targetEntries;

  // The tree size frozen after warmups — the identity every measured row's
  // fingerprint claims (see the check inside runPair below). The CLI
  // rejects --warmups 0, but direct callers may pass it; with zero warmups
  // the freeze observes nothing, so arming defers to the first measured
  // pair instead of never firing.
  int? expectedControlEntries;
  int? expectedTargetEntries;
  var identityArmed = false;

  P3RunOutcome fail(int repetition, String message) => P3RunOutcome(
    measuredPairs: pairs,
    failedRepetition: repetition,
    failureMessage: message,
    controlEntries: controlEntries,
    targetEntries: targetEntries,
  );

  Future<P3PairTimings> runPair() async {
    final controlWatch = Stopwatch()..start();
    controlEntries = await listControl().timeout(
      listingTimeout,
      onTimeout: () =>
          throw TimeoutException('control listing', listingTimeout),
    );
    final control = controlWatch.elapsed;

    final targetWatch = Stopwatch()..start();
    targetEntries = await listTarget().timeout(
      listingTimeout,
      onTimeout: () => throw TimeoutException('target listing', listingTimeout),
    );
    final target = targetWatch.elapsed;

    // The results schema requires every row to carry one fingerprint, and
    // entry counts are a fingerprint axis: a tree that changes size mid-run
    // cannot be represented honestly, so the run fails at the changing
    // pair instead of smearing one count across every row.
    if (identityArmed) {
      expectedControlEntries ??= controlEntries;
      expectedTargetEntries ??= targetEntries;
    }
    if (expectedControlEntries != null &&
        (expectedControlEntries != controlEntries ||
            expectedTargetEntries != targetEntries)) {
      throw StateError(
        'entry count changed mid-run: control '
        '$expectedControlEntries->${controlEntries ?? '?'} / target '
        '${expectedTargetEntries ?? '?'}->${targetEntries ?? '?'}',
      );
    }

    return P3PairTimings(control: control, target: target);
  }

  for (var warmup = 0; warmup < warmups; warmup++) {
    if (runClock.elapsed >= deadline) {
      return fail(0, 'run deadline exceeded before warmup pair $warmup');
    }
    try {
      await runPair();
    } on TimeoutException catch (error) {
      return fail(
        0,
        'warmup pair $warmup ${error.message} timed out after '
        '${listingTimeout.inMilliseconds} ms',
      );
    } catch (error) {
      return fail(0, 'warmup pair $warmup failed: ${_describe(error)}');
    }
  }

  // Freeze the observed tree size as the run's scenario identity; the
  // guard below arms even when no warmup pair ran.
  expectedControlEntries = controlEntries;
  expectedTargetEntries = targetEntries;
  identityArmed = true;

  for (var repetition = 0; repetition < repetitions; repetition++) {
    if (runClock.elapsed >= deadline) {
      return fail(
        repetition,
        'run deadline exceeded before repetition $repetition '
        '(${pairs.length} completed)',
      );
    }
    try {
      pairs.add(await runPair());
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

  return P3RunOutcome(
    measuredPairs: pairs,
    failedRepetition: null,
    failureMessage: null,
    controlEntries: controlEntries,
    targetEntries: targetEntries,
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

/// Median with the checker's exact definition (odd: the middle element;
/// even: the mean of the two central values), so the stdout summary can
/// never disagree with what test/benchmarks/check.dart computes.
double medianOf(List<double> values) {
  if (values.isEmpty) {
    throw ArgumentError('median of an empty list');
  }
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) {
    return sorted[middle];
  }
  return (sorted[middle - 1] + sorted[middle]) / 2;
}

// --- Run-mode detection ----------------------------------------------------

/// Detects the VM's compile mode for the fingerprint's `mode` axis.
/// `dart compile exe` output is product-mode AOT whose [Platform.script]
/// is the binary itself; anything running from a Dart/kernel source file
/// is JIT regardless of product mode. A JIT process can therefore never
/// report `aot`, and `dart run` (local iteration, 08 §6) reports `jit`.
String detectRunMode({bool? productMode, Uri? scriptUri}) {
  final product = productMode ?? const bool.fromEnvironment('dart.vm.product');
  final script = (scriptUri ?? Platform.script).path.toLowerCase();
  final runsFromSource =
      script.endsWith('.dart') ||
      script.endsWith('.dill') ||
      script.endsWith('.jit') ||
      script.endsWith('.dart.snapshot');
  return product && !runsFromSource ? 'aot' : 'jit';
}

// --- Mid-level collection over a browse channel ----------------------------

/// Collects P3 through [openChannel] (called once: both legs of every pair
/// share that one retained channel) and releases it via [releaseServer]
/// on every exit path. Measurement failures still write the results file
/// with the completed rows plus one honest error row; usage failures
/// (canonical aliasing) write nothing.
Future<P3RunResult> runP3Collection({
  required P3CollectorConfig config,
  required P3FingerprintFields fingerprint,
  required Future<PaneChannel> Function() openChannel,
  required Future<void> Function() releaseServer,
}) async {
  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  var released = false;
  PaneChannel? channel;

  // The collect() body returns only an exit code; the P3RunResult is
  // built once, AFTER the finally-bound cleanup, so `released` reflects
  // reality instead of a value captured before cleanup ran.
  Future<int> collect() async {
    // Failure before any listing: one error row, entry counts unknown — the
    // requested (not canonical) paths are the honest scenario provenance.
    Future<int> failBeforeListing(String context, Object error) async {
      final message = '$context failed: ${_describe(error)}';
      await _writeResultsOrReport(
        config,
        stderrBuffer,
        buildResultsDocument(
          fingerprint: fingerprint,
          targetPath: config.targetPath,
          controlPath: config.controlPath,
          warmups: config.warmups,
          requestedRepetitions: config.repetitions,
          controlEntries: null,
          targetEntries: null,
          rows: [
            _errorRowJson(
              repetition: 0,
              error: message,
              fingerprint: fingerprint,
              targetPath: config.targetPath,
              controlPath: config.controlPath,
              warmups: config.warmups,
              repetitions: config.repetitions,
              controlEntries: null,
              targetEntries: null,
            ),
          ],
        ),
      );
      stderrBuffer.writeln('P3 collection failed: $message');
      return 1;
    }

    final PaneChannel openedChannel;
    try {
      openedChannel = await openChannel().timeout(
        config.channelOpenTimeout,
        onTimeout: () => throw TimeoutException(
          'timed out after ${config.channelOpenTimeout.inSeconds} s',
          config.channelOpenTimeout,
        ),
      );
    } catch (error) {
      return failBeforeListing('browse channel open', error);
    }
    channel = openedChannel;

    final String canonicalTarget;
    final String canonicalControl;
    try {
      canonicalTarget = await openedChannel.fs
          .canonicalize(config.targetPath)
          .timeout(config.listingTimeout);
      canonicalControl = await openedChannel.fs
          .canonicalize(config.controlPath)
          .timeout(config.listingTimeout);
    } catch (error) {
      return failBeforeListing('canonicalizing paths', error);
    }
    if (canonicalTarget == canonicalControl) {
      // Usage failure: write nothing, exit 2 after cleanup.
      stderrBuffer.writeln(
        'P3 usage error: --target and --control must be distinct paths; '
        'both canonicalize to "$canonicalTarget".',
      );
      return 2;
    }

    final outcome = await collectListingOverheadPairs(
      listControl: () async =>
          (await openedChannel.fs.listDirectory(config.controlPath)).length,
      listTarget: () async =>
          (await openedChannel.fs.listDirectory(config.targetPath)).length,
      warmups: config.warmups,
      repetitions: config.repetitions,
      listingTimeout: config.listingTimeout,
      deadline: config.deadline,
    );

    final rows = <Map<String, Object?>>[
      for (var index = 0; index < outcome.measuredPairs.length; index++)
        _okRowJson(
          repetition: index,
          pair: outcome.measuredPairs[index],
          fingerprint: fingerprint,
          targetPath: canonicalTarget,
          controlPath: canonicalControl,
          warmups: config.warmups,
          repetitions: config.repetitions,
          controlEntries: outcome.controlEntries,
          targetEntries: outcome.targetEntries,
        ),
      if (!outcome.completed)
        _errorRowJson(
          repetition: outcome.failedRepetition!,
          error: outcome.failureMessage!,
          fingerprint: fingerprint,
          targetPath: canonicalTarget,
          controlPath: canonicalControl,
          warmups: config.warmups,
          repetitions: config.repetitions,
          controlEntries: outcome.controlEntries,
          targetEntries: outcome.targetEntries,
        ),
    ];

    final writeError = await _writeResultsOrReport(
      config,
      stderrBuffer,
      buildResultsDocument(
        fingerprint: fingerprint,
        targetPath: canonicalTarget,
        controlPath: canonicalControl,
        warmups: config.warmups,
        requestedRepetitions: config.repetitions,
        controlEntries: outcome.controlEntries,
        targetEntries: outcome.targetEntries,
        rows: rows,
      ),
    );
    if (writeError != null) {
      return 74;
    }

    if (outcome.completed) {
      final median = medianOf([
        for (final pair in outcome.measuredPairs) pair.differenceMs,
      ]);
      stdoutBuffer.writeln(
        'P3 listing overhead: median ${_formatMs(median)} ms '
        '(target ${outcome.targetEntries} entries, control '
        '${outcome.controlEntries} entries; ${outcome.measuredPairs.length} '
        'measured pairs, ${config.warmups} warmup pairs discarded; '
        'mode ${fingerprint.mode})',
      );
      stdoutBuffer.writeln('results: ${config.outputPath}');
      return 0;
    }

    stderrBuffer.writeln(
      'P3 collection failed: ${outcome.failureMessage} '
      '(${outcome.measuredPairs.length} of ${config.repetitions} measured '
      'pairs completed; partial results written)',
    );
    return 1;
  }

  final int exitCode;
  try {
    exitCode = await collect();
  } finally {
    // Bounded cleanup on every path; teardown problems are reported, not
    // swallowed, but never mask the measurement outcome.
    final channelToClose = channel;
    if (channelToClose != null) {
      try {
        await channelToClose.close().timeout(p3TeardownTimeout);
      } catch (error) {
        stderrBuffer.writeln(
          'warning: browse channel close failed: ${_describe(error)}',
        );
      }
    }
    try {
      await releaseServer().timeout(p3TeardownTimeout);
      released = true;
    } catch (error) {
      stderrBuffer.writeln(
        'warning: server release failed: ${_describe(error)}',
      );
    }
  }
  return P3RunResult(
    exitCode: exitCode,
    stdout: stdoutBuffer.toString(),
    stderr: stderrBuffer.toString(),
    released: released,
  );
}

// --- Results document ------------------------------------------------------

/// The scenarioConfig axis: everything a later calibration must pin for
/// these numbers to be comparable. Entry counts are part of the config —
/// a tree that changed size is a different scenario, surfaced as drift
/// rather than a silent comparison.
String buildScenarioConfig({
  required String targetPath,
  required String controlPath,
  required int warmups,
  required int repetitions,
  required int? controlEntries,
  required int? targetEntries,
}) {
  String entryWord(int? count) => count?.toString() ?? 'unknown';
  return 'p3/v1'
      ';target=$targetPath'
      ';control=$controlPath'
      ';target-entries=${entryWord(targetEntries)}'
      ';control-entries=${entryWord(controlEntries)}'
      ';warmups=$warmups'
      ';repetitions=$repetitions'
      ';pairing=control-then-target-one-channel';
}

Map<String, Object?> buildResultsDocument({
  required P3FingerprintFields fingerprint,
  required String targetPath,
  required String controlPath,
  required int warmups,
  required int requestedRepetitions,
  required int? controlEntries,
  required int? targetEntries,
  required List<Map<String, Object?>> rows,
}) => {
  'schema': p3ResultsSchemaId,
  'rows': rows,
  'provenance': {
    'scenario': p3ScenarioId,
    'generatedUtc': DateTime.now().toUtc().toIso8601String(),
    'pairProtocol':
        'control listing then target listing over one retained browse '
        'channel; authentication/setup excluded; difference unclipped',
    'warmupsDiscarded': warmups,
    'measuredRepetitionsRequested': requestedRepetitions,
    'measuredRepetitionsCompleted': rows
        .where((row) => row['status'] == 'ok')
        .length,
    'canonicalTarget': targetPath,
    'canonicalControl': controlPath,
    'controlEntries': controlEntries,
    'targetEntries': targetEntries,
  },
};

Map<String, Object?> _okRowJson({
  required int repetition,
  required P3PairTimings pair,
  required P3FingerprintFields fingerprint,
  required String targetPath,
  required String controlPath,
  required int warmups,
  required int repetitions,
  required int? controlEntries,
  required int? targetEntries,
}) => {
  'scenario': p3ScenarioId,
  'repetition': repetition,
  'status': 'ok',
  'value': pair.differenceMs,
  'unit': 'ms',
  // Raw pair timings: the audit trail behind each difference.
  'controlMs': pair.controlMs,
  'targetMs': pair.targetMs,
  'fingerprint': fingerprint.toJson(
    buildScenarioConfig(
      targetPath: targetPath,
      controlPath: controlPath,
      warmups: warmups,
      repetitions: repetitions,
      controlEntries: controlEntries,
      targetEntries: targetEntries,
    ),
  ),
};

Map<String, Object?> _errorRowJson({
  required int repetition,
  required String error,
  required P3FingerprintFields fingerprint,
  required String targetPath,
  required String controlPath,
  required int warmups,
  required int repetitions,
  required int? controlEntries,
  required int? targetEntries,
}) => {
  'scenario': p3ScenarioId,
  'repetition': repetition,
  'status': 'error',
  'error': error,
  'fingerprint': fingerprint.toJson(
    buildScenarioConfig(
      targetPath: targetPath,
      controlPath: controlPath,
      warmups: warmups,
      repetitions: repetitions,
      controlEntries: controlEntries,
      targetEntries: targetEntries,
    ),
  ),
};

/// Atomic write through an owned unique temp file; returns null on
/// success or the IO error for the caller to report (never a silent skip).
Future<Object?> _writeResultsOrReport(
  P3CollectorConfig config,
  StringBuffer stderrBuffer,
  Map<String, Object?> document,
) async {
  File? temp;
  try {
    temp = File(
      '${config.outputPath}.p3-$pid-${DateTime.now().microsecondsSinceEpoch}'
      '.tmp',
    );
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(document),
    );
    await temp.rename(config.outputPath);
    return null;
  } catch (error) {
    stderrBuffer.writeln(
      'error: cannot write results to ${config.outputPath}: $error',
    );
    // Best-effort cleanup: a failed write must not leave its temp file
    // behind for artifact globs to pick up; cleanup failures stay quiet so
    // the write error above remains the reported outcome.
    try {
      await temp?.delete();
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
/// pool wiring, and drives [runP3Collection]. Returns the process exit
/// code instead of exiting so tests can call it in-process.
Future<int> p3Main(
  List<String> arguments, {
  required void Function(String) writeStdout,
  required void Function(String) writeStderr,
  required Map<String, String> environment,
}) async {
  final P3CollectorConfig config;
  try {
    config = P3CollectorConfig.parse(arguments);
  } on P3HelpRequested {
    writeStdout(_usageText);
    return 0;
  } on P3UsageException catch (error) {
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

  final hostKeyPubPath = config.hostKeyPubPath ?? p3DefaultHostKeyPubPath;
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

  final fingerprint = P3FingerprintFields(
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
    id: 'p3-collector',
    label: 'p3-collector',
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
    final result = await runP3Collection(
      config: config,
      fingerprint: fingerprint,
      openChannel: () =>
          manager.openBrowseChannel(server.id, paneTabId: 'p3-collector'),
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
  } catch (error) {
    // runP3Collection catches its own error paths; anything reaching here
    // is an unexpected failure that still deserves the transcript tail
    // and a structured nonzero exit instead of an uncaught crash.
    writeStderr('P3 collection failed unexpectedly: $error');
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
  exitCode = await p3Main(
    arguments,
    writeStdout: stdout.writeln,
    writeStderr: stderr.writeln,
    environment: Platform.environment,
  );
}
