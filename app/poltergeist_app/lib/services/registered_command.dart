import 'package:flutter/widgets.dart';

import '../l10n/app_localizations.dart';

/// Which surface a command acts on (02 §8.1).
enum CommandScope { app, pane, selection, editor }

/// The app's top-level menus (02 §9's table, in menu-bar order). `app` is
/// the macOS application menu — platform chrome the registry renders on
/// macOS only; no command ever places into it.
enum AppMenuId { app, file, edit, view, go, commands, window, help }

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
  });

  final AppMenuId menu;

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
/// This is the M2 debug subset of the 02 §8.1 command model: id, scope,
/// an ARB label, enablement, an optional per-platform shortcut, and the
/// run action with its invoking [BuildContext] resolved at invocation
/// time, never captured. The M3 command registry adds CommandContext
/// resolution, menu/palette renderings, and the keyboard-completeness
/// invariant, and replaces this shape together with the debug-only
/// surface that consumes it.
class RegisteredCommand {
  // Not const: the initializer assert reads a function-typed field,
  // which is not a potentially-constant expression.
  RegisteredCommand({
    required this.id,
    required this.scope,
    required this.label,
    this.icon,
    this.enabled = _alwaysEnabled,
    required this.run,
    this.activators,
    this.menuPlacement,
    this.submenuItems,
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

  /// The Material icon the toolbar renders for this command. Null keeps
  /// the M2 debug surface's bug icon; M3's registry replaces these
  /// per-command renderings.
  final IconData? icon;

  final bool Function() enabled;

  static bool _alwaysEnabled() => true;

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

  /// Executes the command with the invoking surface's [context].
  /// Implementations must not capture [context] and must re-check
  /// `context.mounted` after any `await` before using it again.
  final Future<void> Function(BuildContext context) run;
}
