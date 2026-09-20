// The enrolled half of Settings → Backup: the account summary, the
// §3.3 status line ("Back up now" + last-round bookkeeping), the durable
// notice set — paused way-out, dead account, decode tripwire, pin
// quarantine, corrupt store — and the account actions each mode allows:
// §4.2's sign-out for both, §4.1's typed-confirmation delete for
// separate only, §4.4's switch entry and its optional post-switch
// delete offer.
import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/bookmark_backup_service.dart';
import '../../services/sync_account_gate.dart';
import 'backup_switch_dialog.dart';

/// The enrolled view. Stateless by shape — every rendered fact lives on
/// the service, which notifies after each durable change.
final class BackupEnrolledView extends StatelessWidget {
  const BackupEnrolledView({
    super.key,
    required this.service,
    this.gate = const SyncAccountGate.production(),
  });

  final BookmarkBackupService service;
  final SyncAccountGate gate;

  /// §3.3's manual round. A failure is already the surface's own
  /// `lastSyncError` status — the catch exists only to keep the async
  /// return from surfacing as an unhandled error.
  Future<void> _backUpNow() async {
    try {
      await service.backUpNow();
    } on Object {
      // Rendered through lastSyncError — no second channel needed.
    }
  }

  Future<void> _signOut(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('backup.signout.dialog'),
        title: Text(l10n.backupSignOut),
        content: Text(l10n.backupSignOutBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.backupCancel),
          ),
          FilledButton(
            key: const ValueKey('backup.signout.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.backupSignOut),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await service.signOut();
    } catch (error) {
      if (context.mounted) {
        _reportError(context, error);
      }
    }
  }

  /// A mutating call's failure lands in the messenger when one is
  /// reachable — the durable state is unchanged, so the section simply
  /// re-renders its previous truth.
  static void _reportError(BuildContext context, Object error) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text('$error')));
  }

  Future<void> _resolvePin(
    BuildContext context,
    HostKeyConflict conflict,
    bool keepLocal,
  ) async {
    try {
      await service.resolvePinConflict(conflict, keepLocal: keepLocal);
    } catch (error) {
      if (context.mounted) {
        _reportError(context, error);
      }
    }
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final account = service.account;
    if (account == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _DeleteBackupAccountDialog(
        service: service,
        username: account.username,
        server: account.baseUrl,
      ),
    );
  }

  Future<void> _switchToShared(BuildContext context) =>
      showBackupSwitchDialog(context, service: service, gate: gate);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final account = service.account;
    if (account == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final shared = account.mode == SyncAccountMode.shared;

    return Column(
      key: const ValueKey('backup.enrolled'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.backupTitle, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          shared
              ? l10n.backupEnrolledModeShared
              : l10n.backupEnrolledModeSeparate,
          style: theme.textTheme.bodySmall,
        ),
        Text(l10n.backupEnrolledSummary(account.username, account.baseUrl)),
        const SizedBox(height: 8),
        _BackupStatusLine(service: service),
        if (service.quarantinedPath != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _NoticeText(text: l10n.backupStoreQuarantined),
          ),
        if (service.notices.contains(syncNoticeAccountAuthFailed))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _NoticeText(text: l10n.backupDeadAccount),
          ),
        if (service.passphraseUnverified)
          // The paused statement itself sits in the status line (paused
          // outranks syncing/error there); this notice carries only the
          // way-out copy.
          Text(
            shared
                ? l10n.backupPausedWayOutShared
                : l10n.backupPausedWayOutSeparate,
            style: theme.textTheme.bodySmall,
          ),
        if (service.notices.contains(syncNoticePassphraseCheckFailed))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _NoticeText(text: l10n.backupPassphraseCheckFailed),
          ),
        for (final id in service.trippedIds)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _NoticeText(text: l10n.backupTripwireWarning(id)),
          ),
        for (final conflict in service.pinConflicts)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _NoticeText(
                  text: l10n.backupPinConflictWarning(conflict.locator),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      key: ValueKey('backup.pin.keep.${conflict.locator}'),
                      onPressed: () =>
                          _resolvePin(context, conflict, true),
                      child: Text(l10n.backupPinKeepLocal),
                    ),
                    TextButton(
                      key: ValueKey('backup.pin.accept.${conflict.locator}'),
                      onPressed: () =>
                          _resolvePin(context, conflict, false),
                      child: Text(l10n.backupPinAcceptSynced),
                    ),
                  ],
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              key: const ValueKey('backup.enrolled.backupNow'),
              onPressed: service.syncing ? null : _backUpNow,
              child: Text(l10n.backupNow),
            ),
            TextButton(
              key: const ValueKey('backup.enrolled.signOut'),
              onPressed:
                  service.syncing ? null : () => _signOut(context),
              child: Text(l10n.backupSignOut),
            ),
            // §4.2: a shared account carries the user's Séance data — no
            // delete verb exists on it, and no switch away from it.
            if (!shared) ...[
              if (gate.sharedAccountOffered)
                TextButton(
                  key: const ValueKey('backup.enrolled.switch'),
                  onPressed: service.syncing
                      ? null
                      : () => _switchToShared(context),
                  child: Text(l10n.backupSwitchToShared),
                ),
              TextButton(
                key: const ValueKey('backup.enrolled.delete'),
                onPressed: service.syncing
                    ? null
                    : () => _deleteAccount(context),
                child: Text(l10n.backupDeleteAccount),
              ),
            ],
          ],
        ),
        if (service.deleteSeparateOffered)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const ValueKey('backup.enrolled.deleteRetained'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) =>
                      _DeleteRetainedAccountDialog(service: service),
                ),
                child: Text(l10n.backupDeleteSeparateAfterSwitch),
              ),
            ),
          ),
      ],
    );
  }
}

/// §3.3's status line: paused beats progress beats error beats the last
/// round's wall time — the paused hold is the one state the user must
/// not mistake for working.
final class _BackupStatusLine extends StatelessWidget {
  const _BackupStatusLine({required this.service});

  final BookmarkBackupService service;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final error = service.lastSyncError;

    final String text;
    if (service.passphraseUnverified) {
      text = l10n.backupPaused;
    } else if (service.syncing) {
      text = l10n.backupSyncing;
    } else if (error != null) {
      text = l10n.backupSyncFailed(error);
    } else {
      final at = service.lastSyncAt;
      text = at == null ? l10n.backupNeverSynced : _ago(l10n, at);
    }
    final attention = service.passphraseUnverified ||
        (error != null && !service.syncing);
    return Text(
      text,
      key: const ValueKey('backup.enrolled.status'),
      style: theme.textTheme.bodySmall?.copyWith(
        color: attention ? theme.colorScheme.error : null,
      ),
    );
  }

  static String _ago(AppLocalizations l10n, DateTime at) {
    final delta = DateTime.now().difference(at);
    if (delta.inMinutes < 1) return l10n.backupLastSyncedJustNow;
    if (delta.inHours < 1) return l10n.backupLastSyncedMinutesAgo(delta.inMinutes);
    if (delta.inDays < 1) return l10n.backupLastSyncedHoursAgo(delta.inHours);
    return l10n.backupLastSyncedDaysAgo(delta.inDays);
  }
}

/// A durable notice's body in the error tone — a statement the spec
/// demands persist, not a toast.
final class _NoticeText extends StatelessWidget {
  const _NoticeText({required this.text});

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

/// §4.1's separate-account deletion: the consequence copy, then a typed
/// confirmation — the verb arms only when the field equals the account
/// name, so a stray tap cannot destroy the only backup.
final class _DeleteBackupAccountDialog extends StatefulWidget {
  const _DeleteBackupAccountDialog({
    required this.service,
    required this.username,
    required this.server,
  });

  final BookmarkBackupService service;
  final String username;
  final String server;

  @override
  State<_DeleteBackupAccountDialog> createState() =>
      _DeleteBackupAccountDialogState();
}

class _DeleteBackupAccountDialogState
    extends State<_DeleteBackupAccountDialog> {
  final _field = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.deleteSeparateAccount(
        confirmedName: _field.text.trim(),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _error = l10n.backupDeleteFailed('$error'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      key: const ValueKey('backup.delete.dialog'),
      title: Text(l10n.backupDeleteAccountTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.backupDeleteAccountBody(widget.username, widget.server)),
          const SizedBox(height: 12),
          Text(l10n.backupDeleteConfirmHint(widget.username)),
          TextField(
            key: const ValueKey('backup.delete.confirmField'),
            controller: _field,
            enabled: !_busy,
            autofocus: true,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _NoticeText(text: _error!),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.backupCancel),
        ),
        ListenableBuilder(
          listenable: _field,
          builder: (context, _) => FilledButton(
            key: const ValueKey('backup.delete.confirm'),
            onPressed: !_busy && _field.text.trim() == widget.username
                ? _delete
                : null,
            child: Text(l10n.backupDeleteConfirm),
          ),
        ),
      ],
    );
  }
}

/// §4.4's optional post-switch delete: the retained separate account
/// removed through its parked token — or declined, which keeps the old
/// account and drops the token so a later delete means re-enrolling.
final class _DeleteRetainedAccountDialog extends StatefulWidget {
  const _DeleteRetainedAccountDialog({required this.service});

  final BookmarkBackupService service;

  @override
  State<_DeleteRetainedAccountDialog> createState() =>
      _DeleteRetainedAccountDialogState();
}

class _DeleteRetainedAccountDialogState
    extends State<_DeleteRetainedAccountDialog> {
  final _field = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = l10n.backupDeleteSeparateFailed('$error'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final retained = widget.service.retainedAccount;
    if (retained == null) {
      // The retained account can be forgotten through another surface
      // while this dialog sits open — an invisible route that can only
      // be escaped by the barrier is worse than a self-closing one.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }
    return AlertDialog(
      key: const ValueKey('backup.deleteRetained.dialog'),
      title: Text(l10n.backupDeleteSeparateAfterSwitch),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.backupDeleteSeparateBody(
              retained.username,
              retained.baseUrl,
            ),
          ),
          const SizedBox(height: 12),
          Text(l10n.backupDeleteConfirmHint(retained.username)),
          TextField(
            key: const ValueKey('backup.deleteRetained.confirmField'),
            controller: _field,
            enabled: !_busy,
            autofocus: true,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _NoticeText(text: _error!),
            ),
        ],
      ),
      actions: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.backupDeleteSeparateLaterNote,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('backup.deleteRetained.decline'),
                  onPressed: _busy
                      ? null
                      : () => _run(widget.service.declineRetainedDelete),
                  child: Text(l10n.backupDeleteSeparateDecline),
                ),
                const SizedBox(width: 8),
                ListenableBuilder(
                  listenable: _field,
                  builder: (context, _) => FilledButton(
                    key: const ValueKey('backup.deleteRetained.confirm'),
                    onPressed:
                        !_busy && _field.text.trim() == retained.username
                            ? () => _run(
                                  () => widget.service
                                      .deleteRetainedSeparateAccount(
                                    confirmedName: _field.text.trim(),
                                  ),
                                )
                            : null,
                    child: Text(l10n.backupDeleteConfirm),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
