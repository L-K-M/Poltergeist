import 'measure_rtt.dart';
import 'package:test/test.dart';

void main() {
  test('measures the SSH version-to-KEX exchange', () async {
    var clock = Duration.zero;
    final probe = _FakeSshRttProbe(
      onKex: () => clock = const Duration(milliseconds: 10),
    );

    final elapsed = await measureSshExchange(
      'fixture',
      2201,
      connect: (_, _) async => probe,
      now: () => clock,
    );

    expect(probe.calls, ['read-version', 'send-version', 'read-kex', 'close']);
    expect(elapsed, const Duration(milliseconds: 10));
  });

  test('retains seven RTT probes in capture order', () async {
    const capturedMicroseconds = [
      100500,
      99000,
      150000,
      100499,
      100501,
      50000,
      200000,
    ];
    var sampleIndex = 0;
    final evidence = await measureSshRtt(
      'fixture',
      2201,
      measureExchange: (_, _) async =>
          Duration(microseconds: capturedMicroseconds[sampleIndex++]),
      utcNow: () => DateTime.parse('2026-09-01T14:30:00+02:00'),
    );

    expect(evidence.samplesUs, capturedMicroseconds);
    expect(evidence.median, const Duration(microseconds: 100500));
    expect(evidence.medianMs, 101);
    expect(evidence.capturedAtUtc, DateTime.utc(2026, 9, 1, 12, 30));
    expect(evidence.toJson(), {
      'samplesUs': capturedMicroseconds,
      'medianMs': 101,
      'capturedAtUtc': '2026-09-01T12:30:00.000Z',
    });
  });

  test('floors an even-sample midpoint before rounding', () {
    final median = medianRtt(const [
      Duration(microseconds: 100499),
      Duration(microseconds: 100500),
    ]);

    expect(median, const Duration(microseconds: 100499));
    expect(roundRttMilliseconds(median), 100);
  });

  test('formats JSON evidence without changing integer output', () {
    final evidence = SshRttEvidence(
      samplesUs: const [100000, 100001, 100002],
      median: const Duration(microseconds: 100001),
      capturedAtUtc: DateTime.utc(2026, 9, 1),
    );

    expect(formatRttEvidence(evidence, RttOutputFormat.medianMs), '100');
    expect(
      formatRttEvidence(evidence, RttOutputFormat.json),
      '{"samplesUs":[100000,100001,100002],"medianMs":100,'
      '"capturedAtUtc":"2026-09-01T00:00:00.000Z"}',
    );
  });
}

class _FakeSshRttProbe implements SshRttProbe {
  final List<String> calls = [];
  final void Function() onKex;

  _FakeSshRttProbe({required this.onKex});

  @override
  Future<void> readServerIdentification() async {
    calls.add('read-version');
  }

  @override
  Future<void> sendClientIdentification() async {
    calls.add('send-version');
  }

  @override
  Future<void> readServerKexHeader() async {
    calls.add('read-kex');
    onKex();
  }

  @override
  Future<void> close() async {
    calls.add('close');
  }
}
