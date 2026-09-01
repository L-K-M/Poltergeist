import 'package:dartssh2/dartssh2.dart';

import 'config.dart';
import 'harness.dart';
import 'ssh_driver.dart';

const _modernPort = 2201;
const _legacyPort = 2202;
const _rsaPort = 2211;
const _chachaPort = 2212;
const _ed25519Port = 2213;

const _algorithmProfiles = [
  _AlgorithmProfile('default', _modernPort),
  _AlgorithmProfile('legacy-default', _legacyPort),
  _AlgorithmProfile(
    'aes128-gcm',
    _modernPort,
    algorithms: SSHAlgorithms(cipher: [SSHCipherType.aes128gcm]),
  ),
  _AlgorithmProfile(
    'aes256-gcm',
    _modernPort,
    algorithms: SSHAlgorithms(cipher: [SSHCipherType.aes256gcm]),
  ),
  _AlgorithmProfile(
    'rsa-sha2-512',
    _rsaPort,
    algorithms: SSHAlgorithms(hostkey: [SSHHostkeyType.rsaSha512]),
  ),
  _AlgorithmProfile(
    'rsa-sha2-256',
    _rsaPort,
    algorithms: SSHAlgorithms(hostkey: [SSHHostkeyType.rsaSha256]),
  ),
  _AlgorithmProfile('chacha-curve-pq', _chachaPort),
  _AlgorithmProfile('ed25519-only', _ed25519Port),
];

typedef AlgorithmProbe =
    Future<AlgorithmAuditResult> Function(
      BenchEndpoint endpoint, {
      SSHAlgorithms? algorithms,
    });

Future<List<BenchResult>> runAlgorithmAudit(
  BenchConfig config, {
  AlgorithmProbe probe = auditAlgorithms,
}) async {
  final results = <BenchResult>[];
  for (final profile in _algorithmProfiles) {
    final endpoint = BenchEndpoint(
      host: config.endpoint.host,
      port: profile.port,
      username: config.endpoint.username,
      password: config.endpoint.password,
    );
    final audit = await probe(endpoint, algorithms: profile.algorithms);
    results.add(
      BenchResult.capture(
        scenario: 'algorithm-${profile.name}',
        bytes: 0,
        elapsed: audit.elapsed,
        note: '${audit.outcome.name}: ${audit.detail}',
      ),
    );
  }
  results.addAll(_clientSupportEvidence());
  return results;
}

class _AlgorithmProfile {
  final String name;
  final int port;
  final SSHAlgorithms? algorithms;

  const _AlgorithmProfile(this.name, this.port, {this.algorithms});
}

List<BenchResult> _clientSupportEvidence() {
  final ciphers = SSHCipherType.values.map((algorithm) => algorithm.name);
  final kex = const SSHAlgorithms().kex.map((algorithm) => algorithm.name);
  return [
    _supportResult(
      'chacha20-poly1305',
      'chacha20-poly1305@openssh.com',
      ciphers,
    ),
    _supportResult('curve25519', 'curve25519-sha256', kex),
    _supportResult('mlkem768x25519', 'mlkem768x25519-sha256', kex),
  ];
}

BenchResult _supportResult(
  String scenarioSuffix,
  String requiredAlgorithm,
  Iterable<String> availableAlgorithms,
) {
  final available = availableAlgorithms.toList(growable: false);
  return BenchResult.capture(
    scenario: 'algorithm-client-support-$scenarioSuffix',
    bytes: 0,
    elapsed: Duration.zero,
    note:
        'supported=${available.contains(requiredAlgorithm)}; '
        'required=$requiredAlgorithm; available=${available.join(',')}',
  );
}
