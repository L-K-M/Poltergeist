// D12 offline benchmark checker CLI (08 §6).
//
// Offline invocation that evaluates a supplied bench-results file against
// the committed budgets catalog (test/benchmarks/budgets.json, mirroring
// 02 §12), the committed tier-B baseline, and the drift-state store:
//
//   dart run test/benchmarks/check.dart --results <bench-results.json> \
//       --tiers a|b|ab [--baseline <path>] [--drift-state <path>] \
//       [--update-drift-state] [--budgets <path>]
//
// Exit codes: 0 success (including soft overruns and drift skips allowed
// to stay soft by 08 §6), 1 graded failure (missing/errored expected
// scenario, enforced overruns/drift), 64 usage, 65 malformed input
// documents, 74 IO errors.
//
// Enforcement comes from the environment: BENCH_ENFORCE_A for tier-A
// budgets, BENCH_ENFORCE_B for tier-B trends. Values other than
// 0/1/true/false are rejected — an unexpected value must never silently
// read as unenforced.
//
// The future CI bench job (08 §8, not built here) hands artifacts to this
// checker: it writes bench-results.json, passes --tiers matching what ran
// (`ab` on main/dispatch, `a` on PR runs), points --drift-state at the
// state fetched from the latest main-branch bench job's artifact (or an
// actions/cache entry keyed on the fingerprint), and passes
// --update-drift-state on main-branch runs only — PR invocations never
// mutate the state store. That artifact handoff is documentation here;
// no Actions API or cache integration exists in this offline checker.
library;

import 'dart:convert';
import 'dart:io';

import 'check_core.dart';

const defaultBudgetsPath = 'test/benchmarks/budgets.json';
const defaultBaselinePath = 'test/benchmarks/tier-b-baseline.json';

const usageExitCode = 64;
const dataExitCode = 65;
const ioExitCode = 74;
const gradedFailureExitCode = 1;

/// Upper bound on owned-temp acquisition attempts (each name embeds the
/// pid and a microsecond timestamp, so collisions are practically
/// impossible; the bound exists only to fail closed).
const tempNameAttempts = 5;

const _usageText =
    '''
Usage: dart run test/benchmarks/check.dart --results <path> --tiers a|b|ab
Evaluates D12 benchmark results offline (08 §6); budgets gate per 02 §12.
Enforcement flags come from BENCH_ENFORCE_A / BENCH_ENFORCE_B.

Options:
  --results <path>          bench-results.json written by the bench job
  --tiers a|b|ab            which tiers this invocation ran
  --budgets <path>          budgets catalog (default $defaultBudgetsPath)
  --baseline <path>         tier-B baseline (default $defaultBaselinePath)
  --drift-state <path>      drift-state store to read (missing/unreadable
                            means unknown history: counting is
                            conservative, never a reset)
  --update-drift-state      main-branch run: update the drift-state store
                            after evaluation (requires --drift-state and
                            --tiers including b)
  -h, --help                print this usage''';

/// CLI body, exposed for in-process tests. Writes to [out]/[err] (defaults:
/// stdout/stderr) and sets the [exitCode] instead of exiting, so a test
/// runner survives it.
Future<void> checkMain(
  List<String> arguments, {
  IOSink? out,
  IOSink? err,
  Map<String, String>? environment,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final env = environment ?? Platform.environment;

  final CliArguments cli;
  try {
    cli = CliArguments.parse(arguments);
  } on CheckUsageException catch (error) {
    _fail(stderrSink, '$error\n$_usageText', usageExitCode);
    return;
  }
  if (cli.help) {
    stdoutSink.writeln(_usageText);
    return;
  }
  // Parse guarantees both for every non-help invocation.
  final resultsPath = cli.results!;
  final tiers = cli.tiers!;

  final enforceA = _parseEnforceFlag(env['BENCH_ENFORCE_A']);
  if (enforceA == null) {
    _fail(
      stderrSink,
      'BENCH_ENFORCE_A must be 0/1/true/false '
      '(got "${env['BENCH_ENFORCE_A']}")',
      usageExitCode,
    );
    return;
  }
  final enforceB = _parseEnforceFlag(env['BENCH_ENFORCE_B']);
  if (enforceB == null) {
    _fail(
      stderrSink,
      'BENCH_ENFORCE_B must be 0/1/true/false '
      '(got "${env['BENCH_ENFORCE_B']}")',
      usageExitCode,
    );
    return;
  }

  final driftStatePath = cli.driftState;
  final updateDriftState = cli.updateDriftState;
  if (updateDriftState && driftStatePath == null) {
    _fail(
      stderrSink,
      '--update-drift-state requires --drift-state',
      usageExitCode,
    );
    return;
  }
  // A main run that did not evaluate tier B must not write drift state:
  // it observed no tier-B comparison, so it cannot honestly claim a clean
  // one (a wrongly "clean" write would reset the staleness count).
  if (updateDriftState && !tiers.contains(BenchTier.b)) {
    _fail(
      stderrSink,
      '--update-drift-state requires --tiers including b '
      '(a tier-B-blind run must not reset drift state)',
      usageExitCode,
    );
    return;
  }

  // One timestamp per run: evaluation and any state write share it, so
  // the persisted instant can never drift past the evaluation instant.
  final nowUtc = DateTime.now().toUtc().toIso8601String();
  try {
    final catalog = BudgetCatalog.fromJson(
      await _readJsonDocument(cli.budgets, 'budgets.json'),
    );
    catalog.validateCatalog();
    final results = ResultsFile.fromJson(
      await _readJsonDocument(resultsPath, 'results file'),
      catalog,
    );

    TierBBaseline? baseline;
    final baselineFile = File(cli.baseline);
    if (await baselineFile.exists()) {
      baseline = TierBBaseline.fromJson(
        await _readJsonDocument(cli.baseline, 'tier-B baseline'),
        catalog,
      );
    }

    var stateUnknown = driftStatePath != null;
    DriftState? priorState;
    if (driftStatePath != null) {
      final stateFile = File(driftStatePath);
      if (await stateFile.exists()) {
        try {
          priorState = DriftState.fromJson(
            await _readJsonDocument(driftStatePath, 'drift state'),
          );
          stateUnknown = false;
        } on CheckDataException {
          // Undecodable state is history loss, not a data error:
          // counting continues conservatively (08 §6), never a reset.
        } on FileSystemException {
          // So is an unreadable file (EACCES, vanished between exists()
          // and read): the usage text promises "missing/unreadable means
          // unknown history", not an exit-74 abort.
        }
      }
    }

    final report = evaluate(
      catalog: catalog,
      results: results,
      tiers: tiers,
      baseline: baseline,
      baselinePath: cli.baseline,
      priorState: priorState,
      stateUnknown: stateUnknown,
      stateConfigured: driftStatePath != null,
      runKind: updateDriftState ? DriftRunKind.mainRun : DriftRunKind.readOnly,
      enforceA: enforceA,
      enforceB: enforceB,
      nowUtc: nowUtc,
    );

    _printReport(
      stdoutSink,
      report,
      tiers: tiers,
      enforceA: enforceA,
      enforceB: enforceB,
    );

    if (report.newState != null && updateDriftState) {
      await _writeDriftState(driftStatePath!, report.newState!, nowUtc);
    }

    exitCode = report.exitCode;
  } on CheckDataException catch (error) {
    _fail(stderrSink, '$error', dataExitCode);
    return;
  } on FileSystemException catch (error) {
    _fail(
      stderrSink,
      'I/O error${error.path == null ? '' : ' (${error.path})'}: '
      '${error.message}',
      ioExitCode,
    );
    return;
  }
}

/// Parsed command line. Argument parsing stays manual and dependency-free
/// like the other root-level tools (e.g. tool/protocol_guard).
class CliArguments {
  final bool help;
  final String? results;
  final Set<BenchTier>? tiers;
  final String budgets;
  final String baseline;
  final String? driftState;
  final bool updateDriftState;

  const CliArguments({
    required this.help,
    required this.results,
    required this.tiers,
    required this.budgets,
    required this.baseline,
    required this.driftState,
    required this.updateDriftState,
  });

  static CliArguments parse(List<String> arguments) {
    var help = false;
    String? results;
    String? tiersText;
    String? budgets;
    String? baseline;
    String? driftState;
    var updateDriftState = false;

    String? takeValue(int index) {
      if (index + 1 >= arguments.length) {
        throw CheckUsageException('${arguments[index]} requires a value');
      }
      return arguments[index + 1];
    }

    for (var i = 0; i < arguments.length; i++) {
      final argument = arguments[i];
      switch (argument) {
        case '-h' || '--help':
          help = true;
        case '--results':
          results = takeValue(i++);
        case '--tiers':
          tiersText = takeValue(i++);
        case '--budgets':
          budgets = takeValue(i++);
        case '--baseline':
          baseline = takeValue(i++);
        case '--drift-state':
          driftState = takeValue(i++);
        case '--update-drift-state':
          updateDriftState = true;
        default:
          throw CheckUsageException('unknown option $argument');
      }
    }

    if (help) {
      return CliArguments(
        help: true,
        results: null,
        tiers: null,
        budgets: budgets ?? defaultBudgetsPath,
        baseline: baseline ?? defaultBaselinePath,
        driftState: driftState,
        updateDriftState: updateDriftState,
      );
    }
    if (results == null) {
      throw CheckUsageException('--results is required');
    }
    if (tiersText == null) {
      throw CheckUsageException('--tiers is required');
    }
    if (!allowedTiersValues.contains(tiersText)) {
      throw CheckUsageException(
        '--tiers must be one of ${allowedTiersValues.join('|')} '
        '(got "$tiersText")',
      );
    }
    return CliArguments(
      help: false,
      results: results,
      tiers: {
        if (tiersText.contains('a')) BenchTier.a,
        if (tiersText.contains('b')) BenchTier.b,
      },
      budgets: budgets ?? defaultBudgetsPath,
      baseline: baseline ?? defaultBaselinePath,
      driftState: driftState,
      updateDriftState: updateDriftState,
    );
  }
}

/// null = invalid value (fail closed); false = unset/0/false; true = 1/true.
bool? _parseEnforceFlag(String? raw) {
  if (raw == null || raw.isEmpty) {
    return false;
  }
  switch (raw.toLowerCase()) {
    case '1' || 'true':
      return true;
    case '0' || 'false':
      return false;
    default:
      return null;
  }
}

Future<Object?> _readJsonDocument(String path, String source) async {
  // Read raw bytes first: a genuine IO failure (missing/unreadable file)
  // must stay an IO exit (74), while a decode failure below is malformed
  // input (65). File.readAsString would conflate the two — it wraps its
  // UTF-8 decode errors in a FileSystemException.
  final bytes = await File(path).readAsBytes();
  try {
    return jsonDecode(utf8.decode(bytes));
  } on FormatException catch (error) {
    throw CheckDataException(
      '$source ($path) is not valid UTF-8 or JSON: ${error.message}',
    );
  }
}

void _printReport(
  IOSink sink,
  CheckReport report, {
  required Set<BenchTier> tiers,
  required bool enforceA,
  required bool enforceB,
}) {
  sink.writeln(
    'D12 benchmark check (tiers: ${tiers.map((t) => t.name).join(', ')}, '
    'enforce A: $enforceA, enforce B: $enforceB)',
  );
  if (report.tableLines.isEmpty) {
    sink.writeln('no scenario rows to report');
  } else {
    sink.writeln(
      '${'SCENARIO'.padRight(9)} ${'TIER'.padRight(4)} '
      '${'MEASURED'.padRight(28)} ${'LIMIT'.padRight(18)} VERDICT',
    );
    for (final line in report.tableLines) {
      sink.writeln(line);
    }
  }
  for (final notice in report.noticeLines) {
    sink.writeln(notice);
  }
  for (final failure in report.failureLines) {
    sink.writeln('FAIL: $failure');
  }
}

/// Atomic publication of the drift state. The temporary storage is
/// owned and uniquely named: a fixed `<state>.tmp` name would overwrite
/// an unrelated file (or follow a symlink planted there — concrete data
/// loss), so each write acquires its own
/// `<state>.checker-<pid>-<seq>.tmp` on the target filesystem, publishes
/// with rename, and cleans up only the file it created. A torn write
/// therefore never leaves a valid-looking state behind and never touches
/// anything it does not own.
Future<void> _writeDriftState(
  String path,
  DriftState state,
  String nowUtc,
) async {
  final target = File(path).absolute;
  await target.parent.create(recursive: true);
  final payload =
      '${JsonEncoder.withIndent('  ').convert(state.toJson(nowUtc))}\n';
  for (var attempt = 1; attempt <= tempNameAttempts; attempt++) {
    final temporary = File(
      '${target.path}.checker-$pid-${DateTime.now().microsecondsSinceEpoch}'
      '-$attempt.tmp',
    );
    if (await temporary.exists()) {
      continue;
    }
    try {
      await temporary.writeAsString(payload, flush: true);
      await temporary.rename(target.path);
      return;
    } catch (_) {
      // Cleanup only our own temp, then surface the IO failure.
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }
  throw FileSystemException(
    'could not acquire an owned temporary file beside',
    target.path,
  );
}

void _fail(IOSink sink, String message, int code) {
  sink.writeln(message);
  exitCode = code;
}

void main(List<String> arguments) => checkMain(arguments);
