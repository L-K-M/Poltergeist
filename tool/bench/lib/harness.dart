import 'dart:io';

import 'throughput_attempt.dart';

const resolvedDartssh2Version = '3.0.2';
const pinnedSeanceRevision = '2f99f4efb25a83340605464635bdf0f3ba95d931';

/// One attributable measurement row. Rates stay derived from raw values.
class BenchResult {
  final String scenario;
  final int bytes;
  final Duration elapsed;
  final String? note;
  final String dartssh2Version;
  final String seanceRev;
  final int? rttMs;
  final RttEvidence? rttEvidence;
  final List<ThroughputTrialEvidence>? throughputTrials;
  final DateTime timestampUtc;
  final String host;

  BenchResult({
    required this.scenario,
    required this.bytes,
    required this.elapsed,
    this.note,
    required this.dartssh2Version,
    required this.seanceRev,
    int? rttMs,
    this.rttEvidence,
    List<ThroughputTrialEvidence>? throughputTrials,
    required this.timestampUtc,
    required this.host,
  }) : rttMs = rttMs ?? rttEvidence?.medianMs,
       throughputTrials = throughputTrials == null
           ? null
           : List.unmodifiable(throughputTrials) {
    if (rttMs != null &&
        rttEvidence != null &&
        rttMs != rttEvidence!.medianMs) {
      throw ArgumentError('RTT scalar and evidence disagree.');
    }
  }

  factory BenchResult.capture({
    required String scenario,
    required int bytes,
    required Duration elapsed,
    String? note,
    int? rttMs,
    RttEvidence? rttEvidence,
    List<ThroughputTrialEvidence>? throughputTrials,
  }) => BenchResult(
    scenario: scenario,
    bytes: bytes,
    elapsed: elapsed,
    note: note,
    dartssh2Version: resolvedDartssh2Version,
    seanceRev: pinnedSeanceRevision,
    rttMs: rttMs,
    rttEvidence: rttEvidence,
    throughputTrials: throughputTrials,
    timestampUtc: DateTime.now().toUtc(),
    host: Platform.localHostname,
  );

  factory BenchResult.fromJson(Map<String, Object?> json) {
    final rawRttEvidence = json['rttEvidence'];
    final rawTrials = json['throughputTrials'];
    return BenchResult(
      scenario: json['scenario']! as String,
      bytes: json['bytes']! as int,
      elapsed: Duration(microseconds: json['elapsedUs']! as int),
      note: json['note'] as String?,
      dartssh2Version: json['dartssh2Version']! as String,
      seanceRev: json['seanceRev']! as String,
      rttMs: json['rttMs'] as int?,
      rttEvidence: rawRttEvidence == null
          ? null
          : RttEvidence.fromJson(
              (rawRttEvidence as Map).cast<String, Object?>(),
            ),
      throughputTrials: rawTrials == null
          ? null
          : (rawTrials as List<Object?>)
                .map(
                  (trial) => ThroughputTrialEvidence.fromJson(
                    (trial! as Map).cast<String, Object?>(),
                  ),
                )
                .toList(),
      timestampUtc: DateTime.parse(json['timestampUtc']! as String),
      host: json['host']! as String,
    );
  }

  double get mbPerSec => bytes / elapsed.inMicroseconds;

  Map<String, Object?> toJson() => {
    'scenario': scenario,
    'bytes': bytes,
    'dartssh2Version': dartssh2Version,
    'seanceRev': seanceRev,
    'rttMs': rttMs,
    if (rttEvidence != null) 'rttEvidence': rttEvidence!.toJson(),
    'elapsedUs': elapsed.inMicroseconds,
    'note': note,
    'timestampUtc': timestampUtc.toIso8601String(),
    'host': host,
    if (throughputTrials != null)
      'throughputTrials': throughputTrials!
          .map((trial) => trial.toJson())
          .toList(),
  };
}

class BenchRunFailure implements Exception {
  final String message;
  final List<BenchResult> results;

  const BenchRunFailure(this.message, this.results);

  @override
  String toString() => message;
}
