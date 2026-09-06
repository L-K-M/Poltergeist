import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

const _nonceLength = 24;
const _macLength = 16;
const _fixturePassphrase = 'Poltergeist vault contract';
const _fixtureSalt = '000102030405060708090a0b0c0d0e0f';
const _fixtureParams = Argon2Params(
  memory: 64,
  iterations: 2,
  parallelism: 1,
  hashLength: 32,
);

// Independent fixture: argon2-cffi 25.1.0 hash_secret_raw(Type.ID, version=19)
// with the inputs above; memory_cost=64 means KiB. Subkeys use Python hmac:
// PRK = HMAC-SHA256(domain, master); OKM = HMAC-SHA256(PRK, b'\x01').
// This is RFC 5869 extract/expand with an empty info field, not a round trip.
const _fixtureMaster =
    '82ee6580d2371d9456235eede187f3c8dd2a01faa8a2de4bcda8adb290053e6d';
const _fixtureVaultKey =
    'be31ac22976334b1f9baf40d7efaed9f0783e4c8131d66fcd0d536ffc4531ce0';
const _fixtureAuthVerifier =
    '27008e5ba6668715b4872d9185fd39a3eff3b81ef29992273323a35dd0170a57';

const _sealingKey =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const _sealingPlaintext = 'bookmark contract: /srv/data/\u{1f47b}';

// Independent PyNaCl 1.5.0 crypto_aead_xchacha20poly1305_ietf_encrypt fixture:
// UTF-8 plaintext above, no AAD, key above, nonce bytes 00 through 17.
const _sealedFixture =
    '000102030405060708090a0b0c0d0e0f1011121314151617' // nonce
    'fcad6014fdb3ffc5132749a0bf20c98b3f7d088a8ea46bc41b7b4bd7125d6ac8e5'
    '0cdaba354e2389ee516bdc5c73746834'; // MAC

void main() {
  test('Argon2id memory is KiB (RFC 9106 section 5.3)', () async {
    // https://www.rfc-editor.org/rfc/rfc9106.html#section-5.3
    // The published answer detects a memory-unit change independently of Vault.
    const memoryKiB = 32;
    const iterations = 3;
    const parallelism = 4;
    const hashLength = 32;
    final algorithm = Argon2id(
      memory: memoryKiB,
      iterations: iterations,
      parallelism: parallelism,
      hashLength: hashLength,
    );
    final derived = await algorithm.deriveKey(
      secretKey: SecretKey(
        _hex(
          '0101010101010101010101010101010101010101010101010101010101010101',
        ),
      ),
      nonce: _hex('02020202020202020202020202020202'),
      optionalSecret: _hex('0303030303030303'),
      associatedData: _hex('040404040404040404040404'),
    );

    expect(
      await derived.extractBytes(),
      _hex('0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659'),
    );
  });

  group('VaultCrypto key derivation', () {
    late VaultKeys keys;

    setUpAll(() async {
      keys = await VaultCrypto.deriveKeys(
        passphrase: _fixturePassphrase,
        salt: _hex(_fixtureSalt),
        params: _fixtureParams,
      );
    });

    test('passes Argon2 memory through as KiB', () {
      expect(keys.masterKey, _hex(_fixtureMaster));
    });

    test('separates vault and auth domains with HKDF salts', () {
      expect(
        keys.vaultKey,
        _hex(_fixtureVaultKey),
        reason: 'HKDF salt is seance/v1/vault-encryption-key; info is empty',
      );
      expect(
        keys.authVerifier,
        _hex(_fixtureAuthVerifier),
        reason: 'HKDF salt is seance/v1/auth-verifier; info is empty',
      );
      expect(keys.vaultKey, isNot(orderedEquals(keys.authVerifier)));
    });
  });

  test('VaultCrypto opens nonce(24) || ciphertext || mac(16)', () async {
    final plaintext = await VaultCrypto.open(
      _hex(_sealingKey),
      _hex(_sealedFixture),
    );

    expect(plaintext, utf8.encode(_sealingPlaintext));
  });

  test('VaultCrypto seals nonce(24) || ciphertext || mac(16)', () async {
    final key = _hex(_sealingKey);
    final plaintext = utf8.encode(_sealingPlaintext);
    final blob = await VaultCrypto.seal(key, plaintext);

    expect(blob, hasLength(_nonceLength + plaintext.length + _macLength));

    // Decode explicit wire offsets without Vault.open or concatenation helpers.
    final macOffset = blob.length - _macLength;
    final box = SecretBox(
      blob.sublist(_nonceLength, macOffset),
      nonce: blob.sublist(0, _nonceLength),
      mac: Mac(blob.sublist(macOffset)),
    );
    final decoded = await Xchacha20.poly1305Aead().decrypt(
      box,
      secretKey: SecretKey(key),
    );

    expect(decoded, plaintext);
  });
}

Uint8List _hex(String value) => Uint8List.fromList([
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
]);
