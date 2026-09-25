part of 'sidebar_view.dart';

/// The rail's one-field name prompt (rename, new group, save to
/// servers) — the shared [showNamePrompt].
Future<String?> _promptName(
  BuildContext context, {
  required String title,
  required String fieldLabel,
  required Key fieldKey,
  required Key saveKey,
  String initial = '',
}) => showNamePrompt(
  context,
  title: title,
  fieldLabel: fieldLabel,
  fieldKey: fieldKey,
  saveKey: saveKey,
  initial: initial,
);

/// The rename verb: a store save through the controller, so the
/// `updatedAt` stamp lands. A failed save reports and says so — the
/// record is untouched.
Future<void> _renameBookmark(
  BuildContext context,
  SidebarView view,
  Bookmark bookmark,
) async {
  final l10n = AppLocalizations.of(context);
  final renamed = await _promptName(
    context,
    title: bookmark.kind == BookmarkKind.remotePath
        ? l10n.sidebarRenameServerTitle
        : l10n.sidebarRenameTitle,
    fieldLabel: l10n.sidebarRenameFieldLabel,
    fieldKey: const ValueKey('sidebar.renameField'),
    saveKey: const ValueKey('sidebar.renameSave'),
    initial: bookmark.label,
  );
  if (renamed == null || renamed == bookmark.label || !context.mounted) return;
  try {
    await view.controller.rename(bookmark.id, renamed);
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (context.mounted) _showSidebarError(context, l10n);
  }
}

/// "Move to Group ▸ New Group…": group records are member-carried, so
/// creating a group IS the move.
Future<void> _newGroupFor(
  BuildContext context,
  SidebarView view,
  Bookmark bookmark,
) async {
  final l10n = AppLocalizations.of(context);
  final group = await _promptName(
    context,
    title: l10n.sidebarNewGroupTitle,
    fieldLabel: l10n.sidebarGroupFieldLabel,
    fieldKey: const ValueKey('sidebar.groupField'),
    saveKey: const ValueKey('sidebar.groupSave'),
  );
  if (group == null || !context.mounted) return;
  try {
    await view.controller.moveToGroup(bookmark.id, group);
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (context.mounted) _showSidebarError(context, l10n);
  }
}

/// The + menu's "New Group…": no bookmark to carry it yet, so the group
/// waits in the controller (in memory) for its first member.
Future<void> _newPendingGroup(BuildContext context, SidebarView view) async {
  final l10n = AppLocalizations.of(context);
  final group = await _promptName(
    context,
    title: l10n.sidebarNewGroupTitle,
    fieldLabel: l10n.sidebarGroupFieldLabel,
    fieldKey: const ValueKey('sidebar.groupField'),
    saveKey: const ValueKey('sidebar.groupSave'),
  );
  if (group == null || !context.mounted) return;
  view.controller.addPendingGroup(group);
}

/// The delete verb: a confirmation, then the store remove — the engine
/// cascade rides the controller's `onBookmarkRemoved` seam after the
/// record is actually gone.
Future<void> _deleteBookmark(
  BuildContext context,
  SidebarView view,
  Bookmark bookmark,
) async {
  final l10n = AppLocalizations.of(context);
  final server = bookmark.kind == BookmarkKind.remotePath;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        server ? l10n.sidebarDeleteServerTitle : l10n.sidebarDeleteTitle,
      ),
      content: Text(
        server
            ? l10n.sidebarDeleteServerBody(bookmark.label)
            : l10n.sidebarDeleteBody(bookmark.label),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.tabCloseConfirmCancel),
        ),
        FilledButton(
          key: const ValueKey('sidebar.deleteConfirm'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.sidebarDelete),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await view.controller.remove(bookmark.id);
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (context.mounted) _showSidebarError(context, l10n);
  }
}

/// "Save to Favorites…" on a live Quick Connect session: the pane's
/// save-as-favorite flow, reached from the rail's row and from Server ▸
/// Save to Favorites… — a name (prefilled from the live endpoint, never
/// the raw address), then a store save through [controller].
Future<void> saveSessionToServers(
  BuildContext context,
  SidebarController controller,
  SidebarAdhocSession session,
) async {
  final l10n = AppLocalizations.of(context);
  final name = await promptSaveToServers(
    context,
    session.bookmark,
    fieldKey: const ValueKey('sidebar.saveServerField'),
    saveKey: const ValueKey('sidebar.saveServerSave'),
  );
  if (name == null || !context.mounted) return;
  try {
    await controller.saveRemoteLocation(
      live: session.bookmark,
      path: session.path,
      label: name,
    );
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (context.mounted) _showSidebarError(context, l10n);
  }
}

void _showSidebarError(BuildContext context, AppLocalizations l10n) =>
    _showSidebarNotice(context, l10n.sidebarActionFailed);

void _showSidebarNotice(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}
