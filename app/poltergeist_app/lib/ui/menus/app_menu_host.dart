import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import 'app_menus.dart';

/// Renders the application's menus from the command registry (07 §3.4).
///
/// On macOS the derived model is pushed to the native menu bar through
/// [PlatformMenuBar]; on Windows and Linux the same model renders as a
/// Flutter [MenuBar] strip above [child] (02 §9).
///
/// The host owns no command behavior: labels, enablement, and shortcut
/// hints all come straight from each [RegisteredCommand], and activation
/// delegates to [onRun] — the same path the chord layer and toolbar take.
class AppMenuHost extends StatelessWidget {
  const AppMenuHost({
    super.key,
    required this.commands,
    required this.onRun,
    required this.child,
  });

  /// The live registry snapshot from the shell.
  final List<RegisteredCommand> commands;

  /// Runs a command; called on menu activation with the command itself.
  final Future<void> Function(RegisteredCommand command) onRun;

  /// The content under the menu bar.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final l10n = AppLocalizations.of(context);
    final menus = buildAppMenus(
      commands: commands,
      l10n: l10n,
      platform: platform,
    );

    if (platform == TargetPlatform.macOS) {
      return PlatformMenuBar(
        menus: [for (final menu in menus) _platformMenu(menu, l10n)],
        child: child,
      );
    }

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
                        _anchorRow(row, l10n, platform),
                    ],
                  ],
                  child: Text(menu.title),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: child),
      ],
    );
  }

  // -- MenuBar (Windows/Linux) -----------------------------------------

  Widget _anchorRow(
    AppMenuRow row,
    AppLocalizations l10n,
    TargetPlatform platform,
  ) {
    return switch (row) {
      AppMenuCommandRow(:final command) => MenuItemButton(
        key: ValueKey('menu.item.${command.id}'),
        shortcut: _displayShortcut(command, platform),
        onPressed: command.enabled()
            ? () => unawaited(onRun(command))
            : null,
        child: Text(command.label(l10n)),
      ),
      AppMenuSubmenuRow(:final title, :final items) => SubmenuButton(
        menuChildren: [
          for (final item in items) _anchorRow(item, l10n, platform),
        ],
        child: Text(title),
      ),
      // Provided rows are macOS chrome; the model never emits them on
      // other platforms.
      AppMenuProvidedRow() => const SizedBox.shrink(),
    };
  }

  /// The first registered activator, for the displayed shortcut hint.
  ///
  /// [MenuItemButton.shortcut] is display-only: actual dispatch stays in
  /// the app's chord layer, so the hint and the binding can never drift.
  MenuSerializableShortcut? _displayShortcut(
    RegisteredCommand command,
    TargetPlatform platform,
  ) {
    final activators = command.activators?.call(platform);
    if (activators == null || activators.isEmpty) return null;
    final first = activators.first;
    return first is MenuSerializableShortcut ? first : null;
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
  /// into this callback.
  void _activateNative(
    RegisteredCommand command,
    MenuSerializableShortcut? shortcut,
  ) {
    final intent = shortcut == null ? null : _textFieldIntent(shortcut);
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (intent != null &&
        focusContext != null &&
        focusContext.findAncestorWidgetOfExactType<EditableText>() !=
            null) {
      Actions.maybeInvoke(focusContext, intent);
      return;
    }
    unawaited(onRun(command));
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
