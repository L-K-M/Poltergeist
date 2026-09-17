// Unit tests for the D12 checker's pure arithmetic and validation
// (08 §1 principle 2: the checker's logic is pure and exercised here
// without the CLI's IO; the suite's single file access is the committed
// budgets.json fixture read at the bottom of this file).
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'check.dart' show defaultBaselinePath;
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

    test('scenarioConfig is not a job-wide controlled axis', () {
      // Per-scenario config: distinct scenarios in one job may carry
      // distinct configs (08 §6's one results file), so the axis is
      // compared per scenario against that scenario's own calibration,
      // never across rows or against another scenario's config.
      expect(
        _fingerprint(
          scenarioConfig: 'p3/v1',
        ).controlledMismatches(_fingerprint()),
        isEmpty,
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

    test(
      'schema-2 rejects a landed tier-A scenario without its own '
      'calibrated config',
      () {
        expect(
          () => BudgetCatalog.fromJson({
            'schema': budgetsSchemaV2Id,
            'calibratedFingerprint': _fingerprintJson(),
            'scenarios': [_scenarioJson(landed: true)],
          }),
          throwsA(
            isA<CheckDataException>().having(
              (error) => '$error',
              'message',
              contains(
                'landed tier-A scenario P3 requires a calibratedScenarioConfig',
              ),
            ),
          ),
        );
      },
    );

    test(
      'schema-2 rejects a calibration that claims a job-wide config',
      () {
        expect(
          () => BudgetCatalog.fromJson({
            'schema': budgetsSchemaV2Id,
            'calibratedFingerprint': _fingerprintJson(
              scenarioConfig: 'p3/v1;singular',
            ),
            'scenarios': [
              _scenarioJson(landed: true, calibratedConfig: 'p3/v1;a'),
            ],
          }),
          throwsA(
            isA<CheckDataException>().having(
              (error) => '$error',
              'message',
              contains(
                'calibratedFingerprint.scenarioConfig is per-scenario in '
                'schema $budgetsSchemaV2Id',
              ),
            ),
          ),
        );
      },
    );

    test(
      'a tier-B scenario row carrying a calibrated config is rejected',
      () {
        expect(
          () => BudgetCatalog.fromJson({
            'schema': budgetsSchemaV2Id,
            'scenarios': [
              _scenarioJson(
                id: 'P1',
                tier: 'b',
                calibratedConfig: 'p1/v1;dead-data',
              ),
            ],
          }),
          throwsA(
            isA<CheckDataException>().having(
              (error) => '$error',
              'message',
              contains(
                'calibratedScenarioConfig is only valid for tier-A '
                'scenarios',
              ),
            ),
          ),
        );
      },
    );

    test(
      'schema-1 rejects the per-scenario calibrated config (mixed form)',
      () {
        expect(
          () => BudgetCatalog.fromJson({
            'schema': budgetsSchemaId,
            'scenarios': [
              _scenarioJson(calibratedConfig: 'p3/v1;a'),
            ],
          }),
          throwsA(
            isA<CheckDataException>().having(
              (error) => '$error',
              'message',
              contains('calibratedScenarioConfig requires schema '
                  '$budgetsSchemaV2Id'),
            ),
          ),
        );
      },
    );

    test(
      'schema-1 decomposes a singular calibrated config onto every '
      'tier-A scenario',
      () {
        final catalog = BudgetCatalog.fromJson({
          'schema': budgetsSchemaId,
          'calibratedFingerprint': _fingerprintJson(
            scenarioConfig: 'p3/v1;singular',
          ),
          'scenarios': [
            _scenarioJson(landed: true),
            _scenarioJson(id: 'P7', landed: true),
            _scenarioJson(id: 'P1', tier: 'b', landed: true),
          ],
        });
        catalog.validateCatalog();
        expect(catalog.schemaId, budgetsSchemaId);
        // The legacy singular config becomes each tier-A scenario's own
        // calibrated config (tier B never carries one).
        expect(
          catalog.scenarios['P3']!.calibratedScenarioConfig,
          'p3/v1;singular',
        );
        expect(
          catalog.scenarios['P7']!.calibratedScenarioConfig,
          'p3/v1;singular',
        );
        expect(catalog.scenarios['P1']!.calibratedScenarioConfig, isNull);
      },
    );

    test('schema-2 parses per-scenario calibrated configs', () {
      final catalog = BudgetCatalog.fromJson({
        'schema': budgetsSchemaV2Id,
        'calibratedFingerprint': _fingerprintJson(),
        'scenarios': [
          _scenarioJson(landed: true, calibratedConfig: 'p3/v1;a'),
          _scenarioJson(id: 'P7', landed: true, calibratedConfig: 'p7/v1;b'),
        ],
      });
      catalog.validateCatalog();
      expect(catalog.scenarios['P3']!.calibratedScenarioConfig, 'p3/v1;a');
      expect(catalog.scenarios['P7']!.calibratedScenarioConfig, 'p7/v1;b');
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

    test(
      'a job-wide axis difference across two scenarios is still rejected',
      () {
        final catalog = BudgetCatalog.fromJson({
          'schema': budgetsSchemaId,
          'scenarios': [_scenarioJson(), _scenarioJson(id: 'P5')],
        });
        expect(
          () => ResultsFile.fromJson(
            _resultsJson(
              rows: [
                _rowJson(repetition: 0),
                _rowJson(
                  scenario: 'P5',
                  repetition: 0,
                  fingerprint: _fingerprintJson(runnerImage: 'other-image'),
                ),
              ],
            ),
            catalog,
          ),
          throwsA(
            isA<CheckDataException>().having(
              (error) => '$error',
              'message',
              contains('different environment fingerprint'),
            ),
          ),
        );
      },
    );

    test(
      'rows of different tiers may carry different runtime axes',
      () {
        // The one `ab` results file of a main-branch job mixes tier-A
        // rows (standalone Dart AOT collectors, no Flutter) with tier-B
        // rows (the Flutter engine's bundled Dart, profile mode): the
        // runtime axes never agree by construction, so agreement is
        // enforced per tier while the machine axes stay job-wide.
        final catalog = BudgetCatalog.fromJson({
          'schema': budgetsSchemaId,
          'scenarios': [
            _scenarioJson(),
            _scenarioJson(id: 'P1', tier: 'b'),
          ],
        });
        final results = ResultsFile.fromJson(
          _resultsJson(
            rows: [
              _rowJson(repetition: 0),
              _rowJson(
                scenario: 'P1',
                repetition: 0,
                fingerprint: _fingerprintJson(
                  mode: 'profile',
                  dartVersion: '3.13.2-engine',
                  flutterVersion: '3.47.2',
                ),
              ),
            ],
          ),
          catalog,
        );
        expect(results.rows, hasLength(2));
        expect(results.fingerprints.keys, {BenchTier.a, BenchTier.b});
        expect(results.fingerprints[BenchTier.a]!.mode, 'aot');
        expect(results.fingerprints[BenchTier.b]!.mode, 'profile');
      },
    );

    test(
      'rows of one tier carrying different runtime axes are rejected',
      () {
        final catalog = BudgetCatalog.fromJson({
          'schema': budgetsSchemaId,
          'scenarios': [
            _scenarioJson(),
            _scenarioJson(id: 'P5'),
          ],
        });
        expect(
          () => ResultsFile.fromJson(
            _resultsJson(
              rows: [
                _rowJson(repetition: 0),
                _rowJson(
                  scenario: 'P5',
                  repetition: 0,
                  fingerprint: _fingerprintJson(mode: 'jit'),
                ),
              ],
            ),
            catalog,
          ),
          throwsA(
            isA<CheckDataException>().having(
              (error) => '$error',
              'message',
              contains('different environment fingerprint'),
            ),
          ),
        );
      },
    );

    test(
      'a machine-axis difference across tiers is still rejected',
      () {
        final catalog = BudgetCatalog.fromJson({
          'schema': budgetsSchemaId,
          'scenarios': [
            _scenarioJson(),
            _scenarioJson(id: 'P1', tier: 'b'),
          ],
        });
        expect(
          () => ResultsFile.fromJson(
            _resultsJson(
              rows: [
                _rowJson(repetition: 0),
                _rowJson(
                  scenario: 'P1',
                  repetition: 0,
                  fingerprint: _fingerprintJson(
                    mode: 'profile',
                    dartVersion: '3.13.2-engine',
                    flutterVersion: '3.47.2',
                    cpuModel: 'other-cpu',
                  ),
                ),
              ],
            ),
            catalog,
          ),
          throwsA(
            isA<CheckDataException>().having(
              (error) => '$error',
              'message',
              contains('different environment fingerprint'),
            ),
          ),
        );
      },
    );

    test(
      'repetitions of one scenario with differing configs are rejected',
      () {
        expect(
          () => ResultsFile.fromJson(
            _resultsJson(
              rows: [
                _rowJson(
                  repetition: 0,
                  fingerprint: _fingerprintJson(scenarioConfig: 'p3/v1;a'),
                ),
                _rowJson(
                  repetition: 1,
                  fingerprint: _fingerprintJson(scenarioConfig: 'p3/v1;b'),
                ),
              ],
            ),
            _catalog(),
          ),
          throwsA(
            isA<CheckDataException>().having(
              (error) => '$error',
              'message',
              contains('conflicting scenarioConfig'),
            ),
          ),
        );
      },
    );

    test(
      'distinct configs across scenarios parse into one results file',
      () {
        final catalog = BudgetCatalog.fromJson({
          'schema': budgetsSchemaId,
          'scenarios': [
            _scenarioJson(),
            _scenarioJson(id: 'P5'),
          ],
        });
        final results = ResultsFile.fromJson(
          _resultsJson(
            rows: [
              _rowJson(
                repetition: 0,
                fingerprint: _fingerprintJson(scenarioConfig: 'p3/v1;a'),
              ),
              _rowJson(
                scenario: 'P5',
                repetition: 0,
                fingerprint: _fingerprintJson(scenarioConfig: 'p5/v1;b'),
              ),
            ],
          ),
          catalog,
        );
        expect(results.rows, hasLength(2));
      },
    );

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

    test(
      'rejects a baseline that claims a job-wide scenarioConfig',
      () {
        expect(
          () => TierBBaseline.fromJson({
            'schema': baselineSchemaId,
            'fingerprint': _fingerprintJson(
              mode: 'profile',
              scenarioConfig: 'p1/v1;claimed-job-wide',
            ),
            'scenarios': {
              'P1': {'median': 95, 'unit': 'ms', 'repetitions': 3},
            },
          }, _catalog()),
          throwsA(
            isA<CheckDataException>().having(
              (error) => '$error',
              'message',
              contains(
                'tier-B baseline: fingerprint.scenarioConfig must be null',
              ),
            ),
          ),
        );
      },
    );

    test(
      'the job-wide scenarioConfig rejection holds under schema -2 too',
      () {
        expect(
          () => TierBBaseline.fromJson({
            'schema': baselineSchemaV2Id,
            'fingerprint': _fingerprintJson(
              mode: 'profile',
              scenarioConfig: 'p1/v1;claimed-job-wide',
            ),
            'scenarios': {
              'P1': {
                'median': 95,
                'unit': 'ms',
                'repetitions': 3,
                'scenarioConfig': 'p1/v1;a',
              },
            },
          }, _tierBCatalog()),
          throwsA(
            isA<CheckDataException>().having(
              (error) => '$error',
              'message',
              contains(
                'tier-B baseline: fingerprint.scenarioConfig must be null',
              ),
            ),
          ),
        );
      },
    );

    test('schema -2 entries record their per-scenario config', () {
      final baseline = TierBBaseline.fromJson({
        'schema': baselineSchemaV2Id,
        'fingerprint': _fingerprintJson(mode: 'profile'),
        'scenarios': {
          'P1': {
            'median': 95,
            'unit': 'ms',
            'repetitions': 3,
            'scenarioConfig': 'p1/v1;entries=10000',
          },
          // A recorded null is a legitimate record: the collector emits
          // no config, so the entry binds its median to config-free runs.
          'P4': {
            'median': 35,
            'unit': 'ms',
            'repetitions': 5,
            'scenarioConfig': null,
          },
        },
      }, _tierBCatalog());
      expect(baseline.schemaId, baselineSchemaV2Id);
      expect(baseline.scenarios['P1']!.scenarioConfigRecorded, isTrue);
      expect(
        baseline.scenarios['P1']!.scenarioConfig,
        'p1/v1;entries=10000',
      );
      expect(baseline.scenarios['P4']!.scenarioConfigRecorded, isTrue);
      expect(baseline.scenarios['P4']!.scenarioConfig, isNull);
    });

    test('schema -2 rejects an entry without a scenarioConfig key', () {
      // The absent key is ambiguous (unrecorded or config-free?), so a
      // -2 file must carry it explicitly — null included.
      expect(
        () => TierBBaseline.fromJson({
          'schema': baselineSchemaV2Id,
          'fingerprint': _fingerprintJson(mode: 'profile'),
          'scenarios': {
            'P1': {'median': 95, 'unit': 'ms', 'repetitions': 3},
          },
        }, _tierBCatalog()),
        throwsA(
          isA<CheckDataException>().having(
            (error) => '$error',
            'message',
            contains(
              'P1.scenarioConfig is required under schema '
              '$baselineSchemaV2Id',
            ),
          ),
        ),
      );
    });

    test('legacy schema -1 entries parse with no recorded config', () {
      final baseline = TierBBaseline.fromJson({
        'schema': baselineSchemaId,
        'fingerprint': _fingerprintJson(mode: 'profile'),
        'scenarios': {
          'P1': {'median': 95, 'unit': 'ms', 'repetitions': 3},
        },
      }, _tierBCatalog());
      expect(baseline.schemaId, baselineSchemaId);
      expect(baseline.scenarios['P1']!.scenarioConfigRecorded, isFalse);
    });

    test(
      'schema -1 rejects an entry carrying scenarioConfig (mixed form)',
      () {
        expect(
          () => TierBBaseline.fromJson({
            'schema': baselineSchemaId,
            'fingerprint': _fingerprintJson(mode: 'profile'),
            'scenarios': {
              'P1': {
                'median': 95,
                'unit': 'ms',
                'repetitions': 3,
                'scenarioConfig': 'p1/v1;a',
              },
            },
          }, _tierBCatalog()),
          throwsA(
            isA<CheckDataException>().having(
              (error) => '$error',
              'message',
              contains(
                'P1.scenarioConfig requires schema $baselineSchemaV2Id',
              ),
            ),
          ),
        );
      },
    );
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
    final results = ResultsFile(const [row], {BenchTier.a: row.fingerprint});
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

  // 02 §12 values as amended by the 2026-09-17 CI-fingerprint
  // recalibration (STATUS item 22); spec and catalog must move together.
  group('the committed budgets catalog mirrors 02 §12 as amended', () {
    test('parses with tier A landed under the recorded calibration', () {
      final catalog = _committedCatalog();
      catalog.validateCatalog();
      // The committed catalog uses the canonical per-scenario-config
      // schema; the legacy -1 form stays readable for old files.
      expect(catalog.schemaId, budgetsSchemaV2Id);
      expect(catalog.scenarios.keys, [
        'P1',
        'P2',
        'P3',
        'P4',
        'P5',
        'P6',
        'P7',
      ]);
      // Tier A landed 2026-09-17 under the owner ruling on STATUS item
      // 22: the recorded fingerprint is the one the pooled main-branch
      // bench artifacts actually carried (provenance in
      // test/benchmarks/README.md). The fingerprint pins are deliberate —
      // a recalibration must update this test in the same commit.
      final calibration = catalog.calibratedFingerprint;
      expect(calibration, isNotNull);
      expect(
        calibration!.runnerImage,
        'ubuntu-latest@20260907.300.1',
      );
      expect(calibration.arch, 'linux_x64');
      expect(
        calibration.dartVersion,
        '3.13.4 (stable) (Tue Sep 15 01:01:15 2026 -0700) '
        'on "linux_x64"',
      );
      expect(calibration.flutterVersion, isNull);
      expect(calibration.mode, 'aot');
      expect(calibration.cpuModel, 'AMD EPYC 7763 64-Core Processor');
      expect(calibration.scenarioConfig, isNull);
      // Derive the tier-A ids from the catalog and pin the set: a future
      // tier-A scenario added unlanded must fail here, not slip past a
      // remembered literal list.
      final tierAIds = catalog.scenarios.values
          .where((budget) => budget.tier == BenchTier.a)
          .map((budget) => budget.id)
          .toSet();
      expect(tierAIds, {'P3', 'P5', 'P7'});
      for (final id in tierAIds) {
        final budget = catalog.scenarios[id]!;
        expect(
          budget.landed,
          isTrue,
          reason: '$id landed with the 2026-09-17 tier-A flip',
        );
        expect(
          budget.calibratedScenarioConfig,
          isNotNull,
          reason: 'a landed tier-A scenario records the config its '
              'budget was calibrated under',
        );
      }
      for (final budget in catalog.scenarios.values) {
        if (budget.tier == BenchTier.b) {
          expect(
            budget.landed,
            isFalse,
            reason:
                '${budget.id} must stay unlanded until the real '
                'harness/job introduction (07 §1)',
          );
        }
      }
    });

    test('records the per-scenario configs the pooled artifacts carried',
        () {
      final catalog = _committedCatalog();
      // The exact strings the cited main-branch artifacts recorded;
      // check_cli_test.dart exercises comparison against them. These
      // embed the calibration machine's absolute paths, so config
      // comparison only matches an identical checkout layout until the
      // collector's config generator emits fixture-relative paths.
      expect(
        catalog.scenarios['P3']!.calibratedScenarioConfig,
        'p3/v1;target=/home/poltergeist/bench/fixtures/entries-10000;'
        'control=/home/poltergeist/bench;target-entries=10000;'
        'control-entries=2;warmups=2;repetitions=5;'
        'pairing=control-then-target-one-channel',
      );
      expect(
        catalog.scenarios['P5']!.calibratedScenarioConfig,
        'p5/v1;drop=/home/poltergeist/bench/fixtures/entries-10000;'
        'kind=directory;root-entries=10000;'
        'first-file=/home/poltergeist/bench/fixtures/entries-10000/'
        'entry-08368.txt;warmups=2;repetitions=5;start=lease+first-byte;'
        'hash=off',
      );
      expect(
        catalog.scenarios['P7']!.calibratedScenarioConfig,
        'p7/v1;root=/home/poltergeist/bench/fixtures;entries=10813;'
        'directories=10;warmups=2;repetitions=5;readdir-depth=8;'
        'traversal=recursive-pipelined-one-channel',
      );
    });

    // The values, tiers, operators, and repetition floors, one row per
    // 02 §12 budget (08 §6 assigns the tiers; 07 §3.4 sets P3's median
    // of >= 5 warm runs; 08 §6 sets the tier-B >= 3 repetition floor).
    // P3/P5 carry the 2026-09-17 CI-fingerprint recalibration (pooled
    // median × 1.2, rounded up to the next 500 ms — STATUS item 22).
    for (final entry in {
      'P1': ('b', 'lessThan', 150.0, 'ms', 3),
      'P2': ('b', 'lessThan', 1000.0, 'ms', 3),
      'P3': ('a', 'lessThan', 5500.0, 'ms', 5),
      'P4': ('b', 'lessThan', 100.0, 'ms', 3),
      'P5': ('a', 'lessThan', 6000.0, 'ms', 3),
      'P6': ('b', 'atMost', 0.2, '%', 3),
      // P7 landed unrecalibrated: the pooled median (2 280.1 entries/s)
      // clears 1 000 with 128 % headroom — the throughput equivalent of
      // the 1.2× latency margin needs only 1 899 entries/s.
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

  group('the committed tier-B baseline matches the checker contract', () {
    // The committed baseline is a real measurement record, not a fixture:
    // a file that fails this contract would turn every main-branch
    // `--tiers ab` run into an exit-65 malformed-input failure, so the
    // file's own validity is pinned here (08 §1: a rail without a test
    // is absent).
    test('parses against the committed catalog and records the tier-B '
        'runtime axes', () {
      final baseline = _committedBaseline();
      // The canonical schema records each entry's measured config.
      expect(baseline.schemaId, baselineSchemaV2Id);
      // Mode is validated per store: the baseline must carry the tier-B
      // profile runtime, never the tier-A AOT one — and the per-tier
      // runtime axis (#125) records the Flutter-bundled Dart and the
      // Flutter version, which differ from the job SDK's.
      expect(baseline.fingerprint.mode, eligibleModeByTier[BenchTier.b]);
      expect(baseline.fingerprint.flutterVersion, isNotNull);
      expect(baseline.fingerprint.dartVersion, isNotNull);
      expect(baseline.fingerprint.runnerImage, isNotNull);
      expect(baseline.fingerprint.arch, isNotNull);
      expect(baseline.fingerprint.cpuModel, isNotNull);
      // scenarioConfig is a per-scenario axis; the baseline schema
      // rejects a job-wide claim — each entry records its own instead.
      expect(baseline.fingerprint.scenarioConfig, isNull);
    });

    test('carries only tier-B scenarios with comparable medians', () {
      final catalog = _committedCatalog();
      final baseline = _committedBaseline();
      expect(baseline.scenarios, isNotEmpty);
      for (final entry in baseline.scenarios.entries) {
        final budget = catalog.scenarios[entry.key];
        expect(
          budget,
          isNotNull,
          reason: 'baseline scenario ${entry.key} must exist in the '
              'catalog',
        );
        expect(
          budget!.tier,
          BenchTier.b,
          reason: 'baseline scenario ${entry.key} must be tier-B',
        );
        expect(entry.value.unit, budget.unit);
        expect(entry.value.median.isFinite, isTrue);
        expect(entry.value.median, greaterThan(0));
        expect(
          entry.value.repetitions,
          greaterThanOrEqualTo(1),
          reason: 'a baseline median must count its observations',
        );
        expect(
          entry.value.scenarioConfigRecorded,
          isTrue,
          reason: 'a -2 baseline entry records the config its median '
              'was measured under',
        );
      }
      // Pin the exact committed set: P1/P2/P4 have honest pooled
      // medians and P6 deliberately has none (every leg errored), so a
      // fabricated P6 median — or a dropped entry — fails here. New
      // entries arrive via a baseline-refresh PR and update this pin.
      expect(
        baseline.scenarios.keys,
        unorderedEquals(['P1', 'P2', 'P4']),
      );
      // Pin values too so an edited median, repetition count, or config
      // fails alongside a dropped or fabricated entry. The configs are
      // the ones the cited main-branch artifacts actually recorded.
      expect(baseline.scenarios['P1']!.median, 1061.087);
      expect(baseline.scenarios['P1']!.repetitions, 12);
      expect(
        baseline.scenarios['P1']!.scenarioConfig,
        'local-entries-10000-first-paint',
      );
      expect(baseline.scenarios['P2']!.median, 10781.459);
      expect(baseline.scenarios['P2']!.repetitions, 12);
      expect(
        baseline.scenarios['P2']!.scenarioConfig,
        'local-entries-100000-first-paint',
      );
      expect(baseline.scenarios['P4']!.median, 35.398);
      expect(baseline.scenarios['P4']!.repetitions, 5);
      expect(
        baseline.scenarios['P4']!.scenarioConfig,
        'local-tabs-5-entries-10000-tab-switch',
      );
    });
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
  String dartVersion = '3.12.0',
  String? flutterVersion,
  String arch = 'x64',
  String? scenarioConfig,
}) => {
  'runnerImage': runnerImage,
  'arch': arch,
  'dartVersion': dartVersion,
  'flutterVersion': flutterVersion,
  'mode': mode,
  'cpuModel': cpuModel,
  'scenarioConfig': scenarioConfig,
};

Map<String, Object?> _scenarioJson({
  String id = 'P3',
  String tier = 'a',
  String operator = 'lessThan',
  bool landed = false,
  String? calibratedConfig,
}) => {
  'id': id,
  'tier': tier,
  'summary': 'synthetic test scenario',
  'operator': operator,
  'value': 50,
  'unit': 'ms',
  'minimumRepetitions': 2,
  'landed': landed,
  if (calibratedConfig != null)
    'calibratedScenarioConfig': calibratedConfig,
};

BudgetCatalog _catalog() => BudgetCatalog.fromJson({
  'schema': budgetsSchemaId,
  'scenarios': [_scenarioJson()],
});

/// A catalog that knows the tier-B scenario ids the baseline fixtures
/// use (baseline parsing validates entries against the catalog's tier).
BudgetCatalog _tierBCatalog() => BudgetCatalog.fromJson({
  'schema': budgetsSchemaId,
  'scenarios': [
    _scenarioJson(id: 'P1', tier: 'b'),
    _scenarioJson(id: 'P4', tier: 'b'),
  ],
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

// The committed tier-B baseline, read through the same parser the CLI
// uses — a file that cannot parse here would exit-65 every `--tiers b`
// invocation.
final _committedBaselineJson = File(
  defaultBaselinePath,
).readAsStringSync();

TierBBaseline? _cachedCommittedBaseline;
TierBBaseline _committedBaseline() => _cachedCommittedBaseline ??=
    TierBBaseline.fromJson(
      jsonDecode(_committedBaselineJson),
      _committedCatalog(),
    );
