import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';

/// One row inside a derived menu.
///
/// The menu model is a pure function of the command registry (07 §3.4 /
/// D21): the app renderer only serializes these rows, so menu content can
/// never drift from what is registered.
sealed class AppMenuRow {
  const AppMenuRow();
}

/// A command leaf row.
final class AppMenuCommandRow extends AppMenuRow {
  const AppMenuCommandRow(this.command);
  final RegisteredCommand command;
}

/// A named submenu grouping command rows (02 §9 "Sort By").
final class AppMenuSubmenuRow extends AppMenuRow {
  AppMenuSubmenuRow({required this.title});

  final String title;
  final List<AppMenuCommandRow> items = [];
}

/// A platform-provided native item — used only on macOS for the
/// application and window chrome (02 §9).
final class AppMenuProvidedRow extends AppMenuRow {
  const AppMenuProvidedRow(this.type);
  final PlatformProvidedMenuItemType type;
}

/// A top-level menu: a localized title plus divider-separated groups of
/// rows in render order.
class AppMenuModel {
  const AppMenuModel({
    required this.id,
    required this.title,
    required this.groups,
  });

  final AppMenuId id;
  final String title;

  /// Sections in order; the renderer inserts a divider between groups.
  final List<List<AppMenuRow>> groups;
}

/// Derives the app's menus from the registered commands for [platform].
///
/// Commands without a [RegisteredCommand.menuPlacement] never appear —
/// there are no disabled placeholders for commands that do not exist yet,
/// and stable [CommandMenuPlacement.order] slots leave gaps for future
/// commands. Menus with no rows are dropped (except the macOS chrome
/// below).
List<AppMenuModel> buildAppMenus({
  required List<RegisteredCommand> commands,
  required AppLocalizations l10n,
  required TargetPlatform platform,
}) {
  final placed = <AppMenuId, List<RegisteredCommand>>{};
  for (final command in commands) {
    final placement = command.menuPlacement;
    if (placement == null) continue;
    assert(
      placement.menu != AppMenuId.app,
      'the macOS application menu is platform chrome only',
    );
    placed.putIfAbsent(placement.menu, () => []).add(command);
  }

  final menus = <AppMenuModel>[
    if (platform == TargetPlatform.macOS) _macAppMenu(l10n),
  ];

  for (final id in AppMenuId.values) {
    if (id == AppMenuId.app) continue;
    var groups = _menuGroups(placed[id] ?? const [], l10n);
    if (platform == TargetPlatform.macOS && id == AppMenuId.window) {
      groups = [
        const [
          AppMenuProvidedRow(PlatformProvidedMenuItemType.minimizeWindow),
          AppMenuProvidedRow(PlatformProvidedMenuItemType.zoomWindow),
        ],
        ...groups,
      ];
    }
    if (groups.isEmpty) continue;
    menus.add(
      AppMenuModel(id: id, title: _menuTitle(id, l10n), groups: groups),
    );
  }
  return menus;
}

/// The macOS application menu — standard chrome only (02 §9). No
/// Poltergeist commands live here.
AppMenuModel _macAppMenu(AppLocalizations l10n) => AppMenuModel(
  id: AppMenuId.app,
  title: l10n.appTitle,
  groups: const [
    [AppMenuProvidedRow(PlatformProvidedMenuItemType.about)],
    [AppMenuProvidedRow(PlatformProvidedMenuItemType.servicesSubmenu)],
    [
      AppMenuProvidedRow(PlatformProvidedMenuItemType.hide),
      AppMenuProvidedRow(PlatformProvidedMenuItemType.hideOtherApplications),
      AppMenuProvidedRow(PlatformProvidedMenuItemType.showAllApplications),
    ],
    [AppMenuProvidedRow(PlatformProvidedMenuItemType.quit)],
  ],
);

/// Sorts one menu's commands by `(group, order)` and splits the sorted
/// run into divider-separated groups.
List<List<AppMenuRow>> _menuGroups(
  List<RegisteredCommand> items,
  AppLocalizations l10n,
) {
  final sorted = [...items]..sort((a, b) {
    final pa = a.menuPlacement!;
    final pb = b.menuPlacement!;
    final byGroup = pa.group.compareTo(pb.group);
    if (byGroup != 0) return byGroup;
    final byOrder = pa.order.compareTo(pb.order);
    if (byOrder != 0) return byOrder;
    return a.id.compareTo(b.id);
  });
  assert(() {
    final slots = <String>{};
    for (final command in sorted) {
      final p = command.menuPlacement!;
      assert(
        slots.add('${p.group}:${p.order}'),
        '${command.id} shares menu slot ${p.group}:${p.order}',
      );
    }
    return true;
  }());

  final groups = <List<AppMenuRow>>[];
  var group = -1;
  List<AppMenuRow>? rows;
  for (final command in sorted) {
    final placement = command.menuPlacement!;
    if (placement.group != group) {
      group = placement.group;
      rows = [];
      groups.add(rows);
    }
    final submenu = placement.submenu;
    if (submenu == null) {
      rows!.add(AppMenuCommandRow(command));
    } else {
      final title = submenu(l10n);
      final row = rows!
          .whereType<AppMenuSubmenuRow>()
          .where((r) => r.title == title)
          .firstOrNull;
      if (row == null) {
        final created = AppMenuSubmenuRow(title: title)
          ..items.add(AppMenuCommandRow(command));
        rows.add(created);
      } else {
        row.items.add(AppMenuCommandRow(command));
      }
    }
  }
  return groups;
}

String _menuTitle(AppMenuId id, AppLocalizations l10n) => switch (id) {
  AppMenuId.app => l10n.appTitle,
  AppMenuId.file => l10n.menuFile,
  AppMenuId.edit => l10n.menuEdit,
  AppMenuId.view => l10n.menuView,
  AppMenuId.go => l10n.menuGo,
  AppMenuId.commands => l10n.menuCommands,
  AppMenuId.window => l10n.menuWindow,
  AppMenuId.help => l10n.menuHelp,
};
