// CLI-level tests for the D12 checker (test/benchmarks/check.dart).
//
// Every fixture is synthetic and lives in a per-test temp directory —
// never in the production baseline paths (no fabricated calibrated
// fingerprints, baselines, or measurements are ever committed). The bulk
// of the battery runs [checkMain] in-process against those temp files
// with a memory sink and the process-global exitCode asserted and reset;
// a subprocess battery pins the real process contract (argument parsing,
// stdout/stderr wiring, exit status).
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'check.dart';
import 'check_core.dart';

void main() {
  late Directory tempDir;
  late MemorySink out;
  late MemorySink err;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('poltergeist-d12-check-');
    out = MemorySink();
    err = MemorySink();
  });

  tearDown(() async {
    exitCode = 0;
    await tempDir.delete(recursive: true);
  });

  Future<String> writeFixture(String name, Object? json) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsString(jsonEncode(json));
    return file.path;
  }

  String pathOf(String name) => '${tempDir.path}/$name';

  /// Runs the CLI in-process with temp-file fixtures and returns the
  /// captured (exit, stdout, stderr).
  Future<(int, String, String)> runChecker({
    List<String> arguments = const [],
    Map<String, String> environment = const {},
  }) async {
    exitCode = 0;
    out.clear();
    err.clear();
    await checkMain(arguments, out: out, err: err, environment: environment);
    return (exitCode, out.text, err.text);
  }

  test('usage errors exit 64 with the usage text on stderr', () async {
    final (exitCodeValue, stdoutText, stderrText) = await runChecker(
      arguments: ['--tiers', 'a'],
    );
    expect(exitCodeValue, 64);
    expect(stderrText, contains('--results is required'));
    expect(stderrText, contains('Usage: dart run test/benchmarks/check.dart'));
    expect(stdoutText, isEmpty);
  });

  test(
    'a bad enforcement value fails closed instead of reading as off',
    () async {
      final results = await writeFixture(
        'results.json',
        _resultsJson(rows: [_rowJson()]),
      );
      final (exitCodeValue, _, stderrText) = await runChecker(
        arguments: ['--results', results, '--tiers', 'a'],
        environment: {'BENCH_ENFORCE_A': 'yes'},
      );
      expect(exitCodeValue, 64);
      expect(stderrText, contains('BENCH_ENFORCE_A must be 0/1/true/false'));
    },
  );

  test('malformed budgets exit 65; unreadable files exit 74', () async {
    final results = await writeFixture(
      'results.json',
      _resultsJson(rows: [_rowJson()]),
    );
    final badBudgets = await writeFixture('budgets.json', {'schema': 'x'});
    var (exitCodeValue, _, stderrText) = await runChecker(
      arguments: [
        '--results',
        results,
        '--tiers',
        'a',
        '--budgets',
        badBudgets,
      ],
    );
    expect(exitCodeValue, 65);
    expect(stderrText, contains('unsupported schema'));

    (exitCodeValue, _, stderrText) = await runChecker(
      arguments: ['--results', pathOf('missing-results.json'), '--tiers', 'a'],
    );
    expect(exitCodeValue, 74);
    expect(stderrText, isNotEmpty);
  });

  test('declared tier with no landed scenarios prints that no budgets were '
      'evaluated', () async {
    final budgets = await writeFixture('budgets.json', _budgetsJson());
    final results = await writeFixture(
      'results.json',
      _resultsJson(rows: [_rowJson()]),
    );
    final (exitCodeValue, stdoutText, _) = await runChecker(
      arguments: ['--results', results, '--tiers', 'a', '--budgets', budgets],
    );
    expect(exitCodeValue, 0);
    expect(stdoutText, contains('no budgets were evaluated'));
    expect(stdoutText, contains('reported (unlanded)'));
  });

  test(
    'a passing tier-A scenario with a matching calibration passes',
    () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(calibrated: _fingerprintJson(), landedIds: {'P3'}),
      );
      final results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 5; i++) _rowJson(repetition: i, value: 40 + i),
          ],
        ),
      );
      final (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', results, '--tiers', 'a', '--budgets', budgets],
        environment: {'BENCH_ENFORCE_A': '1'},
      );
      expect(exitCodeValue, 0, reason: stdoutText);
      expect(stdoutText, contains('pass'));
      // The median of 40..44 is 42.
      expect(stdoutText, contains('42 ms (median of 5)'));
    },
  );

  test(
    'an enforced overrun fails; a soft overrun notices and exits zero',
    () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(calibrated: _fingerprintJson(), landedIds: {'P3'}),
      );
      final slow = await writeFixture(
        'slow.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 5; i++) _rowJson(repetition: i, value: 60),
          ],
        ),
      );
      var (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', slow, '--tiers', 'a', '--budgets', budgets],
      );
      expect(exitCodeValue, 0);
      expect(stdoutText, contains('overrun (notice: not enforced)'));
      expect(stdoutText, contains('60 ms (median of 5)'));

      (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', slow, '--tiers', 'a', '--budgets', budgets],
        environment: {'BENCH_ENFORCE_A': '1'},
      );
      expect(exitCodeValue, 1);
      expect(stdoutText, contains('FAIL: scenario P3'));
      expect(stdoutText, contains('overrun (fail: enforced)'));
    },
  );

  test(
    'the exact budget boundary honors the operator (P3 < 50 ms strict)',
    () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(calibrated: _fingerprintJson(), landedIds: {'P3'}),
      );
      final atBoundary = await writeFixture(
        'boundary.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 5; i++) _rowJson(repetition: i, value: 50),
          ],
        ),
      );
      final (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: [
          '--results',
          atBoundary,
          '--tiers',
          'a',
          '--budgets',
          budgets,
        ],
        environment: {'BENCH_ENFORCE_A': '1'},
      );
      expect(exitCodeValue, 1, reason: 'a 50 ms median does not satisfy < 50');
      expect(stdoutText, contains('overrun (fail: enforced)'));
    },
  );

  test(
    'expected scenarios missing/errored/too-few fail even while soft',
    () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(calibrated: _fingerprintJson(), landedIds: {'P3'}),
      );

      // Missing entirely.
      final empty = await writeFixture(
        'empty.json',
        _resultsJson(
          rows: [_rowJson(scenario: 'P5', repetition: 0, unit: 'ms')],
        ),
      );
      var (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', empty, '--tiers', 'a', '--budgets', budgets],
      );
      expect(exitCodeValue, 1);
      expect(stdoutText, contains('FAIL: expected scenario P3'));
      expect(stdoutText, contains('is missing from the results file'));

      // All repetitions errored.
      final errored = await writeFixture(
        'errored.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 5; i++)
              _rowJson(repetition: i, status: 'error', error: 'fixture died'),
          ],
        ),
      );
      (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', errored, '--tiers', 'a', '--budgets', budgets],
      );
      expect(exitCodeValue, 1);
      expect(stdoutText, contains('all errored'));
      expect(stdoutText, contains('repetition 0 errored: fixture died'));

      // Only 2 of the required 5 repetitions.
      final few = await writeFixture(
        'few.json',
        _resultsJson(
          rows: [for (var i = 0; i < 2; i++) _rowJson(repetition: i)],
        ),
      );
      (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', few, '--tiers', 'a', '--budgets', budgets],
      );
      expect(exitCodeValue, 1);
      expect(
        stdoutText,
        contains(
          '2 eligible repetition(s) but 5 are '
          'required',
        ),
      );
    },
  );

  test(
    'debug/JIT-mode observations never count as eligible tier-A reps',
    () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(calibrated: _fingerprintJson(), landedIds: {'P3'}),
      );
      final results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 5; i++)
              _rowJson(
                repetition: i,
                fingerprint: _fingerprintJson(mode: 'jit'),
              ),
          ],
        ),
      );
      final (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', results, '--tiers', 'a', '--budgets', budgets],
        environment: {'BENCH_ENFORCE_A': '1'},
      );
      expect(exitCodeValue, 1);
      expect(
        stdoutText,
        contains('measured in mode "jit" — tier a requires "aot"'),
      );
      expect(stdoutText, contains('no observation in the eligible mode'));
    },
  );

  test('tier-A controlled-axis drift skips with a recalibrate notice and '
      'exit zero in every mode', () async {
    final budgets = await writeFixture(
      'budgets.json',
      _budgetsJson(
        calibrated: _fingerprintJson(runnerImage: 'image-2026'),
        landedIds: {'P3'},
      ),
    );
    final results = await writeFixture(
      'results.json',
      _resultsJson(
        rows: [
          for (var i = 0; i < 5; i++)
            _rowJson(
              repetition: i,
              fingerprint: _fingerprintJson(runnerImage: 'image-2027'),
            ),
        ],
      ),
    );
    for (final environment in [
      const <String, String>{},
      const {'BENCH_ENFORCE_A': '1'},
    ]) {
      final (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', results, '--tiers', 'a', '--budgets', budgets],
        environment: environment,
      );
      expect(exitCodeValue, 0, reason: 'tier-A drift never reddens');
      expect(stdoutText, contains('hardware drift — recalibrate'));
      expect(
        stdoutText,
        contains('controlled axis runnerImage (image-2026 != image-2027)'),
      );
      expect(stdoutText, contains('skipped: hardware drift'));
      expect(stdoutText, contains('baseline-refresh PR'));
    }
  });

  test('rows for an undeclared tier are reported, not judged', () async {
    final budgets = await writeFixture(
      'budgets.json',
      _budgetsJson(calibrated: _fingerprintJson(), landedIds: {'P3', 'P1'}),
    );
    final results = await writeFixture(
      'results.json',
      _resultsJson(
        rows: [
          ...[for (var i = 0; i < 5; i++) _rowJson(repetition: i)],
          _rowJson(
            scenario: 'P1',
            repetition: 0,
            unit: 'ms',
            fingerprint: _fingerprintJson(mode: 'profile'),
          ),
        ],
      ),
    );
    final (exitCodeValue, stdoutText, _) = await runChecker(
      arguments: ['--results', results, '--tiers', 'a', '--budgets', budgets],
    );
    expect(exitCodeValue, 0, reason: stdoutText);
    expect(stdoutText, contains('not evaluated (tier b not declared)'));
  });

  test(
    'an absent tier-B baseline is loud, soft-zero, enforced-nonzero',
    () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(landedIds: {'P1'}),
      );
      final results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 3; i++)
              _rowJson(
                scenario: 'P1',
                repetition: i,
                unit: 'ms',
                fingerprint: _fingerprintJson(mode: 'profile'),
              ),
          ],
        ),
      );

      var (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: [
          '--results',
          results,
          '--tiers',
          'b',
          '--budgets',
          budgets,
          '--baseline',
          pathOf('absent-baseline.json'),
        ],
      );
      expect(exitCodeValue, 0);
      expect(
        stdoutText,
        contains(
          'NOT ENFORCED: no committed tier-B '
          'baseline',
        ),
      );
      expect(stdoutText, contains('skipped: no committed baseline'));

      (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: [
          '--results',
          results,
          '--tiers',
          'b',
          '--budgets',
          budgets,
          '--baseline',
          pathOf('absent-baseline.json'),
        ],
        environment: {'BENCH_ENFORCE_B': '1'},
      );
      expect(exitCodeValue, 1);
      expect(
        stdoutText,
        contains(
          'FAIL: tier b is declared and '
          'BENCH_ENFORCE_B is set',
        ),
      );
    },
  );

  test(
    'tier-B trend: exactly +25% passes, more regresses once enforced',
    () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(landedIds: {'P1'}),
      );
      final baseline = await writeFixture('baseline.json', _baselineJson());
      // Baseline median 100; exactly 125 is not a regression (> 25% only).
      final atBoundary = await writeFixture(
        'boundary.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 3; i++)
              _rowJson(
                scenario: 'P1',
                repetition: i,
                value: 125,
                unit: 'ms',
                fingerprint: _fingerprintJson(mode: 'profile'),
              ),
          ],
        ),
      );
      var (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: [
          '--results',
          atBoundary,
          '--tiers',
          'b',
          '--budgets',
          budgets,
          '--baseline',
          baseline,
        ],
        environment: {'BENCH_ENFORCE_B': '1'},
      );
      expect(exitCodeValue, 0, reason: stdoutText);
      expect(stdoutText, contains('pass'));

      final over = await writeFixture(
        'over.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 3; i++)
              _rowJson(
                scenario: 'P1',
                repetition: i,
                value: 126,
                unit: 'ms',
                fingerprint: _fingerprintJson(mode: 'profile'),
              ),
          ],
        ),
      );
      (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: [
          '--results',
          over,
          '--tiers',
          'b',
          '--budgets',
          budgets,
          '--baseline',
          baseline,
        ],
      );
      expect(exitCodeValue, 0);
      expect(stdoutText, contains('regression (notice: not enforced)'));

      (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: [
          '--results',
          over,
          '--tiers',
          'b',
          '--budgets',
          budgets,
          '--baseline',
          baseline,
        ],
        environment: {'BENCH_ENFORCE_B': '1'},
      );
      expect(exitCodeValue, 1);
      expect(stdoutText, contains('regression (fail: enforced)'));
      expect(stdoutText, contains('regresses 26.0% against baseline 100'));
    },
  );

  test(
    'tier-B controlled-axis mismatch is soft-zero and enforced-nonzero',
    () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(landedIds: {'P1'}),
      );
      final baseline = await writeFixture(
        'baseline.json',
        _baselineJson(runnerImage: 'image-2026'),
      );
      final results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 3; i++)
              _rowJson(
                scenario: 'P1',
                repetition: i,
                unit: 'ms',
                fingerprint: _fingerprintJson(
                  mode: 'profile',
                  runnerImage: 'image-2027',
                ),
              ),
          ],
        ),
      );
      var (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: [
          '--results',
          results,
          '--tiers',
          'b',
          '--budgets',
          budgets,
          '--baseline',
          baseline,
        ],
      );
      expect(exitCodeValue, 0);
      expect(stdoutText, contains('hardware drift — recalibrate'));
      expect(stdoutText, contains('skipped: hardware drift'));
      expect(stdoutText, contains('never cross-compared'));

      (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: [
          '--results',
          results,
          '--tiers',
          'b',
          '--budgets',
          budgets,
          '--baseline',
          baseline,
        ],
        environment: {'BENCH_ENFORCE_B': '1'},
      );
      expect(exitCodeValue, 1);
      expect(
        stdoutText,
        contains('FAIL: tier-B baseline controlled axis runnerImage'),
      );
    },
  );

  test('a landed tier-B scenario missing from the baseline fails only when '
      'enforced', () async {
    final budgets = await writeFixture(
      'budgets.json',
      _budgetsJson(landedIds: {'P4'}),
    );
    final baseline = await writeFixture('baseline.json', _baselineJson());
    final results = await writeFixture(
      'results.json',
      _resultsJson(
        rows: [
          for (var i = 0; i < 3; i++)
            _rowJson(
              scenario: 'P4',
              repetition: i,
              value: 80,
              unit: 'ms',
              fingerprint: _fingerprintJson(mode: 'profile'),
            ),
        ],
      ),
    );
    var (exitCodeValue, stdoutText, _) = await runChecker(
      arguments: [
        '--results',
        results,
        '--tiers',
        'b',
        '--budgets',
        budgets,
        '--baseline',
        baseline,
      ],
    );
    expect(exitCodeValue, 0);
    expect(stdoutText, contains('no committed baseline entry for P4'));

    (exitCodeValue, stdoutText, _) = await runChecker(
      arguments: [
        '--results',
        results,
        '--tiers',
        'b',
        '--budgets',
        budgets,
        '--baseline',
        baseline,
      ],
      environment: {'BENCH_ENFORCE_B': '1'},
    );
    expect(exitCodeValue, 1);
    expect(stdoutText, contains('no entry for it'));
  });

  group('drift-state progression (tier-B CPU axis)', () {
    test('six runs stay green, the seventh reddens once enforced, and a '
        'clean run resets', () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(landedIds: {'P1'}),
      );
      final baseline = await writeFixture(
        'baseline.json',
        _baselineJson(cpuModel: 'baseline-cpu'),
      );
      final results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 3; i++)
              _rowJson(
                scenario: 'P1',
                repetition: i,
                unit: 'ms',
                fingerprint: _fingerprintJson(
                  mode: 'profile',
                  cpuModel: 'new-cpu',
                ),
              ),
          ],
        ),
      );
      final statePath = pathOf('drift-state.json');
      // A prior clean main run's state: the progression below then counts
      // 1..6 on known history (a missing state would count conservatively
      // at the threshold instead — its own test covers that behavior).
      await File(statePath).writeAsString(
        jsonEncode(const DriftState({}).toJson('2026-09-14T00:00:00Z')),
      );

      for (var run = 1; run < driftStaleThreshold; run++) {
        final (exitCodeValue, stdoutText, _) = await runChecker(
          arguments: [
            '--results',
            results,
            '--tiers',
            'b',
            '--budgets',
            budgets,
            '--baseline',
            baseline,
            '--drift-state',
            statePath,
            '--update-drift-state',
          ],
          environment: {'BENCH_ENFORCE_B': '1'},
        );
        expect(exitCodeValue, 0, reason: 'run $run must not redden');
        expect(
          stdoutText,
          contains(
            'hardware drift — refresh the '
            'baseline',
          ),
        );
        final state = DriftState.fromJson(
          jsonDecode(await File(statePath).readAsString()),
        );
        expect(
          state.notices['tier-b/cpu']!.consecutiveMainRuns,
          run,
          reason: 'run $run must count up',
        );
      }

      // The seventh consecutive drift run reddens.
      final (seventhExit, seventhOut, _) = await runChecker(
        arguments: [
          '--results',
          results,
          '--tiers',
          'b',
          '--budgets',
          budgets,
          '--baseline',
          baseline,
          '--drift-state',
          statePath,
          '--update-drift-state',
        ],
        environment: {'BENCH_ENFORCE_B': '1'},
      );
      expect(seventhExit, 1);
      expect(seventhOut, contains('baseline stale — refresh required'));

      // An intervening clean main run resets the count.
      final cleanResults = await writeFixture(
        'clean.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 3; i++)
              _rowJson(
                scenario: 'P1',
                repetition: i,
                unit: 'ms',
                fingerprint: _fingerprintJson(
                  mode: 'profile',
                  cpuModel: 'baseline-cpu',
                ),
              ),
          ],
        ),
      );
      final (cleanExit, _, _) = await runChecker(
        arguments: [
          '--results',
          cleanResults,
          '--tiers',
          'b',
          '--budgets',
          budgets,
          '--baseline',
          baseline,
          '--drift-state',
          statePath,
          '--update-drift-state',
        ],
        environment: {'BENCH_ENFORCE_B': '1'},
      );
      expect(cleanExit, 0);
      final state = DriftState.fromJson(
        jsonDecode(await File(statePath).readAsString()),
      );
      expect(state.notices, isEmpty, reason: 'a clean run clears streaks');
    });

    test('the same progression stays exit-zero while soft', () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(landedIds: {'P1'}),
      );
      final baseline = await writeFixture(
        'baseline.json',
        _baselineJson(cpuModel: 'baseline-cpu'),
      );
      final results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 3; i++)
              _rowJson(
                scenario: 'P1',
                repetition: i,
                unit: 'ms',
                fingerprint: _fingerprintJson(
                  mode: 'profile',
                  cpuModel: 'new-cpu',
                ),
              ),
          ],
        ),
      );
      final statePath = pathOf('drift-state.json');
      await File(statePath).writeAsString(
        jsonEncode(const DriftState({}).toJson('2026-09-14T00:00:00Z')),
      );
      var (exitCodeValue, stdoutText, _) = (0, '', '');
      for (var run = 0; run < driftStaleThreshold; run++) {
        (exitCodeValue, stdoutText, _) = await runChecker(
          arguments: [
            '--results',
            results,
            '--tiers',
            'b',
            '--budgets',
            budgets,
            '--baseline',
            baseline,
            '--drift-state',
            statePath,
            '--update-drift-state',
          ],
        );
        expect(exitCodeValue, 0, reason: 'soft mode reddens nothing here');
      }
      expect(
        stdoutText,
        contains('red once BENCH_ENFORCE_B is set'),
        reason: 'the threshold crossing is still announced while soft',
      );
    });

    test('PR invocations never mutate state', () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(landedIds: {'P1'}),
      );
      final baseline = await writeFixture(
        'baseline.json',
        _baselineJson(cpuModel: 'baseline-cpu'),
      );
      final results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 3; i++)
              _rowJson(
                scenario: 'P1',
                repetition: i,
                unit: 'ms',
                fingerprint: _fingerprintJson(
                  mode: 'profile',
                  cpuModel: 'new-cpu',
                ),
              ),
          ],
        ),
      );
      final statePath = pathOf('drift-state.json');
      await runChecker(
        arguments: [
          '--results',
          results,
          '--tiers',
          'b',
          '--budgets',
          budgets,
          '--baseline',
          baseline,
          '--drift-state',
          statePath,
        ],
      );
      expect(
        await File(statePath).exists(),
        isFalse,
        reason: 'a PR run must not create or write the state store',
      );
      expect(out.text, isNot(contains('baseline stale')));
    });

    test(
      'missing or unreadable state counts conservatively, never resets',
      () async {
        final budgets = await writeFixture(
          'budgets.json',
          _budgetsJson(landedIds: {'P1'}),
        );
        final baseline = await writeFixture(
          'baseline.json',
          _baselineJson(cpuModel: 'baseline-cpu'),
        );
        final results = await writeFixture(
          'results.json',
          _resultsJson(
            rows: [
              for (var i = 0; i < 3; i++)
                _rowJson(
                  scenario: 'P1',
                  repetition: i,
                  unit: 'ms',
                  fingerprint: _fingerprintJson(
                    mode: 'profile',
                    cpuModel: 'new-cpu',
                  ),
                ),
            ],
          ),
        );

        // No state file at all: unknown history escalates immediately under
        // enforcement instead of restarting from a fresh count.
        var (exitCodeValue, stdoutText, _) = await runChecker(
          arguments: [
            '--results',
            results,
            '--tiers',
            'b',
            '--budgets',
            budgets,
            '--baseline',
            baseline,
            '--drift-state',
            pathOf('never-existed.json'),
          ],
          environment: {'BENCH_ENFORCE_B': '1'},
        );
        expect(exitCodeValue, 1);
        expect(stdoutText, contains('drift history unknown'));
        expect(stdoutText, contains('baseline stale — refresh required'));

        // An undecodable state file is history loss, not a data error.
        final corrupt = File(pathOf('corrupt-state.json'));
        await corrupt.writeAsString('{not json');
        (exitCodeValue, stdoutText, _) = await runChecker(
          arguments: [
            '--results',
            results,
            '--tiers',
            'b',
            '--budgets',
            budgets,
            '--baseline',
            baseline,
            '--drift-state',
            corrupt.path,
          ],
          environment: {'BENCH_ENFORCE_B': '1'},
        );
        expect(exitCodeValue, 1);
        expect(stdoutText, contains('drift history unknown'));
      },
    );

    test('--update-drift-state with a tier-B-blind scope is refused', () async {
      final results = await writeFixture(
        'results.json',
        _resultsJson(rows: [_rowJson()]),
      );
      final (exitCodeValue, _, stderrText) = await runChecker(
        arguments: [
          '--results',
          results,
          '--tiers',
          'a',
          '--drift-state',
          pathOf('state.json'),
          '--update-drift-state',
        ],
      );
      expect(exitCodeValue, 64);
      expect(
        stderrText,
        contains(
          '--update-drift-state requires --tiers '
          'including b',
        ),
      );
    });
  });

  test('the state write is atomic and touches nothing else', () async {
    final budgets = await writeFixture(
      'budgets.json',
      _budgetsJson(landedIds: {'P1'}),
    );
    final baseline = await writeFixture(
      'baseline.json',
      _baselineJson(cpuModel: 'baseline-cpu'),
    );
    final results = await writeFixture(
      'results.json',
      _resultsJson(
        rows: [
          for (var i = 0; i < 3; i++)
            _rowJson(
              scenario: 'P1',
              repetition: i,
              unit: 'ms',
              fingerprint: _fingerprintJson(
                mode: 'profile',
                cpuModel: 'new-cpu',
              ),
            ),
        ],
      ),
    );
    final unrelated = File(pathOf('unrelated.json'));
    await unrelated.writeAsString('keep me');
    final statePath = pathOf('nested/state.json');
    await runChecker(
      arguments: [
        '--results',
        results,
        '--tiers',
        'b',
        '--budgets',
        budgets,
        '--baseline',
        baseline,
        '--drift-state',
        statePath,
        '--update-drift-state',
      ],
    );
    expect(
      jsonDecode(await File(statePath).readAsString()),
      isA<Map<String, Object?>>(),
    );
    expect(
      await File('$statePath.tmp').exists(),
      isFalse,
      reason: 'the temp file must be renamed away',
    );
    expect(await unrelated.readAsString(), 'keep me');
  });

  group('subprocess contract', () {
    // A small battery of true process runs pins the outermost wiring:
    // argument parsing, stdout/stderr, and the real exit status.
    test('help exits 0 and prints usage to stdout', () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/benchmarks/check.dart',
        '--help',
      ]);
      expect(result.exitCode, 0);
      expect(result.stdout as String, contains('Evaluates D12 benchmark'));
      expect(result.stderr as String, isEmpty);
    });

    test('a soft passing run exits 0', () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(calibrated: _fingerprintJson(), landedIds: {'P3'}),
      );
      final results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: [for (var i = 0; i < 5; i++) _rowJson(repetition: i)],
        ),
      );
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/benchmarks/check.dart',
        '--results',
        results,
        '--tiers',
        'a',
        '--budgets',
        budgets,
      ]);
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout as String, contains('pass'));
    });

    test('a missing expected scenario exits 1 in a real process', () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(calibrated: _fingerprintJson(), landedIds: {'P3'}),
      );
      final results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: [_rowJson(scenario: 'P5', repetition: 0, unit: 'ms')],
        ),
      );
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          'test/benchmarks/check.dart',
          '--results',
          results,
          '--tiers',
          'a',
          '--budgets',
          budgets,
        ],
        environment: {...Platform.environment, 'BENCH_ENFORCE_A': '1'},
      );
      expect(result.exitCode, 1);
      expect(
        result.stdout as String,
        contains(
          'FAIL: expected scenario '
          'P3',
        ),
      );
    });
  });
}

/// Minimal in-memory IOSink so checkMain can run in-process.
class MemorySink implements IOSink {
  final _buffer = StringBuffer();

  String get text => _buffer.toString();

  void clear() => _buffer.clear();

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeln([Object? object = '', Object? arg2, Object? arg3]) =>
      _buffer.writeln(object);

  @override
  void add(List<int> data) => _buffer.write(utf8.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  Encoding get encoding => utf8;

  @override
  set encoding(Encoding encoding) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => Future.value();

  @override
  Future<void> close() => Future.value();

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> flush() => Future.value();
}

Map<String, Object?> _budgetsJson({
  Object? calibrated,
  Set<String> landedIds = const {},
}) => {
  'schema': budgetsSchemaId,
  'calibratedFingerprint': calibrated,
  'scenarios': [
    for (final id in ['P1', 'P2', 'P3', 'P4', 'P5', 'P6', 'P7'])
      () {
        final tierBSceanrio = {'P1', 'P2', 'P4', 'P6'};
        return {
          'id': id,
          'tier': tierBSceanrio.contains(id) ? 'b' : 'a',
          'summary': 'synthetic',
          'operator': id == 'P6'
              ? 'atMost'
              : (id == 'P7' ? 'atLeast' : 'lessThan'),
          'value': switch (id) {
            'P1' => 150,
            'P2' => 1000,
            'P3' => 50,
            'P4' => 100,
            'P5' => 500,
            'P6' => 0.2,
            _ => 1000,
          },
          'unit': switch (id) {
            'P6' => '%',
            'P7' => 'entries/s',
            _ => 'ms',
          },
          'minimumRepetitions': id == 'P3' ? 5 : 3,
          'landed': landedIds.contains(id),
        };
      }(),
  ],
};

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

Map<String, Object?> _baselineJson({
  String runnerImage = 'image-2026',
  String cpuModel = 'test-cpu',
}) => {
  'schema': baselineSchemaId,
  'fingerprint': _fingerprintJson(
    mode: 'profile',
    runnerImage: runnerImage,
    cpuModel: cpuModel,
  ),
  'scenarios': {
    'P1': {'median': 100, 'unit': 'ms', 'repetitions': 3},
  },
};

Map<String, Object?> _fingerprintJson({
  String runnerImage = 'image-2026',
  String mode = 'aot',
  String cpuModel = 'test-cpu',
}) => {
  'runnerImage': runnerImage,
  'arch': 'x64',
  'dartVersion': '3.12.0',
  'flutterVersion': null,
  'mode': mode,
  'cpuModel': cpuModel,
  'scenarioConfig': null,
};
