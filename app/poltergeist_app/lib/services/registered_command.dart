import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

/// Which surface a command acts on (02 §8.1).
enum CommandScope { app, pane, selection, editor }

/// The app's top-level menus (10 §8's table, in menu-bar order). `app` is
/// the macOS application menu — commands reach it only through
/// [CommandMenuPlacement.appMenuOnMac], never by naming it directly.
/// `server` is D32's rename of 02 §9's "Commands" menu.
enum AppMenuId { app, file, edit, view, go, server, window, help }

/// Where a command sits in the D32 header toolbar (10 §4). Commands
/// without one never render there — the toolbar is a curated rendering
/// of the registry, not the registry itself (D21 holds: every control
/// is still a registered command).
enum ToolbarSlot {
  /// Before the title: sidebar toggle, back/forward.
  leading,

  /// The everyday file verbs (New Folder, Trash, Copy to Other Pane).
  actions,

  /// Labelled primary actions (Sync, Connect).
  primary,

  /// Status toggles (activity, inspector).
  status,
}

class CommandToolbarPlacement {
  const CommandToolbarPlacement({
    required this.slot,
    required this.order,
    this.labelled = false,
    this.group = 0,
  });

  final ToolbarSlot slot;

  /// Ascending within the slot.
  final int order;

  /// Whether the button shows its label beside the icon at full width
  /// (primary actions); icon-only buttons still carry a tooltip.
  final bool labelled;

  /// Buttons sharing a group inside a slot render in one capsule.
  final int group;
}

/// A command's position inside a top-level menu, declared at registration
/// (D21: menus are a rendering of the registry, never a parallel list).
///
/// [order] slots follow 02 §9's table positions with gaps between them so
/// a command that lands later keeps a stable placement without
/// renumbering its neighbours. [group] splits one menu into
/// divider-separated sections — rows with different group values are
/// separated by a divider on both menu backends. [submenu] names a 02 §9
/// ▸ submenu (Sort By, Open With, Recent) the command joins as a
/// MEMBER; a command that IS the parameterized submenu carries
/// [RegisteredCommand.submenuItems] instead.
class CommandMenuPlacement {
  const CommandMenuPlacement({
    required this.menu,
    required this.order,
    this.group = 0,
    this.submenu,
    this.appMenuOnMac = false,
  });

  final AppMenuId menu;

  /// On macOS the command moves into the application menu instead of
  /// [menu] (Settings…, About, Check for Updates — the AppKit
  /// convention); every other platform keeps [menu]. The same [order]
  /// and [group] apply inside the app menu.
  final bool appMenuOnMac;

  /// The 02 §9 table slot; ascending within a group.
  final int order;

  /// Divider-separated section inside the menu; ascending across groups.
  final int group;

  /// The ▸ submenu this item nests under, localized like the label.
  final String Function(AppLocalizations)? submenu;
}

/// The §8.1 keyboard-completeness invariant's documented exceptions:
/// command ids that ship with neither a menu path nor a platform
/// shortcut, keyed to their reason. Empty today — every registered
/// command is menu- or shortcut-reachable on every platform. An entry
/// must name why the command is exempt; the invariant test fails on an
/// undocumented or unregistered id.
const Map<String, String> kMenuReachabilityExceptions = {};

/// One registered user action (D21: every user action is a registered
/// command; menus, shortcuts, and toolbar buttons are renderings of the
/// registry).
///
/// The 02 §8.1 command model: id, scope, an ARB label, enablement, an
/// optional per-platform shortcut, menu and toolbar placements, and the
/// run action with its invoking [BuildContext] resolved at invocation
/// time, never captured. Menus, the D32 header toolbar, context menus,
/// and the Quick Open palette are all renderings of these rows.
class RegisteredCommand {
  // Not const: the initializer assert reads a function-typed field,
  // which is not a potentially-constant expression.
  RegisteredCommand({
    required this.id,
    required this.scope,
    required this.label,
    this.icon,
    this.enabled = _alwaysEnabled,
    this.disabledReason,
    required this.run,
    this.activators,
    this.menuPlacement,
    this.submenuItems,
    this.toolbarPlacement,
    this.checked,
    this.tooltip,
    this.shortLabel,
  }) : assert(
         submenuItems == null || menuPlacement?.submenu == null,
         'A parameterized command must not also join a merged submenu '
         'via menuPlacement.submenu.',
       );

  /// Dotted lowerCamel, grouped by noun (`connect.*`, `pane.*`, 02 §8.1).
  final String id;

  final CommandScope scope;

  /// The ARB-sourced label (D20); commands carry no hard-coded copy.
  final String Function(AppLocalizations) label;

  /// The icon the toolbar, context menus, and palette render for this
  /// command. A command with a [toolbarPlacement] must carry one.
  final IconData? icon;

  final bool Function() enabled;

  static bool _alwaysEnabled() => true;

  /// Why the command is unavailable while [enabled] is false (02 §8.4:
  /// the palette shows the reason under a disabled row). Null means no
  /// spelled-out reason — the row renders dimmed with no subtitle.
  final String Function(AppLocalizations l10n)? disabledReason;

  /// Per-platform shortcut chords; null when the command has none.
  /// The returned list is freshly built (or const) per call and must be
  /// treated as immutable — callers copy before mutating.
  final List<ShortcutActivator> Function(TargetPlatform)? activators;

  /// Where this command appears in the app menus (02 §9). Null leaves it
  /// shortcut/palette-only — allowed only while §8.1's menu-or-shortcut
  /// invariant still holds for it (a chord exists, or the id sits in
  /// [kMenuReachabilityExceptions]).
  final CommandMenuPlacement? menuPlacement;

  /// The parameterized-command shape (02 §8.1's `file.openWith` /
  /// `view.sortBy` / `go.recent` family): when set, this command's menu
  /// slot renders as a ▸ submenu whose rows are parameter-bound
  /// invocations built fresh per menu render — the item commands carry
  /// their parameter inside `run`, never take a menuPlacement of their
  /// own, and are never themselves registered (the parent command owns
  /// the registry id).
  final List<RegisteredCommand> Function(AppLocalizations l10n)?
  submenuItems;

  /// Where the D32 header toolbar renders this command; null keeps it
  /// out of the toolbar (menus, chords, palette, and context menus only).
  final CommandToolbarPlacement? toolbarPlacement;

  /// Toggle state for view toggles (Show/Hide Sidebar, Inspector): menus
  /// render a checkmark where the platform supports one, and toolbar
  /// buttons render selected. Null means the command is not a toggle.
  final bool Function()? checked;

  /// The toolbar tooltip when it should differ from [label] (a toggle's
  /// "Show Inspector" vs its menu label); null uses [label].
  final String Function(AppLocalizations)? tooltip;

  /// The compact label a labelled toolbar button shows ("Sync" for
  /// "Synchronize Panes…"); null uses [label].
  final String Function(AppLocalizations)? shortLabel;

  /// Executes the command with the invoking surface's [context].
  /// Implementations must not capture [context] and must re-check
  /// `context.mounted` after any `await` before using it again.
  final Future<void> Function(BuildContext context) run;
}
