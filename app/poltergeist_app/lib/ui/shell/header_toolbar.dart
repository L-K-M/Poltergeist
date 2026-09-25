import 'dart:async';

import 'package:flutter/material.dart';

import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import '../../services/shortcut_format.dart';
import '../../theme/app_theme.dart';

/// Widths below which the header sheds detail (10 §4's overflow order):
/// primary buttons drop their labels first, then the everyday actions
/// fold into the "»" menu. Labels never ellipsize.
const _unlabelPrimaryBelow = 820.0;
const _foldActionsBelow = 680.0;

/// D32's header toolbar (10 §4): a curated rendering of the command
/// registry — only commands that declare a [CommandToolbarPlacement]
/// appear, grouped by slot into ForkLift-style capsules — plus the
/// active location's title, the filter field, and (Windows/Linux) the ☰
/// main menu. Every button keeps the `command.<id>` key, a tooltip with
/// its shortcut, and runs through [onRun] — the same path menus and
/// chords take.
class HeaderToolbar extends StatelessWidget {
  const HeaderToolbar({
    super.key,
    required this.commands,
    required this.onRun,
    required this.title,
    this.statusExtras = const {},
    this.badges = const {},
    this.filterField,
    this.menuButton,
    this.leadingInset = 0,
    this.nativeTitlebar = false,
  });

  /// macOS: the header sits under the native unified toolbar band, which
  /// claims clicks for window drag/zoom — every interactive control is
  /// wrapped in a [MacosToolbarPassthrough] so its clicks reach Flutter,
  /// while empty header space keeps the native titlebar behavior.
  final bool nativeTitlebar;

  final List<RegisteredCommand> commands;
  final Future<void> Function(RegisteredCommand command) onRun;

  /// The active location's title block (folder name + subtitle).
  final Widget title;

  /// Per-command replacement renderings for status slots — the activity
  /// button's progress ring replaces its plain icon while work runs.
  final Map<String, Widget Function(BuildContext context, Widget button)>
  statusExtras;

  /// Per-command badges (the inspector toggle's alert count).
  final Map<String, ToolbarBadge> badges;

  final Widget? filterField;
  final Widget? menuButton;

  /// Room left for the macOS traffic lights when the sidebar is hidden.
  final double leadingInset;

  @override
  Widget build(BuildContext context) {
    final chrome = PoltergeistChrome.of(context);
    final placed = [
      for (final command in commands)
        if (command.toolbarPlacement != null) command,
    ]..sort((a, b) {
        final pa = a.toolbarPlacement!;
        final pb = b.toolbarPlacement!;
        final bySlot = pa.slot.index.compareTo(pb.slot.index);
        if (bySlot != 0) return bySlot;
        final byGroup = pa.group.compareTo(pb.group);
        if (byGroup != 0) return byGroup;
        return pa.order.compareTo(pb.order);
      });
    List<RegisteredCommand> slot(ToolbarSlot s) => [
      for (final command in placed)
        if (command.toolbarPlacement!.slot == s) command,
    ];

    Widget pass(Widget child) =>
        nativeTitlebar ? MacosToolbarPassthrough(child: child) : child;

    final header = Container(
      height: chrome.headerHeight,
      color: chrome.headerBackground,
      padding: EdgeInsetsDirectional.only(start: 8 + leadingInset, end: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final labelPrimary = width >= _unlabelPrimaryBelow;
          final foldActions = width < _foldActionsBelow;
          final actions = slot(ToolbarSlot.actions);
          return Row(
            children: [
              ..._groups(
                context,
                slot(ToolbarSlot.leading),
                labelled: false,
                pass: pass,
              ),
              const SizedBox(width: 8),
              Expanded(child: title),
              const SizedBox(width: 8),
              if (!foldActions)
                ..._groups(context, actions, labelled: false, pass: pass)
              else if (actions.isNotEmpty)
                pass(_OverflowButton(commands: actions, onRun: onRun)),
              ..._groups(
                context,
                slot(ToolbarSlot.primary),
                labelled: labelPrimary,
                pass: pass,
              ),
              ..._groups(
                context,
                slot(ToolbarSlot.status),
                labelled: false,
                pass: pass,
              ),
              if (filterField != null) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: width >= 1000 ? 200 : 150,
                  child: pass(filterField!),
                ),
              ],
              if (menuButton != null) ...[
                const SizedBox(width: 4),
                pass(menuButton!),
              ],
            ],
          );
        },
      ),
    );
    return nativeTitlebar
        ? MacosToolbarPassthroughScope(child: header)
        : header;
  }

  /// Splits [commands] (already sorted) into capsules by group.
  List<Widget> _groups(
    BuildContext context,
    List<RegisteredCommand> commands, {
    required bool labelled,
    required Widget Function(Widget) pass,
  }) {
    if (commands.isEmpty) return const [];
    final groups = <List<RegisteredCommand>>[];
    int? group;
    for (final command in commands) {
      final g = command.toolbarPlacement!.group;
      if (g != group) {
        groups.add([]);
        group = g;
      }
      groups.last.add(command);
    }
    return [
      for (final members in groups)
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 6),
          child: pass(_Capsule(
            children: [
              for (final command in members)
                _decorated(
                  context,
                  command,
                  _ToolbarButton(
                    command: command,
                    onRun: onRun,
                    labelled:
                        labelled && command.toolbarPlacement!.labelled,
                    badge: badges[command.id],
                  ),
                ),
            ],
          )),
        ),
    ];
  }

  Widget _decorated(
    BuildContext context,
    RegisteredCommand command,
    Widget button,
  ) {
    final extra = statusExtras[command.id];
    return extra == null ? button : extra(context, button);
  }
}

/// A count badged on a header button, with the words a screen reader
/// hears for it: the painted number alone is excluded from semantics
/// with the rest of the button's visuals.
class ToolbarBadge {
  const ToolbarBadge({required this.count, required this.announcement});

  final int count;

  /// The count in words ("3 alerts"), announced as the button's value.
  final String announcement;
}

/// ForkLift's rounded group behind related toolbar buttons.
class _Capsule extends StatelessWidget {
  const _Capsule({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final chrome = PoltergeistChrome.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: chrome.capsuleFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// The tooltip text: the label plus the first chord ("New Folder ⇧⌘N").
String commandTooltip(
  RegisteredCommand command,
  AppLocalizations l10n,
  TargetPlatform platform,
) {
  final label = command.tooltip?.call(l10n) ?? command.label(l10n);
  final activators = command.activators?.call(platform);
  if (activators == null || activators.isEmpty) return label;
  final chord = formatShortcutActivator(activators.first, platform);
  return chord == null ? label : l10n.toolbarTooltipWithShortcut(label, chord);
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.command,
    required this.onRun,
    required this.labelled,
    required this.badge,
  });

  final RegisteredCommand command;
  final Future<void> Function(RegisteredCommand command) onRun;
  final bool labelled;
  final ToolbarBadge? badge;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final enabled = command.enabled();
    final checked = command.checked?.call() ?? false;
    final color = enabled
        ? (checked ? theme.colorScheme.primary : theme.colorScheme.onSurface)
        : theme.colorScheme.onSurface.withValues(alpha: 0.38);
    Widget icon = Icon(
      command.icon ?? Icons.circle_outlined,
      size: 17,
      color: color,
    );
    final badge = this.badge;
    final badged = badge != null && badge.count > 0;
    if (badged) {
      icon = Badge(
        label: Text(
          badge.count > 99
              ? l10n.badgeCountOverflow
              : l10n.badgeCount(badge.count),
        ),
        backgroundColor: theme.colorScheme.error,
        textColor: theme.colorScheme.onError,
        child: icon,
      );
    }
    final onTap = enabled ? () => unawaited(onRun(command)) : null;
    return Tooltip(
      message: commandTooltip(command, l10n, theme.platform),
      child: Semantics(
        button: true,
        toggled: command.checked == null ? null : checked,
        label: command.label(l10n),
        value: badged ? badge.announcement : null,
        excludeSemantics: true,
        enabled: enabled,
        // excludeSemantics drops the InkWell's own tap action with its
        // subtree, so the node carries it: a screen reader's activate
        // (VoiceOver's press, Narrator's invoke, TalkBack's tap) runs it.
        onTap: onTap,
        child: InkWell(
          key: ValueKey('command.${command.id}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          hoverColor: chrome.hoverFill,
          child: Container(
            height: 26,
            constraints: const BoxConstraints(minWidth: 30),
            padding: EdgeInsets.symmetric(horizontal: labelled ? 8 : 6),
            decoration: checked
                ? BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                  )
                : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                icon,
                if (labelled) ...[
                  const SizedBox(width: 5),
                  Text(
                    command.shortLabel?.call(l10n) ?? command.label(l10n),
                    maxLines: 1,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "»" menu the everyday actions fold into on narrow windows.
class _OverflowButton extends StatelessWidget {
  const _OverflowButton({required this.commands, required this.onRun});

  final List<RegisteredCommand> commands;
  final Future<void> Function(RegisteredCommand command) onRun;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return MenuAnchor(
      menuChildren: [
        for (final command in commands)
          MenuItemButton(
            key: ValueKey('toolbar.overflow.${command.id}'),
            leadingIcon: Icon(command.icon, size: 16),
            onPressed: command.enabled()
                ? () => unawaited(onRun(command))
                : null,
            child: Text(command.label(l10n)),
          ),
      ],
      builder: (context, controller, _) => Padding(
        padding: const EdgeInsetsDirectional.only(start: 6),
        child: IconButton(
          key: const ValueKey('toolbar.overflow'),
          tooltip: l10n.toolbarMoreTooltip,
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.keyboard_double_arrow_right),
        ),
      ),
    );
  }
}
