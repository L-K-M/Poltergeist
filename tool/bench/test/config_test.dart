import 'dart:convert';

import 'package:poltergeist_m0_bench/config.dart';
import 'package:poltergeist_m0_bench/throughput_attempt.dart';
import 'package:test/test.dart';

void main() {
  test('endpoint settings remain isolate-sendable', () {
    const endpoint = BenchEndpoint(
      host: 'fixture',
      port: 2201,
      username: 'user',
      password: 'test-only',
      identityFile: '/fixture/id_ed25519',
    );

    final decoded = BenchEndpoint.fromJson(endpoint.toJson());

    expect(decoded.toJson(), endpoint.toJson());
    expect(decoded.identityFile, '/fixture/id_ed25519');
  });

  test('parses attributable seven-probe RTT evidence', () {
    final evidence = RttEvidence.parse(
      jsonEncode({
        'samplesUs': [103000, 99000, 101000, 100000, 102000, 98000, 104000],
        'medianMs': 101,
        'capturedAtUtc': '2026-09-01T12:34:56.000Z',
      }),
    );

    expect(evidence.samplesUs, [
      103000,
      99000,
      101000,
      100000,
      102000,
      98000,
      104000,
    ]);
    expect(evidence.medianMs, 101);
    expect(evidence.capturedAtUtc, DateTime.utc(2026, 9, 1, 12, 34, 56));
    expect(evidence.reference, startsWith('rtt-sha256:'));
    expect(RttEvidence.fromJson(evidence.toJson()), evidence);
  });

  test('rejects incomplete or inconsistent RTT evidence', () {
    expect(
      () => RttEvidence.parse(
        '{"samplesUs":[100000],"medianMs":100,'
        '"capturedAtUtc":"2026-09-01T12:34:56Z"}',
      ),
      throwsFormatException,
    );
    expect(
      () => RttEvidence.parse(
        '{"samplesUs":[100000,100000,100000,100000,100000,100000,100000],'
        '"medianMs":99,"capturedAtUtc":"2026-09-01T12:34:56Z"}',
      ),
      throwsFormatException,
    );
  });
}
