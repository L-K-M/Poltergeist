import 'config.dart';
import 'harness.dart';
import 'ssh_driver.dart';

const _algorithmProfiles = [
  _AlgorithmProfile('default', 2201),
  _AlgorithmProfile('rsa-sha2-only', 2211),
  _AlgorithmProfile('chacha-curve-pq', 2212),
  _AlgorithmProfile('ed25519-only', 2213),
];

Future<List<BenchResult>> runAlgorithmAudit(BenchConfig config) async {
  final results = <BenchResult>[];
  for (final profile in _algorithmProfiles) {
    final endpoint = BenchEndpoint(
      host: config.endpoint.host,
      port: profile.port,
      username: config.endpoint.username,
      password: config.endpoint.password,
    );
    final audit = await auditAlgorithms(endpoint);
    results.add(
      BenchResult.capture(
        scenario: 'algorithm-${profile.name}',
        bytes: 0,
        elapsed: audit.elapsed,
        note: '${audit.outcome.name}: ${audit.detail}',
      ),
    );
  }
  return results;
}

class _AlgorithmProfile {
  final String name;
  final int port;

  const _AlgorithmProfile(this.name, this.port);
}
