import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_m0_bench/harness.dart';
import 'package:poltergeist_m0_bench/result_aggregator.dart';
import 'package:poltergeist_m0_bench/result_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('M0 result manifest', () {
    test('assigns 75 standard and 3 slow scenarios', () {
      expect(standardShardScenarios, hasLength(standardShardScenarioCount));
      expect(slowShardScenarios, hasLength(slowShardScenarioCount));
      expect(m0ScenarioManifest, hasLength(m0ScenarioCount));
      expect(m0ScenarioManifest.toSet(), hasLength(m0ScenarioCount));
      expect(slowShardScenarios, {
        'dart-hash-on-upload-1gb-rtt100',
        'dart-hash-off-upload-1gb-rtt100',
        'openssh-upload-1gb-rtt100',
      });
    });
  });

  group('aggregateResultShards', () {
    test('preserves rows and follows the canonical manifest', () {
      final standard = _rows(standardShardScenarios.reversed);
      final slow = _rows(slowShardScenarios.reversed);

      final aggregated = aggregateResultShards(
        standardRows: standard,
        slowRows: slow,
      );

      expect(aggregated.map((row) => row['scenario']), m0ScenarioManifest);
      final inputs = {
        for (final row in [...standard, ...slow]) row['scenario']: row,
      };
      for (final row in aggregated) {
        expect(row, inputs[row['scenario']]);
      }
    });

    test('rejects a missing scenario', () {
      final standard = _rows(standardShardScenarios)..removeLast();

      expect(
        () => _aggregate(standard: standard),
        throwsA(isA<ResultAggregationException>()),
      );
    });

    test('rejects an extra scenario', () {
      final standard = _rows(standardShardScenarios)
        ..add(_row('unexpected-scenario'));

      expect(
        () => _aggregate(standard: standard),
        throwsA(isA<ResultAggregationException>()),
      );
    });

    test('rejects a duplicate scenario', () {
      final standard = _rows(standardShardScenarios)
        ..add(_row(standardShardScenarios.first));

      expect(
        () => _aggregate(standard: standard),
        throwsA(isA<ResultAggregationException>()),
      );
    });

    test('rejects a scenario assigned to the wrong shard', () {
      final standard = _rows(standardShardScenarios);
      final slow = _rows(slowShardScenarios);
      standard[0] = slow.removeLast();

      expect(
        () => _aggregate(standard: standard, slow: slow),
        throwsA(isA<ResultAggregationException>()),
      );
    });

    test('rejects wrong dartssh2 attribution', () {
      final standard = _rows(standardShardScenarios);
      standard.first['dartssh2Version'] = '2.21.0';

      expect(
        () => _aggregate(standard: standard),
        throwsA(isA<ResultAggregationException>()),
      );
    });

    test('rejects wrong Seance attribution', () {
      final standard = _rows(standardShardScenarios);
      standard.first['seanceRev'] = 'wrong';

      expect(
        () => _aggregate(standard: standard),
        throwsA(isA<ResultAggregationException>()),
      );
    });

    test('rejects an empty host', () {
      final standard = _rows(standardShardScenarios);
      standard.first['host'] = '  ';

      expect(
        () => _aggregate(standard: standard),
        throwsA(isA<ResultAggregationException>()),
      );
    });

    test('rejects mixed hosts within either shard', () {
      final standard = _rows(standardShardScenarios);
      standard.last['host'] = 'another-runner';

      expect(
        () => _aggregate(standard: standard),
        throwsA(isA<ResultAggregationException>()),
      );
    });

    test('rejects invalid and non-UTC timestamps', () {
      for (final timestamp in [
        'not-a-time',
        '2026-09-01T12:00:00',
        '2026-09-01T12:00:00+01:00',
      ]) {
        final standard = _rows(standardShardScenarios);
        standard.first['timestampUtc'] = timestamp;

        expect(
          () => _aggregate(standard: standard),
          throwsA(isA<ResultAggregationException>()),
          reason: timestamp,
        );
      }
    });

    test('rejects RTT on a LAN row', () {
      final standard = _rows(standardShardScenarios);
      final row = standard.firstWhere(
        (candidate) => '${candidate['scenario']}'.endsWith('-lan'),
      );
      row['rttMs'] = 1;

      expect(
        () => _aggregate(standard: standard),
        throwsA(isA<ResultAggregationException>()),
      );
    });

    test('rejects missing or non-positive shaped RTT', () {
      for (final rttMs in [null, 0, -1]) {
        final standard = _rows(standardShardScenarios);
        final row = standard.firstWhere(
          (candidate) => '${candidate['scenario']}'.endsWith('-rtt100'),
        );
        row['rttMs'] = rttMs;

        expect(
          () => _aggregate(standard: standard),
          throwsA(isA<ResultAggregationException>()),
          reason: '$rttMs',
        );
      }
    });

    test('rejects mixed RTT measurements in the slow cell', () {
      final slow = _rows(slowShardScenarios);
      slow.last['rttMs'] = 101;

      expect(
        () => _aggregate(slow: slow),
        throwsA(isA<ResultAggregationException>()),
      );
    });

    test('rejects negative byte counts', () {
      final standard = _rows(standardShardScenarios);
      standard.first['bytes'] = -1;

      expect(
        () => _aggregate(standard: standard),
        throwsA(isA<ResultAggregationException>()),
      );
    });

    test('rejects non-positive measurement elapsed time', () {
      final standard = _rows(standardShardScenarios);
      standard.first['elapsedUs'] = 0;

      expect(
        () => _aggregate(standard: standard),
        throwsA(isA<ResultAggregationException>()),
      );
    });

    test('allows zero elapsed time only for client support evidence', () {
      final standard = _rows(standardShardScenarios);
      final support = standard.firstWhere(
        (row) => '${row['scenario']}'.startsWith('algorithm-client-support-'),
      );
      support['elapsedUs'] = 0;

      expect(
        _aggregate(standard: standard),
        hasLength(m0ScenarioManifest.length),
      );

      support['elapsedUs'] = -1;
      expect(
        () => _aggregate(standard: standard),
        throwsA(isA<ResultAggregationException>()),
      );
    });
  });

  test('aggregateResultFiles writes canonical JSON', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-result-aggregate-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final standardPath = '${directory.path}/standard.json';
    final slowPath = '${directory.path}/slow.json';
    final outputPath = '${directory.path}/combined.json';
    await File(
      standardPath,
    ).writeAsString(jsonEncode(_rows(standardShardScenarios.reversed)));
    await File(
      slowPath,
    ).writeAsString(jsonEncode(_rows(slowShardScenarios.reversed)));

    await aggregateResultFiles(
      standardPath: standardPath,
      slowPath: slowPath,
      outputPath: outputPath,
    );

    final output = await File(outputPath).readAsString();
    final decoded = jsonDecode(output) as List<Object?>;
    expect(output, endsWith('\n'));
    expect(decoded.map((row) => (row! as Map)['scenario']), m0ScenarioManifest);
  });

  group('aggregate CLI', () {
    const usageExitCode = 64;
    const dataExitCode = 65;
    const ioExitCode = 74;

    test('writes from explicit shard paths', () async {
      final directory = await Directory.systemTemp.createTemp(
        'poltergeist-result-cli-success-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final standardPath = '${directory.path}/standard.json';
      final slowPath = '${directory.path}/slow.json';
      final outputPath = '${directory.path}/output.json';
      await File(
        standardPath,
      ).writeAsString(jsonEncode(_rows(standardShardScenarios)));
      await File(slowPath).writeAsString(jsonEncode(_rows(slowShardScenarios)));

      final result = await _runCli([
        '--standard',
        standardPath,
        '--slow',
        slowPath,
        '--output',
        outputPath,
      ]);

      expect(result.exitCode, 0);
      final decoded = jsonDecode(await File(outputPath).readAsString()) as List;
      expect(decoded, hasLength(m0ScenarioCount));
    });

    test('reports usage errors', () async {
      final result = await _runCli(const []);

      expect(result.exitCode, usageExitCode);
      expect(result.stderr, contains('Usage:'));
    });

    test('reports invalid shard data', () async {
      final directory = await Directory.systemTemp.createTemp(
        'poltergeist-result-cli-data-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final standardPath = '${directory.path}/standard.json';
      final slowPath = '${directory.path}/slow.json';
      await File(standardPath).writeAsString('[]');
      await File(slowPath).writeAsString('[]');

      final result = await _runCli([
        '--standard',
        standardPath,
        '--slow',
        slowPath,
        '--output',
        '${directory.path}/output.json',
      ]);

      expect(result.exitCode, dataExitCode);
      expect(result.stderr, contains('missing'));
    });

    test('reports input I/O errors', () async {
      final directory = await Directory.systemTemp.createTemp(
        'poltergeist-result-cli-io-',
      );
      addTearDown(() => directory.delete(recursive: true));

      final result = await _runCli([
        '--standard',
        '${directory.path}/missing-standard.json',
        '--slow',
        '${directory.path}/missing-slow.json',
        '--output',
        '${directory.path}/output.json',
      ]);

      expect(result.exitCode, ioExitCode);
      expect(result.stderr, isNotEmpty);
    });
  });
}

List<Map<String, Object?>> _rows(Iterable<String> scenarios) => [
  for (final scenario in scenarios) _row(scenario),
];

Map<String, Object?> _row(String scenario) => {
  'scenario': scenario,
  'bytes': 1,
  'dartssh2Version': resolvedDartssh2Version,
  'seanceRev': pinnedSeanceRevision,
  'rttMs': scenario.endsWith('-rtt100') ? 100 : null,
  'elapsedUs': scenario.startsWith('algorithm-client-support-') ? 0 : 1,
  'note': 'original:$scenario',
  'timestampUtc': '2026-09-01T12:00:00Z',
  'host': 'runner',
};

List<Map<String, Object?>> _aggregate({
  List<Map<String, Object?>>? standard,
  List<Map<String, Object?>>? slow,
}) => aggregateResultShards(
  standardRows: standard ?? _rows(standardShardScenarios),
  slowRows: slow ?? _rows(slowShardScenarios),
);

Future<ProcessResult> _runCli(List<String> arguments) => Process.run(
  Platform.resolvedExecutable,
  ['run', 'bin/aggregate.dart', ...arguments],
  workingDirectory: _packageRoot,
);

String get _packageRoot {
  final current = Directory.current.path;
  if (File('$current/tool/bench/pubspec.yaml').existsSync()) {
    return '$current/tool/bench';
  }
  return current;
}
