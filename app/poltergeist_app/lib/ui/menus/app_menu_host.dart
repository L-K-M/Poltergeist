import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import 'app_menus.dart';

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
  });

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
      return PlatformMenuBar(
        menus: _syncedMenus(menus, l10n),
        child: widget.child,
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
        Expanded(child: widget.child),
      ],
    );
  }

  /// Serializes [menus] once per content change; a rebuild with an
  /// unchanged signature reuses the same item objects so the platform
  /// bar's `listEquals` check short-circuits the channel sync.
  List<PlatformMenuItem> _syncedMenus(
    List<AppMenuModel> menus,
    AppLocalizations l10n,
  ) {
    final signature = _signature(menus);
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
  List<Object?> _signature(List<AppMenuModel> menus) => [
    for (final menu in menus) ...[
      menu.id,
      menu.title,
      for (final group in menu.groups) ...[
        _rowBoundary,
        for (final row in group) ..._rowSignature(row),
      ],
    ],
  ];

  /// Positional marker inside a signature; identity-stable across builds.
  static const _rowBoundary = Object();

  Iterable<Object?> _rowSignature(AppMenuRow row) sync* {
    switch (row) {
      case AppMenuCommandRow(:final command):
        yield (command.id, command.enabled(), _nativeShortcut(command));
      case AppMenuSubmenuRow(:final title, :final items):
        yield _rowBoundary;
        yield title;
        for (final item in items) {
          yield* _rowSignature(item);
        }
      case AppMenuProvidedRow(:final type):
        yield type;
    }
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
            ? () => unawaited(widget.onRun(command))
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
  /// into this callback. When the field's handler is absent or disabled
  /// (a read-only field's Paste, say), the command runs as usual rather
  /// than the key equivalent being swallowed.
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
      final action = Actions.maybeFind(focusContext, intent: intent);
      if (action != null && action.isEnabled(intent)) {
        Actions.invoke(focusContext, intent);
        return;
      }
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
