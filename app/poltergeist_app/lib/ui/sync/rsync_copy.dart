// The `sync.copyRsyncCommand` verb (05 §2.1): one implementation for
// both surfaces of the registered command — the plan view's action-bar
// button and the Commands-menu row. The controller owns the export
// text; this file owns the clipboard write and the §2.1 toast
// differentiation (the permanent+none configuration warns at copy
// time, not only inside the pasted note block).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
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
  await Clipboard.setData(ClipboardData(text: export.text));
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context);
  showTopToastIn(
    context,
    message: export.permanentDeletions
        ? l10n.syncCopiedRsyncCommandPermanent
        : l10n.syncCopiedRsyncCommand,
  );
}
