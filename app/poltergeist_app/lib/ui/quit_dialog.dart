import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'panes/pane_format.dart';

/// The quit-with-transfers warning (02 §10): quitting while the queue
/// holds live tasks interrupts the close and offers the §10 verbs —
/// `Pause and Quit` (default), `Cancel Transfers and Quit`, and `Keep
/// Transferring`, which cancels the close. A dismissed dialog answers
/// nothing and counts as Keep Transferring: the quit is vetoed.
enum QuitConfirmChoice { pauseAndQuit, cancelTransfersAndQuit }

/// Shows the §10 quit confirmation. [activeTasks] is the count of
/// non-terminal tasks (paused counts); [remainingBytes] is the
/// discovered-total-minus-completed floor rendered as "remaining so
/// far" — it only grows as scans discover more, so the copy never
/// overstates what is left.
Future<QuitConfirmChoice?> showQuitConfirmDialog(
  BuildContext context, {
  required int activeTasks,
  required int remainingBytes,
}) {
  return showDialog<QuitConfirmChoice>(
    context: context,
    builder: (dialogContext) {
      final l10n = AppLocalizations.of(dialogContext);
      final platform = Theme.of(dialogContext).platform;
      return AlertDialog(
        key: const ValueKey('quit.dialog'),
        // The body plus the restart note must survive long
        // localizations inside short windows.
        scrollable: true,
        title: Text(l10n.quitConfirmTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              remainingBytes > 0
                  ? l10n.quitConfirmBodyRemaining(
                      activeTasks,
                      formatPaneSize(remainingBytes, platform: platform),
                    )
                  : l10n.quitConfirmBody(activeTasks),
            ),
            const SizedBox(height: 8),
            Text(l10n.quitConfirmRestartNote),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('quit.keepTransferring'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.quitKeepTransferring),
          ),
          TextButton(
            key: const ValueKey('quit.cancelTransfers'),
            onPressed: () => Navigator.of(dialogContext).pop(
              QuitConfirmChoice.cancelTransfersAndQuit,
            ),
            child: Text(l10n.quitCancelTransfersAndQuit),
          ),
          FilledButton(
            key: const ValueKey('quit.pauseAndQuit'),
            onPressed: () => Navigator.of(dialogContext).pop(
              QuitConfirmChoice.pauseAndQuit,
            ),
            child: Text(l10n.quitPauseAndQuit),
          ),
        ],
      );
    },
  );
}

/// The close-path flush failure warning (07 §3.5): the journal did not
/// finish writing, so the window stayed open rather than destroying
/// itself over an unflushed queue. Renders the failure inside
/// ARB-authored copy — the raw error is machine data, not authored UI
/// text.
Future<void> showQuitFlushFailedDialog(
  BuildContext context, {
  required String error,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final l10n = AppLocalizations.of(dialogContext);
      return AlertDialog(
        key: const ValueKey('quitFlush.dialog'),
        scrollable: true,
        title: Text(l10n.quitFlushFailedTitle),
        content: Text(l10n.quitFlushFailedBody(error)),
        actions: [
          TextButton(
            key: const ValueKey('quitFlush.dismiss'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.quitFlushFailedDismiss),
          ),
        ],
      );
    },
  );
}
