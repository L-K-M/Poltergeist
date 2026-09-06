import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:poltergeist_app/services/file_stores.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_file_stores_test_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  group('FileVaultStore', () {
    test('persists sealed blobs across store instances', () async {
      final file = File('${temporaryDirectory.path}/vault.json');
      final vaultKey = secureRandomBytes(32);

      await SecretVault(FileVaultStore(file), vaultKey).putSecret(
        const Secret(id: 's1', kind: SecretKind.password, value: 'hunter2'),
      );

      // Only opaque ciphertext lands on disk.
      final raw = await file.readAsString();
      expect(raw, isNot(contains('hunter2')));
      expect(raw, contains('"s1"'));

      // A fresh store over the same file opens what the first one sealed.
      final reopened = SecretVault(FileVaultStore(file), vaultKey);
      expect((await reopened.getSecret('s1'))!.value, 'hunter2');
    });

    test('deleting a secret removes it from disk', () async {
      final file = File('${temporaryDirectory.path}/vault.json');
      final vault = SecretVault(FileVaultStore(file), secureRandomBytes(32));
      await vault.putSecret(
        const Secret(id: 's1', kind: SecretKind.password, value: 'x'),
      );
      await vault.deleteSecret('s1');

      expect(await vault.getSecret('s1'), isNull);
      expect(await FileVaultStore(file).getSecretBlob('s1'), isNull);
    });

    test('a corrupt vault file starts empty instead of wedging startup',
        () async {
      final file = File('${temporaryDirectory.path}/vault.json');
      await file.parent.create(recursive: true);
      await file.writeAsString('{not json');

      final store = FileVaultStore(file);
      expect(await store.getSecretBlob('s1'), isNull);

      // The bad file is quarantined aside, not deleted.
      final quarantined = temporaryDirectory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.corrupt-'))
          .toList();
      expect(quarantined, hasLength(1));
      expect(file.existsSync(), isFalse);
    });
  });

  group('FileHostKeyStore', () {
    const key = HostKey(
      host: 'nas.local',
      port: 2222,
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:abc123',
      pinnedAt: 1700000000,
    );

    test('pins and reloads host keys across instances', () async {
      final file = File('${temporaryDirectory.path}/known_hosts.json');
      await FileHostKeyStore(file).put(key);

      final reloaded = await FileHostKeyStore(file).get('nas.local', 2222);
      expect(reloaded!.fingerprintSha256, 'SHA256:abc123');
      expect(await FileHostKeyStore(file).all(), hasLength(1));
    });

    test('a corrupt known_hosts file starts empty instead of wedging startup',
        () async {
      final file = File('${temporaryDirectory.path}/known_hosts.json');
      await file.parent.create(recursive: true);
      await file.writeAsString('[{');

      final store = FileHostKeyStore(file);
      expect(await store.get('nas.local', 2222), isNull);
      expect(await store.all(), isEmpty);

      expect(
        temporaryDirectory
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('.corrupt-')),
        hasLength(1),
      );
    });
  });
}
