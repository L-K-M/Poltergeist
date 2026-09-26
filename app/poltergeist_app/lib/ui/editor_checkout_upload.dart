import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/checkout_prompt_ledger.dart';
import '../services/checkout_session.dart';

/// The upload belongs to the app's checkout session, not the workspace
/// that opened the editor. Its conflict question belongs to the surface
/// invoking it, so an editor keeps working after that workspace closes.
Future<bool> uploadEditorCheckout({
  required BuildContext context,
  required CheckoutSession session,
  required CheckoutPromptLedger prompts,
  required ManagedRemoteFile copy,
  required String serverLabel,
}) async {
  final key = '${copy.serverId}|${copy.remotePath}';
  final ownsKey = prompts.uploading.add(key);
  try {
    return await session.uploadLocalCopy(copy);
  } on RemoteFileException catch (error) {
    if (error.kind != RemoteFileErrorKind.conflict || !context.mounted) {
      rethrow;
    }
    final l10n = AppLocalizations.of(context);
    final overwrite = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.editorConflictTitle),
        content: Text(
          l10n.editorConflictBody(remoteBasename(copy.remotePath), serverLabel),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.editorConflictCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.editorConflictOverwrite),
          ),
        ],
      ),
    );
    if (overwrite != true) return false;
    return session.uploadLocalCopy(copy, overwriteRemoteChanges: true);
  } finally {
    if (ownsKey) prompts.uploading.remove(key);
  }
}
