import 'package:poltergeist_m0_bench/harness.dart';
import 'package:test/test.dart';

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

    final decoded = BenchResult.fromJson(result.toJson());

    expect(decoded.toJson(), result.toJson());
    expect(decoded.mbPerSec, 250);
    expect(result.toJson(), result.toJson());
  });
}
