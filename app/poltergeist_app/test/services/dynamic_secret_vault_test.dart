import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/dynamic_secret_vault.dart';
import 'package:poltergeist_app/services/secure_master_key.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final _keyA = List<int>.generate(32, (i) => i);
final _keyB = List<int>.generate(32, (i) => 255 - i);

Secret _secret(String id) => Secret(
      id: id,
      kind: SecretKind.password,
      value: 'value-$id',
      updatedAt: 1,
    );

void main() {
  test('every call lands on the key the provider reports now', () async {
    final store = InMemoryVaultStore();
    var key = _keyA;
    final vault = DynamicSecretVault(
      store,
      () async => SecretVault(store, key),
    );

    await vault.putSecret(_secret('s1'));
    expect((await vault.getSecret('s1'))!.value, 'value-s1');

    // The re-key swaps the keystore entry: the old blob no longer opens,
    // and a new write seals under the new key.
    key = _keyB;
    expect(await vault.readableSecret('s1'), isNull);
    await vault.putSecret(_secret('s2'));
    expect((await SecretVault(store, _keyB).getSecret('s2'))!.value,
        'value-s2');
    expect(await SecretVault(store, _keyA).readableSecret('s2'), isNull);
  });

  test('no key reads as the locked vault and reports nothing', () async {
    final reports = <Object>[];
    final vault = DynamicSecretVault(
      InMemoryVaultStore(),
      () async => null,
      onError: (error, _) => reports.add(error),
    );

    await expectLater(
      vault.getSecret('s1'),
      throwsA(isA<VaultLockedException>()),
    );
    expect(reports, isEmpty);
  });

  test('a failing keystore reports, then fails the call', () async {
    final reports = <Object>[];
    final failure = StateError('keychain unavailable');
    final vault = DynamicSecretVault(
      InMemoryVaultStore(),
      () async => throw failure,
      onError: (error, _) => reports.add(error),
    );

    await expectLater(vault.putSecret(_secret('s1')), throwsA(same(failure)));
    expect(reports, [same(failure)]);
  });

  test('a throwing reporter never masks the keystore fault', () async {
    final failure = StateError('keychain unavailable');
    final vault = DynamicSecretVault(
      InMemoryVaultStore(),
      () async => throw failure,
      onError: (_, _) => throw StateError('reporter down'),
    );

    await expectLater(vault.getSecret('s1'), throwsA(same(failure)));
  });
}
