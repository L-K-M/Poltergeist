import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import '../panes/pane_context_menu.dart';
import '../shell/shell_commands.dart'
    show
        kFileDeleteCommandId,
        kSelectionMoveToOtherPaneCommandId,
        kSelectionTransferToOtherPaneCommandId;
import '../top_toast.dart';
import 'compact_posture.dart';

/// The verbs the selection bar carries itself (D32 §9); every other
/// selection-scoped command goes behind More.
const _barCommandIds = {
  kSelectionTransferToOtherPaneCommandId,
  kSelectionMoveToOtherPaneCommandId,
  kFileDeleteCommandId,
};

/// The More sheet's sections: the registry's selection-scoped verbs the
/// bar does not carry, in the row context menu's order (D32 §6) so the
/// phone lists them where the desktop menu does; selection verbs the
/// context menu does not name follow in registry order.
List<List<RegisteredCommand>> compactMoreSections(
  List<RegisteredCommand> commands,
) {
  final selection = [
    for (final command in commands)
      if (command.scope == CommandScope.selection &&
          !_barCommandIds.contains(command.id))
        command,
  ];
  final placed = <String>{};
  final sections = <List<RegisteredCommand>>[];
  for (final section in resolvePaneContextSections(
    selection,
    kPaneRowContextMenu,
  )) {
    sections.add(section);
    placed.addAll(section.map((command) => command.id));
  }
  final rest = [
    for (final command in selection)
      if (!placed.contains(command.id)) command,
  ];
  if (rest.isNotEmpty) sections.add(rest);
  return sections;
}

/// D32 §9's bottom action bar while items are selected: Copy and Move to
/// the other pane (named by its letter — the two-pane model's implicit
/// destination), Delete, and More. Each item is the registered command
/// (D21): its enablement, its run path, and its full label for assistive
/// tech. A disabled item still answers a tap with the command's reason,
/// so a greyed Copy explains that the other pane has no folder open
/// instead of doing nothing.
///
/// Share is deliberately absent: it needs a platform share plugin this
/// slice does not add (recorded as deferred in STATUS).
class CompactSelectionBar extends StatelessWidget {
  const CompactSelectionBar({
    super.key,
    required this.commands,
    required this.onRun,
    required this.otherPaneLetter,
    required this.moreTitle,
  });

  final List<RegisteredCommand> commands;
  final Future<void> Function(RegisteredCommand command) onRun;

  /// "B" while pane A shows, and vice versa.
  final String otherPaneLetter;

  /// The More sheet's title ("3 selected").
  final String moreTitle;

  RegisteredCommand? _command(String id) {
    for (final command in commands) {
      if (command.id == id) return command;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final more = compactMoreSections(commands);
    return Material(
      key: const ValueKey(CompactKey.selectionBar),
      color: colors.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 80,
          child: Row(
            children: [
              _item(
                context,
                key: CompactKey.actionCopy,
                command: _command(kSelectionTransferToOtherPaneCommandId),
                icon: Icons.content_copy_outlined,
                label: l10n.compactActionCopyTo(otherPaneLetter),
              ),
              _item(
                context,
                key: CompactKey.actionMove,
                command: _command(kSelectionMoveToOtherPaneCommandId),
                icon: Icons.drive_file_move_outline,
                label: l10n.compactActionMoveTo(otherPaneLetter),
              ),
              _item(
                context,
                key: CompactKey.actionDelete,
                command: _command(kFileDeleteCommandId),
                icon: Icons.delete_outline,
                label: l10n.compactActionDelete,
              ),
              _BarItem(
                key: const ValueKey(CompactKey.actionMore),
                icon: Icons.more_horiz,
                label: l10n.compactActionMore,
                semanticLabel: l10n.compactActionMore,
                enabled: more.isNotEmpty,
                onPressed: () => unawaited(
                  showPaneContextSheet(
                    context,
                    title: moreTitle,
                    sections: more,
                    onRun: onRun,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(
    BuildContext context, {
    required CompactKey key,
    required RegisteredCommand? command,
    required IconData icon,
    required String label,
  }) {
    final l10n = AppLocalizations.of(context);
    final enabled = command != null && command.enabled();
    return _BarItem(
      key: ValueKey(key),
      icon: command?.icon ?? icon,
      label: label,
      semanticLabel: command?.label(l10n) ?? label,
      enabled: enabled,
      onPressed: () {
        if (command == null) return;
        if (command.enabled()) {
          unawaited(onRun(command));
          return;
        }
        final reason = command.disabledReason?.call(l10n);
        if (reason != null) showTopToastIn(context, message: reason);
      },
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({
    super.key,
    required this.icon,
    required this.label,
    required this.semanticLabel,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String semanticLabel;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final color = enabled
        ? colors.onSurface
        : colors.onSurface.withValues(alpha: 0.38);
    return Expanded(
      child: Semantics(
        button: true,
        enabled: enabled,
        label: semanticLabel,
        // The InkWell below is excluded, so the node carries the tap: a
        // node without one is not clickable to TalkBack, Switch Access or
        // Voice Access. Wired while disabled too, so the reason toast
        // answers it.
        onTap: onPressed,
        excludeSemantics: true,
        child: InkWell(
          onTap: onPressed,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
