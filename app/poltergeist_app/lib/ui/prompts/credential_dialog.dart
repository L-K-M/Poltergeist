import 'package:flutter/material.dart';

import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/identity_file_reader.dart';

/// What the user answered to a credential prompt. Exactly one secret shape
/// is set — the password, or the identity file's key material (read from
/// disk by the dialog's submit path, so the coordinator never re-reads it).
class CredentialDialogResult {
  final String? password;
  final String? privateKeyPem;
  final String? keyPassphrase;

  /// True when the user asked to store the answer in the local vault under
  /// the config's secretRef (04 §2.1: "offers to save under the same id").
  final bool saveToVault;

  const CredentialDialogResult({
    this.password,
    this.privateKeyPem,
    this.keyPassphrase,
    this.saveToVault = false,
  });
}

/// The connect-time credential prompt (07 §3.3): shown when the vault holds
/// no secret for the server. Fields follow the auth method — a password, or
/// a key-file path plus passphrase; [readKeyFile] (the coordinator's
/// audited identity-file reader, D18) is injected so the dialog never
/// touches the filesystem itself and tests need no files.
Future<CredentialDialogResult?> showCredentialDialog(
  BuildContext context,
  CredentialPromptData data, {
  required Future<String> Function(String path) readKeyFile,
  bool vaultUnavailable = false,
}) {
  return showDialog<CredentialDialogResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CredentialDialog(
      data: data,
      readKeyFile: readKeyFile,
      vaultUnavailable: vaultUnavailable,
    ),
  );
}

class _CredentialDialog extends StatefulWidget {
  const _CredentialDialog({
    required this.data,
    required this.readKeyFile,
    this.vaultUnavailable = false,
  });

  final CredentialPromptData data;
  final Future<String> Function(String path) readKeyFile;
  final bool vaultUnavailable;

  @override
  State<_CredentialDialog> createState() => _CredentialDialogState();
}

class _CredentialDialogState extends State<_CredentialDialog> {
  late final TextEditingController _password = TextEditingController();
  late final TextEditingController _keyPath = TextEditingController(
    text: widget.data.identityFilePath ?? '',
  );
  late final TextEditingController _passphrase = TextEditingController();
  bool _saveToVault = false;
  bool _readingKey = false;
  String? _keyFileError;

  bool get _keyAuth => widget.data.authMethod == AuthMethod.privateKey;

  @override
  void dispose() {
    _password.dispose();
    _keyPath.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_keyAuth) {
      final path = _keyPath.text.trim();
      if (path.isEmpty) return;

      setState(() {
        _readingKey = true;
        _keyFileError = null;
      });
      String pem;
      try {
        pem = await widget.readKeyFile(path);
      } on Object catch (error) {
        if (!mounted) return;
        setState(() {
          _readingKey = false;
          _keyFileError = error is IdentityFileReadException
              ? error.message
              : error.toString();
        });
        return;
      }
      if (!mounted) return;
      Navigator.pop(context, _result(privateKeyPem: pem));
      return;
    }

    Navigator.pop(context, _result(password: _password.text));
  }

  CredentialDialogResult _result({String? password, String? privateKeyPem}) =>
      CredentialDialogResult(
        password: password,
        privateKeyPem: privateKeyPem,
        keyPassphrase: _keyAuth && _passphrase.text.isNotEmpty
            ? _passphrase.text
            : null,
        saveToVault: _saveToVault,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final secretRef = widget.data.secretRef;

    return AlertDialog(
      title: Text(l10n.credentialTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            l10n.credentialEndpoint(
              widget.data.username,
              widget.data.host,
              widget.data.port,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          if (widget.vaultUnavailable) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                l10n.credentialVaultUnavailable,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (_keyAuth) ...[
            TextField(
              controller: _keyPath,
              autofocus: true,
              decoration: InputDecoration(labelText: l10n.credentialKeyFileField),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passphrase,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(
                labelText: l10n.credentialPassphraseField,
              ),
            ),
            if (_keyFileError != null) ...[
              const SizedBox(height: 8),
              Text(
                l10n.credentialKeyFileReadError(_keyFileError!),
                style: TextStyle(color: scheme.error),
              ),
            ],
          ] else
            TextField(
              controller: _password,
              autofocus: true,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: l10n.credentialPasswordField,
              ),
            ),
          if (secretRef != null)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _saveToVault,
              onChanged: (value) => setState(() {
                _saveToVault = value ?? false;
              }),
              title: Text(l10n.credentialSaveInVault),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(l10n.credentialCancel),
        ),
        FilledButton(
          onPressed: _readingKey ? null : _submit,
          child: _readingKey
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.credentialConnect),
        ),
      ],
    );
  }
}
