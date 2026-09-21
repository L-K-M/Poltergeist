import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/editor_registry_controller.dart';
import '../../services/external_file_opener.dart';
import '../../services/pane_controller.dart';
import '../../services/registered_command.dart';
import '../../services/workspace_controller.dart';
import '../settings/editor_settings.dart';

/// The parameterized open-with command (02 §8.1's `file.openWith`
/// shape; the task-brief id is `open-with-external`). Its File-menu
/// slot renders as the `Open With ▸` submenu — the items are
/// parameter-bound invocations rebuilt per render, so the rows always
/// track the live selection and registry.
const kOpenWithExternalCommandId = 'open-with-external';

/// The chooser result selecting `Other…` — an app pick rather than a
/// resolved editor id.
const kOpenWithOtherChoice = 'open-with-external:other';

/// Builds the `open-with-external` command (06 §4.2's Open With ▸ row).
///
/// [openWith] is the shell's dispatch: it takes the pane, the entry,
/// and a concrete selector — a registered editor id or
/// `poltergeist.system`/`poltergeist.builtin` — and runs the §4.2
/// local/remote launch chain. [pickAndOpen] is the `Other…` flow: pick
/// an application, register it, maybe bind the extension, then open.
RegisteredCommand buildOpenWithCommand({
  required WorkspaceController workspace,
  required EditorRegistryController? registry,
  ExternalFileOpener externalOpener = const ExternalFileOpener(),
  required Future<void> Function(
    PaneController pane,
    RemoteFileEntry entry,
    String editorId,
  )
  openWith,
  required Future<void> Function(
    BuildContext context,
    PaneController pane,
    RemoteFileEntry entry,
  )
  pickAndOpen,
}) {
  // The cursor's file/symlink row is the target — the same enablement
  // gate as file.editBuiltIn (directories never open with an editor).
  ({PaneController pane, RemoteFileEntry entry})? target() {
    final pane = workspace.activeTabController;
    final cursor = pane?.cursorIndex;
    if (pane == null ||
        !pane.verbsEnabled ||
        cursor == null ||
        cursor < 0 ||
        cursor >= pane.entries.length) {
      return null;
    }
    final entry = pane.entries[cursor];
    if (entry.type != RemoteFileType.file &&
        entry.type != RemoteFileType.symbolicLink) {
      return null;
    }
    return (pane: pane, entry: entry);
  }

  RegisteredCommand item(String suffix, String label, String editorId) =>
      RegisteredCommand(
        // Parameter-bound items share the parent's registry id — the
        // suffix only keeps menu keys unique; they are never registered
        // themselves.
        id: '$kOpenWithExternalCommandId:$suffix',
        scope: CommandScope.selection,
        label: (_) => label,
        enabled: () => target() != null,
        run: (_) async {
          final resolved = target();
          if (resolved == null) return;
          if (editorId == EditorRegistry.builtInId) {
            // The built-in row takes §4.2's capped built-in path —
            // routing through the same verb as `file.editBuiltIn`
            // keeps the local in-place open and the capped remote
            // checkout identical, row gates included.
            await resolved.pane.editInBuiltInEditor(resolved.entry);
            return;
          }
          await openWith(resolved.pane, resolved.entry, editorId);
        },
      );

  List<RegisteredCommand> items(AppLocalizations l10n) {
    final resolved = target();
    return [
      item('builtin', l10n.openWithBuiltInLabel, EditorRegistry.builtInId),
      for (final editor
          in registry?.registry.compatibleEditors(resolved?.entry.path ?? '') ??
              const <ExternalEditorDefinition>[])
        item('editor.${editor.id}', editor.displayName, editor.id),
      if (currentEditorHostPlatform != null)
        item(
          'system',
          l10n.openWithSystemDefaultLabel,
          EditorRegistry.systemDefaultId,
        ),
      RegisteredCommand(
        id: kOpenWithOtherChoice,
        scope: CommandScope.selection,
        label: (l10n) => l10n.openWithOtherLabel,
        enabled: () => target() != null,
        run: (context) async {
          final resolved = target();
          if (resolved == null) return;
          await pickAndOpen(context, resolved.pane, resolved.entry);
        },
      ),
      // §4.1's menu tail: `Configure Editors…` deep-links to the §8
      // Editing sections' bounded mount. Disabled without a registry —
      // a settings-less boot has nothing to configure.
      RegisteredCommand(
        id: '$kOpenWithExternalCommandId:configure',
        scope: CommandScope.selection,
        label: (l10n) => l10n.openWithConfigureLabel,
        enabled: () => registry != null,
        run: (context) async {
          final controller = registry;
          if (controller == null) return;
          await showEditorsSettingsDialog(
            context,
            controller: controller,
            opener: externalOpener,
          );
        },
      ),
    ];
  }

  return RegisteredCommand(
    id: kOpenWithExternalCommandId,
    scope: CommandScope.selection,
    label: (l10n) => l10n.fileOpenWithLabel,
    icon: Icons.open_in_new_outlined,
    // The submenu stays openable without a selection when a registry
    // exists: the per-editor rows gate on target() individually, and
    // Configure Editors… must stay reachable as the settings deep link.
    enabled: () => target() != null || registry != null,
    // The non-menu invocation path (palette later; the §1 refusal
    // router today): the same rows as the submenu, as a chooser dialog.
    run: (context) async {
      final resolved = target();
      if (resolved == null || !context.mounted) return;
      final selected = await showOpenWithChooser(
        context,
        registry: registry?.registry,
        path: resolved.entry.path,
      );
      if (selected == null || !context.mounted) return;
      if (selected == kOpenWithOtherChoice) {
        await pickAndOpen(context, resolved.pane, resolved.entry);
        return;
      }
      if (selected == EditorRegistry.builtInId) {
        await resolved.pane.editInBuiltInEditor(resolved.entry);
        return;
      }
      await openWith(resolved.pane, resolved.entry, selected);
    },
    // 02 §9's File menu: the Open With ▸ slot between Open (60) and
    // Edit in Poltergeist (63).
    menuPlacement: const CommandMenuPlacement(
      menu: AppMenuId.file,
      order: 62,
      group: 1,
    ),
    submenuItems: items,
  );
}

/// The Open With chooser — the dialog rendering of the same rows the
/// `Open With ▸` submenu carries (02 §8.1's parameterized command
/// invoked outside a menu). Returns the selected editor id, a
/// `poltergeist.*` reserved selector, [kOpenWithOtherChoice] for the
/// app pick, or null on cancel. `Configure Editors…` is deliberately
/// absent here: the chooser answers "which editor", and a mid-pick
/// detour into settings is not an answer.
Future<String?> showOpenWithChooser(
  BuildContext context, {
  required EditorRegistry? registry,
  required String path,
}) {
  final l10n = AppLocalizations.of(context);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(l10n.fileOpenWithLabel),
      children: [
        SimpleDialogOption(
          key: const ValueKey('openWith.builtin'),
          onPressed: () =>
              Navigator.of(dialogContext).pop(EditorRegistry.builtInId),
          child: Text(l10n.openWithBuiltInLabel),
        ),
        for (final editor in registry?.compatibleEditors(path) ??
            const <ExternalEditorDefinition>[])
          SimpleDialogOption(
            key: ValueKey('openWith.${editor.id}'),
            onPressed: () => Navigator.of(dialogContext).pop(editor.id),
            child: Text(editor.displayName),
          ),
        if (currentEditorHostPlatform != null)
          SimpleDialogOption(
            key: const ValueKey('openWith.system'),
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(EditorRegistry.systemDefaultId),
            child: Text(l10n.openWithSystemDefaultLabel),
          ),
        const Divider(),
        SimpleDialogOption(
          key: const ValueKey('openWith.other'),
          onPressed: () =>
              Navigator.of(dialogContext).pop(kOpenWithOtherChoice),
          child: Text(l10n.openWithOtherLabel),
        ),
      ],
    ),
  );
}

/// The remember-choice prompt after an `Other…` pick for an entry that
/// HAS an extension (06 §4.1's per-extension binding write): Cancel
/// aborts the open entirely, Open proceeds once — and a checked
/// "always use" binds the extension to the picked editor first.
/// Returns the remember flag, or null when cancelled.
Future<bool?> showRememberEditorChoice(
  BuildContext context, {
  required String name,
  required String editor,
  required String extension,
}) => showDialog<bool>(
  context: context,
  builder: (dialogContext) => _RememberEditorDialog(
    name: name,
    editor: editor,
    extension: extension,
  ),
);

class _RememberEditorDialog extends StatefulWidget {
  const _RememberEditorDialog({
    required this.name,
    required this.editor,
    required this.extension,
  });

  final String name;
  final String editor;
  final String extension;

  @override
  State<_RememberEditorDialog> createState() => _RememberEditorDialogState();
}

class _RememberEditorDialogState extends State<_RememberEditorDialog> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.openWithPickedTitle(widget.name, widget.editor)),
      content: CheckboxListTile(
        key: const ValueKey('openWith.remember'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          l10n.openWithRememberForExtension(
            widget.editor,
            widget.extension,
          ),
        ),
        value: _remember,
        onChanged: (value) => setState(() => _remember = value ?? false),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.openWithCancel),
        ),
        FilledButton(
          key: const ValueKey('openWith.confirm'),
          onPressed: () => Navigator.of(context).pop(_remember),
          child: Text(l10n.openWithConfirmOpen),
        ),
      ],
    );
  }
}
