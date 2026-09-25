import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import '../menus/menu_shortcut_hint.dart';
import '../shell/shell_commands.dart'
    show
        kFileDeleteCommandId,
        kFileDownloadToCommandId,
        kFileDuplicateCommandId,
        kFileNewFileCommandId,
        kFileNewFolderCommandId,
        kSelectionMoveToOtherPaneCommandId,
        kSelectionTransferToOtherPaneCommandId;
import 'open_with_commands.dart' show kOpenWithExternalCommandId;
import 'pane_commands.dart';

/// D32 §6's row context menu, section by section, as registry ids: the
/// menu is a rendering of the registry (D21), so enablement, labels,
/// and shortcut hints come from the same rows the menus and palette
/// read.
const kPaneRowContextMenu = <List<String>>[
  [
    kGoOpenCommandId,
    kOpenWithExternalCommandId,
    kFileEditBuiltInCommandId,
    kFilePreviewCommandId,
  ],
  [
    kFileGetInfoCommandId,
    kFileRenameCommandId,
    kFileDuplicateCommandId,
    kSelectionCopyPathCommandId,
  ],
  [kFileNewFolderCommandId, kFileNewFileCommandId],
  [
    kSelectionTransferToOtherPaneCommandId,
    kSelectionMoveToOtherPaneCommandId,
    kFileDownloadToCommandId,
  ],
  [kFileDeleteCommandId],
];

/// The empty-area menu: the folder-level verbs — nothing that acts on
/// a selection the pointer did not land on.
const kPaneEmptyContextMenu = <List<String>>[
  [kFileNewFolderCommandId, kFileNewFileCommandId],
  [kSelectionCopyPathCommandId],
  [kViewToggleHiddenCommandId, kViewRefreshCommandId],
  [kEditSelectAllCommandId],
];

/// Resolves [sections] against the registered [commands]: unregistered
/// slots drop out, and so does a section left empty.
List<List<RegisteredCommand>> resolvePaneContextSections(
  List<RegisteredCommand> commands,
  List<List<String>> sections,
) {
  final byId = {for (final command in commands) command.id: command};
  return [
    for (final section in sections)
      if (section.map((id) => byId[id]).nonNulls.toList() case final rows
          when rows.isNotEmpty)
        rows,
  ];
}

/// The pointer/keyboard menu's rows for [sections] (a [MenuAnchor]'s
/// children), keyed `pane.context.<id>`. [firstItemFocus] lands on the
/// first row so a keyboard-opened menu (Shift+F10, the Menu key) can
/// take focus straight away.
List<Widget> buildPaneContextMenuItems({
  required BuildContext context,
  required List<List<RegisteredCommand>> sections,
  required Future<void> Function(RegisteredCommand command) onRun,
  FocusNode? firstItemFocus,
}) {
  final l10n = AppLocalizations.of(context);
  final platform = Theme.of(context).platform;
  var first = true;
  FocusNode? takeFirstFocus() {
    if (!first) return null;
    first = false;
    return firstItemFocus;
  }

  Widget row(RegisteredCommand command) {
    final enabled = command.enabled();
    final icon = command.icon == null ? null : Icon(command.icon, size: 16);
    final submenu = command.submenuItems;
    if (submenu != null) {
      return SubmenuButton(
        key: ValueKey('pane.context.${command.id}'),
        focusNode: takeFirstFocus(),
        leadingIcon: icon,
        menuChildren: [
          for (final item in submenu(l10n))
            MenuItemButton(
              onPressed: item.enabled() ? () => unawaited(onRun(item)) : null,
              child: Text(item.label(l10n)),
            ),
        ],
        child: Text(command.label(l10n)),
      );
    }
    final checked = command.checked;
    if (checked != null) {
      return CheckboxMenuButton(
        key: ValueKey('pane.context.${command.id}'),
        focusNode: takeFirstFocus(),
        trailingIcon: MenuShortcutHint.forCommand(command, platform),
        value: checked(),
        onChanged: enabled ? (_) => unawaited(onRun(command)) : null,
        child: Text(command.label(l10n)),
      );
    }
    return MenuItemButton(
      key: ValueKey('pane.context.${command.id}'),
      focusNode: takeFirstFocus(),
      leadingIcon: icon,
      trailingIcon: MenuShortcutHint.forCommand(command, platform),
      onPressed: enabled ? () => unawaited(onRun(command)) : null,
      child: Text(command.label(l10n)),
    );
  }

  return [
    for (var i = 0; i < sections.length; i++) ...[
      if (i > 0) const Divider(height: 9, indent: 12, endIndent: 12),
      for (final command in sections[i]) row(command),
    ],
  ];
}

/// D32 §5/§9's touch rendering of the same verbs: a bottom sheet opened
/// by a long-press. A submenu command (Open With ▸) runs its own
/// non-menu path — the chooser dialog — instead of nesting a menu in a
/// sheet.
Future<void> showPaneContextSheet(
  BuildContext context, {
  required String? title,
  required List<List<RegisteredCommand>> sections,
  required Future<void> Function(RegisteredCommand command) onRun,
}) {
  final l10n = AppLocalizations.of(context);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 8),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(sheetContext).textTheme.titleSmall,
              ),
            ),
          for (var i = 0; i < sections.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            for (final command in sections[i])
              ListTile(
                key: ValueKey('pane.context.${command.id}'),
                leading: command.icon == null ? null : Icon(command.icon),
                title: Text(command.label(l10n)),
                trailing: command.checked == null
                    ? null
                    : Icon(
                        command.checked!()
                            ? Icons.check_box_outlined
                            : Icons.check_box_outline_blank,
                      ),
                enabled: command.enabled(),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(onRun(command));
                },
              ),
          ],
        ],
      ),
    ),
  );
}
