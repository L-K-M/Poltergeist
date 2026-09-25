// The production [ServerEditorDelegate]: what the editor's seams resolve to
// when the catalog drives it. Written to the shape Séance's AppState +
// AppServices answered (testServerConnection/resolveCredentials @ 035b0d8),
// recomposed over Poltergeist's services — see docs/PORTS.md.
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../theme/app_theme.dart';
import '../ui/prompts/host_key_dialog.dart';
import '../ui/prompts/keyboard_interactive_dialog.dart';
import '../ui/server_editor.dart';
import 'bookmark_backup_service.dart';
import 'identity_file_reader.dart';
import 'transfer_limits_controller.dart';

/// The application layer behind the server editor: catalog truth and sync
/// writes through [BookmarkBackupService], credential reads through the
/// dynamic vault, the connection test over the real transport with the
/// trial-pin semantics upstream's `testServerConnection` carries.
final class ServerEditorBackend extends ServerEditorDelegate {
  ServerEditorBackend({
    required this._backups,
    required this._vault,
    required this._hostKeys,
    required this._identityReader,
    required this._navigatorKey,
    required this._transferLimits,
  });

  final BookmarkBackupService _backups;

  /// The resolving vault (dynamic_secret_vault.dart): re-reads the current
  /// key per call, so an enrollment rekey mid-edit does not strand the
  /// editor's credential paths on a dead generation.
  final SecretVault _vault;
  final HostKeyStore _hostKeys;
  final IdentityFileReader _identityReader;
  final GlobalKey<NavigatorState> _navigatorKey;
  final TransferLimitsController _transferLimits;

  @override
  List<ServerConfig> get servers =>
      _backups.catalog?.servers ?? const <ServerConfig>[];

  @override
  bool get syncConfigured => _backups.account != null;

  @override
  Color get themeSeed => poltergeistSeedColor;

  @override
  Future<String?> pickIdentityFile() async {
    final result = await FilePicker.pickFiles();
    final files = result?.files ?? const [];
    if (files.isEmpty) return null;
    // No withData: the path is what is stored — "reference, don't store"
    // reads the key at connect, so there is nothing to do with bytes here.
    return files.single.path;
  }

  @override
  Future<Secret?> readSecret(String secretId) =>
      _backups.serverSecretById(secretId);

  /// Credential first, config second — the order upstream's save keeps, and
  /// load-bearing here: [BookmarkBackupService.saveServer] publishes the
  /// opted-in `secret:` record, which reads the vault, so the entry must
  /// exist before the config names it; and a config write that then failed
  /// leaves only a vault entry nothing references (the retried save reuses
  /// the draft id and adopts it).
  @override
  Future<void> save(ServerConfig config, {Secret? secret}) async {
    if (secret != null) await _backups.saveServerSecret(secret);
    await _backups.saveServer(config);
  }

  @override
  TransferConcurrency get defaultTransferConcurrency =>
      _transferLimits.perServer;

  @override
  TransferConcurrency? transferConcurrencyFor(String serverId) =>
      _transferLimits.overrideFor(serverId);

  @override
  Future<void> saveTransferConcurrency(
    String serverId,
    TransferConcurrency? value,
  ) => _transferLimits.setOverride(serverId, value);

  /// Authenticate without a shell — upstream's `testServerConnection` shape:
  /// draft fields outrank the vault so the test reports on what the form
  /// says, and a trial host-key approval is pinned for the attempt only
  /// ([liveHostAuthenticator] wraps the store in `UnpinnedHostKeyStore`
  /// itself, so this call cannot be wired to pin).
  @override
  Future<ConnectionTestResult> testConnection(
    ServerConfig config, {
    String? draftPassword,
    String? draftPrivateKey,
    String? draftKeyPassphrase,
    SshConnectionLog? log,
  }) {
    return runConnectionTest(
      config: config,
      credentials: () => _resolveCredentials(
        config,
        draftPassword: draftPassword,
        draftPrivateKey: draftPrivateKey,
        draftKeyPassphrase: draftKeyPassphrase,
      ),
      authenticate: liveHostAuthenticator(
        hostKeys: _hostKeys,
        onHostKey: _promptForHostKey,
        onKeyboardInteractive: _promptKeyboardInteractive,
      ),
      log: log,
    );
  }

  /// What a connection authenticates with, draft fields first — the port of
  /// upstream's `resolveCredentials` minus its security-bookmark branch
  /// (Poltergeist is not sandboxed; referenced keys open by path).
  ///
  /// Read the drafts only under their own auth method, as the editor passes
  /// them: a stale box's text must never beat the stored credential of the
  /// method actually in force.
  Future<SshCredentials> _resolveCredentials(
    ServerConfig config, {
    String? draftPassword,
    String? draftPrivateKey,
    String? draftKeyPassphrase,
  }) async {
    String? draft(String? value) =>
        (value == null || value.isEmpty) ? null : value;
    switch (config.authMethod) {
      case AuthMethod.agent:
        return const SshCredentials.agent();
      case AuthMethod.password:
        final typed = draft(draftPassword);
        if (typed != null) return SshCredentials.password(typed);
        final secret = config.secretRef == null
            ? null
            : await _vault.getSecret(config.secretRef!);
        return SshCredentials.password(secret?.value ?? '');
      case AuthMethod.privateKey:
        // "Reference, don't store": read the key from disk at connect time.
        if (config.identityFilePath != null) {
          final pem = await _identityReader.read(
            serverId: config.id,
            serverLabel: '${config.username}@${config.host}',
            identityFilePath: config.identityFilePath!,
          );
          return SshCredentials.privateKey(
            pem,
            // Behind the `??`, so a typed passphrase skips the read that was
            // about to be discarded.
            keyPassphrase:
                draft(draftKeyPassphrase) ??
                (config.secretRef == null
                    ? null
                    : (await _vault.getSecret(config.secretRef!))
                        ?.keyPassphrase),
          );
        }
        final typedPem = draft(draftPrivateKey);
        if (typedPem != null) {
          return SshCredentials.privateKey(
            typedPem,
            keyPassphrase: draft(draftKeyPassphrase),
          );
        }
        final secret = config.secretRef == null
            ? null
            : await _vault.getSecret(config.secretRef!);
        return SshCredentials.privateKey(
          secret?.value ?? '',
          keyPassphrase: draft(draftKeyPassphrase) ?? secret?.keyPassphrase,
        );
    }
  }

  /// The trial's host-key prompt: the same dialog a real connect raises,
  /// answered on the root navigator so it works while the editor is open.
  /// Returning false declines — the trial fails honestly rather than
  /// granting trust.
  Future<bool> _promptForHostKey(HostKeyDecision decision) async {
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return false;
    final presented = decision.presented;
    return showHostKeyDialog(
      context,
      HostKeyPromptData(
        host: presented.host,
        port: presented.port,
        keyType: presented.type,
        fingerprintSha256: presented.fingerprintSha256,
        pinnedFingerprintSha256: decision.pinned?.fingerprintSha256,
      ),
    );
  }

  /// A keyboard-interactive challenge during the trial — the same dialog a
  /// real connect raises; an empty answer list cancels.
  Future<List<String>> _promptKeyboardInteractive(
    List<String> prompts,
    String name,
    String instruction,
  ) async {
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return const <String>[];
    return showKeyboardInteractiveDialog(
      context,
      KeyboardInteractivePromptData(
        name: name,
        instruction: instruction,
        prompts: prompts,
      ),
    );
  }
}
