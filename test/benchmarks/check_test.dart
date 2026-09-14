// Unit tests for the D12 checker's pure arithmetic and validation
// (08 §1 principle 2: the checker's logic is pure and exercised here
// without the CLI's IO; the suite's single file access is the committed
// budgets.json fixture read at the bottom of this file).
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'check_core.dart';

void main() {
  group('median', () {
    test('odd count picks the middle value', () {
      expect(median([5, 1, 3]), 3);
      expect(median([41.2, 39.0, 44.0, 38.5, 60.0]), 41.2);
    });

    test('even count averages the two central values', () {
      expect(median([1, 2, 3, 4]), 2.5);
    });

    test('single value', () {
      expect(median([7.5]), 7.5);
    });

    test('empty list is rejected', () {
      expect(() => median([]), throwsArgumentError);
    });
  });

  group('satisfiesBudget keeps the exact boundary operator', () {
    test('lessThan is strict: the budget value itself fails', () {
      expect(satisfiesBudget(BudgetOperator.lessThan, 149.9, 150), isTrue);
      expect(satisfiesBudget(BudgetOperator.lessThan, 150, 150), isFalse);
      expect(satisfiesBudget(BudgetOperator.lessThan, 150.1, 150), isFalse);
    });

    test('atMost is inclusive', () {
      expect(satisfiesBudget(BudgetOperator.atMost, 0.2, 0.2), isTrue);
      expect(satisfiesBudget(BudgetOperator.atMost, 0.2001, 0.2), isFalse);
    });

    test('atLeast is inclusive', () {
      expect(satisfiesBudget(BudgetOperator.atLeast, 1000, 1000), isTrue);
      expect(satisfiesBudget(BudgetOperator.atLeast, 999.9, 1000), isFalse);
    });
  });

  group('regressionFraction', () {
    test('lower-is-better: positive when worse, fraction of baseline', () {
      const op = BudgetOperator.lessThan;
      expect(regressionFraction(op, 125, 100), closeTo(0.25, 1e-9));
      expect(regressionFraction(op, 130, 100), closeTo(0.30, 1e-9));
      expect(regressionFraction(op, 90, 100), closeTo(-0.10, 1e-9));
    });

    test('upper-is-better (P7 shape): improvement is negative', () {
      const op = BudgetOperator.atLeast;
      expect(regressionFraction(op, 750, 1000), closeTo(0.25, 1e-9));
      expect(regressionFraction(op, 1200, 1000), closeTo(-0.20, 1e-9));
    });

    test('zero baseline cannot define a ratio', () {
      const op = BudgetOperator.lessThan;
      expect(regressionFraction(op, 0, 0), 0);
      expect(regressionFraction(op, 1, 0), double.infinity);
      const upper = BudgetOperator.atLeast;
      expect(regressionFraction(upper, 0, 0), 0);
      expect(regressionFraction(upper, -1, 0), double.infinity);
    });

    test('a negative baseline keeps the regression sign', () {
      const op = BudgetOperator.lessThan;
      // Baseline -10, current -5: -5 is worse for a lower-is-better
      // metric, so the fraction must be positive (a regression), not the
      // sign-flipped -0.5 the raw division produces.
      expect(regressionFraction(op, -5, -10), closeTo(0.5, 1e-9));
      // Current -15 is better: negative fraction (an improvement).
      expect(regressionFraction(op, -15, -10), closeTo(-0.5, 1e-9));
      // The higher-is-better branch divides by the magnitude too: -15
      // misses an atLeast target of -10 (regression), -5 clears it.
      expect(
        regressionFraction(BudgetOperator.atLeast, -15, -10),
        closeTo(0.5, 1e-9),
      );
      expect(
        regressionFraction(BudgetOperator.atLeast, -5, -10),
        closeTo(-0.5, 1e-9),
      );
    });

    test('exactly 25% is not a regression (fail on > 25%)', () {
      expect(
        regressionFraction(BudgetOperator.lessThan, 125, 100) >
            tierBRegressionFraction,
        isFalse,
      );
      expect(
        regressionFraction(BudgetOperator.lessThan, 125.001, 100) >
            tierBRegressionFraction,
        isTrue,
      );
    });
  });

  group('controlled-axis comparison', () {
    test('identical fingerprints produce no mismatches', () {
      expect(_fingerprint().controlledMismatches(_fingerprint()), isEmpty);
    });

    test('cpu model is not a controlled axis', () {
      final other = _fingerprint(cpuModel: 'other-cpu');
      expect(_fingerprint().controlledMismatches(other), isEmpty);
    });

    test('controlled mismatches name the axis and both values', () {
      final other = _fingerprint(runnerImage: 'image-2027');
      final mismatches = _fingerprint().controlledMismatches(other);
      expect(mismatches.keys, ['runnerImage']);
      expect(mismatches['runnerImage'], ('image-2026', 'image-2027'));
    });

    test('mode is validated per store, not a cross-row drift axis', () {
      // One ab job carries aot (tier A) and profile (tier B) rows in a
      // single file; mode equality is enforced through eligibility and
      // the calibration/baseline store checks, not here.
      expect(
        _fingerprint(
          mode: 'aot',
        ).controlledMismatches(_fingerprint(mode: 'profile')),
        isEmpty,
      );
    });

    test('optional axes participate (empty vs value)', () {
      expect(
        _fingerprint(
          scenarioConfig: 'p3-v1',
        ).controlledMismatches(_fingerprint()),
        containsPair('scenarioConfig', ('p3-v1', '')),
      );
    });
  });

  group('advanceDriftState', () {
    test('unknown history counts conservatively at the threshold, not 1', () {
      final next = advanceDriftState(
        null,
        true,
        {'tier-b/cpu'},
        'now',
        mayReset: false,
      );
      expect(
        next.notices['tier-b/cpu']!.consecutiveMainRuns,
        driftStaleThreshold,
      );
    });

    test('a fired key increments its prior streak', () {
      final prior = DriftState({
        'tier-b/cpu': const DriftNoticeState(
          consecutiveMainRuns: 6,
          lastSeenUtc: 'earlier',
        ),
      });
      final next = advanceDriftState(
        prior,
        false,
        {'tier-b/cpu'},
        'now',
        mayReset: false,
      );
      expect(next.notices['tier-b/cpu']!.consecutiveMainRuns, 7);
    });

    test('a new key starts at 1 when history is known', () {
      final next = advanceDriftState(
        const DriftState({}),
        false,
        {'tier-b/controlled/runnerImage'},
        'now',
        mayReset: false,
      );
      expect(
        next.notices['tier-b/controlled/runnerImage']!.consecutiveMainRuns,
        1,
      );
    });

    test('an intervening run without the notice drops the streak', () {
      final prior = DriftState({
        'tier-b/cpu': const DriftNoticeState(
          consecutiveMainRuns: 6,
          lastSeenUtc: 'earlier',
        ),
      });
      final next = advanceDriftState(
        prior,
        false,
        {'other-key'},
        'now',
        mayReset: true,
      );
      expect(next.notices.containsKey('tier-b/cpu'), isFalse);
    });

    test('a clean run clears every streak', () {
      final prior = DriftState({
        'tier-b/cpu': const DriftNoticeState(
          consecutiveMainRuns: 3,
          lastSeenUtc: 'earlier',
        ),
      });
      final next = advanceDriftState(
        prior,
        false,
        const {},
        'now',
        mayReset: true,
      );
      expect(next.notices, isEmpty);

      // Without reset eligibility the prior streak survives verbatim:
      // only a clean, observed main run may clear it.
      final preserved = advanceDriftState(
        prior,
        false,
        const {},
        'now',
        mayReset: false,
      );
      expect(
        preserved.notices['tier-b/cpu']!.consecutiveMainRuns,
        3,
        reason: 'a non-clean run preserves prior streaks',
      );
    });
  });

  group('budgets.json validation', () {
    test('rejects an unknown schema', () {
      expect(
        () => BudgetCatalog.fromJson({
          'schema': 'something-else',
          'scenarios': [_scenarioJson()],
        }),
        throwsA(isA<CheckDataException>()),
      );
    });

    test('rejects duplicate scenario ids', () {
      expect(
        () => BudgetCatalog.fromJson({
          'schema': budgetsSchemaId,
          'scenarios': [_scenarioJson(), _scenarioJson()],
        }),
        throwsA(
          isA<CheckDataException>().having(
            (error) => '$error',
            'message',
            contains('duplicate scenario id'),
          ),
        ),
      );
    });

    test('rejects a landed tier-A scenario without calibration', () {
      expect(
        () => BudgetCatalog.fromJson({
          'schema': budgetsSchemaId,
          'scenarios': [_scenarioJson(landed: true)],
        }).validateCatalog(),
        throwsA(
          isA<CheckDataException>().having(
            (error) => '$error',
            'message',
            contains('requires a calibratedFingerprint'),
          ),
        ),
      );
    });

    test('a landed tier-A scenario with calibration validates', () {
      final catalog = BudgetCatalog.fromJson({
        'schema': budgetsSchemaId,
        'calibratedFingerprint': _fingerprintJson(),
        'scenarios': [_scenarioJson(landed: true)],
      });
      catalog.validateCatalog();
      expect(catalog.scenarios['P3']!.landed, isTrue);
    });

    test('rejects a calibration quoted in a non-AOT mode', () {
      expect(
        () => BudgetCatalog.fromJson({
          'schema': budgetsSchemaId,
          'calibratedFingerprint': _fingerprintJson(mode: 'profile'),
          'scenarios': [_scenarioJson()],
        }).validateCatalog(),
        throwsA(
          isA<CheckDataException>().having(
            (error) => '$error',
            'message',
            contains('calibratedFingerprint.mode must be "aot"'),
          ),
        ),
      );
    });

    test('accepts a landed tier-B scenario without calibration', () {
      // Tier B trends against the committed baseline, not the calibration.
      final catalog = BudgetCatalog.fromJson({
        'schema': budgetsSchemaId,
        'scenarios': [_scenarioJson(id: 'P1', tier: 'b', landed: true)],
      });
      catalog.validateCatalog();
    });

    test('rejects unknown operator and tier values', () {
      expect(
        () => BudgetCatalog.fromJson({
          'schema': budgetsSchemaId,
          'scenarios': [_scenarioJson(operator: 'under')],
        }),
        throwsA(isA<CheckDataException>()),
      );
      expect(
        () => BudgetCatalog.fromJson({
          'schema': budgetsSchemaId,
          'scenarios': [_scenarioJson(tier: 'c')],
        }),
        throwsA(isA<CheckDataException>()),
      );
    });
  });

  group('results-file validation', () {
    test('rejects an unknown scenario id', () {
      expect(
        () => ResultsFile.fromJson(
          _resultsJson(rows: [_rowJson(scenario: 'P99')]),
          _catalog(),
        ),
        throwsA(
          isA<CheckDataException>().having(
            (error) => '$error',
            'message',
            contains('unknown scenario id P99'),
          ),
        ),
      );
    });

    test('rejects duplicate (scenario, repetition) observations', () {
      expect(
        () => ResultsFile.fromJson(
          _resultsJson(
            rows: [_rowJson(repetition: 0), _rowJson(repetition: 0)],
          ),
          _catalog(),
        ),
        throwsA(
          isA<CheckDataException>().having(
            (error) => '$error',
            'message',
            contains('duplicate observation'),
          ),
        ),
      );
    });

    test('rejects a unit that disagrees with the catalog', () {
      expect(
        () => ResultsFile.fromJson(
          _resultsJson(rows: [_rowJson(unit: 's')]),
          _catalog(),
        ),
        throwsA(
          isA<CheckDataException>().having(
            (error) => '$error',
            'message',
            contains('incompatible units'),
          ),
        ),
      );
    });

    test('rejects rows carrying two different fingerprints', () {
      expect(
        () => ResultsFile.fromJson(
          _resultsJson(
            rows: [
              _rowJson(repetition: 0),
              _rowJson(
                repetition: 1,
                fingerprint: _fingerprintJson(runnerImage: 'other-image'),
              ),
            ],
          ),
          _catalog(),
        ),
        throwsA(
          isA<CheckDataException>().having(
            (error) => '$error',
            'message',
            contains('different environment fingerprint'),
          ),
        ),
      );
    });

    test('rejects an errored row that also carries a value', () {
      expect(
        () => ResultsFile.fromJson(
          _resultsJson(
            rows: [
              {
                'scenario': 'P3',
                'repetition': 0,
                'status': 'error',
                'error': 'boom',
                'value': 1,
                'fingerprint': _fingerprintJson(),
              },
            ],
          ),
          _catalog(),
        ),
        throwsA(
          isA<CheckDataException>().having(
            (error) => '$error',
            'message',
            contains('errored but carries a value'),
          ),
        ),
      );
    });

    test('rejects an ok row without a finite value', () {
      expect(
        () => ResultsFile.fromJson(
          _resultsJson(rows: [_rowJson(value: 'fast')]),
          _catalog(),
        ),
        throwsA(isA<CheckDataException>()),
      );
    });
  });

  group('tier-B baseline validation', () {
    test('rejects a tier-A scenario entry', () {
      expect(
        () => TierBBaseline.fromJson({
          'schema': baselineSchemaId,
          'fingerprint': _fingerprintJson(mode: 'profile'),
          'scenarios': {
            'P3': {'median': 40, 'unit': 'ms', 'repetitions': 5},
          },
        }, _catalog()),
        throwsA(
          isA<CheckDataException>().having(
            (error) => '$error',
            'message',
            contains('baseline stores tier-B measurements only'),
          ),
        ),
      );
    });

    test('rejects a baseline quoted outside profile mode', () {
      expect(
        () => TierBBaseline.fromJson({
          'schema': baselineSchemaId,
          'fingerprint': _fingerprintJson(mode: 'aot'),
          'scenarios': const <String, Object?>{},
        }, _catalog()),
        throwsA(
          isA<CheckDataException>().having(
            (error) => '$error',
            'message',
            contains('fingerprint.mode must be "profile"'),
          ),
        ),
      );
    });

    test('rejects a unit that disagrees with the catalog', () {
      expect(
        () => TierBBaseline.fromJson({
          'schema': baselineSchemaId,
          'fingerprint': _fingerprintJson(),
          'scenarios': {
            'P1': {'median': 95, 'unit': 's', 'repetitions': 3},
          },
        }, _catalog()),
        throwsA(isA<CheckDataException>()),
      );
    });
  });

  group('drift-state parsing', () {
    test('round-trips through JSON', () {
      final state = DriftState.fromJson(
        jsonDecode(
          jsonEncode(
            const DriftState({
              'tier-b/cpu': DriftNoticeState(
                consecutiveMainRuns: 2,
                lastSeenUtc: '2026-09-14T00:00:00Z',
              ),
            }).toJson('now'),
          ),
        ),
      );
      expect(state.notices['tier-b/cpu']!.consecutiveMainRuns, 2);
    });

    test('rejects an unknown schema (treated as unreadable by the CLI)', () {
      expect(
        () => DriftState.fromJson({'schema': 'nope'}),
        throwsA(isA<CheckDataException>()),
      );
    });

    test('rejects a non-positive streak', () {
      expect(
        () => DriftState.fromJson({
          'schema': driftStateSchemaId,
          'notices': {
            'tier-b/cpu': {'consecutiveMainRuns': 0, 'lastSeenUtc': 'now'},
          },
        }),
        throwsA(isA<CheckDataException>()),
      );
    });
  });

  test('evaluate rejects results rows absent from the catalog', () {
    // ResultsFile.fromJson already rejects unknown ids at parse; this
    // pins the same contract for a hand-built ResultsFile (the public
    // constructor), so no path can reach a null-check crash instead.
    final catalog = _catalog();
    const row = ResultRow(
      scenario: 'P99',
      repetition: 0,
      isOk: true,
      value: 1,
      unit: 'ms',
      fingerprint: BenchFingerprint(
        runnerImage: 'r',
        arch: 'x64',
        dartVersion: '3',
        flutterVersion: null,
        mode: 'aot',
        cpuModel: 'c',
        scenarioConfig: null,
      ),
    );
    final results = ResultsFile(const [row], row.fingerprint);
    expect(
      () => evaluate(
        catalog: catalog,
        results: results,
        tiers: const {BenchTier.a},
        stateConfigured: false,
        runKind: DriftRunKind.readOnly,
        enforceA: false,
        enforceB: false,
        nowUtc: '2026-09-14T00:00:00Z',
      ),
      throwsA(
        isA<CheckDataException>().having(
          (error) => '$error',
          'message',
          contains('unknown scenario id P99'),
        ),
      ),
    );
  });

  group('the committed budgets catalog mirrors 02 §12', () {
    test('parses and carries P1-P7 unlanded with no calibration', () {
      final catalog = _committedCatalog();
      catalog.validateCatalog();
      expect(catalog.calibratedFingerprint, isNull);
      expect(catalog.scenarios.keys, [
        'P1',
        'P2',
        'P3',
        'P4',
        'P5',
        'P6',
        'P7',
      ]);
      for (final budget in catalog.scenarios.values) {
        expect(
          budget.landed,
          isFalse,
          reason:
              '${budget.id} must stay unlanded until the real '
              'harness/job introduction (07 §1)',
        );
      }
    });

    // The values, tiers, operators, and repetition floors, one row per
    // 02 §12 budget (08 §6 assigns the tiers; 07 §3.4 sets P3's median
    // of >= 5 warm runs; 08 §6 sets the tier-B >= 3 repetition floor).
    for (final entry in {
      'P1': ('b', 'lessThan', 150.0, 'ms', 3),
      'P2': ('b', 'lessThan', 1000.0, 'ms', 3),
      'P3': ('a', 'lessThan', 50.0, 'ms', 5),
      'P4': ('b', 'lessThan', 100.0, 'ms', 3),
      'P5': ('a', 'lessThan', 500.0, 'ms', 3),
      'P6': ('b', 'atMost', 0.2, '%', 3),
      'P7': ('a', 'atLeast', 1000.0, 'entries/s', 3),
    }.entries) {
      test('${entry.key} mirrors 02 §12', () {
        final catalog = _committedCatalog();
        final budget = catalog.scenarios[entry.key]!;
        final (tier, operator, value, unit, minReps) = entry.value;
        expect(budget.tier.name, tier);
        expect(budget.operator.name, operator);
        expect(budget.value, value);
        expect(budget.unit, unit);
        expect(budget.minimumRepetitions, minReps);
      });
    }
  });
}

BenchFingerprint _fingerprint({
  String runnerImage = 'image-2026',
  String mode = 'aot',
  String cpuModel = 'test-cpu',
  String? scenarioConfig,
}) => BenchFingerprint.fromJson(
  _fingerprintJson(
    runnerImage: runnerImage,
    mode: mode,
    cpuModel: cpuModel,
    scenarioConfig: scenarioConfig,
  ),
  'test',
);

Map<String, Object?> _fingerprintJson({
  String runnerImage = 'image-2026',
  String mode = 'aot',
  String cpuModel = 'test-cpu',
  String? scenarioConfig,
}) => {
  'runnerImage': runnerImage,
  'arch': 'x64',
  'dartVersion': '3.12.0',
  'flutterVersion': null,
  'mode': mode,
  'cpuModel': cpuModel,
  'scenarioConfig': scenarioConfig,
};

Map<String, Object?> _scenarioJson({
  String id = 'P3',
  String tier = 'a',
  String operator = 'lessThan',
  bool landed = false,
}) => {
  'id': id,
  'tier': tier,
  'summary': 'synthetic test scenario',
  'operator': operator,
  'value': 50,
  'unit': 'ms',
  'minimumRepetitions': 2,
  'landed': landed,
};

BudgetCatalog _catalog() => BudgetCatalog.fromJson({
  'schema': budgetsSchemaId,
  'scenarios': [_scenarioJson()],
});

Map<String, Object?> _resultsJson({required List<Map<String, Object?>> rows}) =>
    {'schema': resultsSchemaId, 'rows': rows};

Map<String, Object?> _rowJson({
  String scenario = 'P3',
  int repetition = 0,
  String status = 'ok',
  Object? value = 40,
  String unit = 'ms',
  String? error,
  Map<String, Object?>? fingerprint,
}) => {
  'scenario': scenario,
  'repetition': repetition,
  'status': status,
  if (status == 'ok') ...{'value': value, 'unit': unit},
  if (error != null) 'error': error,
  'fingerprint': fingerprint ?? _fingerprintJson(),
};

// Loaded lazily so a missing or edited catalog file fails loudly here.
final _committedBudgetsJson = File(
  'test/benchmarks/budgets.json',
).readAsStringSync();

BudgetCatalog? _cachedCommittedCatalog;
BudgetCatalog _committedCatalog() => _cachedCommittedCatalog ??=
    BudgetCatalog.fromJson(jsonDecode(_committedBudgetsJson));
