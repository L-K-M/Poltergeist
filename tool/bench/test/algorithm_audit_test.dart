import 'package:poltergeist_m0_bench/algorithm_audit.dart';
import 'package:poltergeist_m0_bench/config.dart';
import 'package:poltergeist_m0_bench/ssh_driver.dart';
import 'package:test/test.dart';

void main() {
  test(
    'audits forced AES-GCM and independent modern-algorithm support',
    () async {
      final forcedCiphers = <String>[];
      final forcedHostKeys = <String>[];
      final results = await runAlgorithmAudit(
        _config,
        probe: (endpoint, {algorithms}) async {
          forcedCiphers.addAll(
            algorithms?.cipher.map((cipher) => cipher.name) ?? const [],
          );
          forcedHostKeys.addAll(
            algorithms?.hostkey.map((hostKey) => hostKey.name) ?? const [],
          );
          return const AlgorithmAuditResult(
            outcome: AlgorithmAuditOutcome.connected,
            elapsed: Duration.zero,
            detail: 'connected',
          );
        },
      );

      expect(
        forcedCiphers,
        containsAll(['aes128-gcm@openssh.com', 'aes256-gcm@openssh.com']),
      );
      expect(forcedHostKeys, containsAll(['rsa-sha2-256', 'rsa-sha2-512']));
      expect(
        results.map((result) => result.scenario),
        containsAll([
          'algorithm-legacy-default',
          'algorithm-aes128-gcm',
          'algorithm-aes256-gcm',
          'algorithm-rsa-sha2-256',
          'algorithm-rsa-sha2-512',
          'algorithm-client-support-chacha20-poly1305',
          'algorithm-client-support-curve25519',
          'algorithm-client-support-mlkem768x25519',
        ]),
      );
    },
  );
}

const _config = BenchConfig(
  endpoint: BenchEndpoint(
    host: '127.0.0.1',
    port: 2201,
    username: 'poltergeist',
    password: 'test',
  ),
  remoteRoot: '/home/poltergeist/bench',
  identityFile: 'unused',
  outputFile: 'unused',
  linkName: 'lan',
  fixtureRoot: 'unused',
  uploadRoot: 'unused',
  rttEvidence: null,
);
