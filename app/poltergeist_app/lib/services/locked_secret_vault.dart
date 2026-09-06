// Ported from Séance app/seance_app/lib/services/app_services.dart @ 99a3585 (LockedSecretVault); see docs/PORTS.md.
import 'package:poltergeist_core/poltergeist_core.dart';

import 'secure_master_key.dart';

/// A vault without its key: the OS keystore was unavailable at bootstrap, so
/// no key exists this session. Reads and writes fail with a clear message
/// instead of decrypting with a wrong key (which would look like corruption)
/// or fabricating an ephemeral one (which would silently orphan anything saved
/// now on the next launch). Deleting stays legal — it needs no key.
class LockedSecretVault extends SecretVault {
  LockedSecretVault(VaultStore store) : super(store, const <int>[]);

  @override
  Future<Secret?> getSecret(String id) async =>
      throw const VaultLockedException();

  @override
  Future<void> putSecret(Secret secret) async =>
      throw const VaultLockedException();
}
