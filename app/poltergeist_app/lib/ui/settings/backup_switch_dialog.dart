// 04 §4.4's B→A switch, step for step: the fleet confirmation and its
// disclosures → the shared-account login → the driver's seven steps
// (retained token, local sign-out, store wipe, shared login, dirty-mark,
// re-seal, hold set) → the hold set's per-locator decisions → done. The
// optional separate-account delete stays on the enrolled view — it is
// gated on the first successful shared sync, which this dialog cannot
// prove.
import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/bookmark_backup_service.dart';
import '../../services/sync_account_gate.dart';
import '../../services/sync_enrollment_validation.dart';
import 'backup_enrollment_form.dart';

/// Opens the §4.4 switch flow. Offered only where the gate already
/// passed — the enrolled view guards its entry button on
/// `gate.sharedAccountOffered`, so a null tag cannot reach here.
Future<void> showBackupSwitchDialog(
  BuildContext context, {
  required BookmarkBackupService service,
  SyncAccountGate gate = const SyncAccountGate.production(),
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => BackupSwitchDialog(service: service, gate: gate),
    );

final class BackupSwitchDialog extends StatefulWidget {
  const BackupSwitchDialog({
    super.key,
    required this.service,
    required this.gate,
  });

  final BookmarkBackupService service;
  final SyncAccountGate gate;

  @override
  State<BackupSwitchDialog> createState() => _BackupSwitchDialogState();
}

enum _SwitchPhase { confirm, working, conflicts, done, failed }

class _BackupSwitchDialogState extends State<BackupSwitchDialog> {
  _SwitchPhase _phase = _SwitchPhase.confirm;
  bool _fleetConfirmed = false;
  String? _error;
  BackupSwitchOutcome? _outcome;

  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _passphrase = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The switch stays on the same deployed server almost always —
    // prefill it, editable for the rare operator who moved fleets.
    _url.text = widget.service.account?.baseUrl ?? '';
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _switch() async {
    final l10n = AppLocalizations.of(context);
    final issue = validateSyncEnrollment(
      mode: SyncEnrollmentMode.login,
      baseUrl: _url.text,
      username: _username.text,
      password: _password.text,
      encryptionPassphrase: _passphrase.text,
    );
    if (issue != null) {
      setState(() => _error = describeEnrollmentIssue(l10n, issue));
      return;
    }
    setState(() {
      _phase = _SwitchPhase.working;
      _error = null;
    });
    try {
      final outcome = await widget.service.switchToShared(
        baseUrl: _url.text.trim(),
        username: _username.text.trim(),
        password: _password.text,
        encryptionPassphrase: _passphrase.text,
      );
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _phase = outcome.held.isEmpty
            ? _SwitchPhase.done
            : _SwitchPhase.conflicts;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _phase = _SwitchPhase.failed;
          _error = l10n.backupSwitchFailed(
            describeEnrollmentError(l10n, error),
          );
        });
      }
    }
  }

  /// §4.4's hold set drains one decision at a time: the service refresh
  /// recomputes `pinConflicts`, and an empty remainder completes the
  /// switch — the spec forbids a click-through on a conflicting host.
  Future<void> _resolve(HostKeyConflict conflict, bool keepLocal) async {
    await widget.service.resolvePinConflict(conflict, keepLocal: keepLocal);
    if (!mounted) return;
    if (widget.service.pinConflicts.isEmpty) {
      setState(() => _phase = _SwitchPhase.done);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final version = widget.gate.minimumSharedVersion;

    return AlertDialog(
      key: const ValueKey('backup.switch.dialog'),
      title: Text(l10n.backupSwitchTitle),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: switch (_phase) {
            _SwitchPhase.confirm => _buildConfirm(l10n, version),
            _SwitchPhase.working =>
              Text(l10n.backupSwitchWorking),
            _SwitchPhase.conflicts => _buildConflicts(l10n),
            _SwitchPhase.done => _buildDone(l10n),
            _SwitchPhase.failed => _buildFailed(l10n),
          },
        ),
      ),
      actions: switch (_phase) {
        _SwitchPhase.confirm => [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.backupCancel),
            ),
            FilledButton(
              key: const ValueKey('backup.switch.continue'),
              onPressed:
                  _fleetConfirmed && version != null ? _switch : null,
              child: Text(l10n.backupContinue),
            ),
          ],
        _SwitchPhase.working => const [],
        _SwitchPhase.conflicts => const [],
        _SwitchPhase.done || _SwitchPhase.failed => [
            FilledButton(
              key: const ValueKey('backup.switch.close'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.backupClose),
            ),
          ],
      },
    );
  }

  /// §4.3's disclosures restated at the point of commitment — the shared
  /// account's copy, the fleet checkbox with its helper, and (while the
  /// recorded tag lacks Séance #56's fix) the auto-trust disclosure.
  Widget _buildConfirm(AppLocalizations l10n, String? version) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (version != null) Text(l10n.backupModeShared(version)),
        CheckboxListTile(
          key: const ValueKey('backup.switch.fleet'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          value: _fleetConfirmed,
          onChanged: (value) =>
              setState(() => _fleetConfirmed = value ?? false),
          title: version == null
              ? null
              : Text(l10n.backupFleetCheckbox(version)),
          subtitle: Text(l10n.backupFleetHelper),
        ),
        if (!widget.gate.sharedIncludesSeance56Fix)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              l10n.backupSharedPinDisclosure,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('backup.switch.url'),
          controller: _url,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: l10n.backupServerUrlField),
        ),
        TextField(
          key: const ValueKey('backup.switch.username'),
          controller: _username,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: l10n.backupUsernameField),
        ),
        TextField(
          key: const ValueKey('backup.switch.password'),
          controller: _password,
          obscureText: true,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: l10n.backupAccountPasswordField,
            helperText: l10n.backupAccountPasswordHelper,
          ),
        ),
        TextField(
          key: const ValueKey('backup.switch.passphrase'),
          controller: _passphrase,
          obscureText: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: l10n.backupEncryptionPassphraseField,
            helperText: l10n.backupEncryptionPassphraseHelper,
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              key: const ValueKey('backup.switch.error'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }

  /// The hold set: one verbatim decision block per conflicting locator,
  /// adopt-fleet or keep-local, no bulk resolution.
  Widget _buildConflicts(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('backup.switch.conflicts'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.backupSwitchConflictTitle,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        for (final conflict in widget.service.pinConflicts) ...[
          Text(
            l10n.backupSwitchConflictBody(conflict.locator),
            key: ValueKey('backup.switch.conflict.${conflict.locator}'),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                key: ValueKey(
                  'backup.switch.adoptFleet.${conflict.locator}',
                ),
                onPressed: () => _resolve(conflict, false),
                child: Text(l10n.backupSwitchAdoptFleet),
              ),
              TextButton(
                key: ValueKey(
                  'backup.switch.keepLocal.${conflict.locator}',
                ),
                onPressed: () => _resolve(conflict, true),
                child: Text(l10n.backupPinKeepLocal),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildDone(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final outcome = _outcome;
    return Column(
      key: const ValueKey('backup.switch.done'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.backupSwitchDone),
        if (outcome?.passphraseUnverified ?? false) ...[
          const SizedBox(height: 8),
          Text(
            l10n.backupPaused,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error),
          ),
          Text(
            l10n.backupPausedWayOutShared,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _buildFailed(AppLocalizations l10n) {
    return Text(
      _error ?? '',
      key: const ValueKey('backup.switch.failed'),
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.error),
    );
  }
}
