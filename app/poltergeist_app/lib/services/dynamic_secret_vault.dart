import 'package:poltergeist_core/poltergeist_core.dart';

import 'secure_master_key.dart';

/// A [SecretVault] whose key is re-resolved per call instead of captured
/// at construction. The vault key can change underneath a long-lived
/// consumer — enrollment swaps the keystore entry for the
/// passphrase-derived shared key — and a captured instance would keep
/// sealing under the stale key, writing blobs nothing can open.
/// Delegation makes every operation land on whatever key the provider
/// currently reports; a null provider result behaves like the locked
/// vault (nothing readable or writable this session). A provider that
/// throws (a failing platform keystore) reports through [onError] and
/// then fails the call: some callers swallow vault faults by design,
/// so the report is the only trace a broken keystore leaves.
final class DynamicSecretVault extends SecretVault {
  DynamicSecretVault(
    VaultStore store,
    this._current, {
    void Function(Object error, StackTrace stackTrace)? onError,
  })  : // Keep the reporter private while allowing injection.
        // ignore: prefer_initializing_formals
        _onError = onError,
        super(store, const <int>[]);

  final Future<SecretVault?> Function() _current;
  final void Function(Object error, StackTrace stackTrace)? _onError;

  Future<SecretVault> _vault() async {
    final SecretVault? vault;
    try {
      vault = await _current();
    } on Object catch (error, stackTrace) {
      try {
        _onError?.call(error, stackTrace);
      } on Object {
        // Reporting must never mask the keystore fault it reports.
      }
      rethrow;
    }
    if (vault == null) throw const VaultLockedException();
    return vault;
  }

  @override
  Future<Secret?> getSecret(String id) async =>
      (await _vault()).getSecret(id);

  @override
  Future<Secret?> readableSecret(String id) async =>
      (await _vault()).readableSecret(id);

  @override
  Future<void> putSecret(Secret secret) async =>
      (await _vault()).putSecret(secret);

  @override
  Future<void> putSecrets(Iterable<Secret> secrets) async =>
      (await _vault()).putSecrets(secrets);

  @override
  Future<void> deleteSecret(String id) async =>
      (await _vault()).deleteSecret(id);
}
