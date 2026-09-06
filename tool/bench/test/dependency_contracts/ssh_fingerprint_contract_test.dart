import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartssh2/dartssh2.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../support/host_key_peer.dart';

void main() {
  test('SSH contract exercises the product dartssh2 version', () async {
    // Separate resolution must not let a product bump test an old dependency.
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:dartssh2/dartssh2.dart'),
    );
    final manifest =
        loadYaml(
              await File.fromUri(
                library!.resolve('../pubspec.yaml'),
              ).readAsString(),
            )
            as YamlMap;
    final harness = await Isolate.resolvePackageUri(
      Uri.parse('package:poltergeist_m0_bench/harness.dart'),
    );
    // Anchor to this checkout even when the runner starts elsewhere.
    final lock =
        loadYaml(
              await File.fromUri(
                harness!.resolve('../../../pubspec.lock'),
              ).readAsString(),
            )
            as YamlMap;

    expect(manifest['version'], lock['packages']['dartssh2']['version']);
  });

  // Keep raw SSH tests in the sanctioned harness, outside product layers.
  test(
    'host-key callback receives OpenSSH SHA256 text as UTF-8 bytes',
    () async {
      final peer = HostKeyPeer();
      addTearDown(peer.close);
      final received = <(String, List<int>)>[];
      final client = SSHClient(
        peer.socket,
        username: 'contract-test',
        onVerifyHostKey: (type, fingerprint) {
          received.add((type, List<int>.of(fingerprint)));
          // Stop before authentication; this test owns only the trust boundary.
          return false;
        },
      );
      addTearDown(client.close);

      await expectLater(
        client.authenticated,
        throwsA(
          isA<SSHAuthAbortError>().having(
            (error) => error.reason,
            'reason',
            isA<SSHHostkeyError>(),
          ),
        ),
      );

      expect(received, hasLength(1));
      expect(received.single.$1, HostKeyPeer.hostKeyType);
      expect(received.single.$2, utf8.encode(HostKeyPeer.fingerprint));
    },
  );
}
