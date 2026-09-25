// The Settings → Editing surface's bounded mount (06 §8): the
// `Open With ▸ Configure Editors…` deep-link destination — the two
// registry-backed sections (Default editor, External editors) in a
// dialog until the full five-tab Settings screen lands, mounted exactly
// like the Backup section's bounded dialog. The tab's remaining
// sections (double-click action, preview/download thresholds) are
// settings-backed by other stores and land with that screen.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/settings_models.dart';
import '../../services/external_file_opener.dart';
import '../top_toast.dart';
import 'preview_settings.dart';

/// The `open-with-external` Configure Editors… destination (06 §4.1's
/// menu tail): the Editing sections that already have a backing store.
/// [previewSettings] mounts the §8 "Preview & downloads" rows when a
/// preview cache is wired — null leaves the tab's remaining sections
/// absent rather than rendered-dead.
Future<void> showEditorsSettingsDialog(
  BuildContext context, {
  required EditorRegistryModel controller,
  ExternalFileOpener opener = const ExternalFileOpener(),
  PreviewDownloadsSettings? previewSettings,
}) =>
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext);
        return AlertDialog(
          key: const ValueKey('editors.settings.dialog'),
          title: Text(l10n.settingsTitle),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  EditorsSettingsSection(
                    controller: controller,
                    opener: opener,
                  ),
                  if (previewSettings != null) ...[
                    const SizedBox(height: 20),
                    PreviewDownloadsSection(settings: previewSettings),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('editors.settings.close'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.editorSettingsClose),
            ),
          ],
        );
      },
    );

/// The §8 registry-backed sections: the Default-editor dropdown and the
/// External-editors list with its row actions — every mutation goes
/// through the controller's persist-first discipline (06 §8's
/// immediate-persist model), so a failed settings write restores the
/// pre-mutation registry and the surfaced error.
final class EditorsSettingsSection extends StatelessWidget {
  const EditorsSettingsSection({
    super.key,
    required this.controller,
    this.opener = const ExternalFileOpener(),
    this.picker,
  });

  final EditorRegistryModel controller;
  final ExternalFileOpener opener;

  /// `Add Editor…`'s picker, when it is not [opener]'s: the Settings
  /// window has no plugins or runner channels of its own, so it asks the
  /// app to show the platform's picker.
  final EditorPicker? picker;

  Future<void> _guarded(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (context.mounted) {
        showTopToastIn(context, message: error.toString());
      }
    }
  }

  /// §8's `Add Editor…`: the platform pick, then the same edit dialog as
  /// the row action so extensions can be scoped before the registration
  /// persists (Séance's `_addEditor` flow — a cancelled dialog discards
  /// the pick entirely).
  Future<void> _addEditor(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    try {
      final picked = await (picker ?? opener.pickEditor)(
        dialogTitle: l10n.editorPickDialogTitle,
      );
      if (picked == null || !context.mounted) return;
      final updated = await _editEditorDialog(
        context,
        editor: picked,
        adding: true,
      );
      if (updated == null || !context.mounted) return;
      await controller.register(updated);
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (context.mounted) {
        showTopToastIn(context, message: error.toString());
      }
    }
  }

  Future<void> _editEditor(
    BuildContext context,
    ExternalEditorDefinition editor,
  ) async {
    final updated = await _editEditorDialog(context, editor: editor);
    if (updated == null || !context.mounted) return;
    await _guarded(context, () => controller.register(updated));
  }

  Future<void> _removeEditor(
    BuildContext context,
    ExternalEditorDefinition editor,
  ) async {
    final l10n = AppLocalizations.of(context);
    final isDefault =
        controller.registry.defaultEditorId == editor.id;
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('editors.remove.dialog'),
        title: Text(l10n.editorRemoveTitle(editor.displayName)),
        // §8: removing the current default resets it to System
        // default — the confirm names that consequence up front.
        content: Text(
          isDefault
              ? l10n.editorRemoveDefaultBody
              : l10n.editorRemoveBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.editorDialogCancel),
          ),
          FilledButton(
            key: const ValueKey('editors.remove.confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.editorRemoveLabel),
          ),
        ],
      ),
    );
    if (remove != true || !context.mounted) return;
    await _guarded(context, () => controller.remove(editor.id));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final registry = controller.registry;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(l10n.editorDefaultLabel)),
                DropdownButton<String>(
                  key: const ValueKey('editors.default'),
                  value: registry.defaultEditorId,
                  items: [
                    DropdownMenuItem(
                      key: const ValueKey('editors.default.builtin'),
                      value: EditorRegistry.builtInId,
                      child: Text(l10n.editorBuiltInOption),
                    ),
                    // Always present so `value` can always match an
                    // item — a synced registry may carry the system
                    // default to a host that can't launch it; disabled
                    // there, same as other-platform editors below.
                    DropdownMenuItem(
                      key: const ValueKey('editors.default.system'),
                      value: EditorRegistry.systemDefaultId,
                      enabled: currentEditorHostPlatform != null,
                      child: Text(l10n.editorSystemDefaultOption),
                    ),
                    // §8: other-platform definitions stay visible in
                    // the dropdown but disabled, suffixed "(another
                    // platform)" — synced registries can carry them.
                    for (final editor in registry.editors)
                      DropdownMenuItem(
                        key: ValueKey('editors.default.${editor.id}'),
                        value: editor.id,
                        enabled: editor.isAvailableOnCurrentPlatform,
                        child: Text(
                          editor.isAvailableOnCurrentPlatform
                              ? editor.displayName
                              : l10n.editorNameOtherPlatform(
                                  editor.displayName,
                                ),
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    if (id == null) return;
                    unawaited(
                      _guarded(context, () => controller.setDefault(id)),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              l10n.editorListLabel,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            if (registry.editors.isEmpty)
              Text(l10n.editorEmptyState)
            else
              for (final editor in registry.editors)
                _EditorListRow(
                  editor: editor,
                  onEdit: () => unawaited(_editEditor(context, editor)),
                  onRemove: () => unawaited(_removeEditor(context, editor)),
                ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const ValueKey('editors.add'),
              onPressed: () => unawaited(_addEditor(context)),
              icon: const Icon(Icons.add),
              label: Text(l10n.editorAddLabel),
            ),
          ],
        );
      },
    );
  }
}

/// The §8 registry row: display name, launch target, accepted
/// extensions as `*.ext` chips, and the Edit… / Remove actions.
/// Other-platform definitions render disabled — they are real registry
/// entries (sync or a dual-boot shared disk put them there), just not
/// launchable here.
class _EditorListRow extends StatelessWidget {
  const _EditorListRow({
    required this.editor,
    required this.onEdit,
    required this.onRemove,
  });

  final ExternalEditorDefinition editor;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final available = editor.isAvailableOnCurrentPlatform;
    final theme = Theme.of(context);
    final name = available
        ? editor.displayName
        : l10n.editorNameOtherPlatform(editor.displayName);
    return Padding(
      key: ValueKey('editors.row.${editor.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: available
                      ? null
                      : theme.textTheme.bodyMedium?.copyWith(
                          color: theme.disabledColor,
                        ),
                ),
                Text(
                  editor.launchTarget,
                  style: theme.textTheme.bodySmall,
                ),
                if (editor.acceptedExtensions.isNotEmpty)
                  Wrap(
                    spacing: 4,
                    children: [
                      for (final extension in editor.acceptedExtensions)
                        Chip(
                          label: Text('*.$extension'),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
              ],
            ),
          ),
          TextButton(
            key: ValueKey('editors.edit.${editor.id}'),
            onPressed: available ? onEdit : null,
            child: Text(l10n.editorEditLabel),
          ),
          TextButton(
            key: ValueKey('editors.remove.${editor.id}'),
            onPressed: onRemove,
            child: Text(l10n.editorRemoveLabel),
          ),
        ],
      ),
    );
  }
}

/// The §8 edit dialog — display name plus the comma-separated
/// extensions field. Validation failures render inline under the name
/// field (the FormatException's diagnostic); only a valid result pops.
Future<ExternalEditorDefinition?> _editEditorDialog(
  BuildContext context, {
  required ExternalEditorDefinition editor,
  bool adding = false,
}) {
  final name = TextEditingController(text: editor.displayName);
  final extensions = TextEditingController(
    text: editor.acceptedExtensions.join(', '),
  );
  String? validationError;
  final l10n = AppLocalizations.of(context);
  return showDialog<ExternalEditorDefinition>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Text(
          adding ? l10n.editorAddTitle : l10n.editorEditTitle,
        ),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                autofocus: true,
                onChanged: (_) {
                  if (validationError != null) {
                    setDialogState(() => validationError = null);
                  }
                },
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l10n.editorNameFieldLabel,
                  errorText: validationError,
                ),
              ),
              TextField(
                controller: extensions,
                onChanged: (_) {
                  if (validationError != null) {
                    setDialogState(() => validationError = null);
                  }
                },
                decoration: InputDecoration(
                  labelText: l10n.editorExtensionsFieldLabel,
                  hintText: l10n.editorExtensionsFieldHint,
                  helperText: l10n.editorExtensionsFieldHelper,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                editor.launchTarget,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.editorDialogCancel),
          ),
          FilledButton(
            key: const ValueKey('editors.edit.save'),
            onPressed: () {
              try {
                Navigator.of(dialogContext).pop(
                  editor.copyWith(
                    displayName: validateEditorDisplayName(name.text),
                    acceptedExtensions: normalizeEditorExtensions(
                      extensions.text.split(','),
                    ),
                  ),
                );
              } on FormatException catch (error) {
                setDialogState(() => validationError = error.message);
              }
            },
            child: Text(l10n.editorDialogSave),
          ),
        ],
      ),
    ),
  ).whenComplete(() {
    name.dispose();
    extensions.dispose();
  });
}
