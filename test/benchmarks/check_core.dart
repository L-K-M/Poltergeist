// D12 offline benchmark checker — pure evaluation core (08 §6).
//
// This library has no IO: the CLI shell (check.dart) reads files, feeds the
// parsed inputs to [evaluate], prints the report, and applies the exit code.
// Keeping the arithmetic, validation, and drift-state transitions here makes
// them testable at the lowest useful level (08 §1 principles 1–2).
//
// Input formats (all JSON, versioned by a `schema` string so later revisions
// can never be silently misread):
//
// * budgets.json      — the committed P1–P7 catalog mirroring 02 §12, plus
//                       the tier-A calibrated fingerprint (null until real
//                       calibration runs; a landed tier-A scenario with a
//                       null calibration is rejected, because it could never
//                       be honestly compared).
// * results file      — what a bench job's run wrote: per-repetition rows
//                       keyed (scenario, repetition) with value/unit or an
//                       error, all sharing one environment fingerprint.
//                       This is a D12-specific format; it deliberately does
//                       not reuse the M0 evidence envelope (different
//                       schema, validator, and provenance).
// * tier-B baseline   — committed medians per tier-B scenario with the
//                       fingerprint they were measured under.
// * drift state       — the small state store that time-boxes drift skips
//                       (consecutive-main-run counters per drift notice).
//
// Semantics implemented (08 §6 verbatim):
//  * `--tiers` scopes the expected set; expected = landed scenarios of the
//    declared tiers. Missing/errored expected scenarios fail in every mode.
//  * Soft mode (the tier's BENCH_ENFORCE_* flag unset) softens overruns
//    only — never missing/errored scenarios, never drift exits that the
//    plan marks as hard.
//  * Tier-A budget comparison skips on any controlled-axis mismatch with
//    the calibrated fingerprint, exits zero in every mode, and never
//    escalates through the drift state.
//  * Tier-B compares the median of the in-job repetitions against the
//    committed baseline and fails on a > 25 % regression once enforced;
//    controlled-axis mismatch is a hard non-zero exit once BENCH_ENFORCE_B
//    is set, while the uncontrolled CPU axis skips with a loud notice and
//    only reddens through the >= 7 consecutive-main-run staleness rule.
//  * A missing/unreadable drift state is "count unknown": the fired
//    notices are counted conservatively at the escalation threshold, never
//    reset to a fresh count.

/// Usage error: bad flags or bad enforcement-variable values (exit 64).
class CheckUsageException implements Exception {
  final String message;

  const CheckUsageException(this.message);

  @override
  String toString() => message;
}

/// Data error: malformed or incompatible input documents (exit 65).
class CheckDataException implements Exception {
  final String message;

  const CheckDataException(this.message);

  @override
  String toString() => message;
}

/// Minimum in-job repetitions for a tier-B comparison (08 §6 mechanics).
const tierBMinimumRepetitions = 3;

/// Consecutive main-branch drift runs after which the job reddens with
/// "baseline stale — refresh required" (08 §6, the drift time-box).
const driftStaleThreshold = 7;

/// Allowed `--tiers` values, mapping to the declared tier set.
const allowedTiersValues = ['a', 'b', 'ab'];

const budgetsSchemaId = 'poltergeist-d12-budgets-1';
const resultsSchemaId = 'poltergeist-d12-results-1';
const baselineSchemaId = 'poltergeist-d12-baseline-1';
const driftStateSchemaId = 'poltergeist-d12-drift-state-1';

/// The regression budget of a tier-B trend comparison: a median worse than
/// the baseline by strictly more than this fraction fails (08 §6 table).
const tierBRegressionFraction = 0.25;

enum BenchTier { a, b }

enum BudgetOperator { lessThan, atMost, atLeast }

/// The measurement mode eligible per tier. A debug/JIT number must never
/// masquerade as an eligible AOT/profile measurement (08 §6), so rows in
/// any other mode are not counted toward the repetition minimum.
const eligibleModeByTier = {BenchTier.a: 'aot', BenchTier.b: 'profile'};

/// Environment fingerprint of one bench job. Split per 08 §6: controlled
/// axes must match the calibrated/baseline fingerprint or the comparison
/// skips (tier A: always skip; tier B: skip while soft, hard fail once
/// enforced); the uncontrolled CPU axis skips with a notice and never
/// auto-reddens on its own.
class BenchFingerprint {
  final String runnerImage;
  final String arch;
  final String dartVersion;
  final String? flutterVersion;
  final String mode;
  final String cpuModel;
  final String? scenarioConfig;

  const BenchFingerprint({
    required this.runnerImage,
    required this.arch,
    required this.dartVersion,
    required this.flutterVersion,
    required this.mode,
    required this.cpuModel,
    required this.scenarioConfig,
  });

  /// Controlled axes and their values, in stable order, for drift
  /// comparison. `mode` is deliberately absent here: one main-branch job
  /// writes tier-A (aot) and tier-B (profile) rows into one results file,
  /// so mode is not a cross-row axis — it is validated per store instead
  /// (rows by tier eligibility, the calibration and the baseline at their
  /// own parse/validate time), which keeps “AOT/profile mode” a controlled
  /// axis of 08 §6 without rejecting the plan's own `ab` results file.
  Map<String, String> get controlledAxes => {
    'runnerImage': runnerImage,
    'arch': arch,
    'dartVersion': dartVersion,
    'flutterVersion': flutterVersion ?? '',
    'scenarioConfig': scenarioConfig ?? '',
  };

  /// Per-axis mismatches of the controlled axes between [this] and
  /// [other], keyed by axis name with the differing values.
  Map<String, (String, String)> controlledMismatches(BenchFingerprint other) {
    final mine = controlledAxes;
    final theirs = other.controlledAxes;
    return {
      for (final axis in mine.keys)
        if (mine[axis] != theirs[axis]) axis: (mine[axis]!, theirs[axis]!),
    };
  }

  factory BenchFingerprint.fromJson(Object? json, String source) {
    final map = _expectMap(json, '$source: fingerprint');
    return BenchFingerprint(
      runnerImage: _expectString(
        map['runnerImage'],
        '$source: fingerprint.runnerImage',
      ),
      arch: _expectString(map['arch'], '$source: fingerprint.arch'),
      dartVersion: _expectString(
        map['dartVersion'],
        '$source: fingerprint.dartVersion',
      ),
      flutterVersion: _expectOptionalString(
        map['flutterVersion'],
        '$source: fingerprint.flutterVersion',
      ),
      mode: _expectString(map['mode'], '$source: fingerprint.mode'),
      cpuModel: _expectString(map['cpuModel'], '$source: fingerprint.cpuModel'),
      scenarioConfig: _expectOptionalString(
        map['scenarioConfig'],
        '$source: fingerprint.scenarioConfig',
      ),
    );
  }
}

/// One scenario row of the committed budgets catalog (02 §12 values).
class ScenarioBudget {
  final String id;
  final BenchTier tier;
  final String summary;
  final BudgetOperator operator;
  final double value;
  final String unit;
  final int minimumRepetitions;
  final bool landed;

  const ScenarioBudget({
    required this.id,
    required this.tier,
    required this.summary,
    required this.operator,
    required this.value,
    required this.unit,
    required this.minimumRepetitions,
    required this.landed,
  });

  String describeLimit() {
    final operatorText = switch (operator) {
      BudgetOperator.lessThan => '<',
      BudgetOperator.atMost => '<=',
      BudgetOperator.atLeast => '>=',
    };
    return '$operatorText ${_formatNumber(value)} $unit';
  }
}

class BudgetCatalog {
  /// Controlled axes the tier-A budgets were calibrated under; null until a
  /// real calibration run records them (no fabricated fingerprints).
  final BenchFingerprint? calibratedFingerprint;
  final Map<String, ScenarioBudget> scenarios;

  const BudgetCatalog(this.calibratedFingerprint, this.scenarios);

  factory BudgetCatalog.fromJson(Object? json) {
    final map = _expectMap(json, 'budgets.json');
    if (map['schema'] != budgetsSchemaId) {
      throw CheckDataException(
        'budgets.json: unsupported schema ${map['schema']} '
        '(expected $budgetsSchemaId)',
      );
    }
    final rows = map['scenarios'];
    if (rows is! List || rows.isEmpty) {
      throw CheckDataException(
        'budgets.json: scenarios must be a non-empty '
        'list',
      );
    }
    final scenarios = <String, ScenarioBudget>{};
    for (final row in rows) {
      final budget = _parseScenarioBudget(row);
      if (scenarios.containsKey(budget.id)) {
        throw CheckDataException(
          'budgets.json: duplicate scenario id ${budget.id}',
        );
      }
      scenarios[budget.id] = budget;
    }
    final calibrated = map['calibratedFingerprint'];
    final catalog = BudgetCatalog(
      calibrated == null
          ? null
          : BenchFingerprint.fromJson(
              calibrated,
              'budgets.json: calibratedFingerprint',
            ),
      scenarios,
    );
    // Parse always yields a validated catalog: the landed-tier-A and
    // calibration-mode invariants must not depend on every caller
    // remembering the separate validateCatalog() call.
    catalog.validateCatalog();
    return catalog;
  }

  /// A landed tier-A scenario without a committed calibration could never
  /// be honestly compared, so the catalog itself is malformed. The
  /// calibration must also record the tier-A measurement mode (AOT, per
  /// 08 §6's `dart compile exe` rule) — a calibration quoted in any other
  /// mode is a miscalibration.
  void validateCatalog() {
    final calibrationMode = calibratedFingerprint?.mode;
    if (calibratedFingerprint != null &&
        calibrationMode != eligibleModeByTier[BenchTier.a]) {
      throw CheckDataException(
        'budgets.json: calibratedFingerprint.mode must be '
        '"${eligibleModeByTier[BenchTier.a]}" for '
        'tier-A budgets (got "$calibrationMode")',
      );
    }
    for (final budget in scenarios.values) {
      if (budget.landed &&
          budget.tier == BenchTier.a &&
          calibratedFingerprint == null) {
        throw CheckDataException(
          'budgets.json: landed tier-A scenario ${budget.id} requires a '
          'calibratedFingerprint (08 §6: an absolute number measured on '
          'different axes is never compared against a budget)',
        );
      }
    }
  }

  static ScenarioBudget _parseScenarioBudget(Object? json) {
    final map = _expectMap(json, 'budgets.json: scenario');
    final id = _expectString(map['id'], 'budgets.json: scenario.id');
    final tierText = _expectString(map['tier'], 'budgets.json: $id.tier');
    final tier = switch (tierText) {
      'a' => BenchTier.a,
      'b' => BenchTier.b,
      _ => throw CheckDataException(
        'budgets.json: $id.tier must be "a" or "b" (got "$tierText")',
      ),
    };
    final operatorText = _expectString(
      map['operator'],
      'budgets.json: $id.operator',
    );
    final operator = switch (operatorText) {
      'lessThan' => BudgetOperator.lessThan,
      'atMost' => BudgetOperator.atMost,
      'atLeast' => BudgetOperator.atLeast,
      _ => throw CheckDataException(
        'budgets.json: $id.operator must be lessThan, atMost, or '
        'atLeast (got "$operatorText")',
      ),
    };
    final value = _expectDouble(
      map['value'],
      'budgets.json: $id.value',
    ).toDouble();
    final minimumRepetitions = _expectInt(
      map['minimumRepetitions'],
      'budgets.json: $id.minimumRepetitions',
    );
    if (minimumRepetitions < 1) {
      throw CheckDataException(
        'budgets.json: $id.minimumRepetitions must be >= 1 '
        '(got $minimumRepetitions)',
      );
    }
    return ScenarioBudget(
      id: id,
      tier: tier,
      summary: _expectString(map['summary'], 'budgets.json: $id.summary'),
      operator: operator,
      value: value,
      unit: _expectString(map['unit'], 'budgets.json: $id.unit'),
      minimumRepetitions: minimumRepetitions,
      landed: _expectBool(map['landed'], 'budgets.json: $id.landed'),
    );
  }
}

/// One per-repetition observation. Either a value (`status: "ok"`) or a
/// recorded error; failed observations are kept, never silently dropped.
class ResultRow {
  final String scenario;
  final int repetition;
  final bool isOk;
  final double? value;
  final String? unit;
  final String? error;
  final BenchFingerprint fingerprint;

  const ResultRow({
    required this.scenario,
    required this.repetition,
    required this.isOk,
    this.value,
    this.unit,
    this.error,
    required this.fingerprint,
  });
}

class ResultsFile {
  final List<ResultRow> rows;

  /// All rows must share one fingerprint: a mid-job environment change is
  /// not a comparable sample (08 §6 compares the job, not a mixture).
  final BenchFingerprint fingerprint;

  const ResultsFile(this.rows, this.fingerprint);

  static ResultsFile fromJson(Object? json, BudgetCatalog catalog) {
    final map = _expectMap(json, 'results file');
    if (map['schema'] != resultsSchemaId) {
      throw CheckDataException(
        'results file: unsupported schema ${map['schema']} '
        '(expected $resultsSchemaId)',
      );
    }
    final rows = map['rows'];
    if (rows is! List) {
      throw CheckDataException('results file: rows must be a list');
    }
    final parsed = <ResultRow>[];
    final seen = <String>{};
    BenchFingerprint? fingerprint;
    for (final row in rows) {
      final parsedRow = _parseResultRow(row, catalog);
      final key = '${parsedRow.scenario}/${parsedRow.repetition}';
      if (!seen.add(key)) {
        throw CheckDataException(
          'results file: duplicate observation for scenario '
          '${parsedRow.scenario}, repetition ${parsedRow.repetition} — '
          'the repetition index is part of the aggregation key (08 §6)',
        );
      }
      if (fingerprint == null) {
        fingerprint = parsedRow.fingerprint;
      } else if (_fingerprintsDiffer(fingerprint, parsedRow.fingerprint)) {
        throw CheckDataException(
          'results file: row $key carries a different environment '
          'fingerprint than earlier rows; one job must run on one '
          'environment',
        );
      }
      parsed.add(parsedRow);
    }
    if (fingerprint == null) {
      throw CheckDataException('results file: rows must not be empty');
    }
    return ResultsFile(parsed, fingerprint);
  }

  static ResultRow _parseResultRow(Object? json, BudgetCatalog catalog) {
    final map = _expectMap(json, 'results file: row');
    final scenario = _expectString(map['scenario'], 'results file: scenario');
    final budget = catalog.scenarios[scenario];
    if (budget == null) {
      throw CheckDataException(
        'results file: unknown scenario id $scenario — budgets.json must '
        'carry every scenario the harness reports (landed or not)',
      );
    }
    final repetition = _expectInt(
      map['repetition'],
      'results file: $scenario.repetition',
    );
    if (repetition < 0) {
      throw CheckDataException(
        'results file: $scenario.repetition must be >= 0 (got $repetition)',
      );
    }
    final status = _expectString(map['status'], 'results file: status');
    final fingerprint = BenchFingerprint.fromJson(
      map['fingerprint'],
      'results file: $scenario/$repetition',
    );
    switch (status) {
      case 'ok':
        final value = _expectDouble(
          map['value'],
          'results file: $scenario/$repetition.value',
        ).toDouble();
        final unit = _expectString(
          map['unit'],
          'results file: $scenario/$repetition.unit',
        );
        if (unit != budget.unit) {
          throw CheckDataException(
            'results file: $scenario/$repetition carries unit "$unit" but '
            'budgets.json declares "${budget.unit}" — incompatible units '
            'are never silently converted',
          );
        }
        return ResultRow(
          scenario: scenario,
          repetition: repetition,
          isOk: true,
          value: value,
          unit: unit,
          fingerprint: fingerprint,
        );
      case 'error':
        final error = map['error'];
        if (map['value'] != null) {
          throw CheckDataException(
            'results file: $scenario/$repetition is errored but carries a '
            'value — a failed observation records its error, not a value',
          );
        }
        return ResultRow(
          scenario: scenario,
          repetition: repetition,
          isOk: false,
          error: _expectString(
            error,
            'results file: $scenario/$repetition.error',
          ),
          fingerprint: fingerprint,
        );
      default:
        throw CheckDataException(
          'results file: $scenario/$repetition.status must be "ok" or '
          '"error" (got "$status")',
        );
    }
  }

  static bool _fingerprintsDiffer(BenchFingerprint a, BenchFingerprint b) {
    // Full-axis inequality across rows except mode (see controlledAxes):
    // cpuModel is uncontrolled for *comparison* policy but a row-level
    // difference still means two environments in one job, which is
    // rejected here.
    return a.controlledMismatches(b).isNotEmpty || a.cpuModel != b.cpuModel;
  }
}

/// Committed tier-B baseline medians with the fingerprint they were
/// measured under.
class TierBBaseline {
  final BenchFingerprint fingerprint;
  final Map<String, BaselineEntry> scenarios;

  const TierBBaseline(this.fingerprint, this.scenarios);

  factory TierBBaseline.fromJson(Object? json, BudgetCatalog catalog) {
    final map = _expectMap(json, 'tier-B baseline');
    if (map['schema'] != baselineSchemaId) {
      throw CheckDataException(
        'tier-B baseline: unsupported schema ${map['schema']} '
        '(expected $baselineSchemaId)',
      );
    }
    final fingerprint = BenchFingerprint.fromJson(
      map['fingerprint'],
      'tier-B baseline: fingerprint',
    );
    if (fingerprint.mode != eligibleModeByTier[BenchTier.b]) {
      throw CheckDataException(
        'tier-B baseline: fingerprint.mode must be '
        '"${eligibleModeByTier[BenchTier.b]}" for tier-B '
        'measurements (got "${fingerprint.mode}")',
      );
    }
    final entries = _expectMap(map['scenarios'], 'tier-B baseline: scenarios');
    final scenarios = <String, BaselineEntry>{};
    for (final entry in entries.entries) {
      final budget = catalog.scenarios[entry.key];
      if (budget == null) {
        throw CheckDataException(
          'tier-B baseline: unknown scenario id ${entry.key}',
        );
      }
      if (budget.tier != BenchTier.b) {
        throw CheckDataException(
          'tier-B baseline: scenario ${entry.key} is a tier-'
          '${budget.tier == BenchTier.a ? 'a' : 'b'} scenario; the '
          'baseline stores tier-B measurements only',
        );
      }
      final entryMap = _expectMap(entry.value, 'tier-B baseline: ${entry.key}');
      final median = _expectDouble(
        entryMap['median'],
        'tier-B baseline: ${entry.key}.median',
      ).toDouble();
      final unit = _expectString(
        entryMap['unit'],
        'tier-B baseline: ${entry.key}.unit',
      );
      if (unit != budget.unit) {
        throw CheckDataException(
          'tier-B baseline: ${entry.key} carries unit "$unit" but '
          'budgets.json declares "${budget.unit}"',
        );
      }
      final repetitions = _expectInt(
        entryMap['repetitions'],
        'tier-B baseline: ${entry.key}.repetitions',
      );
      if (repetitions < 1) {
        throw CheckDataException(
          'tier-B baseline: ${entry.key}.repetitions must be >= 1',
        );
      }
      scenarios[entry.key] = BaselineEntry(
        median: median,
        unit: unit,
        repetitions: repetitions,
      );
    }
    return TierBBaseline(fingerprint, scenarios);
  }
}

class BaselineEntry {
  final double median;
  final String unit;
  final int repetitions;

  const BaselineEntry({
    required this.median,
    required this.unit,
    required this.repetitions,
  });
}

/// Drift-state store: consecutive-main-run counters per fired tier-B drift
/// notice key (e.g. `tier-b/controlled/runnerImage`, `tier-b/cpu`).
class DriftState {
  final Map<String, DriftNoticeState> notices;

  const DriftState(this.notices);

  factory DriftState.fromJson(Object? json) {
    final map = _expectMap(json, 'drift state');
    if (map['schema'] != driftStateSchemaId) {
      throw CheckDataException(
        'drift state: unsupported schema ${map['schema']} '
        '(expected $driftStateSchemaId)',
      );
    }
    final rawNotices = _expectMap(map['notices'], 'drift state: notices');
    final notices = <String, DriftNoticeState>{};
    for (final entry in rawNotices.entries) {
      final noticeMap = _expectMap(entry.value, 'drift state: ${entry.key}');
      final consecutive = _expectInt(
        noticeMap['consecutiveMainRuns'],
        'drift state: ${entry.key}.consecutiveMainRuns',
      );
      if (consecutive < 1) {
        throw CheckDataException(
          'drift state: ${entry.key}.consecutiveMainRuns must be >= 1',
        );
      }
      notices[entry.key] = DriftNoticeState(
        consecutiveMainRuns: consecutive,
        lastSeenUtc: _expectString(
          noticeMap['lastSeenUtc'],
          'drift state: ${entry.key}.lastSeenUtc',
        ),
      );
    }
    return DriftState(notices);
  }

  Map<String, Object?> toJson(String updatedUtc) => {
    'schema': driftStateSchemaId,
    'updatedUtc': updatedUtc,
    'notices': {
      for (final entry in notices.entries)
        entry.key: {
          'consecutiveMainRuns': entry.value.consecutiveMainRuns,
          'lastSeenUtc': entry.value.lastSeenUtc,
        },
    },
  };
}

class DriftNoticeState {
  final int consecutiveMainRuns;
  final String lastSeenUtc;

  const DriftNoticeState({
    required this.consecutiveMainRuns,
    required this.lastSeenUtc,
  });
}

/// Advances the drift state for one main-branch run. Keys that fired this
/// run count up (unknown prior history counts conservatively at the
/// escalation threshold — a missing state is never a reset); keys that did
/// not fire are dropped, so an intervening clean run clears the streak.
DriftState advanceDriftState(
  DriftState? prior,
  bool priorUnknown,
  Set<String> firedKeys,
  String nowUtc,
) {
  final next = <String, DriftNoticeState>{};
  for (final key in firedKeys) {
    final previous = prior?.notices[key];
    final consecutive = priorUnknown
        ? driftStaleThreshold
        : (previous?.consecutiveMainRuns ?? 0) + 1;
    next[key] = DriftNoticeState(
      consecutiveMainRuns: consecutive,
      lastSeenUtc: nowUtc,
    );
  }
  return DriftState(next);
}

/// Whether the scenario's measured median satisfies its budget, with the
/// exact boundary operator from 02 §12 (strict `<`, inclusive `<=`/`>=`).
bool satisfiesBudget(BudgetOperator operator, double value, double budget) {
  return switch (operator) {
    BudgetOperator.lessThan => value < budget,
    BudgetOperator.atMost => value <= budget,
    BudgetOperator.atLeast => value >= budget,
  };
}

/// The fraction by which [current] regressed against [baseline] in the
/// direction the operator bounds. Positive means worse; a tier-B
/// comparison fails when this strictly exceeds [tierBRegressionFraction].
double regressionFraction(
  BudgetOperator operator,
  double current,
  double baseline,
) {
  final isLowerBetter = switch (operator) {
    BudgetOperator.lessThan || BudgetOperator.atMost => true,
    BudgetOperator.atLeast => false,
  };
  if (baseline == 0) {
    // A zero baseline cannot define a ratio: any nonzero regression is
    // unbounded, exact zero is not a regression.
    if (isLowerBetter) {
      return current > 0 ? double.infinity : 0;
    }
    return current < 0 ? double.infinity : 0;
  }
  // Divide by the magnitude: a schema-valid but negative baseline must
  // keep the regression sign instead of silently flipping it.
  final delta = isLowerBetter ? current - baseline : baseline - current;
  return delta / baseline.abs();
}

/// Median of [values]; an even count averages the two central values.
double median(List<double> values) {
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

/// The evaluation report: everything the CLI prints plus the exit code it
/// must apply and the drift state a main run should persist.
class CheckReport {
  final List<String> tableLines;
  final List<String> noticeLines;
  final List<String> failureLines;

  /// The state after this run's update (main-run semantics applied); null
  /// when the invocation did not configure a drift-state store.
  final DriftState? newState;

  CheckReport()
    : tableLines = [],
      noticeLines = [],
      failureLines = [],
      newState = null;

  CheckReport._(
    this.tableLines,
    this.noticeLines,
    this.failureLines,
    this.newState,
  );

  int get exitCode => failureLines.isEmpty ? 0 : 1;
}

/// Pure evaluation over validated inputs. [tiers] is the declared set from
/// `--tiers`; [baseline] is null when the baseline file is absent;
/// [priorState] is null when no store is configured, and [priorState]
/// together with [stateUnknown] distinguishes "read a state (possibly
/// empty)" from "state missing/unreadable".
CheckReport evaluate({
  required BudgetCatalog catalog,
  required ResultsFile results,
  required Set<BenchTier> tiers,
  TierBBaseline? baseline,
  String? baselinePath,
  DriftState? priorState,
  bool stateUnknown = false,
  bool stateConfigured = true,
  required bool enforceA,
  required bool enforceB,
  required String nowUtc,
}) {
  final table = <String>[];
  final notices = <String>[];
  final failures = <String>[];
  final firedDriftKeys = <String>{};
  var comparisonsHappened = false;
  final rowsByScenario = _rowsByScenario(results);

  assert(
    !stateConfigured || stateUnknown || priorState != null,
    'stateConfigured requires priorState or stateUnknown',
  );

  // Tier-B drift is a property of the baseline vs the run, not of any
  // single scenario: evaluate it once per run so failures and notices
  // appear once per mismatching axis, never once per scenario.
  var tierBDrifted = false;
  if (tiers.contains(BenchTier.b) && baseline != null) {
    final controlled = baseline.fingerprint.controlledMismatches(
      results.fingerprint,
    );
    if (controlled.isNotEmpty) {
      tierBDrifted = true;
      for (final entry in controlled.entries) {
        firedDriftKeys.add('tier-b/controlled/${entry.key}');
        final mismatch =
            'controlled axis ${entry.key} '
            '(${entry.value.$1} != ${entry.value.$2})';
        if (enforceB) {
          failures.add(
            'tier-B baseline $mismatch while BENCH_ENFORCE_B is set — '
            'refresh the baseline via a dedicated baseline-refresh PR '
            '(08 §6)',
          );
        } else {
          notices.add(
            'NOTICE: hardware drift — recalibrate: tier-B $mismatch; '
            'baseline comparison skipped (soft mode)',
          );
        }
      }
      notices.add(
        'NOTICE: hardware drift — recalibrate: tier-B controlled-axis '
        'mismatch against the committed baseline at '
        '${baselinePath ?? '<unspecified>'}; comparison skipped, never '
        'cross-compared',
      );
      _printRefreshProcedure(notices);
    } else if (baseline.fingerprint.cpuModel != results.fingerprint.cpuModel) {
      tierBDrifted = true;
      firedDriftKeys.add('tier-b/cpu');
      notices.add(
        'NOTICE: hardware drift — refresh the baseline: tier-B CPU model '
        'mismatch (${baseline.fingerprint.cpuModel} != '
        '${results.fingerprint.cpuModel}); comparison skipped, never '
        'cross-compared and never auto-reddened on its own',
      );
      _printRefreshProcedure(notices);
    }
  }

  void tableRow(
    String scenario,
    BenchTier tier,
    String measured,
    String limit,
    String verdict,
  ) {
    table.add(
      '${scenario.padRight(9)} ${tier.name.padRight(4)} '
      '${measured.padRight(28)} ${limit.padRight(18)} $verdict',
    );
  }

  // Scope rule: expectations come only from the declared tiers' landed
  // scenarios (08 §6). Rows for other tiers are printed, not judged.
  // ResultsFile.fromJson rejects unknown ids at parse; a hand-built
  // ResultsFile (public constructor) gets the same explicit rejection
  // here rather than a null-check crash further down.
  for (final row in rowsByScenario.entries) {
    final budget = catalog.scenarios[row.key];
    if (budget == null) {
      throw CheckDataException(
        'results file: unknown scenario id ${row.key} — budgets.json '
        'must carry every scenario the harness reports (landed or not)',
      );
    }
    if (!tiers.contains(budget.tier)) {
      final measured = row.value.any((r) => r.isOk)
          ? '${row.value.length} row(s) present'
          : 'errored row(s) present';
      tableRow(
        row.key,
        budget.tier,
        measured,
        '—',
        'not evaluated (tier ${budget.tier.name} not declared)',
      );
      notices.add(
        'NOTICE: scenario ${row.key} rows present but tier '
        '${budget.tier.name} is not in --tiers; not evaluated',
      );
    }
  }

  for (final budget in _orderedScenarios(catalog)) {
    if (!tiers.contains(budget.tier) || !budget.landed) {
      continue;
    }
    final rows = rowsByScenario[budget.id] ?? const [];
    final eligible = rows
        .where(
          (row) =>
              row.isOk &&
              row.fingerprint.mode == eligibleModeByTier[budget.tier],
        )
        .toList();
    final errored = rows.where((row) => !row.isOk).toList();
    final ineligibleMode = rows
        .where(
          (row) =>
              row.isOk &&
              row.fingerprint.mode != eligibleModeByTier[budget.tier],
        )
        .toList();

    for (final row in errored) {
      notices.add(
        'NOTICE: scenario ${budget.id} repetition ${row.repetition} '
        'errored: ${row.error}',
      );
    }
    for (final row in ineligibleMode) {
      notices.add(
        'NOTICE: scenario ${budget.id} repetition ${row.repetition} '
        'measured in mode "${row.fingerprint.mode}" — tier '
        '${budget.tier.name} requires '
        '"${eligibleModeByTier[budget.tier]}"; value not compared',
      );
    }

    if (eligible.isEmpty || eligible.length < budget.minimumRepetitions) {
      // Missing, errored, or invalid observations of an expected scenario
      // fail in every mode: soft mode softens overruns only.
      String reason;
      if (rows.isEmpty) {
        reason = 'is missing from the results file';
      } else if (eligible.isEmpty && errored.isNotEmpty) {
        reason = 'has no successful observation (all errored)';
      } else if (eligible.isEmpty && ineligibleMode.isNotEmpty) {
        reason =
            'has no observation in the eligible mode '
            '"${eligibleModeByTier[budget.tier]}"';
      } else {
        reason =
            'has ${eligible.length} eligible repetition(s) but '
            '${budget.minimumRepetitions} are required';
      }
      failures.add(
        'expected scenario ${budget.id} (tier ${budget.tier.name}) $reason',
      );
      tableRow(
        budget.id,
        budget.tier,
        eligible.isEmpty ? '—' : '${eligible.length} eligible row(s)',
        budget.describeLimit(),
        'missing/invalid (fail)',
      );
      continue;
    }

    comparisonsHappened = true;
    final medianValue = median(eligible.map((row) => row.value!).toList());
    final measured =
        '${_formatNumber(medianValue)} ${budget.unit} '
        '(median of ${eligible.length})';

    if (budget.tier == BenchTier.a) {
      _evaluateTierA(
        budget: budget,
        medianValue: medianValue,
        measured: measured,
        catalog: catalog,
        results: results,
        enforceA: enforceA,
        table: table,
        notices: notices,
        failures: failures,
        tableRow: tableRow,
      );
    } else {
      _evaluateTierB(
        budget: budget,
        medianValue: medianValue,
        measured: measured,
        baseline: baseline,
        baselinePath: baselinePath,
        enforceB: enforceB,
        drifted: tierBDrifted,
        table: table,
        notices: notices,
        failures: failures,
        tableRow: tableRow,
      );
    }
  }

  // Unlanded scenarios with rows are reported without a verdict: their
  // budgets gate nothing yet and no baseline exists to trend against.
  for (final budget in _orderedScenarios(catalog)) {
    if (budget.landed || !tiers.contains(budget.tier)) {
      continue;
    }
    final rows = rowsByScenario[budget.id] ?? const [];
    if (rows.isEmpty) {
      continue;
    }
    final okCount = rows.where((row) => row.isOk).length;
    tableRow(
      budget.id,
      budget.tier,
      okCount == 0 ? 'errored row(s) present' : '$okCount ok row(s) present',
      budget.describeLimit(),
      'reported (unlanded)',
    );
    notices.add(
      'NOTICE: scenario ${budget.id} is not landed in budgets.json; its '
      'value is reported but not budget-checked',
    );
  }

  // Tier-B baseline handling for a declared tier-B scope, independent of
  // individual scenarios (the M3 spike window has no baseline at all).
  if (tiers.contains(BenchTier.b) && baseline == null) {
    notices.add(
      'NOTICE: NOT ENFORCED: no committed tier-B baseline at '
      '${baselinePath ?? '<unspecified>'} — declared tier b cannot be '
      'trend-compared',
    );
    if (enforceB) {
      failures.add(
        'tier b is declared and BENCH_ENFORCE_B is set, but the committed '
        'tier-B baseline is absent (08 §6: non-zero once the enforcement '
        'flag is set)',
      );
    }
  }

  // Drift-state time-boxing (tier-B notices only; tier-A drift skips are
  // loud but never redden, in every mode, per 08 §6).
  DriftState? newState;
  if (stateConfigured) {
    if (priorState == null && stateUnknown) {
      notices.add(
        'NOTICE: drift history unknown (state missing or unreadable): '
        'counting conservatively at the escalation threshold, never as a '
        'fresh count',
      );
    }
    newState = advanceDriftState(
      stateUnknown ? null : priorState,
      stateUnknown,
      firedDriftKeys,
      nowUtc,
    );
    final stale = newState.notices.entries
        .where(
          (entry) => entry.value.consecutiveMainRuns >= driftStaleThreshold,
        )
        .toList();
    for (final entry in stale) {
      if (enforceB) {
        failures.add(
          'baseline stale — refresh required: drift notice ${entry.key} '
          'has fired on >= $driftStaleThreshold consecutive main-branch '
          'runs',
        );
      } else {
        notices.add(
          'NOTICE: baseline nearly/already stale: drift notice '
          '${entry.key} at ${entry.value.consecutiveMainRuns} consecutive '
          'main-branch runs (red once BENCH_ENFORCE_B is set)',
        );
      }
    }
  } else if (firedDriftKeys.isNotEmpty) {
    notices.add(
      'NOTICE: no drift-state store configured (--drift-state absent); '
      'the >= $driftStaleThreshold-run staleness escalation is inactive',
    );
  }

  if (!comparisonsHappened) {
    notices.add(
      'NOTICE: no budgets were evaluated (no landed scenarios in the '
      'declared tier(s) ${tiers.map((t) => t.name).join(', ')})',
    );
  }

  return CheckReport._(table, notices, failures, newState);
}

void _evaluateTierA({
  required ScenarioBudget budget,
  required double medianValue,
  required String measured,
  required BudgetCatalog catalog,
  required ResultsFile results,
  required bool enforceA,
  required List<String> table,
  required List<String> notices,
  required List<String> failures,
  required void Function(String, BenchTier, String, String, String) tableRow,
}) {
  // Tier A compares controlled axes against the calibrated axes recorded
  // alongside budgets.json; on mismatch the budget comparison skips with
  // the loud recalibrate notice and the exit stays zero in every mode.
  // (A landed tier-A scenario always has a calibration — the catalog
  // validator rejects the alternative — so a null calibration here is
  // unreachable; the guard keeps that invariant defensive.)
  final calibrated = catalog.calibratedFingerprint;
  if (calibrated == null) {
    notices.add(
      'NOTICE: hardware drift — recalibrate: budgets.json carries no '
      'calibratedFingerprint; tier-A budget comparison skipped',
    );
    _printRefreshProcedure(notices);
    tableRow(
      budget.id,
      budget.tier,
      measured,
      budget.describeLimit(),
      'skipped: hardware drift',
    );
    return;
  }
  final mismatches = calibrated.controlledMismatches(results.fingerprint);
  if (mismatches.isNotEmpty) {
    for (final entry in mismatches.entries) {
      notices.add(
        'NOTICE: hardware drift — recalibrate: tier-A controlled axis '
        '${entry.key} (${entry.value.$1} != ${entry.value.$2}); budget '
        'comparison skipped (exit stays zero in every mode)',
      );
    }
    _printRefreshProcedure(notices);
    tableRow(
      budget.id,
      budget.tier,
      measured,
      budget.describeLimit(),
      'skipped: hardware drift',
    );
    return;
  }
  if (satisfiesBudget(budget.operator, medianValue, budget.value)) {
    tableRow(budget.id, budget.tier, measured, budget.describeLimit(), 'pass');
    return;
  }
  if (enforceA) {
    failures.add(
      'scenario ${budget.id} median ${_formatNumber(medianValue)} '
      '${budget.unit} fails budget ${budget.describeLimit()} '
      '(BENCH_ENFORCE_A set)',
    );
    tableRow(
      budget.id,
      budget.tier,
      measured,
      budget.describeLimit(),
      'overrun (fail: enforced)',
    );
  } else {
    notices.add(
      'NOTICE: scenario ${budget.id} median ${_formatNumber(medianValue)} '
      '${budget.unit} exceeds budget ${budget.describeLimit()} — not '
      'enforced (BENCH_ENFORCE_A unset)',
    );
    tableRow(
      budget.id,
      budget.tier,
      measured,
      budget.describeLimit(),
      'overrun (notice: not enforced)',
    );
  }
}

void _evaluateTierB({
  required ScenarioBudget budget,
  required double medianValue,
  required String measured,
  required TierBBaseline? baseline,
  required String? baselinePath,
  required bool enforceB,
  required bool drifted,
  required List<String> table,
  required List<String> notices,
  required List<String> failures,
  required void Function(String, BenchTier, String, String, String) tableRow,
}) {
  // Fingerprint drift against the baseline was evaluated once per run by
  // the caller (notices/failures/streak keys already emitted); here it
  // only marks the per-scenario rows.
  if (drifted) {
    tableRow(
      budget.id,
      budget.tier,
      measured,
      'baseline trend',
      'skipped: hardware drift',
    );
    return;
  }

  if (baseline == null) {
    // The tier-level absent-baseline notice and (enforced) failure are
    // emitted by the caller; per-scenario rows still show what ran.
    tableRow(
      budget.id,
      budget.tier,
      measured,
      'baseline trend',
      'skipped: no committed baseline',
    );
    return;
  }
  final entry = baseline.scenarios[budget.id];
  if (entry == null) {
    notices.add(
      'NOTICE: no committed baseline entry for ${budget.id} at '
      '${baselinePath ?? '<unspecified>'}',
    );
    if (enforceB) {
      failures.add(
        'scenario ${budget.id} is landed and enforced, but the committed '
        'tier-B baseline has no entry for it',
      );
    }
    tableRow(
      budget.id,
      budget.tier,
      measured,
      'baseline trend',
      'skipped: no baseline entry',
    );
    return;
  }
  final limit =
      'baseline ${_formatNumber(entry.median)} ${budget.unit} '
      '(fail > +${(tierBRegressionFraction * 100).toStringAsFixed(0)}%)';
  final fraction = regressionFraction(
    budget.operator,
    medianValue,
    entry.median,
  );
  if (fraction <= tierBRegressionFraction) {
    tableRow(budget.id, budget.tier, measured, limit, 'pass');
    return;
  }
  if (enforceB) {
    failures.add(
      'scenario ${budget.id} median ${_formatNumber(medianValue)} '
      '${budget.unit} regresses ${_formatRegression(fraction)} against '
      'baseline ${_formatNumber(entry.median)} ${budget.unit} '
      '(BENCH_ENFORCE_B set)',
    );
    tableRow(
      budget.id,
      budget.tier,
      measured,
      limit,
      'regression (fail: enforced)',
    );
  } else {
    notices.add(
      'NOTICE: scenario ${budget.id} median ${_formatNumber(medianValue)} '
      '${budget.unit} regresses ${_formatRegression(fraction)} against '
      'baseline ${_formatNumber(entry.median)} ${budget.unit} — not '
      'enforced (BENCH_ENFORCE_B unset)',
    );
    tableRow(
      budget.id,
      budget.tier,
      measured,
      limit,
      'regression (notice: not enforced)',
    );
  }
}

void _printRefreshProcedure(List<String> notices) {
  notices.add(
    'NOTICE: refresh procedure: open a dedicated baseline-refresh PR that '
    're-measures on the current fingerprint and updates the committed '
    'calibration/baseline; drift never auto-clears',
  );
}

Map<String, List<ResultRow>> _rowsByScenario(ResultsFile results) {
  final byScenario = <String, List<ResultRow>>{};
  for (final row in results.rows) {
    byScenario.putIfAbsent(row.scenario, () => []).add(row);
  }
  return byScenario;
}

List<ScenarioBudget> _orderedScenarios(BudgetCatalog catalog) {
  final budgets = catalog.scenarios.values.toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  return budgets;
}

String _formatNumber(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.toInt().toString();
  }
  return value.toStringAsFixed(3);
}

String _formatRegression(double fraction) {
  if (fraction.isInfinite) {
    return 'without bound';
  }
  return '${(fraction * 100).toStringAsFixed(1)}%';
}

Map<String, Object?> _expectMap(Object? json, String source) {
  if (json is! Map) {
    throw CheckDataException('$source must be a JSON object');
  }
  return json.cast<String, Object?>();
}

String _expectString(Object? value, String source) {
  if (value is! String || value.isEmpty) {
    throw CheckDataException('$source must be a non-empty string');
  }
  return value;
}

String? _expectOptionalString(Object? value, String source) {
  if (value == null) {
    return null;
  }
  return _expectString(value, source);
}

num _expectDouble(Object? value, String source) {
  if (value is! num || value.isInfinite || value.isNaN) {
    throw CheckDataException('$source must be a finite number');
  }
  return value;
}

int _expectInt(Object? value, String source) {
  if (value is! int) {
    throw CheckDataException('$source must be an integer');
  }
  return value;
}

bool _expectBool(Object? value, String source) {
  if (value is! bool) {
    throw CheckDataException('$source must be a boolean');
  }
  return value;
}
