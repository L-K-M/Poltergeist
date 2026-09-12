import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/pane_controller.dart';
import '../../services/registered_command.dart';
import '../../services/workspace_controller.dart';

const kGoEnclosingCommandId = 'go.enclosing';
const kGoOpenCommandId = 'go.open';
const kViewRefreshCommandId = 'view.refresh';
const kPaneFocusLeftCommandId = 'pane.focusLeft';
const kPaneFocusRightCommandId = 'pane.focusRight';
const kPaneSwapFocusCommandId = 'pane.swapFocus';

/// The pane-command registry slice (D21): every pane action this
/// foundation ships is a registered command. Commands resolve the
/// workspace's ACTIVE pane at invocation time — never a captured one
/// (02 §8.1's CommandContext rule, foundation form).
List<RegisteredCommand> buildPaneCommands({
  required WorkspaceController workspace,
  required VoidCallback focusLeft,
  required VoidCallback focusRight,
  required VoidCallback swapFocus,
}) {
  PaneController? activePane() => workspace.activePane;

  return [
    RegisteredCommand(
      id: kGoEnclosingCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.goEnclosingLabel,
      icon: Icons.arrow_upward_outlined,
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.arrowUp, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.arrowUp, alt: true)],
      ),
      enabled: () => activePane()?.verbsEnabled ?? false,
      run: (_) async {
        activePane()?.goUp();
      },
    ),
    RegisteredCommand(
      id: kGoOpenCommandId,
      scope: CommandScope.selection,
      label: (l10n) => l10n.goOpenLabel,
      icon: Icons.subdirectory_arrow_right_outlined,
      // Enter (Windows/Linux) and ⌘↓/⌘O (macOS) are the §8.3 bindings.
      // The unmodified Enter leg is dispatched by the pane's focus node
      // (02 §8.2 scopes single keys there), never by the chord layer.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.arrowDown, meta: true),
          SingleActivator(LogicalKeyboardKey.keyO, meta: true),
        ],
        other: const [SingleActivator(LogicalKeyboardKey.enter)],
      ),
      enabled: () {
        final pane = activePane();
        final cursor = pane?.cursorIndex;
        return pane != null &&
            pane.verbsEnabled &&
            cursor != null &&
            cursor >= 0 &&
            cursor < pane.entries.length;
      },
      run: (_) async {
        final pane = activePane();
        final cursor = pane?.cursorIndex;
        if (pane == null ||
            cursor == null ||
            cursor < 0 ||
            cursor >= pane.entries.length) {
          return;
        }
        pane.openEntry(pane.entries[cursor]);
      },
    ),
    RegisteredCommand(
      id: kViewRefreshCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.viewRefreshLabel,
      icon: Icons.refresh,
      // Dual macOS/Ctrl registration per 09 §3: meta on macOS, control
      // everywhere else.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyR, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyR, control: true)],
      ),
      enabled: () => activePane()?.phase == PanePhase.browsing,
      run: (_) async {
        activePane()?.refresh();
      },
    ),
    RegisteredCommand(
      id: kPaneFocusLeftCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.paneFocusLeftLabel,
      icon: Icons.west_outlined,
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.arrowLeft, meta: true, alt: true),
        ],
        other: const [
          // The 02 §8.3 spec chord; note Ctrl+Alt+arrows is OS-reserved on
          // some desktops (Intel display rotation on Windows, virtual-
          // desktop switching on KDE/X11) — delivery needs verification on
          // target desktops and the settings slice must allow rebinding.
          // TODO(rebinding): until the settings slice lands, users on
          // affected desktops have no working focus chord — verify
          // delivery on release targets or add a non-reserved secondary
          // default activator before shipping.
          SingleActivator(
            LogicalKeyboardKey.arrowLeft,
            control: true,
            alt: true,
          ),
        ],
      ),
      run: (_) async {
        focusLeft();
      },
    ),
    RegisteredCommand(
      id: kPaneFocusRightCommandId,
      scope: CommandScope.app,
      label: (l10n) => l10n.paneFocusRightLabel,
      icon: Icons.east_outlined,
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.arrowRight, meta: true, alt: true),
        ],
        other: const [
          // Same OS-reservation note as pane.focusLeft above.
          SingleActivator(
            LogicalKeyboardKey.arrowRight,
            control: true,
            alt: true,
          ),
        ],
      ),
      run: (_) async {
        focusRight();
      },
    ),
    RegisteredCommand(
      id: kPaneSwapFocusCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.paneSwapFocusLabel,
      // Plain Tab only while a listing holds focus (02 §8.2): the pane's
      // focus node dispatches it, not a global chord.
      activators: (_) => const [SingleActivator(LogicalKeyboardKey.tab)],
      run: (_) async {
        swapFocus();
      },
    ),
  ];
}

List<ShortcutActivator> Function(TargetPlatform) _perPlatform({
  required List<ShortcutActivator> macOS,
  required List<ShortcutActivator> other,
}) {
  return (platform) => platform == TargetPlatform.macOS ? macOS : other;
}

/// Dispatches modified command chords for the shell (02 §8.3's table).
/// A registered chord is owned by the command layer relative to scopes
/// FARTHER from focus — including a disabled command's chord, which is
/// consumed without falling through to outer scopes (standard Flutter
/// focus precedence still lets a nearer surface take a chord first) —
/// locked in by test.
/// Single keys with no ctrl/meta/alt modifier — including shift-only
/// combos like Shift+Tab — are deliberately excluded; they belong to the
/// pane focus nodes (02 §8.2), so this layer can never fire Enter or Tab
/// globally. This slice's shell contains no text surfaces; dialog routes
/// push above the shell, so their fields never see these chords. The
/// path-editor slice adds the explicit field-first guard with its test.
class CommandChordScope extends StatelessWidget {
  const CommandChordScope({
    super.key,
    required this.commands,
    required this.child,
  });

  final List<RegisteredCommand> commands;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final bindings = <ShortcutActivator, VoidCallback>{};
    for (final command in commands) {
      final activators = command.activators?.call(platform);
      if (activators == null) continue;
      for (final activator in activators) {
        // Two commands claiming one chord is a registration bug; debug
        // builds fail it immediately (release keeps later-command-wins,
        // the documented fallback).
        assert(
          !bindings.containsKey(activator),
          'Duplicate shortcut activator $activator: later command wins',
        );
        // Unmodified keys — any activator type — stay with the pane focus
        // nodes (02 §8.2), not only SingleActivator spellings.
        final bool unmodified = activator is SingleActivator
            ? !activator.control && !activator.meta && !activator.alt
            : activator is CharacterActivator &&
                  !activator.control &&
                  !activator.meta &&
                  !activator.alt;
        if (unmodified) {
          continue;
        }
        bindings[activator] = () {
          if (!command.enabled()) return;
          command.run(context);
        };
      }
    }

    return CallbackShortcuts(bindings: bindings, child: child);
  }
}
