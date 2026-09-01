import 'package:poltergeist_m0_bench/fixture_data.dart';
import 'package:poltergeist_m0_bench/throughput.dart';
import 'package:test/test.dart';

void main() {
  test('warms variants and records counterbalanced repeated trials', () async {
    final calls = <ThroughputVariant>[];
    var elapsed = 0;

    final samples = await collectCounterbalancedSamples((variant) async {
      calls.add(variant);
      elapsed += 10;
      return Duration(microseconds: elapsed);
    });

    expect(calls, [
      ThroughputVariant.dartHashOn,
      ThroughputVariant.dartHashOn,
      ThroughputVariant.openssh,
      ThroughputVariant.openssh,
      ThroughputVariant.dartHashOff,
      ThroughputVariant.dartHashOff,
      ThroughputVariant.dartHashOff,
      ThroughputVariant.dartHashOff,
      ThroughputVariant.openssh,
      ThroughputVariant.openssh,
      ThroughputVariant.dartHashOn,
      ThroughputVariant.dartHashOn,
    ]);
    expect(samples.sampleCount, 2);
    expect(
      samples.medianFor(ThroughputVariant.openssh),
      const Duration(microseconds: 70),
    );
  });

  test('keeps bounded warmups outside measured trials', () async {
    final warmups = <ThroughputVariant>[];
    final trials = <ThroughputVariant>[];

    await collectCounterbalancedSamples(
      (variant) async {
        trials.add(variant);
        return const Duration(microseconds: 1);
      },
      warmup: (variant) async {
        warmups.add(variant);
        return Duration.zero;
      },
    );

    expect(warmups, [
      ThroughputVariant.dartHashOn,
      ThroughputVariant.openssh,
      ThroughputVariant.dartHashOff,
      ThroughputVariant.dartHashOff,
      ThroughputVariant.openssh,
      ThroughputVariant.dartHashOn,
    ]);
    expect(trials, hasLength(6));
  });

  test('rejects a stale hash-on digest', () {
    expect(
      () => validateThroughputEntry(
        actualBytes: 1_000_000,
        digest: 'stale',
        expectedBytes: 1_000_000,
        expectedDigest: fixturePayload1MbSha256,
        hashMode: HashMode.on,
      ),
      throwsStateError,
    );
  });
}
