import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_m0_bench/fixture_data.dart';
import 'package:poltergeist_m0_bench/harness.dart';
import 'package:poltergeist_m0_bench/result_store.dart';
import 'package:poltergeist_m0_bench/throughput_attempt.dart';
import 'package:test/test.dart';

void main() {
  test('appends complete rows without changing earlier evidence', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-result-store-',
    );
    final path = '${directory.path}/results.json';
    addTearDown(() => directory.delete(recursive: true));
    final first = _result('first');
    final second = _result('second');

    await appendResults(path, [first]);
    await appendResults(path, [second]);

    final decoded =
        jsonDecode(await File(path).readAsString()) as List<Object?>;
    expect(decoded, hasLength(2));
    expect((decoded.first! as Map)['scenario'], 'first');
    expect((decoded.last! as Map)['scenario'], 'second');
  });

  test('atomically replaces an attempt checkpoint by reference', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-attempt-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/results.json';
    final store = ThroughputAttemptStore(throughputAttemptOutputPath(path));
    final running = _attempt(ThroughputAttemptStatus.running);
    final success = _attempt(ThroughputAttemptStatus.success);

    await store.checkpoint(running);
    await store.checkpoint(success);

    final decoded =
        jsonDecode(await File('$path.attempts.json').readAsString())
            as List<Object?>;
    expect(decoded, hasLength(1));
    expect((decoded.single! as Map)['status'], 'success');
    expect(File('$path.attempts.json.tmp').existsSync(), isFalse);
  });
}

ThroughputAttempt _attempt(ThroughputAttemptStatus status) => ThroughputAttempt(
  reference: 'sample-trial',
  scenario: 'dart-hash-on-download-1gb-rtt100',
  direction: ThroughputLeg.download,
  variant: ThroughputVariant.dartHashOn,
  replicate: ThroughputReplicate.first,
  ordinal: null,
  phase: ThroughputAttemptPhase.trial,
  payloadBytes: fixturePayload1GbBytes,
  status: status,
  startedAtUtc: DateTime.utc(2026, 9, 1, 12),
  endedAtUtc: status == ThroughputAttemptStatus.running
      ? null
      : DateTime.utc(2026, 9, 1, 12, 1),
  elapsed: status == ThroughputAttemptStatus.running
      ? null
      : const Duration(minutes: 1),
  primeReference: 'sample-prime',
  warmupReference: 'sample-warmup',
  integrity: const ThroughputIntegrityEvidence(
    status: ThroughputIntegrityStatus.pending,
    expectedBytes: fixturePayload1GbBytes,
    expectedSha256: fixturePayload1GbSha256,
    destination: '/tmp/sample.bin',
  ),
);

BenchResult _result(String scenario) => BenchResult(
  scenario: scenario,
  bytes: 1,
  elapsed: const Duration(microseconds: 1),
  dartssh2Version: resolvedDartssh2Version,
  seanceRev: pinnedSeanceRevision,
  timestampUtc: DateTime.utc(2026),
  host: 'test',
);
