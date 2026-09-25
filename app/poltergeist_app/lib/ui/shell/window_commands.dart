import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/registered_command.dart';
import '../../services/workspace_windows/workspace_windows.dart';

const kWindowNewCommandId = 'window.new';
const kWindowCloseCommandId = 'window.close';

/// 00 D38's File ▸ New Window and Close Window, for a shell that fills a
/// workspace window whose runner hosts more of them.
///
/// New Window opens the default workspace (a local home tab in each pane),
/// as the app does on a launch with nothing to restore, and makes it the
/// active window. Close Window takes the same path as the window's close
/// button: the last open window quits the app, through the quit guard.
/// ⌘W stays Close Tab (02 §8.3), so Close Window takes ⇧⌘W, the Mac
/// convention for apps whose ⌘W closes a tab.
List<RegisteredCommand> buildWindowCommands({required WorkspaceWindow window}) {
  return [
    RegisteredCommand(
      id: kWindowNewCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.windowNewLabel,
      icon: Icons.open_in_new,
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyN, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyN, control: true)],
      ),
      run: (_) => window.openWindow(),
      // Ahead of New Tab (order 10), in File's first group.
      menuPlacement: const CommandMenuPlacement(menu: AppMenuId.file, order: 5),
    ),
    RegisteredCommand(
      id: kWindowCloseCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.windowCloseLabel,
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyW, meta: true, shift: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true),
        ],
      ),
      run: (_) => window.close(),
      // After Close Tab (order 30), in its group.
      menuPlacement: const CommandMenuPlacement(
        menu: AppMenuId.file,
        order: 35,
        group: 5,
      ),
    ),
  ];
}

List<ShortcutActivator> Function(TargetPlatform) _perPlatform({
  required List<ShortcutActivator> macOS,
  required List<ShortcutActivator> other,
}) =>
    (platform) => platform == TargetPlatform.macOS ? macOS : other;
