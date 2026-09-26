import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import '../../services/workspace_windows/workspace_window_scope.dart';
import '../../services/workspace_windows/workspace_windows.dart'
    show WorkspaceWindow;
import '../panes/pane_commands.dart' show keyMayRunFrom;
import 'app_menus.dart';
import 'menu_shortcut_hint.dart';

/// Renders the application's menus from the command registry (07 §3.4).
///
/// On macOS the derived model is pushed to the native menu bar through
/// [PlatformMenuBar]; on Windows and Linux the same model renders as a
/// Flutter [MenuBar] strip above the content (02 §9).
///
/// The host owns no command behavior: labels, enablement, and shortcut
/// hints all come straight from each [RegisteredCommand], and activation
/// delegates to [onRun] — the same path the chord layer and toolbar take.
class AppMenuHost extends StatefulWidget {
  const AppMenuHost({
    super.key,
    required this.commands,
    required this.onRun,
    required this.child,
    this.showMenuBar = true,
  });

  /// Whether Windows/Linux render the Flutter [MenuBar] strip above
  /// [child]. D32's shell passes false and renders the same tree behind
  /// the header's ☰ [AppMainMenuButton] instead (10 §8) — no second
  /// chrome band. macOS always uses the native menu bar.
  final bool showMenuBar;

  /// The live registry snapshot from the shell.
  ///
  /// Contract: [commands] is consulted for enablement on every build, so
  /// the shell must rebuild this host whenever any command's
  /// [RegisteredCommand.enabled] result may have flipped — the workspace
  /// listenable that drives the toolbar does exactly that.
  final List<RegisteredCommand> commands;

  /// Runs a command; called on menu activation with the command itself.
  final Future<void> Function(RegisteredCommand command) onRun;

  /// The content under the menu bar.
  final Widget child;

  @override
  State<AppMenuHost> createState() => _AppMenuHostState();
}

class _AppMenuHostState extends State<AppMenuHost> {
  /// Cache for the macOS serialization: [PlatformMenuBar.didUpdateWidget]
  /// re-syncs the whole menu tree over the platform channel whenever the
  /// item objects differ, and the pane listenable rebuilds this host on
  /// every selection/filter notification — so identical menus must keep
  /// identical item objects to stay a no-op.
  List<Object?>? _menuSignature;
  Object? _menuRunner;
  List<PlatformMenuItem>? _platformMenus;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final l10n = AppLocalizations.of(context);
    final menus = buildAppMenus(
      commands: widget.commands,
      l10n: l10n,
      platform: platform,
    );

    if (platform == TargetPlatform.macOS) {
      final synced = _syncedMenus(menus, l10n);
      // With several windows the root renders the one native menu bar,
      // and the active window's items go there (00 D39).
      final window = WorkspaceWindowScope.maybeOf(context);
      final slot = window?.menuBar;
      if (slot == null) {
        return PlatformMenuBar(menus: synced, child: widget.child);
      }
      if (window!.active) _publish(slot, synced, window.window);
      return widget.child;
    }
    if (!widget.showMenuBar) return widget.child;

    return Column(
      children: [
        // MenuBar shrink-wraps its children (MainAxisSize.min); the menu
        // strip reads as a left-aligned bar, so pin it to the start edge.
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: MenuBar(
            children: [
              for (final menu in menus)
                SubmenuButton(
                  key: ValueKey('menu.${menu.id.name}'),
                  menuChildren: [
                    for (var i = 0; i < menu.groups.length; i++) ...[
                      if (i > 0) const _MenuGroupDivider(),
                      for (final row in menu.groups[i])
                        _anchorMenuRow(row, l10n, platform, widget.onRun),
                    ],
                  ],
                  child: Text(menu.title),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: widget.child),
      ],
    );
  }

  /// Hands [menus] to the root's menu bar after this frame (a slot change
  /// rebuilds the root, which must not happen mid-build). Unchanged menus
  /// keep their identity (see [_syncedMenus]), so this is then a no-op.
  void _publish(
    MenuBarSlot slot,
    List<PlatformMenuItem> menus,
    WorkspaceWindow window,
  ) {
    if (identical(slot.value, menus)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Still this window's turn, and still its latest items.
      if (!mounted || !window.isActive) return;
      if (!identical(_platformMenus, menus)) return;
      slot.value = menus;
    });
  }

  /// Serializes [menus] once per content change; a rebuild with an
  /// unchanged signature reuses the same item objects so the platform
  /// bar's `listEquals` check short-circuits the channel sync.
  List<PlatformMenuItem> _syncedMenus(
    List<AppMenuModel> menus,
    AppLocalizations l10n,
  ) {
    final signature = _signature(menus, l10n);
    final cached = _platformMenus;
    if (cached != null &&
        _menuRunner == widget.onRun &&
        listEquals(signature, _menuSignature)) {
      return cached;
    }
    final built = [for (final menu in menus) _platformMenu(menu, l10n)];
    _menuSignature = signature;
    _menuRunner = widget.onRun;
    _platformMenus = built;
    return built;
  }

  /// Everything a native menu item can carry — structure, titles, each
  /// command's enablement and bound key equivalent — flattened to scalars
  /// and records so [listEquals] can compare two builds field-by-field.
  List<Object?> _signature(List<AppMenuModel> menus, AppLocalizations l10n) => [
    for (final menu in menus) ...[
      menu.id,
      menu.title,
      for (final group in menu.groups) ...[
        _rowBoundary,
        for (final row in group) ..._rowSignature(row, l10n),
      ],
    ],
  ];

  /// Positional marker inside a signature; identity-stable across builds.
  static const _rowBoundary = Object();

  Iterable<Object?> _rowSignature(AppMenuRow row, AppLocalizations l10n) sync* {
    switch (row) {
      case AppMenuCommandRow(:final command):
        yield (
          command.id,
          command.label(l10n),
          command.enabled(),
          _nativeShortcut(command),
        );
      case AppMenuSubmenuRow(:final title, :final items):
        yield _rowBoundary;
        yield title;
        for (final item in items) {
          yield* _rowSignature(item, l10n);
        }
      case AppMenuProvidedRow(:final type):
        yield type;
    }
  }


  // -- PlatformMenuBar (macOS) ------------------------------------------

  PlatformMenu _platformMenu(AppMenuModel menu, AppLocalizations l10n) {
    return PlatformMenu(
      label: menu.title,
      menus: [
        for (final group in menu.groups)
          PlatformMenuItemGroup(
            members: [
              for (final row in group) _platformRow(row, l10n),
            ],
          ),
      ],
    );
  }

  PlatformMenuItem _platformRow(AppMenuRow row, AppLocalizations l10n) {
    return switch (row) {
      AppMenuCommandRow(:final command) => _platformCommand(command, l10n),
      AppMenuSubmenuRow(:final title, :final items) => PlatformMenu(
        label: title,
        menus: [
          PlatformMenuItemGroup(
            members: [
              for (final item in items)
                _platformCommand(item.command, l10n),
            ],
          ),
        ],
      ),
      AppMenuProvidedRow(:final type) => PlatformProvidedMenuItem(
        type: type,
      ),
    };
  }

  PlatformMenuItem _platformCommand(
    RegisteredCommand command,
    AppLocalizations l10n,
  ) {
    final shortcut = _nativeShortcut(command);
    return PlatformMenuItem(
      label: command.label(l10n),
      shortcut: shortcut,
      onSelected: command.enabled()
          ? () => _activateNative(command, shortcut)
          : null,
    );
  }

  /// The activator macOS binds natively as the item's key equivalent.
  ///
  /// A natively bound key equivalent intercepts the keystroke before any
  /// in-window surface sees it, so only *modified* chords may bind — an
  /// unmodified equivalent (Enter, Tab, a letter) would steal typing and
  /// focus navigation.
  MenuSerializableShortcut? _nativeShortcut(RegisteredCommand command) {
    for (final activator
        in command.activators?.call(TargetPlatform.macOS) ??
            const <ShortcutActivator>[]) {
      if (activator is SingleActivator) {
        if (!activator.meta && !activator.control && !activator.alt) {
          continue;
        }
        return activator;
      }
      if (activator is CharacterActivator) {
        if (!activator.meta && !activator.control && !activator.alt) {
          continue;
        }
        return activator;
      }
    }
    return null;
  }

  /// Runs a menu item activated natively (click or key equivalent).
  ///
  /// This is 02 §8.2/§9's Edit-menu selector retargeting expressed in
  /// Dart: a natively bound key equivalent reaches the menu before a
  /// focused text field sees the keystroke, so a chord that a text
  /// surface owns outright (⌘A/⌘C/⌘X/⌘V/⌘Z/⌘⇧Z/⌘⌫) re-dispatches the
  /// matching text intent to that field instead of running the command.
  /// No Swift side is needed — the macOS embedder turns menu selections
  /// into this callback. When the field's handler is absent or disabled
  /// (a read-only field's Paste, say), the command runs as usual rather
  /// than the key equivalent being swallowed.
  ///
  /// The embedder hands a key equivalent to the window first, so one
  /// reaches the menu only when nothing there took it (focus outside the
  /// shell's chord scope, say). The chord scope's focus rule still holds
  /// for it ([keyMayRunFrom]): ⌘⌫ must not trash a pane's selection from
  /// wherever focus happens to be. The key still being down is what tells
  /// a key equivalent from a click, and a click on the item runs as usual.
  void _activateNative(
    RegisteredCommand command,
    MenuSerializableShortcut? shortcut,
  ) {
    final intent = shortcut == null ? null : _textFieldIntent(shortcut);
    final focus = FocusManager.instance.primaryFocus;
    final focusContext = focus?.context;
    if (intent != null &&
        focusContext != null &&
        focusContext.findAncestorWidgetOfExactType<EditableText>() !=
            null) {
      final action = Actions.maybeFind(focusContext, intent: intent);
      if (action != null && action.isEnabled(intent)) {
        Actions.invoke(focusContext, intent);
        return;
      }
    }
    if (shortcut is SingleActivator &&
        HardwareKeyboard.instance.isLogicalKeyPressed(shortcut.trigger) &&
        !keyMayRunFrom(command, shortcut, focus)) {
      return;
    }
    unawaited(widget.onRun(command));
  }

  /// Maps a field-owned macOS chord to the intent a focused text field
  /// expects — the same intents the platform Edit verbs would carry.
  Intent? _textFieldIntent(MenuSerializableShortcut shortcut) {
    if (shortcut is! SingleActivator) return null;
    if (!shortcut.meta || shortcut.control || shortcut.alt) return null;
    const cause = SelectionChangedCause.keyboard;
    return switch ((shortcut.trigger, shortcut.shift)) {
      (LogicalKeyboardKey.keyA, false) => const SelectAllTextIntent(cause),
      (LogicalKeyboardKey.keyC, false) => CopySelectionTextIntent.copy,
      (LogicalKeyboardKey.keyX, false) =>
        const CopySelectionTextIntent.cut(cause),
      (LogicalKeyboardKey.keyV, false) => const PasteTextIntent(cause),
      (LogicalKeyboardKey.keyZ, false) => const UndoTextIntent(cause),
      (LogicalKeyboardKey.keyZ, true) => const RedoTextIntent(cause),
      (LogicalKeyboardKey.backspace, false) =>
        const DeleteToLineBreakIntent(forward: false),
      _ => null,
    };
  }
}

/// Divider between menu sections inside a [SubmenuButton] popup.
class _MenuGroupDivider extends StatelessWidget {
  const _MenuGroupDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 9, indent: 12, endIndent: 12);
  }
}

/// One registered-command row in a Flutter menu (the Windows/Linux
/// [MenuBar] and the D32 ☰ button share it): `menu.item.<id>` keys,
/// display-only shortcut hints ([MenuShortcutHint]), and activation
/// through [onRun].
Widget _anchorMenuRow(
  AppMenuRow row,
  AppLocalizations l10n,
  TargetPlatform platform,
  Future<void> Function(RegisteredCommand command) onRun,
) {
  return switch (row) {
    AppMenuCommandRow(:final command) =>
      command.checked == null
          ? MenuItemButton(
              key: ValueKey('menu.item.${command.id}'),
              trailingIcon: MenuShortcutHint.forCommand(command, platform),
              onPressed: command.enabled()
                  ? () => unawaited(onRun(command))
                  : null,
              child: Text(command.label(l10n)),
            )
          // CheckboxMenuButton forwards its key to the MenuItemButton it
          // builds, which would put `menu.item.<id>` on two widgets; the
          // subtree carries it once, like the plain rows.
          : KeyedSubtree(
              key: ValueKey('menu.item.${command.id}'),
              child: CheckboxMenuButton(
                trailingIcon: MenuShortcutHint.forCommand(command, platform),
                value: command.checked!(),
                onChanged: command.enabled()
                    ? (_) => unawaited(onRun(command))
                    : null,
                child: Text(command.label(l10n)),
              ),
            ),
    AppMenuSubmenuRow(:final title, :final items) => SubmenuButton(
      menuChildren: [
        for (final item in items) _anchorMenuRow(item, l10n, platform, onRun),
      ],
      child: Text(title),
    ),
    // Provided rows are macOS chrome; the model never emits them on
    // other platforms.
    AppMenuProvidedRow() => const SizedBox.shrink(),
  };
}

/// D32's Windows/Linux main menu (10 §8): the whole registry-derived
/// menu tree behind one header button — the GNOME/Windows 11 convention
/// — instead of a menu-bar band. Each top-level menu is a submenu keyed
/// `menu.<id>`, its rows keyed `menu.item.<id>` exactly as the strip's.
class AppMainMenuButton extends StatelessWidget {
  const AppMainMenuButton({
    super.key,
    required this.commands,
    required this.onRun,
  });

  final List<RegisteredCommand> commands;
  final Future<void> Function(RegisteredCommand command) onRun;

  /// The panel's floor width, and how far it is pulled back from the
  /// button's trailing edge: a panel this wide ends where the button does.
  static const double _panelWidth = 160;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final l10n = AppLocalizations.of(context);
    final menus = buildAppMenus(
      commands: commands,
      l10n: l10n,
      platform: platform,
    );
    return MenuAnchor(
      // Hung from the button's trailing edge, so the panel keeps the
      // header's end inset. Opened from the leading edge it overflowed
      // the window, and MenuAnchor pushes an overflowing panel back only
      // as far as the overlay's very edge (reservedPadding bounds its
      // size, not its position; OverlayPortal swaps in the Overlay's own
      // MediaQuery padding, so no inset can be injected around the
      // anchor): flush with the window, its rounded corner cut off.
      alignmentOffset: const Offset(-_panelWidth, 0),
      // The floor must reach the panel itself, not only the box around it,
      // and at its stated width: desktop's compact density would take 8 px
      // off it, leaving the panel short of the button's edge.
      crossAxisUnconstrained: false,
      style: const MenuStyle(
        alignment: AlignmentDirectional.bottomEnd,
        minimumSize: WidgetStatePropertyAll(Size(_panelWidth, 0)),
        visualDensity: VisualDensity.standard,
      ),
      menuChildren: [
        for (final menu in menus)
          SubmenuButton(
            key: ValueKey('menu.${menu.id.name}'),
            menuChildren: [
              for (var i = 0; i < menu.groups.length; i++) ...[
                if (i > 0) const _MenuGroupDivider(),
                for (final row in menu.groups[i])
                  _anchorMenuRow(row, l10n, platform, onRun),
              ],
            ],
            child: Text(menu.title),
          ),
      ],
      builder: (context, controller, _) => IconButton(
        key: const ValueKey('menu.main'),
        tooltip: l10n.mainMenuTooltip,
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.menu),
      ),
    );
  }
}
