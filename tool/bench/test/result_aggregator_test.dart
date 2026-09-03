import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_m0_bench/evidence.dart';
import 'package:poltergeist_m0_bench/harness.dart';
import 'package:poltergeist_m0_bench/result_aggregator.dart';
import 'package:poltergeist_m0_bench/result_manifest.dart';
import 'package:test/test.dart';

const _sha = '0123456789abcdef0123456789abcdef01234567';
const _fixtureTree = 'fedcba9876543210fedcba9876543210fedcba98';
const _runId = '901';
const _runAttempt = 2;
const _deadlineStarted = '2026-09-01T11:59:30.000Z';
const _started = '2026-09-01T12:00:00.000Z';
const _finished = '2026-09-01T13:00:00.000Z';
const _deadlineStartedAtMonotonicUs = 1000000;
const _lifecycleElapsedUs = 3600000000;
const _oneMbDigest =
    'd29751f2649b32ff572b5e0a9f541ea660a50f94ff0beedfb0b692b924cc8025';
const _hundredMbDigest =
    'a993f8c574e0fea8c1cdcbcd9408d9e2e107ee6e4d120edcfa11decd53fa0cae';
const _oneGbDigest =
    'bc17f06f9d9b5f6f79ca189a1772b1a3a38d6e40c45bec50f9c4f28144efddca';

// Stand-ins for a pin the live constants have moved past: committed M0
// evidence was measured on revisions later re-pins superseded.
const _supersededDartssh2 = '9.9.9';
const _supersededSeance = 'ffffffffffffffffffffffffffffffffffffffff';

void main() {
  test('writes 78 canonical rows, raw sources, and sorted digests', () async {
    final fixture = await _EvidenceFixture.create();
    addTearDown(fixture.delete);

    final bundle = await aggregateEvidenceDirectory(
      inputRoot: fixture.input.path,
      outputDirectory: fixture.output.path,
      expectedRunId: _runId,
      expectedRunAttempt: _runAttempt,
      expectedGitSha: _sha,
      expectedDartssh2Version: resolvedDartssh2Version,
      expectedSeanceRevision: pinnedSeanceRevision,
    );

    expect(bundle.results, hasLength(m0ScenarioCount));
    expect(bundle.results.map((row) => row['scenario']), m0ScenarioManifest);
    final split = bundle.results.firstWhere(
      (row) => row['scenario'] == 'dart-hash-on-download-1gb-rtt100',
    );
    expect(split['sampleIds'], hasLength(2));
    expect(split['sourceShardIds'], hasLength(2));
    expect(split['note'], contains('aggregate=floor-midpoint'));
    expect(split, isNot(contains('host')));
    expect(split, isNot(contains('timestampUtc')));
    expect(split, isNot(contains('rttMs')));
    final sameRunner = bundle.results.firstWhere(
      (row) => row['scenario'] == 'dart-hash-on-download-100mb-rtt100',
    );
    expect(sameRunner['host'], 'runner-standard');
    expect(sameRunner['timestampUtc'], '2026-09-01T12:30:00.000Z');
    expect(sameRunner['rttMs'], 100);
    expect(sameRunner['rttEvidence'], isA<Map<String, Object?>>());

    final canonical = File('${fixture.output.path}/$canonicalEvidenceFileName');
    final raw = Directory('${fixture.output.path}/$rawEvidenceDirectoryName');
    final sums = File('${fixture.output.path}/$sha256ManifestFileName');
    expect(await canonical.exists(), isTrue);
    expect(await raw.list().length, isolatedSourceCount + 1);
    final sumLines = (await sums.readAsLines()).where(
      (line) => line.isNotEmpty,
    );
    expect(sumLines, hasLength(isolatedSourceCount + 2));
    final sumPaths = [
      for (final line in sumLines) line.substring(line.indexOf('  ') + 2),
    ];
    expect(sumPaths, orderedEquals([...sumPaths]..sort()));
    for (final line in sumLines) {
      final match = RegExp(r'^([a-f0-9]{64})  (.+)$').firstMatch(line)!;
      final file = File('${fixture.output.path}/${match.group(2)}');
      expect(
        sha256.convert(await file.readAsBytes()).toString(),
        match.group(1),
      );
    }
  });

  test(
    'rejects missing, extra, duplicate, and misassigned artifacts',
    () async {
      for (final mutate in <Future<void> Function(_EvidenceFixture)>[
        (fixture) => fixture
            .artifact(isolatedSourceSpecs.first.id)
            .delete(recursive: true),
        (fixture) async {
          await Directory(
            '${fixture.input.path}/$sourceArtifactPrefix-unexpected',
          ).create();
          await File(
            '${fixture.input.path}/$sourceArtifactPrefix-unexpected/'
            '$sourceEnvelopeFileName',
          ).writeAsString('{}');
        },
        (fixture) async {
          final source = isolatedSourceSpecs.first.id;
          final envelope = await fixture.read(source);
          (envelope['identity']! as Map)['shardId'] = standardSourceId;
          await fixture.write(source, envelope);
        },
      ]) {
        final fixture = await _EvidenceFixture.create();
        addTearDown(fixture.delete);
        await mutate(fixture);

        expect(
          () => fixture.aggregate(),
          throwsA(isA<ResultAggregationException>()),
        );
      }
    },
  );

  test('rejects failed and mixed-identity sources', () async {
    for (final mutate in <void Function(Map<String, Object?>)>[
      (source) {
        source['state'] = EvidenceState.failed.name;
        source['exitStatus'] = 1;
        source['failure'] = 'failed';
      },
      (source) {
        (source['identity']! as Map)['workflowRunAttempt'] = 3;
      },
      (source) {
        final identity = source['identity']! as Map;
        (identity['fixture']! as Map)['tree'] = 'different';
      },
    ]) {
      final fixture = await _EvidenceFixture.create();
      addTearDown(fixture.delete);
      final sourceId = isolatedSourceSpecs.first.id;
      final source = await fixture.read(sourceId);
      mutate(source);
      await fixture.write(sourceId, source);

      expect(
        () => fixture.aggregate(),
        throwsA(isA<ResultAggregationException>()),
      );
    }
  });

  test('rejects isolated lifecycle and transfer deadline violations', () async {
    final deadline = DateTime.parse(_deadlineStarted);
    for (final mutate in <void Function(Map<String, Object?>)>[
      (source) {
        source['finishedAtUtc'] = deadline
            .add(isolatedSourceLifecycleBudget)
            .add(const Duration(microseconds: 1))
            .toIso8601String();
      },
      (source) {
        source['lifecycleElapsedUs'] =
            isolatedSourceLifecycleBudget.inMicroseconds + 1;
      },
      (source) {
        final started = DateTime.utc(2026, 9, 1, 12, 10);
        final elapsed =
            isolatedTransferBudget + const Duration(microseconds: 1);
        _mutateFirstTrial(source, (trial) {
          trial['startedAtUtc'] = started.toIso8601String();
          trial['endedAtUtc'] = started.add(elapsed).toIso8601String();
          trial['elapsedUs'] = elapsed.inMicroseconds;
        });
        _setFirstThroughputRowElapsed(source, elapsed.inMicroseconds);
        source['finishedAtUtc'] = DateTime.utc(
          2026,
          9,
          1,
          16,
          20,
        ).toIso8601String();
      },
      (source) {
        final ended = deadline
            .add(isolatedTrialCompletionBudget)
            .add(const Duration(microseconds: 1));
        _mutateFirstTrial(source, (trial) {
          trial['startedAtUtc'] = ended
              .subtract(const Duration(seconds: 1))
              .toIso8601String();
          trial['endedAtUtc'] = ended.toIso8601String();
        });
        source['finishedAtUtc'] = deadline
            .add(const Duration(minutes: 300))
            .toIso8601String();
      },
      (source) {
        source['deadlineStartedAtUtc'] = DateTime.parse(
          _started,
        ).add(const Duration(microseconds: 1)).toIso8601String();
      },
      (source) {
        source['deadlineStartedAtUtc'] = DateTime.parse(_started)
            .subtract(sourceDeadlineSetupTolerance)
            .subtract(const Duration(microseconds: 1))
            .toIso8601String();
      },
    ]) {
      final fixture = await _EvidenceFixture.create();
      addTearDown(fixture.delete);
      final sourceId = isolatedSourceSpecs.first.id;
      final source = await fixture.read(sourceId);
      mutate(source);
      await fixture.write(sourceId, source);

      expect(
        () => fixture.aggregate(),
        throwsA(isA<ResultAggregationException>()),
      );
    }
  });

  test('does not apply the isolated lifecycle bound to standard', () async {
    final fixture = await _EvidenceFixture.create();
    addTearDown(fixture.delete);
    final source = await fixture.read(standardSourceId);
    source['finishedAtUtc'] = DateTime.parse(
      _deadlineStarted,
    ).add(const Duration(hours: 6)).toIso8601String();
    source['lifecycleElapsedUs'] = const Duration(hours: 6).inMicroseconds;
    await fixture.write(standardSourceId, source);

    await fixture.aggregate();
  });

  test(
    'rejects raw-count, midpoint, RTT, warmup, and integrity errors',
    () async {
      for (final mutate in <void Function(Map<String, Object?>)>[
        (source) => (source['attempts']! as List).removeWhere(
          (attempt) => (attempt as Map)['phase'] == 'trial',
        ),
        (source) {
          final row =
              (source['rows']! as List).firstWhere(
                    (candidate) => '${(candidate as Map)['scenario']}'
                        .startsWith('dart-hash-on-download-1mb-lan'),
                  )
                  as Map;
          row['elapsedUs'] = (row['elapsedUs']! as int) + 1;
        },
        (source) {
          final attempt =
              (source['attempts']! as List).firstWhere(
                    (candidate) =>
                        (candidate as Map)['phase'] == 'trial' &&
                        candidate['rttEvidence'] != null,
                  )
                  as Map;
          ((attempt['rttEvidence']! as Map)['samplesUs']! as List).removeLast();
        },
        (source) {
          final attempt =
              (source['attempts']! as List).firstWhere(
                    (candidate) => (candidate as Map)['phase'] == 'trial',
                  )
                  as Map;
          attempt['warmupReference'] = 'missing';
        },
        (source) {
          final attempt =
              (source['attempts']! as List).firstWhere(
                    (candidate) => (candidate as Map)['phase'] == 'trial',
                  )
                  as Map;
          (attempt['integrity']! as Map)['actualBytes'] = 7;
        },
      ]) {
        final fixture = await _EvidenceFixture.create();
        addTearDown(fixture.delete);
        final source = await fixture.read(standardSourceId);
        mutate(source);
        await fixture.write(standardSourceId, source);

        expect(
          () => fixture.aggregate(),
          throwsA(isA<ResultAggregationException>()),
        );
      }
    },
  );

  test(
    'aggregates evidence measured on superseded dependency pins',
    () async {
      final fixture = await _EvidenceFixture.create(
        dartssh2Version: _supersededDartssh2,
        seanceRevision: _supersededSeance,
      );
      addTearDown(fixture.delete);

      final bundle = await fixture.aggregate(
        expectedDartssh2Version: _supersededDartssh2,
        expectedSeanceRevision: _supersededSeance,
      );

      final dependencies = (bundle.identity['dependencies']! as Map)
          .cast<String, Object?>();
      expect(dependencies['dartssh2Version'], _supersededDartssh2);
      expect(dependencies['seanceRevision'], _supersededSeance);
    },
  );

  test(
    'rejects evidence whose pins differ from the expected pins',
    () async {
      final fixture = await _EvidenceFixture.create(
        dartssh2Version: _supersededDartssh2,
        seanceRevision: _supersededSeance,
      );
      addTearDown(fixture.delete);

      await expectLater(
        fixture.aggregate(),
        throwsA(
          isA<ResultAggregationException>().having(
            (error) => error.message,
            'message',
            contains('unexpected dependency pins'),
          ),
        ),
      );
    },
  );

  test('rejects rows whose pins differ from the expected pins', () async {
    final fixture = await _EvidenceFixture.create(
      seanceRevision: _supersededSeance,
    );
    addTearDown(fixture.delete);
    final sourceId = isolatedSourceSpecs.first.id;
    final source = await fixture.read(sourceId);
    ((source['rows']! as List).first as Map)['seanceRev'] =
        pinnedSeanceRevision;
    await fixture.write(sourceId, source);

    await expectLater(
      fixture.aggregate(expectedSeanceRevision: _supersededSeance),
      throwsA(
        isA<ResultAggregationException>().having(
          (error) => error.message,
          'message',
          contains('invalid dependency attribution'),
        ),
      ),
    );
  });

  test('aggregate CLI writes the canonical evidence directory', () async {
    final fixture = await _EvidenceFixture.create();
    addTearDown(fixture.delete);

    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/aggregate.dart',
      '--input-root',
      fixture.input.path,
      '--output-dir',
      fixture.output.path,
      '--run-id',
      _runId,
      '--run-attempt',
      '$_runAttempt',
      '--git-sha',
      _sha,
    ], workingDirectory: _packageRoot);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      await File('${fixture.output.path}/$canonicalEvidenceFileName').exists(),
      isTrue,
    );
  });
}

String get _packageRoot {
  final current = Directory.current.path;
  if (File('$current/tool/bench/pubspec.yaml').existsSync()) {
    return '$current/tool/bench';
  }

  return current;
}

class _EvidenceFixture {
  final Directory root;
  final Directory input;
  final Directory output;

  const _EvidenceFixture(this.root, this.input, this.output);

  static Future<_EvidenceFixture> create({
    String dartssh2Version = resolvedDartssh2Version,
    String seanceRevision = pinnedSeanceRevision,
  }) async {
    final root = await Directory.systemTemp.createTemp('m0-aggregate-');
    final fixture = _EvidenceFixture(
      root,
      Directory('${root.path}/input'),
      Directory('${root.path}/output'),
    );
    await fixture.input.create();
    for (final source in m0SourceManifest) {
      await fixture.artifact(source.id).create();
      await fixture.write(
        source.id,
        _sourceEnvelope(
          source,
          dartssh2Version: dartssh2Version,
          seanceRevision: seanceRevision,
        ),
      );
    }

    return fixture;
  }

  Directory artifact(String sourceId) =>
      Directory('${input.path}/$sourceArtifactPrefix-$sourceId');

  Future<Map<String, Object?>> read(String sourceId) async =>
      (jsonDecode(
                await File(
                  '${artifact(sourceId).path}/$sourceEnvelopeFileName',
                ).readAsString(),
              )
              as Map)
          .cast<String, Object?>();

  Future<void> write(String sourceId, Map<String, Object?> envelope) => File(
    '${artifact(sourceId).path}/$sourceEnvelopeFileName',
  ).writeAsString(jsonEncode(envelope));

  Future<CanonicalEvidenceBundle> aggregate({
    String expectedDartssh2Version = resolvedDartssh2Version,
    String expectedSeanceRevision = pinnedSeanceRevision,
  }) => aggregateEvidenceDirectory(
    inputRoot: input.path,
    outputDirectory: output.path,
    expectedRunId: _runId,
    expectedRunAttempt: _runAttempt,
    expectedGitSha: _sha,
    expectedDartssh2Version: expectedDartssh2Version,
    expectedSeanceRevision: expectedSeanceRevision,
  );

  Future<void> delete() => root.delete(recursive: true);
}

Map<String, Object?> _sourceEnvelope(
  M0SourceSpec source, {
  String dartssh2Version = resolvedDartssh2Version,
  String seanceRevision = pinnedSeanceRevision,
}) {
  final attempts = <Map<String, Object?>>[];
  final primes = <String, Map<String, Object?>>{};
  final rows = <Map<String, Object?>>[];
  if (source.kind == M0SourceKind.standard) {
    for (final scenario in source.scenarios) {
      final specs = standardThroughputTrialSpecs
          .where((trial) => trial.scenario == scenario)
          .toList();
      if (specs.isEmpty) {
        rows.add(
          _row(
            scenario,
            source.id,
            dartssh2Version: dartssh2Version,
            seanceRevision: seanceRevision,
          ),
        );
        continue;
      }
      final bundles = [
        for (final spec in specs)
          _trialBundle(source.id, spec, attempts: attempts, primes: primes),
      ];
      rows.add(
        _row(
          scenario,
          source.id,
          bundles: bundles,
          dartssh2Version: dartssh2Version,
          seanceRevision: seanceRevision,
        ),
      );
    }
  } else {
    final scenario = source.scenarios.single;
    final parsed = _parseScenario(scenario);
    final cell = ThroughputCellSpec(
      link: 'rtt100',
      payload: '1gb',
      direction: parsed.$2,
    );
    final spec = ThroughputTrialSpec(
      cell: cell,
      variant: parsed.$1,
      replicate: source.replicate!,
      ordinal: null,
    );
    final bundle = _trialBundle(
      source.id,
      spec,
      attempts: attempts,
      primes: primes,
    );
    rows.add(
      _row(
        scenario,
        source.id,
        bundles: [bundle],
        dartssh2Version: dartssh2Version,
        seanceRevision: seanceRevision,
      ),
    );
  }

  return {
    'schemaVersion': sourceEnvelopeSchemaVersion,
    'state': EvidenceState.succeeded.name,
    'identity': {
      'poltergeistSha': _sha,
      'workflowRunId': _runId,
      'workflowRunAttempt': _runAttempt,
      'workflowJob': 'm0_bench',
      'shardId': source.id,
      'host': 'runner-${source.id}',
      'runtime': {
        'dartVersion': '3.13.2',
        'operatingSystem': 'linux',
        'operatingSystemVersion': 'Linux test',
        'architecture': 'X64',
        'runnerName': 'runner-${source.id}',
        'runnerImage': 'ubuntu24',
        'runnerImageVersion': '20260901.1',
      },
      'dependencies': {
        'dartssh2Version': dartssh2Version,
        'seanceRevision': seanceRevision,
      },
      'fixture': {
        'tree': _fixtureTree,
        'imageId': 'sha256:${sha256.convert(utf8.encode(source.id))}',
        'openSshClientVersion': 'OpenSSH_10.5',
        'openSshServerVersion': 'openssh-server-pam-10.5_p1-r1',
        'dataVersion': fixtureDataVersion,
      },
    },
    'deadlineStartedAtUtc': _deadlineStarted,
    'deadlineStartedAtMonotonicUs': _deadlineStartedAtMonotonicUs,
    'startedAtUtc': _started,
    'finishedAtUtc': _finished,
    'lifecycleElapsedUs': _lifecycleElapsedUs,
    'exitStatus': 0,
    'failure': null,
    'rows': rows,
    'attempts': attempts,
  };
}

void _mutateFirstTrial(
  Map<String, Object?> source,
  void Function(Map<Object?, Object?> trial) mutate,
) {
  final attempts = source['attempts']! as List;
  final recorded = attempts.cast<Map>().firstWhere(
    (attempt) => attempt['phase'] == 'trial',
  );
  final reference = recorded['reference'];
  mutate(recorded);

  for (final row in (source['rows']! as List).cast<Map>()) {
    final bundles = row['throughputTrials'];
    if (bundles is! List) continue;

    for (final bundle in bundles.cast<Map>()) {
      final trial = bundle['trial']! as Map;
      if (trial['reference'] != reference) continue;

      mutate(trial);
      return;
    }
  }
  throw StateError('Missing embedded trial $reference.');
}

void _setFirstThroughputRowElapsed(Map<String, Object?> source, int elapsedUs) {
  for (final row in (source['rows']! as List).cast<Map>()) {
    if (row['throughputTrials'] is! List) continue;

    row['elapsedUs'] = elapsedUs;
    return;
  }
  throw StateError('Missing throughput row.');
}

Map<String, Object?> _row(
  String scenario,
  String sourceId, {
  List<Map<String, Object?>>? bundles,
  String dartssh2Version = resolvedDartssh2Version,
  String seanceRevision = pinnedSeanceRevision,
}) {
  final elapsed = bundles == null
      ? (scenario.startsWith('algorithm-client-support-') ? 0 : 10)
      : bundles.length == 1
      ? ((bundles.single['trial']! as Map)['elapsedUs']! as int)
      : _midpoint([
          for (final bundle in bundles)
            ((bundle['trial']! as Map)['elapsedUs']! as int),
        ]);
  final row = <String, Object?>{
    'scenario': scenario,
    'bytes': expectedBytesForScenario(scenario),
    'dartssh2Version': dartssh2Version,
    'seanceRev': seanceRevision,
    'rttMs': scenario.endsWith('-rtt100') ? 100 : null,
    'elapsedUs': elapsed,
    'note': 'source=$sourceId',
    'timestampUtc': '2026-09-01T12:30:00.000Z',
    'host': 'runner-$sourceId',
  };
  if (scenario.endsWith('-rtt100')) row['rttEvidence'] = _rttEvidence();
  if (bundles != null) row['throughputTrials'] = bundles;

  return row;
}

Map<String, Object?> _trialBundle(
  String sourceId,
  ThroughputTrialSpec spec, {
  required List<Map<String, Object?>> attempts,
  required Map<String, Map<String, Object?>> primes,
}) {
  final base = '$sourceId-${spec.sampleId}';
  final sourcePrimeKey = spec.cell.id;
  final warmupPrimeKey = '${spec.cell.link}-1mb-${spec.cell.direction.label}';
  final sourcePrime = primes.putIfAbsent(sourcePrimeKey, () {
    final prime = _attempt(
      reference: '$sourceId-$sourcePrimeKey-prime',
      scenario: spec.scenario,
      spec: spec,
      phase: 'prime',
      bytes: spec.cell.bytes,
      destination: 'source/$sourceId-$sourcePrimeKey',
    );
    attempts.add(prime);
    return prime;
  });
  final warmupPrime = primes.putIfAbsent(warmupPrimeKey, () {
    final prime = _attempt(
      reference: '$sourceId-$warmupPrimeKey-prime',
      scenario: spec.scenario,
      spec: spec,
      phase: 'prime',
      bytes: fixturePayloadOneMegabyteBytes,
      destination: 'source/$sourceId-$warmupPrimeKey',
    );
    attempts.add(prime);
    return prime;
  });
  final warmup = _attempt(
    reference: '$base-warmup',
    scenario: spec.scenario,
    spec: spec,
    phase: 'warmup',
    bytes: fixturePayloadOneMegabyteBytes,
    destination: 'destination/$base-warmup',
    primeReference: warmupPrime['reference']! as String,
  );
  final trial = _attempt(
    reference: '$base-trial',
    scenario: spec.scenario,
    spec: spec,
    phase: 'trial',
    bytes: spec.cell.bytes,
    destination: 'destination/$base-trial',
    primeReference: sourcePrime['reference']! as String,
    warmupReference: warmup['reference']! as String,
    elapsedUs: spec.replicate * 100,
  );
  attempts.addAll([warmup, trial]);

  return {
    'sourcePrime': sourcePrime,
    'warmupSourcePrime': warmupPrime,
    'warmup': warmup,
    'trial': trial,
  };
}

Map<String, Object?> _attempt({
  required String reference,
  required String scenario,
  required ThroughputTrialSpec spec,
  required String phase,
  required int bytes,
  required String destination,
  String? primeReference,
  String? warmupReference,
  int elapsedUs = 10,
}) {
  final attemptScenario = switch (phase) {
    'prime' =>
      '${spec.cell.direction.label}-${_payloadLabel(bytes)}-'
          '${spec.cell.link}-source-prime',
    'warmup' => scenario,
    _ => scenario,
  };
  final ordinal = spec.ordinal ?? 1;
  final warmupStartSecond = 10 + (ordinal - 1) * 3;
  final trialStartSecond = warmupStartSecond + 2;

  return {
    'reference': reference,
    'scenario': attemptScenario,
    'direction': spec.cell.direction.label,
    'variant': phase == 'prime' ? null : spec.variant.label,
    'replicate': phase == 'prime' ? null : spec.replicate,
    'ordinal': phase == 'prime' ? null : spec.ordinal,
    'phase': phase,
    'payloadBytes': bytes,
    'status': 'success',
    'startedAtUtc': phase == 'trial'
        ? _attemptTime(trialStartSecond)
        : phase == 'warmup'
        ? _attemptTime(warmupStartSecond)
        : '2026-09-01T12:05:00.000Z',
    'endedAtUtc': phase == 'trial'
        ? _attemptTime(trialStartSecond + 1)
        : phase == 'warmup'
        ? _attemptTime(warmupStartSecond + 1)
        : '2026-09-01T12:05:01.000Z',
    'elapsedUs': elapsedUs,
    'primeReference': primeReference,
    'warmupReference': warmupReference,
    'rttEvidence': spec.cell.link == 'rtt100' ? _rttEvidence() : null,
    'integrity': {
      'status': 'verified',
      'expectedBytes': bytes,
      'actualBytes': bytes,
      'expectedSha256': _digestForBytes(bytes),
      'actualSha256': _digestForBytes(bytes),
      'destination': destination,
      'detail': null,
    },
    'error': null,
  };
}

String _attemptTime(int second) =>
    '2026-09-01T12:10:${second.toString().padLeft(2, '0')}.000Z';

Map<String, Object?> _rttEvidence() {
  final source = <String, Object?>{
    'samplesUs': [99000, 100000, 101000, 98000, 102000, 100000, 100000],
    'medianMs': 100,
    'capturedAtUtc': '2026-09-01T12:04:00.000Z',
  };
  final digest = sha256.convert(utf8.encode(jsonEncode(source)));

  return {'reference': 'rtt-sha256:$digest', ...source};
}

int _midpoint(List<int> values) {
  final ordered = [...values]..sort();
  return (ordered[0] + ordered[1]) ~/ 2;
}

String _digestForBytes(int bytes) => switch (bytes) {
  fixturePayloadOneMegabyteBytes => _oneMbDigest,
  fixturePayloadOneHundredMegabytesBytes => _hundredMbDigest,
  fixturePayloadOneGigabyteBytes => _oneGbDigest,
  _ => throw StateError('Unknown fixture size: $bytes'),
};

String _payloadLabel(int bytes) => switch (bytes) {
  fixturePayloadOneMegabyteBytes => '1mb',
  fixturePayloadOneHundredMegabytesBytes => '100mb',
  fixturePayloadOneGigabyteBytes => '1gb',
  _ => throw StateError('Unknown fixture size: $bytes'),
};

(M0ThroughputVariant, M0ThroughputDirection) _parseScenario(String scenario) {
  final variant = M0ThroughputVariant.values.firstWhere(
    (candidate) => scenario.startsWith('${candidate.label}-'),
  );
  final direction = M0ThroughputDirection.values.firstWhere(
    (candidate) => scenario.contains('-${candidate.label}-'),
  );
  return (variant, direction);
}
