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
    expect(out.errors, isEmpty, reason: 'stdout routed through addError');
    expect(err.errors, isEmpty, reason: 'stderr routed through addError');
    return (exitCode, out.text, err.text);
  }

  /// A clean tier-B observation set: landed P1, matching baseline
  /// fingerprint, three in-budget repetitions — a run that legitimately
  /// clears drift streaks.
  Future<({String budgets, String baseline, String results})>
  writeCleanTierBFixtures() async {
    final budgets = await writeFixture(
      'budgets.json',
      _budgetsJson(landedIds: {'P1'}),
    );
    final baseline = await writeFixture('baseline.json', _baselineJson());
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
    return (budgets: budgets, baseline: baseline, results: results);
  }

  /// The drift fixture shared by the drift-state battery: three P1
  /// repetitions in profile mode on a mismatching CPU model.
  Future<String> writeDriftResults() => writeFixture(
    'results.json',
    _resultsJson(
      rows: [
        for (var i = 0; i < 3; i++)
          _rowJson(
            scenario: 'P1',
            repetition: i,
            unit: 'ms',
            fingerprint: _fingerprintJson(mode: 'profile', cpuModel: 'new-cpu'),
          ),
      ],
    ),
  );

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

  test(
    'a results file with invalid UTF-8 bytes exits 65, not a crash',
    () async {
      final budgets = await writeFixture('budgets.json', _budgetsJson());
      final binary = File(pathOf('results.json'));
      await binary.writeAsBytes([0x7b, 0x22, 0x61, 0xff, 0xfe, 0x7d]);
      final (exitCodeValue, _, stderrText) = await runChecker(
        arguments: [
          '--results',
          binary.path,
          '--tiers',
          'a',
          '--budgets',
          budgets,
        ],
      );
      expect(exitCodeValue, 65, reason: stderrText);
      expect(stderrText, contains('not valid UTF-8 or JSON'));
    },
  );

  test(
    'an unreadable existing drift-state file counts as unknown history',
    // dart_tools (Ubuntu) and Linux dev hosts have chmod; on Windows
    // Process.run would throw on the missing executable instead of
    // returning non-zero.
    skip: Platform.isWindows ? 'chmod is absent on Windows' : false,
    () async {
      // An absent chmod binary throws ProcessException rather than
      // returning a non-zero exit (minimal containers, non-POSIX hosts).
      var chmodWorks = false;
      try {
        chmodWorks = (await Process.run('chmod', ['--version'])).exitCode == 0;
      } on ProcessException {
        chmodWorks = false;
      }
      if (!chmodWorks) {
        markTestSkipped('chmod is unavailable on this host');
        return;
      }
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(landedIds: {'P1'}),
      );
      final baseline = await writeFixture(
        'baseline.json',
        _baselineJson(cpuModel: 'baseline-cpu'),
      );
      final results = await writeDriftResults();
      // Exists but unreadable (EACCES): history loss, not an exit-74 abort —
      // the usage text promises "missing/unreadable means unknown history".
      final locked = File(pathOf('locked-state.json'));
      await locked.writeAsString(
        jsonEncode(const DriftState({}).toJson('2026-09-14T00:00:00Z')),
      );
      final lock = await Process.run('chmod', ['000', locked.path]);
      expect(lock.exitCode, 0, reason: lock.stderr as String);
      try {
        await locked.readAsString();
        await Process.run('chmod', ['644', locked.path]);
        // A privileged reader (root) bypasses mode bits, so the EACCES
        // path is untestable in this environment. markTestSkipped only
        // MARKS the test skipped — it neither throws nor returns, so
        // execution continues and must leave the test explicitly.
        markTestSkipped(
          'reader is privileged (root bypasses mode bits); EACCES '
          'untestable',
        );
        return;
      } on FileSystemException {
        // Expected: the mode change denies the read.
      }
      try {
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
            locked.path,
          ],
          environment: {'BENCH_ENFORCE_B': '1'},
        );
        expect(exitCodeValue, 1, reason: 'conservative counting reddens');
        expect(stdoutText, contains('drift history unknown'));
      } finally {
        await Process.run('chmod', ['644', locked.path]);
      }
    },
  );

  test('an unknown-history state still prints its notice when no drift '
      'fires this run', () async {
    final budgets = await writeFixture(
      'budgets.json',
      _budgetsJson(landedIds: {'P1'}),
    );
    final baseline = await writeFixture('baseline.json', _baselineJson());
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
        pathOf('never-existed.json'),
      ],
    );
    expect(exitCodeValue, 0);
    expect(stdoutText, contains('drift history unknown'));
  });

  test('a tier-B controlled-axis mismatch fails once per axis, not once '
      'per scenario', () async {
    final budgets = await writeFixture(
      'budgets.json',
      _budgetsJson(landedIds: {'P1', 'P4'}),
    );
    final baseline = await writeFixture(
      'baseline.json',
      _baselineJson(
        runnerImage: 'image-2026',
        scenarios: {
          'P1': {'median': 100, 'unit': 'ms', 'repetitions': 3},
          'P4': {'median': 80, 'unit': 'ms', 'repetitions': 3},
        },
      ),
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
          for (var i = 0; i < 3; i++)
            _rowJson(
              scenario: 'P4',
              repetition: i,
              value: 80,
              unit: 'ms',
              fingerprint: _fingerprintJson(
                mode: 'profile',
                runnerImage: 'image-2027',
              ),
            ),
        ],
      ),
    );
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
      ],
      environment: {'BENCH_ENFORCE_B': '1'},
    );
    expect(exitCodeValue, 1);
    final failureLines = stdoutText
        .split('\n')
        .where((line) => line.startsWith('FAIL: tier-B baseline'))
        .toList();
    expect(
      failureLines,
      hasLength(1),
      reason: 'one failure per mismatching axis, not per scenario',
    );
  });

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
      expect(
        stdoutText,
        contains(RegExp(r'^P3\s+a\s.*\spass$', multiLine: true)),
      );
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
      expect(stdoutText, contains('FAIL: expected scenario P3'));
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
      expect(
        stdoutText,
        contains(RegExp(r'^P1\s+b\s.*\spass$', multiLine: true)),
      );

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

  test('a tier-B-blind run skips the baseline but notes an explicit '
      '--baseline', () async {
    // The baseline is consulted only by a declared tier-B scope: under
    // --tiers a a catalog that knows no tier-B scenario still runs
    // clean even though the default --baseline resolves to the
    // committed file (the collector subprocess tests rely on this),
    // and an explicitly passed --baseline earns a stderr note instead
    // of vanishing silently.
    final budgets = await writeFixture('budgets.json', {
      'schema': budgetsSchemaV2Id,
      'calibratedFingerprint': _fingerprintJson(),
      'scenarios': [
        {
          'id': 'P3',
          'tier': 'a',
          'summary': 'synthetic',
          'operator': 'lessThan',
          'value': 50,
          'unit': 'ms',
          'minimumRepetitions': 5,
          'landed': false,
        },
      ],
    });
    final results = await writeFixture(
      'results.json',
      _resultsJson(rows: [_rowJson()]),
    );

    var (exitCodeValue, _, stderrText) = await runChecker(
      arguments: ['--results', results, '--tiers', 'a', '--budgets', budgets],
    );
    expect(exitCodeValue, 0, reason: stderrText);
    expect(stderrText, isNot(contains('ignoring')));

    // Deliberately invalid, proving the tier-B-blind path never parses
    // the file (a valid document would also pass if parsing returned).
    final baseline = await writeFixture('baseline.json', {
      'unexpected': true,
    });
    (exitCodeValue, _, stderrText) = await runChecker(
      arguments: [
        '--results',
        results,
        '--tiers',
        'a',
        '--budgets',
        budgets,
        '--baseline',
        baseline,
      ],
    );
    expect(exitCodeValue, 0, reason: stderrText);
    expect(
      stderrText,
      contains(
        'note: --baseline is consulted only when --tiers includes b',
      ),
    );
  });

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

  test('a present baseline never promotes unlanded scenarios to '
      'expected', () async {
    // The M3 window runs every tier-B scenario unlanded: the committed
    // baseline must not turn their rows — including errored ones — into
    // failures. "Expected" stays the landed set (08 §6); the baseline
    // only arms drift evaluation and the absent-baseline notice goes
    // away.
    final budgets = await writeFixture('budgets.json', _budgetsJson());
    final baseline = await writeFixture('baseline.json', _baselineJson());
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
          for (var i = 0; i < 3; i++)
            _rowJson(
              scenario: 'P6',
              repetition: i,
              status: 'error',
              error: 'fixture died',
              unit: '%',
              fingerprint: _fingerprintJson(mode: 'profile'),
            ),
        ],
      ),
    );
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
      ],
    );
    expect(exitCodeValue, 0, reason: stdoutText);
    expect(stdoutText, isNot(contains('FAIL:')));
    expect(stdoutText, contains('reported (unlanded)'));
    expect(
      stdoutText,
      isNot(contains('NOT ENFORCED: no committed tier-B baseline')),
      reason: 'the baseline exists, so its absent-notice must not print',
    );
  });

  test('baseline-present drift is evaluated per run, even when every '
      'tier-B scenario is unlanded', () async {
    // Drift is a property of the baseline vs the run fingerprint, not of
    // any landed scenario: with the baseline committed, a controlled-axis
    // rotation surfaces the recalibrate notice in soft mode (hard exit
    // once enforced) even though no scenario is expected.
    final budgets = await writeFixture('budgets.json', _budgetsJson());
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
    expect(exitCodeValue, 0, reason: stdoutText);
    expect(stdoutText, contains('hardware drift — recalibrate'));
    expect(
      stdoutText,
      contains('controlled axis runnerImage (image-2026 != image-2027)'),
    );
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
  });

  test('the committed baseline drives the default invocation path', () async {
    // check.dart resolves --budgets/--baseline to the committed files by
    // default; this run exercises exactly what the bench job's
    // `--tiers ab` invocation does on a matching fingerprint: no
    // absent-baseline notice, no drift, exit zero. P1 is landed since
    // the M9 flip, so its rows now run the baseline trend comparison —
    // a 40 ms median against the committed ~1 s baseline passes (the
    // gate fires only on a > 25 % regression).
    final baselineDoc =
        jsonDecode(File(defaultBaselinePath).readAsStringSync())
            as Map<String, Object?>;
    final baselineFingerprint =
        Map<String, Object?>.from(baselineDoc['fingerprint'] as Map);
    final results = await writeFixture(
      'results.json',
      _resultsJson(
        rows: [
          // Every landed tier-B scenario must appear: a missing expected
          // scenario fails in every mode. Configs match the committed
          // baseline entries so the comparisons execute.
          for (final (scenario, config) in [
            ('P1', 'local-entries-10000-first-paint'),
            ('P2', 'local-entries-100000-first-paint'),
            ('P4', 'local-tabs-5-entries-10000-tab-switch'),
          ])
            for (var i = 0; i < 3; i++)
              _rowJson(
                scenario: scenario,
                repetition: i,
                unit: 'ms',
                fingerprint: {
                  ...baselineFingerprint,
                  'scenarioConfig': config,
                },
              ),
        ],
      ),
    );
    var (exitCodeValue, stdoutText, _) = await runChecker(
      arguments: ['--results', results, '--tiers', 'b'],
    );
    expect(exitCodeValue, 0, reason: stdoutText);
    expect(stdoutText, contains('pass'));
    expect(
      stdoutText,
      isNot(contains('NOT ENFORCED: no committed tier-B baseline')),
    );
    expect(stdoutText, isNot(contains('hardware drift')));

    // A rotated runner image against the committed baseline is a
    // controlled-axis drift notice on the default path too — the
    // baseline's fingerprint is what arms that detection.
    final driftedResults = await writeFixture(
      'drifted.json',
      _resultsJson(
        rows: [
          for (final scenario in ['P1', 'P2', 'P4'])
            for (var i = 0; i < 3; i++)
              _rowJson(
                scenario: scenario,
                repetition: i,
                unit: 'ms',
                fingerprint: {
                  ...baselineFingerprint,
                  'runnerImage': 'ubuntu-latest@20991231.999.9',
                },
              ),
        ],
      ),
    );
    (exitCodeValue, stdoutText, _) = await runChecker(
      arguments: ['--results', driftedResults, '--tiers', 'b'],
    );
    expect(exitCodeValue, 0, reason: stdoutText);
    expect(stdoutText, contains('hardware drift — recalibrate'));
    expect(stdoutText, contains('controlled axis runnerImage'));
  });

  group('the committed tier-A catalog (landed 2026-09-17, STATUS item 22)',
      () {
    // These runs drive the real committed budgets.json through the
    // default --budgets path — the same evaluation the bench job's
    // `--tiers a` invocation applies. The fingerprint and per-scenario
    // calibrated configs are read back out of the committed catalog, so
    // a future recalibration PR re-pins the recorded values in
    // check_test.dart rather than this fixture.
    late BudgetCatalog committedCatalog;

    setUp(() {
      committedCatalog = BudgetCatalog.fromJson(
        jsonDecode(File(defaultBudgetsPath).readAsStringSync()),
      );
    });

    Map<String, Object?> committedFingerprint(String scenario) {
      final calibrated = committedCatalog.calibratedFingerprint!;
      return {
        'runnerImage': calibrated.runnerImage,
        'arch': calibrated.arch,
        'dartVersion': calibrated.dartVersion,
        'flutterVersion': calibrated.flutterVersion,
        'mode': calibrated.mode,
        'cpuModel': calibrated.cpuModel,
        'scenarioConfig':
            committedCatalog.scenarios[scenario]!.calibratedScenarioConfig,
      };
    }

    /// One full job's worth of landed tier-A rows at the calibrated
    /// fingerprint: P3 keeps its 5-repetition floor, P5/P7 their 3.
    List<Map<String, Object?>> landedRows({
      double p3 = 4451,
      double p5 = 4775,
      double p7 = 2280,
      Map<String, Object?> Function(String scenario)? fingerprint,
    }) => [
      for (var i = 0; i < 5; i++)
        _rowJson(
          scenario: 'P3',
          repetition: i,
          value: p3,
          fingerprint: (fingerprint ?? committedFingerprint)('P3'),
        ),
      for (var i = 0; i < 3; i++)
        _rowJson(
          scenario: 'P5',
          repetition: i,
          value: p5,
          fingerprint: (fingerprint ?? committedFingerprint)('P5'),
        ),
      for (var i = 0; i < 3; i++)
        _rowJson(
          scenario: 'P7',
          repetition: i,
          value: p7,
          unit: 'entries/s',
          fingerprint: (fingerprint ?? committedFingerprint)('P7'),
        ),
    ];

    test('in-budget medians at the calibrated fingerprint pass under '
        'enforcement', () async {
      final results = await writeFixture(
        'results.json',
        _resultsJson(rows: landedRows()),
      );
      // 'true' is the spelling the production repo variable carries; the
      // '1' spelling stays covered by the over-budget test below.
      final (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', results, '--tiers', 'a'],
        environment: {'BENCH_ENFORCE_A': 'true'},
      );
      expect(exitCodeValue, 0, reason: stdoutText);
      for (final id in ['P3', 'P5', 'P7']) {
        expect(
          stdoutText,
          contains(RegExp('^$id\\s+a\\s.*\\spass\$', multiLine: true)),
        );
      }
      expect(stdoutText, isNot(contains('skipped: hardware drift')));
      expect(stdoutText, isNot(contains('reported (unlanded)')));
    });

    test('an over-budget landed median fails once enforced and notices '
        'while soft', () async {
      final results = await writeFixture(
        'results.json',
        _resultsJson(rows: landedRows(p5: 6500)),
      );
      var (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', results, '--tiers', 'a'],
        environment: {'BENCH_ENFORCE_A': '1'},
      );
      expect(exitCodeValue, 1, reason: stdoutText);
      expect(stdoutText, contains('FAIL: scenario P5'));
      expect(stdoutText, contains('overrun (fail: enforced)'));

      (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', results, '--tiers', 'a'],
      );
      expect(exitCodeValue, 0, reason: stdoutText);
      expect(stdoutText, contains('overrun (notice: not enforced)'));
    });

    test('a missing or errored landed scenario fails in every mode',
        () async {
      // P5 absent from the file entirely — soft mode softens overruns
      // only, never a missing expected scenario.
      var results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: landedRows()
              .where((row) => row['scenario'] != 'P5')
              .toList(),
        ),
      );
      for (final environment in [
        const <String, String>{},
        const {'BENCH_ENFORCE_A': '1'},
      ]) {
        final (exitCodeValue, stdoutText, _) = await runChecker(
          arguments: ['--results', results, '--tiers', 'a'],
          environment: environment,
        );
        expect(exitCodeValue, 1, reason: stdoutText);
        expect(
          stdoutText,
          contains(
            'FAIL: expected scenario P5 (tier a) is missing from the '
            'results file',
          ),
        );
      }

      // P5 present but every repetition errored.
      results = await writeFixture(
        'results-errored.json',
        _resultsJson(
          rows: [
            ...landedRows().where((row) => row['scenario'] != 'P5'),
            for (var i = 0; i < 3; i++)
              _rowJson(
                scenario: 'P5',
                repetition: i,
                status: 'error',
                error: 'fixture died',
                fingerprint: committedFingerprint('P5'),
              ),
          ],
        ),
      );
      for (final environment in [
        const <String, String>{},
        const {'BENCH_ENFORCE_A': '1'},
      ]) {
        final (exitCodeValue, stdoutText, _) = await runChecker(
          arguments: ['--results', results, '--tiers', 'a'],
          environment: environment,
        );
        expect(exitCodeValue, 1, reason: stdoutText);
        expect(
          stdoutText,
          contains('FAIL: expected scenario P5 (tier a) repetition 0 '
              'errored: fixture died'),
        );
      }
    });

    test('a per-scenario config mismatch drift-skips only that scenario',
        () async {
      final results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: landedRows(
            fingerprint: (scenario) => {
              ...committedFingerprint(scenario),
              if (scenario == 'P3')
                'scenarioConfig': 'p3/v1;target=/elsewhere;changed=true',
            },
          ),
        ),
      );
      final (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', results, '--tiers', 'a'],
        environment: {'BENCH_ENFORCE_A': '1'},
      );
      // Tier-A drift never reddens, even enforced.
      expect(exitCodeValue, 0, reason: stdoutText);
      expect(stdoutText, contains('controlled axis scenarioConfig'));
      expect(stdoutText, contains('for scenario P3'));
      expect(
        stdoutText,
        contains(RegExp(r'^P3\s+a\s.*skipped: hardware drift$',
            multiLine: true)),
      );
      for (final id in ['P5', 'P7']) {
        expect(
          stdoutText,
          contains(RegExp('^$id\\s+a\\s.*\\spass\$', multiLine: true)),
        );
      }
    });

    test('a controlled-axis mismatch drift-skips tier A, exit zero even '
        'enforced', () async {
      final results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: landedRows(
            fingerprint: (scenario) => {
              ...committedFingerprint(scenario),
              'dartVersion': '9.9.9 (stable) on "linux_x64"',
            },
          ),
        ),
      );
      final (exitCodeValue, stdoutText, _) = await runChecker(
        arguments: ['--results', results, '--tiers', 'a'],
        environment: {'BENCH_ENFORCE_A': '1'},
      );
      expect(exitCodeValue, 0, reason: stdoutText);
      expect(stdoutText, contains('controlled axis dartVersion'));
      expect(stdoutText, contains('skipped: hardware drift'));
      expect(stdoutText, isNot(contains('FAIL:')));
    });
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
      final results = await writeDriftResults();
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
      final results = await writeDriftResults();
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
      final results = await writeDriftResults();
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

  test('an errored repetition of an expected scenario fails even while '
      'soft', () async {
    final budgets = await writeFixture(
      'budgets.json',
      _budgetsJson(landedIds: {'P1'}),
    );
    final baseline = await writeFixture('baseline.json', _baselineJson());
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
          _rowJson(
            scenario: 'P1',
            repetition: 3,
            status: 'error',
            error: 'synthetic collector failed',
            fingerprint: _fingerprintJson(mode: 'profile'),
          ),
        ],
      ),
    );
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
      ],
    );
    expect(
      exitCodeValue,
      1,
      reason: 'a failed repetition cannot hide behind successful ones',
    );
    expect(stdoutText, contains('FAIL: expected scenario P1'));
    expect(
      stdoutText,
      contains('repetition 3 errored: synthetic collector failed'),
    );
  });

  test(
    'a partially-populated baseline cannot prove a clean main run',
    () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(landedIds: {'P1', 'P4'}),
      );
      // The baseline carries P1 only: P4 is expected, fully measured, and
      // yet uncomparable — a skipped comparison must veto the reset.
      final baseline = await writeFixture(
        'baseline.json',
        _baselineJson(
          scenarios: {
            'P1': {'median': 100, 'unit': 'ms', 'repetitions': 3},
          },
        ),
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
      final statePath = pathOf('state.json');
      final prior = const DriftState({
        'tier-b/cpu': DriftNoticeState(
          consecutiveMainRuns: 3,
          lastSeenUtc: '2026-09-14T00:00:00Z',
        ),
      }).toJson('2026-09-14T00:00:00Z');
      await File(statePath).writeAsString(jsonEncode(prior));

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
      );
      expect(exitCodeValue, 0, reason: 'soft mode, no graded failure');
      expect(stdoutText, contains('no committed baseline entry for P4'));
      expect(
        await File(statePath).readAsString(),
        jsonEncode(prior),
        reason: 'a skipped comparison vetoes the reset',
      );
    },
  );

  test('a persisted stale streak reddens a read-only call', () async {
    final budgets = await writeFixture(
      'budgets.json',
      _budgetsJson(landedIds: {'P1'}),
    );
    final baseline = await writeFixture(
      'baseline.json',
      _baselineJson(cpuModel: 'baseline-cpu'),
    );
    final results = await writeDriftResults();
    final statePath = pathOf('state.json');
    final seven = const DriftState({
      'tier-b/cpu': DriftNoticeState(
        consecutiveMainRuns: driftStaleThreshold,
        lastSeenUtc: '2026-09-14T00:00:00Z',
      ),
    }).toJson('2026-09-14T00:00:00Z');
    await File(statePath).writeAsString(jsonEncode(seven));

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
      ],
      environment: {'BENCH_ENFORCE_B': '1'},
    );
    expect(
      exitCodeValue,
      1,
      reason: 'seven actual main drift runs already happened',
    );
    expect(stdoutText, contains('baseline stale — refresh required'));
  });

  test(
    'a read-only call does not grade a hypothetical next main run',
    () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(landedIds: {'P1'}),
      );
      final baseline = await writeFixture(
        'baseline.json',
        _baselineJson(cpuModel: 'baseline-cpu'),
      );
      final results = await writeDriftResults();
      final statePath = pathOf('state.json');
      // Six actual main drift runs are six for this PR too; the seventh
      // escalation belongs to an actual main run, not a read-only call.
      final six = const DriftState({
        'tier-b/cpu': DriftNoticeState(
          consecutiveMainRuns: 6,
          lastSeenUtc: '2026-09-14T00:00:00Z',
        ),
      }).toJson('2026-09-14T00:00:00Z');
      await File(statePath).writeAsString(jsonEncode(six));
      final before = await File(statePath).readAsString();

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
        ],
        environment: {'BENCH_ENFORCE_B': '1'},
      );
      expect(exitCodeValue, 0, reason: stdoutText);
      expect(stdoutText, isNot(contains('baseline stale')));
      expect(
        await File(statePath).readAsString(),
        before,
        reason: 'a PR never writes state',
      );
    },
  );

  test(
    'the state write never touches a pre-existing unrelated temp file',
    () async {
      final fixtures = await writeCleanTierBFixtures();
      final prior = const DriftState({
        'tier-b/cpu': DriftNoticeState(
          consecutiveMainRuns: 3,
          lastSeenUtc: '2026-09-14T00:00:00Z',
        ),
      }).toJson('2026-09-14T00:00:00Z');
      await File(pathOf('state.json')).writeAsString(jsonEncode(prior));
      final unrelated = File(pathOf('state.json.tmp'));
      await unrelated.writeAsString('unrelated sentinel\n');
      await runChecker(
        arguments: [
          '--results',
          fixtures.results,
          '--tiers',
          'b',
          '--budgets',
          fixtures.budgets,
          '--baseline',
          fixtures.baseline,
          '--drift-state',
          pathOf('state.json'),
          '--update-drift-state',
        ],
      );
      expect(await unrelated.readAsString(), 'unrelated sentinel\n');
      final state = DriftState.fromJson(
        jsonDecode(await File(pathOf('state.json')).readAsString()),
      );
      expect(state.notices, isEmpty, reason: 'a clean run clears streaks');
      expect(
        Directory(
          tempDir.path,
        ).listSync().where((entry) => entry.path.contains('.checker-')),
        isEmpty,
        reason: 'no owned temp may linger after publication',
      );
    },
  );

  test('the state write never follows a pre-existing temp symlink', () async {
    final fixtures = await writeCleanTierBFixtures();
    final victim = File(pathOf('victim.txt'));
    await victim.writeAsString('unrelated sentinel\n');
    await Link(pathOf('state.json.tmp')).create(victim.path);
    await runChecker(
      arguments: [
        '--results',
        fixtures.results,
        '--tiers',
        'b',
        '--budgets',
        fixtures.budgets,
        '--baseline',
        fixtures.baseline,
        '--drift-state',
        pathOf('state.json'),
        '--update-drift-state',
      ],
    );
    expect(await victim.readAsString(), 'unrelated sentinel\n');
    expect(
      await File(pathOf('state.json')).exists(),
      isTrue,
      reason: 'the state is still published',
    );
    expect(
      Directory(
        tempDir.path,
      ).listSync().where((entry) => entry.path.contains('.checker-')),
      isEmpty,
    );
  });

  test('a failed main write cleans only its own temp and preserves the '
      'original', () async {
    final fixtures = await writeCleanTierBFixtures();
    // A directory at the target path makes the final rename fail; the
    // owned temp must be cleaned up and the original left untouched.
    final blocked = Directory(pathOf('state.json'));
    await blocked.create();
    final (exitCodeValue, _, stderrText) = await runChecker(
      arguments: [
        '--results',
        fixtures.results,
        '--tiers',
        'b',
        '--budgets',
        fixtures.budgets,
        '--baseline',
        fixtures.baseline,
        '--drift-state',
        blocked.path,
        '--update-drift-state',
      ],
    );
    expect(exitCodeValue, 74, reason: stderrText);
    expect(await blocked.exists(), isTrue);
    // Exactly the three fixtures and the blocked directory: no temp of
    // any name may linger after a failed publish.
    expect(
      Directory(tempDir.path)
          .listSync()
          .map((entry) => entry.path.split(Platform.pathSeparator).last)
          .toSet(),
      {'budgets.json', 'results.json', 'baseline.json', 'state.json'},
    );
  });

  test('a failed main run preserves prior drift history', () async {
    final budgets = await writeFixture(
      'budgets.json',
      _budgetsJson(landedIds: {'P1'}),
    );
    // The row's fingerprint matches the baseline, so no drift fires;
    // P1 is landed and missing, so the run fails without observing any
    // tier-B comparison — the prior count of six must survive it.
    final baseline = await writeFixture('baseline.json', _baselineJson());
    final results = await writeFixture(
      'results.json',
      _resultsJson(
        rows: [
          _rowJson(
            scenario: 'P2',
            repetition: 0,
            unit: 'ms',
            fingerprint: _fingerprintJson(mode: 'profile'),
          ),
        ],
      ),
    );
    final statePath = pathOf('state.json');
    final six = const DriftState({
      'tier-b/cpu': DriftNoticeState(
        consecutiveMainRuns: 6,
        lastSeenUtc: '2026-09-14T00:00:00Z',
      ),
    }).toJson('2026-09-14T00:00:00Z');
    await File(statePath).writeAsString(jsonEncode(six));
    final before = await File(statePath).readAsString();

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
    expect(exitCodeValue, 1, reason: 'P1 is missing');
    expect(stdoutText, contains('FAIL: expected scenario P1'));
    expect(
      await File(statePath).readAsString(),
      before,
      reason: 'a run with nothing to record leaves the store untouched',
    );
    final state = DriftState.fromJson(jsonDecode(before));
    expect(
      state.notices['tier-b/cpu']!.consecutiveMainRuns,
      6,
      reason: 'a failed run cannot prove a clean main observation',
    );
  });

  test('a clean run against a known-empty store does not rewrite it', () async {
    final fixtures = await writeCleanTierBFixtures();
    final statePath = pathOf('state.json');
    final empty = const DriftState({}).toJson('2026-09-14T00:00:00Z');
    await File(statePath).writeAsString(jsonEncode(empty));
    final (exitCodeValue, _, _) = await runChecker(
      arguments: [
        '--results',
        fixtures.results,
        '--tiers',
        'b',
        '--budgets',
        fixtures.budgets,
        '--baseline',
        fixtures.baseline,
        '--drift-state',
        statePath,
        '--update-drift-state',
      ],
    );
    expect(exitCodeValue, 0);
    expect(
      await File(statePath).readAsString(),
      jsonEncode(empty),
      reason: 'no drift and nothing to clear means no write',
    );
  });

  test('a real drift still counts when another gate fails', () async {
    final budgets = await writeFixture(
      'budgets.json',
      _budgetsJson(landedIds: {'P1'}),
    );
    // Same failing shape, but the observed environment genuinely moved:
    // the CPU axis counts even though P1's comparison never ran —
    // measurement validity, drift, and budget failures are distinct.
    final baseline = await writeFixture(
      'baseline.json',
      _baselineJson(cpuModel: 'baseline-cpu'),
    );
    final results = await writeFixture(
      'results.json',
      _resultsJson(
        rows: [
          _rowJson(
            scenario: 'P2',
            repetition: 0,
            unit: 'ms',
            fingerprint: _fingerprintJson(mode: 'profile'),
          ),
        ],
      ),
    );
    final statePath = pathOf('state.json');
    final six = const DriftState({
      'tier-b/cpu': DriftNoticeState(
        consecutiveMainRuns: 6,
        lastSeenUtc: '2026-09-14T00:00:00Z',
      ),
    }).toJson('2026-09-14T00:00:00Z');
    await File(statePath).writeAsString(jsonEncode(six));

    final (exitCodeValue, _, _) = await runChecker(
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
    expect(exitCodeValue, 1);
    final state = DriftState.fromJson(
      jsonDecode(await File(statePath).readAsString()),
    );
    expect(
      state.notices['tier-b/cpu']!.consecutiveMainRuns,
      7,
      reason: 'an observed environment drift must keep counting',
    );
  });

  test(
    'empty results with no landed scenarios are honest in soft mode',
    () async {
      final budgets = await writeFixture('budgets.json', _budgetsJson());
      final results = await writeFixture(
        'results.json',
        _resultsJson(rows: const []),
      );
      final (exitCodeValue, stdoutText, _) = await runChecker(
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
      expect(exitCodeValue, 0, reason: stdoutText);
      expect(stdoutText, contains('no budgets were evaluated'));
    },
  );

  test('empty results still fail when landed scenarios are expected', () async {
    final budgets = await writeFixture(
      'budgets.json',
      _budgetsJson(landedIds: {'P1'}),
    );
    final baseline = await writeFixture('baseline.json', _baselineJson());
    final results = await writeFixture(
      'results.json',
      _resultsJson(rows: const []),
    );
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
      ],
    );
    expect(exitCodeValue, 1);
    expect(stdoutText, contains('FAIL: expected scenario P1'));
    expect(stdoutText, contains('is missing from the results file'));
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

  group('per-scenario scenarioConfig axis (schema migration)', () {
    test(
      'unlanded P3+P7 with distinct configs in one results file both '
      'report and exit 0',
      () async {
        final budgets = await writeFixture('budgets.json', _budgetsJson());
        final results = await writeFixture(
          'results.json',
          _resultsJson(
            rows: [
              // P3 and P7 each carry their own config — exactly what two
              // collectors writing the one planned results file emit.
              for (var i = 0; i < 5; i++)
                _rowJson(repetition: i, value: 40),
              for (var i = 0; i < 3; i++)
                _rowJson(
                  scenario: 'P7',
                  repetition: i,
                  value: 1200,
                  unit: 'entries/s',
                ),
            ],
          ),
        );
        final (exitCodeValue, stdoutText, _) = await runChecker(
          arguments: ['--results', results, '--tiers', 'a', '--budgets', budgets],
        );
        expect(exitCodeValue, 0, reason: stdoutText);
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

    test(
      'repetitions of one scenario with differing configs exit 65',
      () async {
        final budgets = await writeFixture('budgets.json', _budgetsJson());
        final results = await writeFixture(
          'results.json',
          _resultsJson(
            rows: [
              _rowJson(repetition: 0, scenarioConfig: 'p3/v1;a'),
              _rowJson(repetition: 1, scenarioConfig: 'p3/v1;b'),
            ],
          ),
        );
        final (exitCodeValue, _, stderrText) = await runChecker(
          arguments: ['--results', results, '--tiers', 'a', '--budgets', budgets],
        );
        expect(exitCodeValue, 65);
        expect(stderrText, contains('conflicting scenarioConfig'));
        expect(stderrText, contains('p3/v1;a'));
        expect(stderrText, contains('p3/v1;b'));
      },
    );

    test(
      'two landed tier-A scenarios each compare against their own '
      'calibrated config',
      () async {
        final budgets = await writeFixture(
          'budgets.json',
          _budgetsJson(
            calibrated: _fingerprintJson(),
            landedIds: {'P3', 'P7'},
          ),
        );
        final results = await writeFixture(
          'results.json',
          _resultsJson(
            rows: [
              for (var i = 0; i < 5; i++)
                _rowJson(repetition: i, value: 40),
              for (var i = 0; i < 3; i++)
                _rowJson(
                  scenario: 'P7',
                  repetition: i,
                  value: 1200,
                  unit: 'entries/s',
                ),
            ],
          ),
        );
        // Enforced: both must genuinely compare and pass, not drift-skip.
        final (exitCodeValue, stdoutText, _) = await runChecker(
          arguments: ['--results', results, '--tiers', 'a', '--budgets', budgets],
          environment: {'BENCH_ENFORCE_A': '1'},
        );
        expect(exitCodeValue, 0, reason: stdoutText);
        expect(
          stdoutText,
          contains(RegExp(r'^P3\s+a\s.*\spass$', multiLine: true)),
        );
        expect(
          stdoutText,
          contains(RegExp(r'^P7\s+a\s.*\spass$', multiLine: true)),
        );
        expect(stdoutText, isNot(contains('skipped: hardware drift')));
      },
    );

    test(
      'a scenario-specific config drift skips only that scenario',
      () async {
        final budgets = await writeFixture(
          'budgets.json',
          _budgetsJson(
            calibrated: _fingerprintJson(),
            landedIds: {'P3', 'P7'},
            // P7's calibration records a different config than the run
            // carries; P3's own calibration is untouched.
            calibratedConfigs: {'P7': 'p7/v1-drifted;tree=20000'},
          ),
        );
        final results = await writeFixture(
          'results.json',
          _resultsJson(
            rows: [
              for (var i = 0; i < 5; i++)
                _rowJson(repetition: i, value: 40),
              for (var i = 0; i < 3; i++)
                _rowJson(
                  scenario: 'P7',
                  repetition: i,
                  value: 1200,
                  unit: 'entries/s',
                ),
            ],
          ),
        );
        final (exitCodeValue, stdoutText, _) = await runChecker(
          arguments: ['--results', results, '--tiers', 'a', '--budgets', budgets],
          environment: {'BENCH_ENFORCE_A': '1'},
        );
        // Tier-A drift never reddens, in any mode.
        expect(exitCodeValue, 0, reason: stdoutText);
        expect(
          stdoutText,
          contains(RegExp(r'^P3\s+a\s.*\spass$', multiLine: true)),
        );
        expect(stdoutText, contains('skipped: hardware drift'));
        expect(
          stdoutText,
          contains(
            'controlled axis scenarioConfig (p7/v1-drifted;tree=20000 != '
            '${_tierATestConfigs['P7']})',
          ),
        );
        expect(stdoutText, contains('baseline-refresh PR'));
      },
    );

    test(
      'legacy budgets schema-1 still calibrates and prints its '
      'deprecation notice',
      () async {
        final budgets = await writeFixture(
          'budgets.json',
          _budgetsJson(
            schema: budgetsSchemaId,
            calibrated: _fingerprintJson(
              scenarioConfig: _tierATestConfigs['P3'],
            ),
            landedIds: {'P3'},
          ),
        );
        final results = await writeFixture(
          'results.json',
          _resultsJson(rows: [for (var i = 0; i < 5; i++) _rowJson(repetition: i)]),
        );
        final (exitCodeValue, stdoutText, _) = await runChecker(
          arguments: ['--results', results, '--tiers', 'a', '--budgets', budgets],
          environment: {'BENCH_ENFORCE_A': '1'},
        );
        expect(exitCodeValue, 0, reason: stdoutText);
        expect(
          stdoutText,
          contains(RegExp(r'^P3\s+a\s.*\spass$', multiLine: true)),
        );
        expect(stdoutText, contains('deprecated schema $budgetsSchemaId'));
      },
    );

    test('mixed and invalid schema forms fail explicitly (exit 65)', () async {
      final results = await writeFixture(
        'results.json',
        _resultsJson(rows: [for (var i = 0; i < 5; i++) _rowJson(repetition: i)]),
      );

      // Schema-2 with a landed tier-A scenario but no per-scenario
      // calibrated config.
      final missingConfig = await writeFixture(
        'missing-config.json',
        _budgetsJson(
          calibrated: _fingerprintJson(),
          landedIds: {'P3'},
          omitCalibratedConfigs: true,
        ),
      );
      var (exitCodeValue, _, stderrText) = await runChecker(
        arguments: [
          '--results', results, '--tiers', 'a', '--budgets', missingConfig,
        ],
      );
      expect(exitCodeValue, 65);
      expect(stderrText, contains('requires a calibratedScenarioConfig'));

      // Schema-2 whose calibration claims a job-wide config.
      final jobWideConfig = await writeFixture(
        'job-wide-config.json',
        _budgetsJson(
          calibrated: _fingerprintJson(scenarioConfig: 'p3/v1;singular'),
          landedIds: {'P3'},
        ),
      );
      (exitCodeValue, _, stderrText) = await runChecker(
        arguments: [
          '--results', results, '--tiers', 'a', '--budgets', jobWideConfig,
        ],
      );
      expect(exitCodeValue, 65);
      expect(stderrText, contains('calibratedFingerprint.scenarioConfig'));

      // Schema-1 carrying the schema-2 per-scenario field.
      final mixed = jsonDecode(jsonEncode(
        _budgetsJson(
          schema: budgetsSchemaId,
          calibrated: _fingerprintJson(),
          landedIds: {'P3'},
        ),
      )) as Map<String, Object?>;
      (mixed['scenarios'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((s) => s['id'] == 'P3')['calibratedScenarioConfig'] =
          _tierATestConfigs['P3'];
      final mixedPath = await writeFixture('mixed.json', mixed);
      (exitCodeValue, _, stderrText) = await runChecker(
        arguments: ['--results', results, '--tiers', 'a', '--budgets', mixedPath],
      );
      expect(exitCodeValue, 65);
      expect(
        stderrText,
        contains('calibratedScenarioConfig requires schema '
            '$budgetsSchemaV2Id'),
      );
    });

    test(
      'a tier-B baseline claiming a job-wide scenarioConfig exits 65',
      () async {
        final budgets = await writeFixture(
          'budgets.json',
          _budgetsJson(landedIds: {'P1'}),
        );
        // _baselineJson's fingerprint carries no config; inject one to
        // build the rejected form.
        final claimed = jsonDecode(jsonEncode(_baselineJson()))
            as Map<String, Object?>;
        (claimed['fingerprint'] as Map<String, Object?>)['scenarioConfig'] =
            'p1/v1;claimed-job-wide';
        final claimedPath = await writeFixture('claimed.json', claimed);
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
        final (exitCodeValue, _, stderrText) = await runChecker(
          arguments: [
            '--results', results, '--tiers', 'b', '--budgets', budgets,
            '--baseline', claimedPath,
          ],
        );
        expect(exitCodeValue, 65);
        expect(
          stderrText,
          contains('tier-B baseline: fingerprint.scenarioConfig must be null'),
        );
      },
    );

    test(
      'a changed workload config never numerically compares: loud '
      'skip soft, hard fail once enforced',
      () async {
        // The F9 regression: a landed scenario whose fixture config was
        // changed uniformly across repetitions must not score against
        // the old baseline's median — a different workload is a
        // non-comparison, not a pass.
        final budgets = await writeFixture(
          'budgets.json',
          _budgetsJson(landedIds: {'P4'}),
        );
        final baseline = await writeFixture(
          'baseline.json',
          _baselineJson(
            scenarios: {
              'P4': {'median': 35, 'unit': 'ms', 'repetitions': 5},
            },
            scenarioConfigs: const {
              'P4': 'local-tabs-5-entries-10000-tab-switch',
            },
          ),
        );
        final results = await writeFixture(
          'results.json',
          _resultsJson(
            rows: [
              for (var i = 0; i < 3; i++)
                _rowJson(
                  scenario: 'P4',
                  repetition: i,
                  value: 20,
                  unit: 'ms',
                  fingerprint: _fingerprintJson(
                    mode: 'profile',
                    scenarioConfig: 'local-tabs-2-entries-10000-tab-switch',
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
        expect(exitCodeValue, 0, reason: stdoutText);
        expect(stdoutText, contains('skipped: config mismatch'));
        expect(
          stdoutText,
          contains(
            'tier-B baseline config mismatch for P4 '
            '(baseline "local-tabs-5-entries-10000-tab-switch" != '
            'run "local-tabs-2-entries-10000-tab-switch")',
          ),
        );
        expect(
          stdoutText,
          isNot(
            contains(
              RegExp(r'^P4\s+b\s.*\spass$', multiLine: true),
            ),
          ),
          reason: 'a changed workload must never produce a numeric pass',
        );

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
        expect(exitCodeValue, 1, reason: stdoutText);
        expect(
          stdoutText,
          contains(
            'FAIL: tier-B baseline scenarioConfig mismatch for P4',
          ),
        );
      },
    );

    test(
      'a config-carrying run cannot compare against a baseline entry '
      'recorded config-free',
      () async {
        // Recorded null is not "accepts anything": it binds the median
        // to config-free runs only.
        final budgets = await writeFixture(
          'budgets.json',
          _budgetsJson(landedIds: {'P4'}),
        );
        final baseline = await writeFixture(
          'baseline.json',
          _baselineJson(
            scenarios: {
              'P4': {'median': 35, 'unit': 'ms', 'repetitions': 5},
            },
          ),
        );
        final results = await writeFixture(
          'results.json',
          _resultsJson(
            rows: [
              for (var i = 0; i < 3; i++)
                _rowJson(
                  scenario: 'P4',
                  repetition: i,
                  value: 20,
                  unit: 'ms',
                  fingerprint: _fingerprintJson(
                    mode: 'profile',
                    scenarioConfig: 'local-tabs-5-entries-10000-tab-switch',
                  ),
                ),
            ],
          ),
        );
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
          ],
        );
        expect(exitCodeValue, 0, reason: stdoutText);
        expect(stdoutText, contains('skipped: config mismatch'));
        expect(
          stdoutText,
          contains(
            'baseline "<none>" != '
            'run "local-tabs-5-entries-10000-tab-switch"',
          ),
        );
      },
    );

    test(
      'a config-free run cannot compare against a baseline entry with a '
      'recorded config',
      () async {
        final budgets = await writeFixture(
          'budgets.json',
          _budgetsJson(landedIds: {'P4'}),
        );
        final baseline = await writeFixture(
          'baseline.json',
          _baselineJson(
            scenarios: {
              'P4': {'median': 35, 'unit': 'ms', 'repetitions': 5},
            },
            scenarioConfigs: const {
              'P4': 'local-tabs-5-entries-10000-tab-switch',
            },
          ),
        );
        final results = await writeFixture(
          'results.json',
          _resultsJson(
            rows: [
              for (var i = 0; i < 3; i++)
                _rowJson(
                  scenario: 'P4',
                  repetition: i,
                  value: 20,
                  unit: 'ms',
                  fingerprint: _fingerprintJson(mode: 'profile'),
                ),
            ],
          ),
        );
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
          ],
          environment: {'BENCH_ENFORCE_B': '1'},
        );
        expect(exitCodeValue, 1, reason: stdoutText);
        expect(stdoutText, contains('skipped: config mismatch'));
        expect(
          stdoutText,
          isNot(contains(RegExp(r'^P4\s+b\s.*\spass$', multiLine: true))),
        );
      },
    );

    test(
      'an unchanged workload config still compares and passes',
      () async {
        final budgets = await writeFixture(
          'budgets.json',
          _budgetsJson(landedIds: {'P4'}),
        );
        const config = 'local-tabs-5-entries-10000-tab-switch';
        final baseline = await writeFixture(
          'baseline.json',
          _baselineJson(
            scenarios: {
              'P4': {'median': 35, 'unit': 'ms', 'repetitions': 5},
            },
            scenarioConfigs: const {'P4': config},
          ),
        );
        final results = await writeFixture(
          'results.json',
          _resultsJson(
            rows: [
              for (var i = 0; i < 3; i++)
                _rowJson(
                  scenario: 'P4',
                  repetition: i,
                  value: 35,
                  unit: 'ms',
                  fingerprint: _fingerprintJson(
                    mode: 'profile',
                    scenarioConfig: config,
                  ),
                ),
            ],
          ),
        );
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
          ],
          environment: {'BENCH_ENFORCE_B': '1'},
        );
        expect(exitCodeValue, 0, reason: stdoutText);
        expect(
          stdoutText,
          contains(RegExp(r'^P4\s+b\s.*\spass$', multiLine: true)),
        );
      },
    );

    test(
      'a legacy schema -1 baseline stays readable but never compares: '
      'loud baseline-config-missing, enforced-nonzero',
      () async {
        // Migration policy: the pre-config baseline keeps parsing (its
        // fingerprint still arms the drift evaluation), but no entry can
        // honestly compare — never an invented config, never a silent
        // numeric pass.
        final budgets = await writeFixture(
          'budgets.json',
          _budgetsJson(landedIds: {'P4'}),
        );
        final baseline = await writeFixture(
          'baseline.json',
          _baselineJson(
            schema: baselineSchemaId,
            scenarios: {
              'P4': {'median': 35, 'unit': 'ms', 'repetitions': 5},
            },
          ),
        );
        // Even a run whose config happens to match what the legacy
        // baseline was measured under cannot compare: the entry simply
        // does not record it.
        final results = await writeFixture(
          'results.json',
          _resultsJson(
            rows: [
              for (var i = 0; i < 3; i++)
                _rowJson(
                  scenario: 'P4',
                  repetition: i,
                  value: 35,
                  unit: 'ms',
                  fingerprint: _fingerprintJson(
                    mode: 'profile',
                    scenarioConfig: 'local-tabs-5-entries-10000-tab-switch',
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
        expect(exitCodeValue, 0, reason: stdoutText);
        expect(stdoutText, contains('skipped: baseline-config-missing'));
        expect(stdoutText, contains('baseline-config-missing'));
        expect(
          stdoutText,
          contains('deprecated schema $baselineSchemaId'),
        );
        expect(
          stdoutText,
          isNot(
            contains(
              RegExp(r'^P4\s+b\s.*\spass$', multiLine: true),
            ),
          ),
          reason: 'a config-less entry must never produce a numeric pass',
        );

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
        expect(exitCodeValue, 1, reason: stdoutText);
        expect(
          stdoutText,
          contains('records no scenarioConfig'),
        );
      },
    );

    test(
      'a config-skipped comparison cannot prove a clean main run',
      () async {
        // Same rule as a missing baseline entry: a comparison that
        // never executed must veto the drift-state reset.
        final budgets = await writeFixture(
          'budgets.json',
          _budgetsJson(landedIds: {'P4'}),
        );
        final baseline = await writeFixture(
          'baseline.json',
          _baselineJson(
            scenarios: {
              'P4': {'median': 35, 'unit': 'ms', 'repetitions': 5},
            },
            scenarioConfigs: const {
              'P4': 'local-tabs-5-entries-10000-tab-switch',
            },
          ),
        );
        final results = await writeFixture(
          'results.json',
          _resultsJson(
            rows: [
              for (var i = 0; i < 3; i++)
                _rowJson(
                  scenario: 'P4',
                  repetition: i,
                  value: 35,
                  unit: 'ms',
                  fingerprint: _fingerprintJson(
                    mode: 'profile',
                    scenarioConfig: 'local-tabs-2-entries-10000-tab-switch',
                  ),
                ),
            ],
          ),
        );
        final statePath = pathOf('state.json');
        final prior = const DriftState({
          'tier-b/cpu': DriftNoticeState(
            consecutiveMainRuns: 3,
            lastSeenUtc: '2026-09-15T00:00:00Z',
          ),
        }).toJson('2026-09-15T00:00:00Z');
        await File(statePath).writeAsString(jsonEncode(prior));

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
        );
        expect(exitCodeValue, 0, reason: 'soft mode, no graded failure');
        expect(stdoutText, contains('skipped: config mismatch'));
        expect(
          await File(statePath).readAsString(),
          jsonEncode(prior),
          reason: 'a skipped comparison vetoes the reset',
        );
      },
    );

    test(
      'a baseline-config-missing skip also vetoes the drift reset',
      () async {
        // The legacy-schema skip is the same unexecuted comparison: it
        // must veto the reset too, in soft and enforced mode alike.
        final budgets = await writeFixture(
          'budgets.json',
          _budgetsJson(landedIds: {'P4'}),
        );
        final baseline = await writeFixture(
          'baseline.json',
          _baselineJson(
            schema: baselineSchemaId,
            scenarios: {
              'P4': {'median': 35, 'unit': 'ms', 'repetitions': 5},
            },
          ),
        );
        final results = await writeFixture(
          'results.json',
          _resultsJson(
            rows: [
              for (var i = 0; i < 3; i++)
                _rowJson(
                  scenario: 'P4',
                  repetition: i,
                  value: 35,
                  unit: 'ms',
                  fingerprint: _fingerprintJson(mode: 'profile'),
                ),
            ],
          ),
        );
        final statePath = pathOf('state.json');
        final prior = const DriftState({
          'tier-b/cpu': DriftNoticeState(
            consecutiveMainRuns: 3,
            lastSeenUtc: '2026-09-15T00:00:00Z',
          ),
        }).toJson('2026-09-15T00:00:00Z');
        await File(statePath).writeAsString(jsonEncode(prior));

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
            statePath,
            '--update-drift-state',
          ],
        );
        expect(exitCodeValue, 0, reason: 'soft mode, no graded failure');
        expect(stdoutText, contains('skipped: baseline-config-missing'));
        expect(
          await File(statePath).readAsString(),
          jsonEncode(prior),
          reason: 'a legacy skip vetoes the reset too',
        );

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
          environment: {'BENCH_ENFORCE_B': '1'},
        );
        expect(exitCodeValue, 1, reason: stdoutText);
        expect(
          await File(statePath).readAsString(),
          jsonEncode(prior),
          reason: 'an enforced failure still cannot touch the state',
        );
      },
    );

    test('baseline schema forms fail explicitly (exit 65)', () async {
      final budgets = await writeFixture(
        'budgets.json',
        _budgetsJson(landedIds: {'P4'}),
      );
      final results = await writeFixture(
        'results.json',
        _resultsJson(
          rows: [
            for (var i = 0; i < 3; i++)
              _rowJson(
                scenario: 'P4',
                repetition: i,
                unit: 'ms',
                fingerprint: _fingerprintJson(mode: 'profile'),
              ),
          ],
        ),
      );

      // Schema -2 whose entry drops the per-scenario config key.
      final missingKey = jsonDecode(jsonEncode(
        _baselineJson(
          scenarios: {
            'P4': {'median': 35, 'unit': 'ms', 'repetitions': 5},
          },
        ),
      )) as Map<String, Object?>;
      ((missingKey['scenarios'] as Map)['P4'] as Map)
          .remove('scenarioConfig');
      final missingKeyPath = await writeFixture('missing-key.json', missingKey);
      var (exitCodeValue, _, stderrText) = await runChecker(
        arguments: [
          '--results',
          results,
          '--tiers',
          'b',
          '--budgets',
          budgets,
          '--baseline',
          missingKeyPath,
        ],
      );
      expect(exitCodeValue, 65, reason: stderrText);
      expect(
        stderrText,
        contains(
          'P4.scenarioConfig is required under schema $baselineSchemaV2Id',
        ),
      );

      // Schema -1 whose entry carries the schema-2 field (mixed form).
      final mixed = jsonDecode(jsonEncode(
        _baselineJson(
          schema: baselineSchemaId,
          scenarios: {
            'P4': {'median': 35, 'unit': 'ms', 'repetitions': 5},
          },
        ),
      )) as Map<String, Object?>;
      ((mixed['scenarios'] as Map)['P4'] as Map)['scenarioConfig'] =
          'local-tabs-5-entries-10000-tab-switch';
      final mixedPath = await writeFixture('mixed.json', mixed);
      (exitCodeValue, _, stderrText) = await runChecker(
        arguments: [
          '--results',
          results,
          '--tiers',
          'b',
          '--budgets',
          budgets,
          '--baseline',
          mixedPath,
        ],
      );
      expect(exitCodeValue, 65, reason: stderrText);
      expect(
        stderrText,
        contains('P4.scenarioConfig requires schema $baselineSchemaV2Id'),
      );
    });
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
      // Scrub ambient enforcement variables so the soft expectation does
      // not depend on the host environment.
      final environment = Map<String, String>.of(Platform.environment)
        ..remove('BENCH_ENFORCE_A')
        ..remove('BENCH_ENFORCE_B');
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'test/benchmarks/check.dart',
        '--results',
        results,
        '--tiers',
        'a',
        '--budgets',
        budgets,
      ], environment: environment);
      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(
        result.stdout as String,
        contains(RegExp(r'^P3\s+a\s.*\spass$', multiLine: true)),
      );
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

  /// Recorded so a test can prove the CLI never routed output through
  /// the error path (a silently-discarded addError would pass vacuously).
  final errors = <Object>[];

  @override
  void addError(Object error, [StackTrace? stackTrace]) => errors.add(error);

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
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() => Future.value();

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> flush() => Future.value();
}

/// Tier-A fixture configs shared by the row and catalog helpers, so a
/// landed scenario's default rows and its default calibration agree
/// (each scenario against its own config, never a shared one).
const _tierATestConfigs = {
  'P3': 'p3/v1-test;target=/t;control=/c;target-entries=10000;warmups=2'
      ';repetitions=5',
  'P5': 'p5/v1-test;tree=1000;repetitions=3',
  'P7': 'p7/v1-test;tree=50000;workers=4;repetitions=3',
};

Map<String, Object?> _budgetsJson({
  Object? calibrated,
  Set<String> landedIds = const {},
  String schema = budgetsSchemaV2Id,
  Map<String, String> calibratedConfigs = const {},
  bool omitCalibratedConfigs = false,
}) => {
  'schema': schema,
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
          // Schema-2 calibrates each tier-A scenario's config
          // individually; omitCalibratedConfigs builds the invalid
          // landed-without-config form.
          if (schema == budgetsSchemaV2Id &&
              !omitCalibratedConfigs &&
              landedIds.contains(id) &&
              !tierBSceanrio.contains(id))
            'calibratedScenarioConfig':
                calibratedConfigs[id] ?? _tierATestConfigs[id]!,
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
  String? scenarioConfig,
}) => {
  'scenario': scenario,
  'repetition': repetition,
  'status': status,
  if (status == 'ok') ...{'value': value, 'unit': unit},
  if (error != null) 'error': error,
  // Rows default to their scenario's tier-A fixture config (null for
  // tier B) so plain fixtures stay self-consistent with the catalog
  // helper's default per-scenario calibration.
  'fingerprint':
      fingerprint ??
      _fingerprintJson(
        scenarioConfig: scenarioConfig ?? _tierATestConfigs[scenario],
      ),
};

Map<String, Object?> _baselineJson({
  String schema = baselineSchemaV2Id,
  String runnerImage = 'image-2026',
  String cpuModel = 'test-cpu',
  Map<String, Object?> scenarios = const {
    'P1': {'median': 100, 'unit': 'ms', 'repetitions': 3},
  },
  Map<String, String?> scenarioConfigs = const {},
}) {
  assert(
    schema == baselineSchemaV2Id || scenarioConfigs.isEmpty,
    'schema -1 fixtures must not carry scenarioConfig (mixed form)',
  );
  assert(
    scenarioConfigs.keys.every(scenarios.containsKey),
    'scenarioConfigs names a scenario with no baseline entry',
  );
  return {
    'schema': schema,
    'fingerprint': _fingerprintJson(
      mode: 'profile',
      runnerImage: runnerImage,
      cpuModel: cpuModel,
    ),
    'scenarios': {
      for (final entry in scenarios.entries)
        entry.key: {
          ...(entry.value as Map).cast<String, Object?>(),
          // Schema -2 records each entry's measured config. Tier-B test
          // rows carry a null scenarioConfig by default (only the tier-A
          // helpers assign configs), so a null record keeps plain fixtures
          // comparable; scenarioConfigs overrides per entry. A -1 fixture
          // must not carry the key (mixed form).
          if (schema == baselineSchemaV2Id)
            'scenarioConfig': scenarioConfigs[entry.key],
        },
    },
  };
}

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
