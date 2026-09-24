// The `sync.copyRsyncCommand` verb (05 §2.1): one implementation for
// every surface of the export — the plan view's action-bar button, the
// Server-menu row, and the Sync sheet's ⋯ menu (D32 §7). The
// controller layer owns the export text; this file owns the clipboard
// write and the §2.1 toast differentiation (the permanent+none
// configuration warns at copy time, not only inside the pasted note
// block).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../l10n/app_localizations.dart';
import '../../services/rsync_endpoints.dart';
import '../../services/sync_plan_controller.dart';
import '../top_toast.dart';

/// Copies [controller]'s rsync export to the clipboard and shows the
/// §2.1 toast. A null export (no plan yet, or a remote side whose
/// `serverConfigId` resolves to nothing) no-ops silently — the
/// command's enablement already gates that case.
Future<void> copyRsyncCommand(
  BuildContext context,
  SyncPlanController controller,
) async {
  final export = controller.rsyncExport();
  if (export == null) return;
  await _copyExport(context, export);
}

/// The Sync sheet's export: no scan has run, so the command renders
/// the ruleset alone — no manual overrides, no scan-derived skip paths
/// — with [pairState]'s untrusted-clock downgrade when the caller has
/// the state. A pair whose remote side does not resolve no-ops (the
/// sheet disables the item for it).
Future<void> copyPairRsyncCommand(
  BuildContext context,
  SyncPair pair,
  RsyncEndpointResolver resolver, {
  SyncPairState? pairState,
}) async {
  final export = syncRsyncExport(
    pair,
    resolver,
    mtimesUntrusted:
        (pairState?.mtimeUnreliableLeft ?? false) ||
        (pairState?.mtimeUnreliableRight ?? false),
    now: DateTime.now(),
  );
  if (export == null) return;
  await _copyExport(context, export);
}

Future<void> _copyExport(BuildContext context, SyncRsyncExport export) async {
  try {
    await Clipboard.setData(ClipboardData(text: export.text));
  } catch (_) {
    // Callers unawait this future — an unguarded platform-channel throw
    // would surface as an unhandled async error; the user gets a toast
    // instead.
    if (!context.mounted) return;
    showTopToastIn(
      context,
      message: AppLocalizations.of(context).syncRsyncCopyFailed,
    );
    return;
  }
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context);
  showTopToastIn(
    context,
    message: export.permanentDeletions
        ? l10n.syncCopiedRsyncCommandPermanent
        : l10n.syncCopiedRsyncCommand,
  );
}
