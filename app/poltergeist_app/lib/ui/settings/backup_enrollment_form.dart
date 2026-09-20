// The unenrolled half of Settings → Backup (04 §4.3): every line of copy
// is the ARB's verbatim §4.3/§4.5 text — this widget only assembles it.
// Design B stays preselected; Design A renders disabled until the
// recorded Séance release tag exists, and its Continue additionally
// waits on the §4.3 fleet checkbox. The driver reports the documented
// outcomes verbatim — the KDF-downgrade refusal, the registration-closed
// text, and (through the durable notice on the enrolled view) the
// three-cause trial-decrypt warning.
import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/bookmark_backup_service.dart';
import '../../services/sync_account_gate.dart';
import '../../services/sync_enrollment_validation.dart';
import '../../services/uuid.dart';

/// Maps an enrollment failure to the ARB copy the spec names for it:
/// §4.5's KDF-downgrade refusal and §4.3's registration-closed text are
/// verbatim; anything else gets the generic live-region line carrying
/// the underlying message.
String describeEnrollmentError(AppLocalizations l10n, Object error) =>
    switch (error) {
      KdfDowngradeException() => l10n.backupKdfRefusal,
      RegistrationClosedException() => l10n.backupRegistrationClosed,
      _ => l10n.backupEnrollFailed('$error'),
    };

/// The validator's issue to its ARB sentence — D20's typed-value mapping
/// kept at the render site, like Séance's.
String describeEnrollmentIssue(
  AppLocalizations l10n,
  SyncEnrollmentIssue issue,
) =>
    switch (issue) {
      SyncEnrollmentIssue.invalidServerUrl => l10n.backupValidationUrl,
      SyncEnrollmentIssue.credentialsInUrl =>
        l10n.backupValidationUrlCredentials,
      SyncEnrollmentIssue.missingUsername => l10n.backupValidationUsername,
      SyncEnrollmentIssue.missingPassword => l10n.backupValidationPassword,
      SyncEnrollmentIssue.missingEncryptionPassphrase =>
        l10n.backupValidationPassphrase,
      SyncEnrollmentIssue.missingConfirmation =>
        l10n.backupValidationConfirm,
      SyncEnrollmentIssue.confirmationMismatch =>
        l10n.backupValidationMismatch,
    };

/// The §4.3 enrollment form: mode choice, disclosures, fields, and the
/// gated Continue. A successful enrollment notifies through the service
/// and the section swaps this form for the enrolled view — a success
/// path never needs a status line of its own.
final class BackupEnrollmentForm extends StatefulWidget {
  const BackupEnrollmentForm({
    super.key,
    required this.service,
    this.gate = const SyncAccountGate.production(),
  });

  final BookmarkBackupService service;

  /// The shared-account gate (04 §4.2/D4). Tests bind fakes both ways —
  /// no tag recorded disables option 2 outright; a tag carrying Séance
  /// #56's fix lifts the auto-trust disclosure.
  final SyncAccountGate gate;

  @override
  State<BackupEnrollmentForm> createState() => _BackupEnrollmentFormState();
}

class _BackupEnrollmentFormState extends State<BackupEnrollmentForm> {
  // §4.3's preselection: Design B is the default the copy leads with —
  // "a new account just for Poltergeist" means register is its first
  // action, login the existing-account path.
  SyncAccountMode _mode = SyncAccountMode.separate;
  SyncEnrollmentMode _action = SyncEnrollmentMode.register;
  bool _fleetConfirmed = false;
  bool _busy = false;
  String? _status;

  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();

  /// §4.1's username suggestion placeholder: a `ghost-<8 hex>` name, the
  /// eight-hex (32-bit) suffix so `ghost-*` accounts are not trivially
  /// enumerable — minted per form, never derived from any Séance name.
  late final String _ghostHint =
      'ghost-${uuidV4().substring(0, 8)}';

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _sharedSelected => _mode == SyncAccountMode.shared;

  /// §4.3's Continue gate: the shared option needs a recorded release
  /// tag AND the user's fleet assertion; the separate option needs only
  /// a stopped driver. Field-level issues are validation's job, not the
  /// button's.
  bool get _canContinue =>
      !_busy &&
      (!_sharedSelected ||
          (widget.gate.sharedAccountOffered && _fleetConfirmed));

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    // Shared accounts exist already — the §4.5 login is their only path.
    final action = _sharedSelected
        ? SyncEnrollmentMode.login
        : _action;
    // Validation and submission must see identical input — trimming only
    // the submitted half would let a padded URL fail validation or a
    // whitespace-only username slip past it.
    final baseUrl = _url.text.trim();
    final username = _username.text.trim();
    final issue = validateSyncEnrollment(
      mode: action,
      baseUrl: baseUrl,
      username: username,
      password: _password.text,
      encryptionPassphrase: _passphrase.text,
      confirmationPassphrase: _confirm.text,
    );
    if (issue != null) {
      setState(() => _status = describeEnrollmentIssue(l10n, issue));
      return;
    }
    setState(() {
      _busy = true;
      _status = action == SyncEnrollmentMode.register
          ? l10n.backupRegistering
          : l10n.backupLoggingIn;
    });
    try {
      if (action == SyncEnrollmentMode.register) {
        await widget.service.registerSeparate(
          baseUrl: baseUrl,
          username: username,
          password: _password.text,
          encryptionPassphrase: _passphrase.text,
        );
      } else {
        await widget.service.loginAccount(
          baseUrl: baseUrl,
          username: username,
          password: _password.text,
          encryptionPassphrase: _passphrase.text,
          mode: _mode,
        );
      }
      // No success line: the enrolled view replaces this form on the
      // service's notify, carrying the real status instead.
    } catch (error) {
      if (mounted) {
        setState(() => _status = describeEnrollmentError(l10n, error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sharedVersion = widget.gate.minimumSharedVersion;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.backupTitle, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(l10n.backupIntro),
        const SizedBox(height: 16),
        RadioGroup<SyncAccountMode>(
          groupValue: _mode,
          onChanged: _busy
              ? (_) {}
              : (mode) => setState(() {
                    if (mode == null) return;
                    _mode = mode;
                    _status = null;
                  }),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BackupModeTile(
                value: SyncAccountMode.separate,
                label: l10n.backupModeSeparate,
                key: const ValueKey('backup.mode.separate'),
              ),
              if (sharedVersion != null)
                _BackupModeTile(
                  value: SyncAccountMode.shared,
                  label: l10n.backupModeShared(sharedVersion),
                  key: const ValueKey('backup.mode.shared'),
                )
              else
                // No recorded tag means §4.3's mandated text cannot be
                // rendered — it interpolates the tag — so the option
                // sits disabled under its short name instead of
                // paraphrasing spec copy.
                ListTile(
                  key: const ValueKey('backup.mode.shared'),
                  enabled: false,
                  // The tile is disabled, but the Radio leaf still takes
                  // taps from the RadioGroup ancestor — block it so the
                  // gated option cannot be selected at all.
                  leading: const IgnorePointer(
                    child: Radio<SyncAccountMode>(
                      value: SyncAccountMode.shared,
                    ),
                  ),
                  title: Text(l10n.backupEnrolledModeShared),
                ),
              if (sharedVersion != null) ...[
                CheckboxListTile(
                  key: const ValueKey('backup.fleet.checkbox'),
                  controlAffinity: ListTileControlAffinity.leading,
                  enabled: !_busy,
                  value: _fleetConfirmed,
                  onChanged: (value) => setState(
                    () => _fleetConfirmed = value ?? false,
                  ),
                  title: Text(l10n.backupFleetCheckbox(sharedVersion)),
                  subtitle: Text(l10n.backupFleetHelper),
                ),
                if (!widget.gate.sharedIncludesSeance56Fix)
                  Padding(
                    padding: const EdgeInsets.only(left: 16, bottom: 8),
                    child: _WarningText(
                      key: const ValueKey('backup.shared.disclosure'),
                      text: l10n.backupSharedPinDisclosure,
                    ),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (!_sharedSelected)
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<SyncEnrollmentMode>(
              key: const ValueKey('backup.enroll.action'),
              segments: [
                ButtonSegment(
                  value: SyncEnrollmentMode.register,
                  label: Text(l10n.backupRegisterTab),
                ),
                ButtonSegment(
                  value: SyncEnrollmentMode.login,
                  label: Text(l10n.backupLoginTab),
                ),
              ],
              selected: {_action},
              showSelectedIcon: false,
              onSelectionChanged: _busy
                  ? null
                  : (selection) => setState(() {
                        _action = selection.first;
                        _status = null;
                      }),
            ),
          ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('backup.enroll.url'),
          controller: _url,
          enabled: !_busy,
          textInputAction: TextInputAction.next,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(labelText: l10n.backupServerUrlField),
        ),
        TextField(
          key: const ValueKey('backup.enroll.username'),
          controller: _username,
          enabled: !_busy,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.username],
          decoration: InputDecoration(
            labelText: l10n.backupUsernameField,
            hintText: _ghostHint,
          ),
        ),
        TextField(
          key: const ValueKey('backup.enroll.password'),
          controller: _password,
          enabled: !_busy,
          obscureText: true,
          textInputAction: TextInputAction.next,
          autofillHints: [
            if (!_sharedSelected && _action == SyncEnrollmentMode.register)
              AutofillHints.newPassword
            else
              AutofillHints.password,
          ],
          decoration: InputDecoration(
            labelText: l10n.backupAccountPasswordField,
            helperText: l10n.backupAccountPasswordHelper,
          ),
        ),
        TextField(
          key: const ValueKey('backup.enroll.passphrase'),
          controller: _passphrase,
          enabled: !_busy,
          obscureText: true,
          textInputAction: _sharedSelected ||
                  _action == SyncEnrollmentMode.login
              ? TextInputAction.done
              : TextInputAction.next,
          decoration: InputDecoration(
            labelText: l10n.backupEncryptionPassphraseField,
            helperText: l10n.backupEncryptionPassphraseHelper,
          ),
        ),
        if (!_sharedSelected && _action == SyncEnrollmentMode.register)
          TextField(
            key: const ValueKey('backup.enroll.confirm'),
            controller: _confirm,
            enabled: !_busy,
            obscureText: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: l10n.backupConfirmPassphraseField,
            ),
          ),
        const SizedBox(height: 8),
        // §4.3's callout — verbatim, in the warning container the spec's
        // tone calls for.
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            l10n.backupPassphraseCallout,
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const ValueKey('backup.enroll.continue'),
            onPressed: _canContinue ? _submit : null,
            child: Text(l10n.backupContinue),
          ),
        ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _status!,
                key: const ValueKey('backup.enroll.status'),
              ),
            ),
          ),
      ],
    );
  }
}

/// One §4.3 mode option: the radio leaf inside a tappable row so the
/// paragraph copy itself selects.
final class _BackupModeTile extends StatelessWidget {
  const _BackupModeTile({
    super.key,
    required this.value,
    required this.label,
  });

  final SyncAccountMode value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Radio<SyncAccountMode>(value: value),
      title: Text(label),
      onTap: () => RadioGroup.maybeOf<SyncAccountMode>(context)
          ?.onChanged(value),
    );
  }
}

/// Spec-copy rendered in the error tone — disclosures and warnings that
/// are statements, not failures.
final class _WarningText extends StatelessWidget {
  const _WarningText({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.error),
    );
  }
}
