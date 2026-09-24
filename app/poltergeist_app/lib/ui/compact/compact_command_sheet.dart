import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import '../../theme/app_theme.dart';
import '../menus/app_menus.dart';
import 'compact_posture.dart';

/// D32 §8's Android row: the ⋮ overflow renders the same menu tree the
/// desktop menu bar and the ☰ button render — [buildAppMenus] over
/// [commands], so nothing on the phone is a parallel list (D21). Each
/// menu becomes a titled section of 48 dp rows; a ▸ submenu lists its
/// members under its own caption, since a sheet has no room for
/// flyouts. Disabled rows stay visible with the command's reason, so
/// the sheet's shape never shifts with state and a greyed verb says why.
Future<void> showCompactCommandSheet(
  BuildContext context, {
  required String title,
  required List<RegisteredCommand> commands,
  required Future<void> Function(RegisteredCommand command) onRun,
}) {
  final l10n = AppLocalizations.of(context);
  final menus = buildAppMenus(
    commands: commands,
    l10n: l10n,
    platform: Theme.of(context).platform,
  );
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      key: const ValueKey(CompactKey.commandSheet),
      expand: false,
      initialChildSize: 0.62,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, scroll) => _CommandSheetBody(
        title: title,
        menus: menus,
        scroll: scroll,
        onRun: (command) {
          Navigator.of(sheetContext).pop();
          unawaited(onRun(command));
        },
      ),
    ),
  );
}

class _CommandSheetBody extends StatelessWidget {
  const _CommandSheetBody({
    required this.title,
    required this.menus,
    required this.scroll,
    required this.onRun,
  });

  final String title;
  final List<AppMenuModel> menus;
  final ScrollController scroll;
  final ValueChanged<RegisteredCommand> onRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(24, 0, 24, 8),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
      ),
    ];
    for (final menu in menus) {
      final rows = <Widget>[];
      for (var i = 0; i < menu.groups.length; i++) {
        final group = [
          for (final row in menu.groups[i]) ..._rowTiles(context, row),
        ];
        if (group.isEmpty) continue;
        if (rows.isNotEmpty) {
          rows.add(const Divider(height: 1, indent: 72));
        }
        rows.addAll(group);
      }
      if (rows.isEmpty) continue;
      children
        ..add(
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(24, 16, 24, 4),
            child: Semantics(
              header: true,
              child: Text(
                menu.title,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
        )
        ..addAll(rows);
    }
    return ListView(
      controller: scroll,
      padding: EdgeInsets.only(
        bottom: 16 + MediaQuery.paddingOf(context).bottom,
      ),
      children: children,
    );
  }

  List<Widget> _rowTiles(BuildContext context, AppMenuRow row) {
    switch (row) {
      case AppMenuCommandRow(:final command):
        return [_CommandTile(command: command, onRun: onRun)];
      case AppMenuSubmenuRow(:final title, :final items):
        if (items.isEmpty) return const [];
        return [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(72, 12, 24, 4),
            child: Text(
              title,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: PoltergeistChrome.of(context).secondaryText,
              ),
            ),
          ),
          for (final item in items)
            _CommandTile(command: item.command, onRun: onRun, nested: true),
        ];
      case AppMenuProvidedRow():
        // AppKit chrome (About, Hide, Quit…) exists only in the native
        // macOS menu bar — never on a touch platform.
        return const [];
    }
  }
}

/// One registry row as a 48 dp tile: the command's icon, label, toggle
/// state, and — while disabled — its spelled-out reason.
class _CommandTile extends StatelessWidget {
  const _CommandTile({
    required this.command,
    required this.onRun,
    this.nested = false,
  });

  final RegisteredCommand command;
  final ValueChanged<RegisteredCommand> onRun;
  final bool nested;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final enabled = command.enabled();
    final checked = command.checked;
    final reason = enabled ? null : command.disabledReason?.call(l10n);
    return ListTile(
      key: ValueKey((CompactKey.commandRow, command.id)),
      contentPadding: const EdgeInsetsDirectional.only(start: 24, end: 16),
      minLeadingWidth: 32,
      leading: nested
          ? const SizedBox(width: 24)
          : Icon(command.icon ?? Icons.chevron_right),
      title: Text(command.label(l10n)),
      subtitle: reason == null
          ? null
          : Text(reason, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: checked == null
          ? null
          : IgnorePointer(
              child: Switch(
                value: checked(),
                onChanged: enabled ? (_) {} : null,
              ),
            ),
      enabled: enabled,
      onTap: () => onRun(command),
    );
  }
}
