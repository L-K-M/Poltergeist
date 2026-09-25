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
  AppMenuSubmenuRow({required this.title, required List<AppMenuCommandRow> items})
    : items = List.unmodifiable(items);

  final String title;
  final List<AppMenuCommandRow> items;
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
  final mac = platform == TargetPlatform.macOS;
  final placed = <AppMenuId, List<RegisteredCommand>>{};
  final appMenu = <RegisteredCommand>[];
  for (final command in commands) {
    final placement = command.menuPlacement;
    if (placement == null) continue;
    assert(
      placement.menu != AppMenuId.app,
      'commands reach the macOS application menu via appMenuOnMac',
    );
    if (mac && placement.appMenuOnMac) {
      appMenu.add(command);
      continue;
    }
    placed.putIfAbsent(placement.menu, () => []).add(command);
  }

  final menus = <AppMenuModel>[
    if (mac) _macAppMenu(l10n, _menuGroups(appMenu, l10n)),
  ];

  for (final id in AppMenuId.values) {
    if (id == AppMenuId.app) continue;
    var groups = _menuGroups(placed[id] ?? const [], l10n);
    if (mac && id == AppMenuId.view) {
      // AppKit's own Enter/Exit Full Screen item (⌃⌘F), last in View as
      // every Mac app places it.
      groups = [
        ...groups,
        const [
          AppMenuProvidedRow(PlatformProvidedMenuItemType.toggleFullScreen),
        ],
      ];
    }
    if (mac && id == AppMenuId.window) {
      groups = [
        const [
          AppMenuProvidedRow(PlatformProvidedMenuItemType.minimizeWindow),
          AppMenuProvidedRow(PlatformProvidedMenuItemType.zoomWindow),
        ],
        ...groups,
        const [
          AppMenuProvidedRow(
            PlatformProvidedMenuItemType.arrangeWindowsInFront,
          ),
        ],
      ];
    }
    if (groups.isEmpty) continue;
    menus.add(
      AppMenuModel(id: id, title: _menuTitle(id, l10n), groups: groups),
    );
  }
  return menus;
}

/// The macOS application menu (10 §8): About, then the commands that
/// declare [CommandMenuPlacement.appMenuOnMac] (Check for Updates…,
/// Settings…), then Services, the hide trio, and Quit — AppKit's order.
/// Quit is AppKit's own row here; Linux and Windows get a registered
/// Quit command at the end of File instead (`app_menu_commands.dart`).
AppMenuModel _macAppMenu(
  AppLocalizations l10n,
  List<List<AppMenuRow>> commandGroups,
) => AppMenuModel(
  id: AppMenuId.app,
  title: l10n.appTitle,
  groups: [
    const [AppMenuProvidedRow(PlatformProvidedMenuItemType.about)],
    ...commandGroups,
    const [AppMenuProvidedRow(PlatformProvidedMenuItemType.servicesSubmenu)],
    const [
      AppMenuProvidedRow(PlatformProvidedMenuItemType.hide),
      AppMenuProvidedRow(PlatformProvidedMenuItemType.hideOtherApplications),
      AppMenuProvidedRow(PlatformProvidedMenuItemType.showAllApplications),
    ],
    const [AppMenuProvidedRow(PlatformProvidedMenuItemType.quit)],
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

  // Per divider-separated section: `ordered` keeps each row's
  // first-occurrence position (a command, an AppMenuSubmenuRow built
  // from a parameterized command's own items, or a submenu title for
  // merged submenu rows whose members buffer in `submenuItems`).
  final groups = <List<AppMenuRow>>[];
  int? group;
  List<Object>? ordered;
  Map<String, List<AppMenuCommandRow>>? submenuItems;

  void flush() {
    final entries = ordered;
    final submenus = submenuItems;
    if (entries == null || submenus == null) return;
    groups.add([
      for (final entry in entries)
        switch (entry) {
          String() => AppMenuSubmenuRow(
            title: entry,
            items: submenus[entry]!,
          ),
          AppMenuSubmenuRow() => entry,
          _ => AppMenuCommandRow(entry as RegisteredCommand),
        },
    ]);
  }

  for (final command in sorted) {
    final placement = command.menuPlacement!;
    if (placement.group != group) {
      flush();
      group = placement.group;
      ordered = [];
      submenuItems = {};
    }
    final submenu = placement.submenu;
    final items = command.submenuItems;
    if (items != null) {
      // A parameterized command renders its own ▸ submenu at its slot:
      // the row's items are the parameter-bound invocations, built at
      // render time so they track the live selection/registry.
      ordered!.add(
        AppMenuSubmenuRow(
          title: command.label(l10n),
          items: [
            for (final item in items(l10n)) AppMenuCommandRow(item),
          ],
        ),
      );
    } else if (submenu == null) {
      ordered!.add(command);
    } else {
      final title = submenu(l10n);
      submenuItems!
          .putIfAbsent(title, () {
            ordered!.add(title);
            return [];
          })
          .add(AppMenuCommandRow(command));
    }
  }
  flush();
  return groups;
}

/// The localized title of one top-level menu — the palette prints it
/// in a command row's "File ▸ Open" path line (02 §8.4).
String appMenuTitle(AppMenuId id, AppLocalizations l10n) =>
    _menuTitle(id, l10n);

String _menuTitle(AppMenuId id, AppLocalizations l10n) => switch (id) {
  AppMenuId.app => l10n.appTitle,
  AppMenuId.file => l10n.menuFile,
  AppMenuId.edit => l10n.menuEdit,
  AppMenuId.view => l10n.menuView,
  AppMenuId.go => l10n.menuGo,
  AppMenuId.server => l10n.menuServer,
  AppMenuId.window => l10n.menuWindow,
  AppMenuId.help => l10n.menuHelp,
};
