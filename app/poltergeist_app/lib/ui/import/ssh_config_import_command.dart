import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/registered_command.dart';
import '../../services/ssh_config_import_setup.dart';
import 'ssh_config_import_dialog.dart';

/// The registered id of the ssh_config import command (02 §8.1's
/// `favorite.*` group; D21, 07 §3.3).
const kSshConfigImportCommandId = 'favorite.importSshConfig';

/// The import entry command: reads the persisted bookmarks for dedupe
/// (D22), shows the preview, and persists the rows the user kept. Key
/// files stay reference-style — no key material is read here (D18).
RegisteredCommand buildSshConfigImportCommand({
  required SshConfigImportSetup setup,
  required bool Function() enabled,
}) {
  return RegisteredCommand(
    id: kSshConfigImportCommandId,
    scope: CommandScope.app,
    label: (l10n) => l10n.sshImportCommandLabel,
    icon: Icons.download_outlined,
    enabled: enabled,
    run: (context) => _runSshConfigImport(context, setup),
  );
}

Future<void> _runSshConfigImport(
  BuildContext context,
  SshConfigImportSetup setup,
) async {
  final List<Bookmark> existing;
  try {
    // Dedupe runs against the persisted store, not a cached list: the
    // preview must reflect what will actually collide on import.
    existing = await setup.bookmarks.load();
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (!context.mounted) return;
    _notify(
      context,
      AppLocalizations.of(context).sshImportFavoritesLoadFailed,
    );
    return;
  }
  if (!context.mounted) return;

  final imported = await showSshConfigImportDialog(
    context,
    service: setup.service,
    configPath: setup.configPath,
    existingBookmarks: existing,
  );
  if (imported == null || imported.isEmpty) return;

  try {
    await setup.bookmarks.upsertAll(imported);
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (!context.mounted) return;
    _notify(
      context,
      AppLocalizations.of(context).sshImportFavoritesSaveFailed,
    );
    return;
  }
  if (!context.mounted) return;

  _notify(
    context,
    AppLocalizations.of(context).sshImportImported(imported.length),
  );
}

void _notify(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message)),
  );
}
