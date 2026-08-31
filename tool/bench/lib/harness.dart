import 'dart:io';

const resolvedDartssh2Version = '2.22.0';
const pinnedSeanceRevision = '43d5d90d39a6b838091f60ddcbacb1a9fb5aea79';

/// One attributable measurement row. Rates stay derived from raw values.
class BenchResult {
  final String scenario;
  final int bytes;
  final Duration elapsed;
  final String? note;
  final String dartssh2Version;
  final String seanceRev;
  final int? rttMs;
  final DateTime timestampUtc;
  final String host;

  const BenchResult({
    required this.scenario,
    required this.bytes,
    required this.elapsed,
    this.note,
    required this.dartssh2Version,
    required this.seanceRev,
    this.rttMs,
    required this.timestampUtc,
    required this.host,
  });

  factory BenchResult.capture({
    required String scenario,
    required int bytes,
    required Duration elapsed,
    String? note,
    int? rttMs,
  }) => BenchResult(
    scenario: scenario,
    bytes: bytes,
    elapsed: elapsed,
    note: note,
    dartssh2Version: resolvedDartssh2Version,
    seanceRev: pinnedSeanceRevision,
    rttMs: rttMs,
    timestampUtc: DateTime.now().toUtc(),
    host: Platform.localHostname,
  );

  factory BenchResult.fromJson(Map<String, Object?> json) => BenchResult(
    scenario: json['scenario']! as String,
    bytes: json['bytes']! as int,
    elapsed: Duration(microseconds: json['elapsedUs']! as int),
    note: json['note'] as String?,
    dartssh2Version: json['dartssh2Version']! as String,
    seanceRev: json['seanceRev']! as String,
    rttMs: json['rttMs'] as int?,
    timestampUtc: DateTime.parse(json['timestampUtc']! as String),
    host: json['host']! as String,
  );

  double get mbPerSec => bytes / elapsed.inMicroseconds;

  Map<String, Object?> toJson() => {
    'scenario': scenario,
    'bytes': bytes,
    'dartssh2Version': dartssh2Version,
    'seanceRev': seanceRev,
    'rttMs': rttMs,
    'elapsedUs': elapsed.inMicroseconds,
    'note': note,
    'timestampUtc': timestampUtc.toIso8601String(),
    'host': host,
  };
}

class BenchRunFailure implements Exception {
  final String message;
  final List<BenchResult> results;

  const BenchRunFailure(this.message, this.results);

  @override
  String toString() => message;
}
