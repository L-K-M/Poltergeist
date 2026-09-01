import 'package:poltergeist_m0_bench/fixture_data.dart';
import 'package:poltergeist_m0_bench/throughput.dart';
import 'package:test/test.dart';

void main() {
  group('ThroughputSlice', () {
    test('full includes every transfer', () {
      expect(_selectedTransfers(ThroughputSlice.full), hasLength(6));
    });

    test('without 1 GB upload keeps the other five transfers', () {
      expect(_selectedTransfers(ThroughputSlice.withoutOneGigabyteUpload), [
        (ThroughputLeg.download, fixturePayload1MbBytes),
        (ThroughputLeg.upload, fixturePayload1MbBytes),
        (ThroughputLeg.download, fixturePayload100MbBytes),
        (ThroughputLeg.upload, fixturePayload100MbBytes),
        (ThroughputLeg.download, fixturePayload1GbBytes),
      ]);
    });

    test('only 1 GB upload excludes every other transfer', () {
      expect(_selectedTransfers(ThroughputSlice.onlyOneGigabyteUpload), [
        (ThroughputLeg.upload, fixturePayload1GbBytes),
      ]);
    });

    test('parses only named CLI values', () {
      expect(ThroughputSlice.parse('full'), ThroughputSlice.full);
      expect(
        ThroughputSlice.parse('without-1gb-upload'),
        ThroughputSlice.withoutOneGigabyteUpload,
      );
      expect(
        ThroughputSlice.parse('only-1gb-upload'),
        ThroughputSlice.onlyOneGigabyteUpload,
      );
      expect(() => ThroughputSlice.parse('uploads'), throwsFormatException);
    });
  });

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

List<(ThroughputLeg, int)> _selectedTransfers(ThroughputSlice slice) {
  const payloadBytes = [
    fixturePayload1MbBytes,
    fixturePayload100MbBytes,
    fixturePayload1GbBytes,
  ];

  return [
    for (final bytes in payloadBytes)
      for (final leg in ThroughputLeg.values)
        if (slice.includes(leg, bytes)) (leg, bytes),
  ];
}
