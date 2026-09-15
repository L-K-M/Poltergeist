import 'package:flutter/material.dart';

import 'dart:async';
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
const kEditSelectAllCommandId = 'edit.selectAll';
const kEditInvertSelectionCommandId = 'edit.invertSelection';
const kSelectionQuickSelectCommandId = 'selection.quickSelect';
const kViewFilterCommandId = 'view.filter';
const kTabNewCommandId = 'tab.new';
const kTabCloseCommandId = 'tab.close';
const kTabReopenClosedCommandId = 'tab.reopenClosed';
const kTabNextCommandId = 'tab.next';
const kTabPreviousCommandId = 'tab.previous';

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
  // Browsing commands resolve the active pane's ACTIVE TAB at invocation
  // time (02 §8.1) — null while the pane sits on the launcher, and every
  // enabled getter below treats null as disabled. Tab commands act on
  // the strip itself.
  PaneController? activeTab() => workspace.activeTabController;

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
      enabled: () => activeTab()?.verbsEnabled ?? false,
      run: (_) async {
        activeTab()?.goUp();
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
        final pane = activeTab();
        final cursor = pane?.cursorIndex;
        return pane != null &&
            pane.verbsEnabled &&
            cursor != null &&
            cursor >= 0 &&
            cursor < pane.entries.length;
      },
      run: (_) async {
        final pane = activeTab();
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
      enabled: () {
        final pane = activeTab();
        return pane != null &&
            pane.phase == PanePhase.browsing &&
            !pane.connectionLost;
      },
      run: (_) async {
        activeTab()?.refresh();
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
          // desktop switching on KDE/X11) — the secondary Ctrl+PageUp
          // below is never reserved, so focus works on stock installs;
          // delivery still needs verification and the settings slice
          // must allow rebinding.
          SingleActivator(
            LogicalKeyboardKey.arrowLeft,
            control: true,
            alt: true,
          ),
          SingleActivator(LogicalKeyboardKey.pageUp, control: true),
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
          // Same OS-reservation note as pane.focusLeft above; the
          // Ctrl+PageDown secondary mirrors it.
          SingleActivator(
            LogicalKeyboardKey.arrowRight,
            control: true,
            alt: true,
          ),
          SingleActivator(LogicalKeyboardKey.pageDown, control: true),
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
    RegisteredCommand(
      id: kEditSelectAllCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.editSelectAllLabel,
      icon: Icons.select_all,
      // ⌘A / Ctrl+A (02 §8.3's table), dual macOS/Ctrl registration.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyA, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyA, control: true)],
      ),
      enabled: () => activeTab()?.verbsEnabled ?? false,
      run: (_) async {
        activeTab()?.selectAll();
      },
    ),
    RegisteredCommand(
      id: kEditInvertSelectionCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.editInvertSelectionLabel,
      icon: Icons.flip,
      // ⇧⌘I / Ctrl+Shift+I (02 §8.3's table).
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyI, meta: true, shift: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyI, control: true, shift: true),
        ],
      ),
      enabled: () => activeTab()?.verbsEnabled ?? false,
      run: (_) async {
        activeTab()?.invertSelection();
      },
    ),
    RegisteredCommand(
      id: kSelectionQuickSelectCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.selectionQuickSelectLabel,
      icon: Icons.manage_search_outlined,
      // ⌘E / Ctrl+E (02 §8.3's table), dual macOS/Ctrl registration.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyE, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyE, control: true)],
      ),
      enabled: () => activeTab()?.verbsEnabled ?? false,
      run: (_) async {
        activeTab()?.openQuickSelect();
      },
    ),
    RegisteredCommand(
      id: kViewFilterCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.viewFilterLabel,
      icon: Icons.filter_list_outlined,
      // ⌘F / Ctrl+F (02 §8.3's table), dual macOS/Ctrl registration.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyF, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyF, control: true)],
      ),
      enabled: () => activeTab()?.verbsEnabled ?? false,
      run: (_) async {
        activeTab()?.openFilter();
      },
    ),
    RegisteredCommand(
      id: kTabNewCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.tabNewLabel,
      icon: Icons.add,
      // ⌘T / Ctrl+T (02 §8.3's table), dual macOS/Ctrl registration.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyT, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyT, control: true)],
      ),
      // Always live — a launcher pane takes a new tab too.
      run: (_) async {
        workspace.activePane.newTab();
      },
    ),
    RegisteredCommand(
      id: kTabCloseCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.tabCloseLabel,
      icon: Icons.close,
      // ⌘W / Ctrl+W (02 §8.3's table), dual macOS/Ctrl registration.
      activators: _perPlatform(
        macOS: const [SingleActivator(LogicalKeyboardKey.keyW, meta: true)],
        other: const [SingleActivator(LogicalKeyboardKey.keyW, control: true)],
      ),
      enabled: () => workspace.activePane.activeTab != null,
      run: (_) async {
        // THE close operation: the guard and confirm live inside it, so
        // this chord and middle-click can never bypass them (02 §3).
        final strip = workspace.activePane;
        final tab = strip.activeTab;
        if (tab != null) await strip.requestCloseTab(tab);
      },
    ),
    RegisteredCommand(
      id: kTabReopenClosedCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.tabReopenClosedLabel,
      icon: Icons.restart_alt_outlined,
      // ⇧⌘T / Ctrl+Shift+T (02 §8.3's table), dual registration.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.keyT, meta: true, shift: true),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true),
        ],
      ),
      enabled: () => workspace.activePane.canReopen,
      run: (_) async {
        await workspace.activePane.reopenClosedTab();
      },
    ),
    RegisteredCommand(
      id: kTabNextCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.tabNextLabel,
      icon: Icons.tab_outlined,
      // ⌃⇥ on every platform; ⇧⌘] is the additional macOS binding (02
      // §8.3). Cycling is pane-scoped: it never crosses into the other
      // pane's strip.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.tab, control: true),
          SingleActivator(
            LogicalKeyboardKey.bracketRight,
            meta: true,
            shift: true,
          ),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.tab, control: true),
        ],
      ),
      enabled: () => workspace.activePane.tabs.length >= 2,
      run: (_) async {
        workspace.activePane.activateNextTab();
      },
    ),
    RegisteredCommand(
      id: kTabPreviousCommandId,
      scope: CommandScope.pane,
      label: (l10n) => l10n.tabPreviousLabel,
      icon: Icons.tab_outlined,
      // ⌃⇧⇥ on every platform; ⇧⌘[ is the additional macOS binding.
      activators: _perPlatform(
        macOS: const [
          SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true),
          SingleActivator(
            LogicalKeyboardKey.bracketLeft,
            meta: true,
            shift: true,
          ),
        ],
        other: const [
          SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true),
        ],
      ),
      enabled: () => workspace.activePane.tabs.length >= 2,
      run: (_) async {
        workspace.activePane.activatePreviousTab();
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
/// globally.
///
/// 02 §8.2's field-first precedence: while any text surface (an
/// [EditableText] — the Quick Select field today, the path editor and
/// filter later) holds primary focus, NO chord fires here at all — not
/// even a disabled command's — and the event keeps propagating to the
/// field's own editing shortcuts (⌘A/⌘C/⌘V/⌘X/⌘Z and their Ctrl
/// equivalents live at app scope, which this layer would otherwise
/// intercept first). Dialog routes push above the shell, so their
/// fields never see these chords either.
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
        // Unmodified keys — any activator type — stay with the pane focus
        // nodes (02 §8.2), not only SingleActivator spellings; skip them
        // BEFORE the duplicate diagnostics so an unmodified overlap is
        // not misreported as a chord collision.
        final bool unmodified = activator is SingleActivator
            ? !activator.control && !activator.meta && !activator.alt
            : activator is CharacterActivator &&
                  !activator.control &&
                  !activator.meta &&
                  !activator.alt;
        if (unmodified) {
          continue;
        }
        // Two commands claiming one chord is a registration bug; debug
        // builds fail it immediately (release keeps later-command-wins,
        // the documented fallback).
        assert(
          !bindings.containsKey(activator),
          'Duplicate shortcut activator $activator: later command wins',
        );
        // Release builds keep later-command-wins silently by design; the
        // print keeps user-reported "shortcut does nothing" diagnosable.
        if (bindings.containsKey(activator)) {
          debugPrint(
            'Duplicate shortcut activator $activator: later command wins',
          );
        }
        bindings[activator] = () {
          if (!command.enabled()) return;
          // Pane commands complete without escaping routes, but a
          // future app-scope chord must not leak an unhandled zone
          // error — the guard mirrors _runCommand's.
          unawaited(
            command.run(context).catchError((Object error, StackTrace st) {
              FlutterError.reportError(
                FlutterErrorDetails(exception: error, stack: st),
              );
            }),
          );
        };
      }
    }

    return Focus(
      // Same posture CallbackShortcuts takes: this node only dispatches,
      // it never takes focus or traversal itself.
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        // Keep CallbackShortcuts' event contract: bindings fire on
        // down/repeat only — never on key-up.
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        // Field-first precedence (02 §8.2): with a text surface focused,
        // chords belong to its editing shortcuts — returning ignored
        // keeps the event propagating upward to them, where a consumed
        // command chord would have swallowed ⌘A mid-typing.
        final primary = FocusManager.instance.primaryFocus;
        if (primary?.context?.findAncestorWidgetOfExactType<EditableText>() !=
            null) {
          return KeyEventResult.ignored;
        }
        var result = KeyEventResult.ignored;
        for (final activator in bindings.keys) {
          if (activator.accepts(event, HardwareKeyboard.instance)) {
            bindings[activator]!();
            result = KeyEventResult.handled;
          }
        }
        return result;
      },
      child: child,
    );
  }
}
