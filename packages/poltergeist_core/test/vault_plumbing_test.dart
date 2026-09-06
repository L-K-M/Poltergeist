import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

// Pins the vault/keystore plumbing re-exported through this package's
// barrel: consumers must never import seance_core directly. A name in an
// `export ... show` list that the pinned library no longer provides fails
// silently at the barrel itself, so every newly re-exported symbol is
// referenced here — a pin that drops or renames one must fail in this
// package, not in the app layer's ports.

void main() {
  test('every vault/keystore barrel symbol resolves at this pin', () {
    expect(
      <Object>[
        Argon2Params,
        HostKeyStore,
        InMemoryHostKeyStore,
        InMemoryVaultStore,
        PreferredPane,
        Secret,
        SecretKind,
        SecretVault,
        ServerColor,
        ServerIcon,
        VaultCrypto,
        VaultKeys,
        VaultStore,
        secureRandomBytes,
      ],
      hasLength(14),
    );
  });

  test('seals, opens, and deletes secrets through the barrel', () async {
    final store = InMemoryVaultStore();
    final vault = SecretVault(store, secureRandomBytes(32));
    const secret = Secret(
      id: 'secret-1',
      kind: SecretKind.password,
      value: 'hunter2',
    );

    await vault.putSecret(secret);
    expect((await vault.getSecret('secret-1'))!.value, 'hunter2');

    final sealed = await store.getSecretBlob('secret-1');
    expect(sealed, isNotNull);

    // The blob is opaque ciphertext: never the plaintext, never ASCII JSON.
    expect(String.fromCharCodes(sealed!), isNot(contains('hunter2')));

    // Fresh nonce per seal (the pinned doc contract): identical plaintext
    // under the same key must never mint identical ciphertext — nonce
    // reuse breaks the AEAD outright.
    await vault.putSecret(
      const Secret(id: 'secret-2', kind: SecretKind.password, value: 'hunter2'),
    );
    expect(await store.getSecretBlob('secret-2'), isNot(equals(sealed)));

    await vault.deleteSecret('secret-1');
    expect(await vault.getSecret('secret-1'), isNull);
  });
}
