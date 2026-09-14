import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:test/test.dart';

import '../support/host_key_peer.dart';

void main() {
  test('peer ignores buffered client data after immediate close', () async {
    final peer = HostKeyPeer();
    addTearDown(peer.close);
    final client = SSHClient(peer.socket, username: 'contract-test');
    addTearDown(client.close);
    final aborted = expectLater(
      client.authenticated,
      throwsA(isA<SSHAuthAbortError>()),
    );

    // The banner is queued, but the peer has not processed it yet.
    await client.close();
    await aborted;
    await client.done;
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
