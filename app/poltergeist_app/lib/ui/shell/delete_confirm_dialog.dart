import 'dart:async';

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../panes/pane_format.dart';

/// The user's answer to a delete confirmation.
sealed class DeleteDecision {
  const DeleteDecision();
}

/// Proceed; [permanent] when the dialog's final wording was a permanent
/// delete (the remote trash checkbox unchecked, or no trash at all).
final class DeleteConfirmed extends DeleteDecision {
  const DeleteConfirmed({required this.permanent});

  final bool permanent;
}

final class DeleteCancelled extends DeleteDecision {
  const DeleteCancelled();
}

/// 02 §10's delete confirmation (D15). The quantifying walk runs behind a
/// cancellable "Counting items…" line; its result picks the wording:
///
/// - permanent: `Delete 12 items (1.4 GB) from prod-web-01? This cannot be
///   undone.` — names instead of a count for ≤ 3 items, the unquantified
///   fallback when the walk gave up, and `Cancel` as the default button
///   (a permanent delete is never the default action);
/// - server trash (the per-server opt-in, pre-checked): move wording and a
///   `Move 12 Items` default, with the helper that server-side trash is a
///   rename, not disposal;
/// - trash unavailable: the permanent wording plus D15's notice.
///
/// Flagged (undecodable-name) descendants are always disclosed.
Future<DeleteDecision> showDeleteConfirmDialog(
  BuildContext context, {
  required Future<DeleteConfirmation?> Function(
    RemoteTransferCancellation cancellation,
  )
  prepare,
  required String locationLabel,
}) async {
  final decision = await showDialog<DeleteDecision>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _DeleteDialog(prepare: prepare, locationLabel: locationLabel),
  );
  return decision ?? const DeleteCancelled();
}

class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog({required this.prepare, required this.locationLabel});

  final Future<DeleteConfirmation?> Function(
    RemoteTransferCancellation cancellation,
  )
  prepare;
  final String locationLabel;

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  final _cancellation = RemoteTransferCancellation();
  DeleteConfirmation? _confirmation;
  Object? _error;
  bool _useServerTrash = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final confirmation = await widget.prepare(_cancellation);
      if (!mounted) return;
      if (confirmation == null) {
        Navigator.of(context).pop(const DeleteCancelled());
        return;
      }
      setState(() {
        _confirmation = confirmation;
        _useServerTrash =
            confirmation.remoteTrashOptIn &&
            confirmation.effectiveDisposition == DeleteDisposition.trash;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  void _cancel() {
    _cancellation.cancel();
    Navigator.of(context).pop(const DeleteCancelled());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final confirmation = _confirmation;

    if (confirmation == null) {
      return AlertDialog(
        key: const ValueKey('delete.dialog'),
        content: Row(
          children: [
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _error == null
                    ? l10n.deleteDialogCounting
                    : l10n.deleteDialogPrepareFailed('$_error'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('delete.cancel'),
            onPressed: _cancel,
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
        ],
      );
    }

    final move = _useServerTrash;
    final count = confirmation.totalItems ?? confirmation.rootPaths.length;
    final size = confirmation.totalBytes == null
        ? null
        : formatPaneSize(confirmation.totalBytes!, platform: theme.platform);
    final location = widget.locationLabel;
    final names = confirmation.rootPaths.length <= 3
        ? confirmation.names.join('”, “')
        : null;

    final String headline;
    if (!confirmation.quantified) {
      headline = move
          ? l10n.deleteDialogMoveUnquantified(location)
          : l10n.deleteDialogDeleteUnquantified(location);
    } else if (names != null) {
      headline = move
          ? l10n.deleteDialogMoveNames(names, location)
          : l10n.deleteDialogDeleteNames(names, location);
    } else {
      headline = move
          ? l10n.deleteDialogMoveCount(count, size ?? '', location)
          : l10n.deleteDialogDeleteCount(count, size ?? '', location);
    }

    final flagged = confirmation.flaggedCount;
    final flaggedLine = !confirmation.quantified
        ? (flagged > 0 ? l10n.deleteDialogFlaggedMaybe : null)
        : (flagged > 0 ? l10n.deleteDialogFlaggedExact(flagged) : null);

    final confirmLabel = move
        ? l10n.deleteDialogConfirmMove(confirmation.rootPaths.length)
        : l10n.deleteDialogConfirmDelete(confirmation.rootPaths.length);

    return AlertDialog(
      key: const ValueKey('delete.dialog'),
      icon: Icon(
        move ? Icons.delete_outline : Icons.warning_amber_rounded,
        color: move ? chrome.secondaryText : theme.colorScheme.error,
      ),
      title: Text(headline, key: const ValueKey('delete.headline')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              move
                  ? l10n.deleteDialogMoveWarning
                  : l10n.deleteDialogIrreversible,
              style: theme.textTheme.bodyMedium,
            ),
            if (confirmation.trashUnavailable) ...[
              const SizedBox(height: 8),
              Text(
                l10n.deleteDialogTrashUnavailable,
                key: const ValueKey('delete.trashUnavailable'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            if (flaggedLine != null) ...[
              const SizedBox(height: 8),
              Text(flaggedLine, style: theme.textTheme.bodySmall),
            ],
            if (confirmation.remoteTrashOptIn) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const ValueKey('delete.serverTrash'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _useServerTrash,
                onChanged: (value) =>
                    setState(() => _useServerTrash = value ?? false),
                title: Text(l10n.deleteDialogServerTrashCheckbox),
                subtitle: move
                    ? Text(l10n.deleteDialogServerTrashHelper)
                    : null,
              ),
            ],
          ],
        ),
      ),
      actions: [
        // A permanent delete is never the default action (02 §10):
        // Cancel takes autofocus unless the reversible move is on.
        TextButton(
          key: const ValueKey('delete.cancel'),
          autofocus: !move,
          onPressed: _cancel,
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const ValueKey('delete.confirm'),
          autofocus: move,
          style: move
              ? null
              : FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
          onPressed: () => Navigator.of(
            context,
          ).pop(DeleteConfirmed(permanent: !move)),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
