import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_m0_bench/harness.dart';
import 'package:poltergeist_m0_bench/throughput_attempt.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('measurement rows round-trip without changing attribution', () {
    final timestamp = DateTime.utc(2026, 8, 31, 12, 34, 56);
    final result = BenchResult(
      scenario: 'download-1m-lan-hash-off',
      bytes: 1_000_000,
      elapsed: const Duration(microseconds: 4000),
      note: 'verified',
      dartssh2Version: resolvedDartssh2Version,
      seanceRev: pinnedSeanceRevision,
      rttMs: 101,
      timestampUtc: timestamp,
      host: 'runner',
    );

    final serialized = jsonEncode(result.toJson());
    final decoded = BenchResult.fromJson(
      (jsonDecode(serialized)! as Map).cast<String, Object?>(),
    );

    expect(decoded.toJson(), result.toJson());
    expect(decoded.mbPerSec, 250);
    expect(result.toJson(), result.toJson());
  });

  test('measurement attribution matches the resolved lock', () async {
    final lock = loadYaml(await File('pubspec.lock').readAsString()) as YamlMap;
    final packages = lock['packages']! as YamlMap;
    final dartssh2 = packages['dartssh2']! as YamlMap;

    expect(dartssh2['version'], resolvedDartssh2Version);

    final seancePackages = packages.entries.where(
      (entry) => '${entry.key}'.startsWith('seance_'),
    );
    expect(seancePackages, isNotEmpty);
    for (final package in seancePackages) {
      final details = package.value! as YamlMap;
      final description = details['description']! as YamlMap;
      expect(description['resolved-ref'], pinnedSeanceRevision);
    }
  });

  test('measurement rows retain raw RTT and transfer evidence', () {
    final rtt = RttEvidence.parse(
      '{"samplesUs":[99000,100000,101000,98000,102000,100000,100000],'
      '"medianMs":100,"capturedAtUtc":"2026-09-01T12:04:00.000Z"}',
    );
    final prime = _attempt(
      phase: ThroughputAttemptPhase.prime,
      reference: 'prime',
      variant: null,
      replicate: null,
      ordinal: null,
      rtt: rtt,
    );
    final warmup = _attempt(
      phase: ThroughputAttemptPhase.warmup,
      reference: 'warmup',
      variant: ThroughputVariant.dartHashOn,
      replicate: ThroughputReplicate.first,
      ordinal: 1,
      rtt: rtt,
      primeReference: prime.reference,
    );
    final trial = _attempt(
      phase: ThroughputAttemptPhase.trial,
      reference: 'trial',
      variant: ThroughputVariant.dartHashOn,
      replicate: ThroughputReplicate.first,
      ordinal: 1,
      rtt: rtt,
      primeReference: prime.reference,
      warmupReference: warmup.reference,
    );
    final result = BenchResult(
      scenario: 'dart-hash-on-download-1mb-rtt100',
      bytes: 1,
      elapsed: const Duration(microseconds: 11),
      dartssh2Version: resolvedDartssh2Version,
      seanceRev: pinnedSeanceRevision,
      rttEvidence: rtt,
      throughputTrials: [
        ThroughputTrialEvidence(
          sourcePrime: prime,
          warmupSourcePrime: prime,
          warmup: warmup,
          trial: trial,
        ),
      ],
      timestampUtc: DateTime.utc(2026, 9, 1, 12, 5),
      host: 'runner',
    );

    final serialized = jsonEncode(result.toJson());
    final decoded = BenchResult.fromJson(
      (jsonDecode(serialized)! as Map).cast<String, Object?>(),
    );

    expect(decoded.toJson(), result.toJson());
    expect(decoded.rttMs, 100);
    expect(decoded.throughputTrials, hasLength(1));
  });
}

ThroughputAttempt _attempt({
  required ThroughputAttemptPhase phase,
  required String reference,
  required ThroughputVariant? variant,
  required ThroughputReplicate? replicate,
  required int? ordinal,
  required RttEvidence rtt,
  String? primeReference,
  String? warmupReference,
}) => ThroughputAttempt(
  reference: reference,
  scenario: 'dart-hash-on-download-1mb-rtt100',
  direction: ThroughputLeg.download,
  variant: variant,
  replicate: replicate,
  ordinal: ordinal,
  phase: phase,
  payloadBytes: 1,
  status: ThroughputAttemptStatus.success,
  startedAtUtc: DateTime.utc(2026, 9, 1, 12, 4),
  endedAtUtc: DateTime.utc(2026, 9, 1, 12, 4, 1),
  elapsed: const Duration(microseconds: 10),
  primeReference: primeReference,
  warmupReference: warmupReference,
  rttEvidence: rtt,
  integrity: const ThroughputIntegrityEvidence(
    status: ThroughputIntegrityStatus.verified,
    expectedBytes: 1,
    actualBytes: 1,
    expectedSha256: 'digest',
    actualSha256: 'digest',
    destination: '/tmp/destination',
  ),
);
