// Tier-B results-file emission (08 §6): the in-app side of the D12
// `poltergeist-d12-results-1` document that the bench job merges with
// the tier-A collectors' output into bench-results.json. Kept pure —
// the integration suites feed it measurements; this owns only the row
// shape, the fingerprint carrier, and the atomic publication.
//
// Row and fingerprint semantics mirror test/benchmarks/check_core.dart:
// every row carries the job-wide environment fingerprint, `status` is
// `ok` (with value+unit) or `error` (with a message, never a value),
// and `scenarioConfig` is the per-scenario fixture-identity axis.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show kDebugMode, kProfileMode, kReleaseMode;

/// The results document's schema id, shared with the tier-A collectors
/// and enforced by test/benchmarks/check_core.dart.
const resultsSchemaId = 'poltergeist-d12-results-1';

/// The environment fingerprint axes every row carries. Mirrors the
/// tier-A collectors: [mode] is DETECTED (a debug run can never report
/// `profile` — the checker's row eligibility then rejects it loudly),
/// never declared.
final class BenchFingerprint {
  const BenchFingerprint({
    required this.runnerImage,
    required this.arch,
    required this.dartVersion,
    required this.flutterVersion,
    required this.mode,
    required this.cpuModel,
  });

  final String runnerImage;
  final String arch;
  final String dartVersion;
  final String? flutterVersion;
  final String mode;
  final String cpuModel;

  /// The mode the running VM actually is: `profile` only under
  /// `dart.vm.product`'s profile sibling. A JIT integration run reports
  /// `debug`, which the checker counts as ineligible for tier B — the
  /// intended loud failure for a wrongly built run.
  static String detectMode() {
    if (kProfileMode) return 'profile';
    if (kDebugMode) return 'debug';
    if (kReleaseMode) return 'release';
    return 'unknown';
  }

  /// The VM arch suffix of [Platform.version] (`... on "linux_x64"`),
  /// matching the tier-A collectors' `_vmArch`.
  static String detectArch() {
    final match = RegExp(r'"([^"]+)"\s*$').firstMatch(Platform.version);
    return match?.group(1) ?? 'unknown';
  }

  /// The CPU model from /proc/cpuinfo, matching the tier-A collectors;
  /// [override] (POLTERGEIST_BENCH_CPU_MODEL) wins. 'unknown' when the
  /// host cannot say — never a fabricated axis.
  static Future<String> detectCpuModel(String? override) async {
    if (override != null && override.isNotEmpty) return override;
    try {
      final cpuinfo = await File('/proc/cpuinfo').readAsString();
      final match = RegExp(
        r'^model name\s*:\s*(.+)$',
        multiLine: true,
      ).firstMatch(cpuinfo);
      if (match != null) return match.group(1)!.trim();
    } on FileSystemException {
      // Not Linux (or unreadable): fall through to the honest unknown.
    }
    return 'unknown';
  }

  Map<String, Object?> toJson(String scenarioConfig) => {
    'runnerImage': runnerImage,
    'arch': arch,
    'dartVersion': dartVersion,
    'flutterVersion': flutterVersion,
    'mode': mode,
    'cpuModel': cpuModel,
    'scenarioConfig': scenarioConfig,
  };
}

/// Accumulates one scenario's per-repetition rows and publishes them as
/// a results document. The writer never drops a failed observation:
/// [addError] rows land beside the `ok` siblings so the checker sees the
/// incomplete measurement set.
final class BenchResults {
  BenchResults({required this.fingerprint});

  final BenchFingerprint fingerprint;
  final List<Map<String, Object?>> _rows = [];

  List<Map<String, Object?>> get rows => List.unmodifiable(_rows);

  void addValue({
    required String scenario,
    required int repetition,
    required double value,
    required String unit,
    required String scenarioConfig,
  }) {
    _rows.add({
      'scenario': scenario,
      'repetition': repetition,
      'status': 'ok',
      'value': value,
      'unit': unit,
      'fingerprint': fingerprint.toJson(scenarioConfig),
    });
  }

  void addError({
    required String scenario,
    required int repetition,
    required String error,
    required String scenarioConfig,
  }) {
    _rows.add({
      'scenario': scenario,
      'repetition': repetition,
      'status': 'error',
      'error': error,
      'fingerprint': fingerprint.toJson(scenarioConfig),
    });
  }

  Map<String, Object?> toJson() => {
    'schema': resultsSchemaId,
    'rows': rows,
  };

  /// Owned-temp + rename publication, the same class the merger and the
  /// tier-A collectors use: a torn write never leaves a valid-looking
  /// results file behind.
  Future<void> writeTo(String path) async {
    final target = File(path).absolute;
    final temporary = File(
      '${target.path}.bench-$pid-'
      '${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temporary.create(exclusive: true);
    try {
      await temporary.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(toJson())}\n',
        flush: true,
      );
      await temporary.rename(target.path);
    } catch (_) {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {
        // Best-effort cleanup; the write error above is the reported one.
      }
      rethrow;
    }
  }
}
