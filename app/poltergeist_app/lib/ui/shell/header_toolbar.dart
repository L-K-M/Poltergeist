import 'dart:async';

import 'package:flutter/material.dart';

import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';

import '../../l10n/app_localizations.dart';
import '../../services/registered_command.dart';
import '../../services/shortcut_format.dart';
import '../../theme/app_theme.dart';
import 'command_icon.dart';
import 'corner_count_badge.dart';

/// How far the header has shed detail (10 §4's overflow order): the
/// filter field narrows, the primary buttons drop their labels, then the
/// everyday actions fold into the "»" menu, then the primary buttons
/// follow them and the filter narrows again. Labels never ellipsize.
/// Each step is taken only when the content measured below would leave
/// the title under [_titleMinWidth] — never at a fixed window width,
/// which a longer translation or a running transfer's extra button
/// would outgrow.
enum _Fold { none, filter, primaryLabels, actions, primary }

/// The narrowest the active location's title may get before the header
/// sheds the next group: a name, never "P…".
const _titleMinWidth = 96.0;

// The metrics the fold is measured with: the numbers the widgets below
// lay out with, so the measured content is what renders.
const _buttonMinWidth = 30.0;
const _buttonIconSize = 17.0;
const _buttonPadding = 6.0;
const _labelledPadding = 8.0;
const _labelGap = 5.0;
const _capsuleInset = 2.0;
const _groupGap = 6.0;
const _titleGap = 8.0;
const _filterGap = 8.0;
const _menuGap = 4.0;

/// A compact IconButton: the "»" button and the ☰ main menu.
const _iconButtonExtent = 40.0;

const _filterWideWidth = 200.0;
const _filterWidth = 150.0;
const _filterNarrowWidth = 120.0;

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
          final leading = slot(ToolbarSlot.leading);
          final actions = slot(ToolbarSlot.actions);
          final primary = slot(ToolbarSlot.primary);
          final status = slot(ToolbarSlot.status);
          double extent(_Fold fold) {
            final foldActions = fold.index >= _Fold.actions.index;
            final foldPrimary = fold == _Fold.primary;
            final overflow =
                (foldActions && actions.isNotEmpty) ||
                (foldPrimary && primary.isNotEmpty);
            return _groupsExtent(context, leading) +
                2 * _titleGap +
                (foldActions ? 0 : _groupsExtent(context, actions)) +
                (overflow ? _groupGap + _iconButtonExtent : 0) +
                (foldPrimary
                    ? 0
                    : _groupsExtent(
                        context,
                        primary,
                        labelled: fold.index < _Fold.primaryLabels.index,
                      )) +
                _groupsExtent(context, status) +
                (filterField == null
                    ? 0
                    : _filterGap + _filterWidthFor(fold)) +
                (menuButton == null ? 0 : _menuGap + _iconButtonExtent);
          }

          final fold = _Fold.values.firstWhere(
            (fold) => extent(fold) + _titleMinWidth <= width,
            orElse: () => _Fold.primary,
          );
          final foldActions = fold.index >= _Fold.actions.index;
          final foldPrimary = fold == _Fold.primary;
          final folded = [
            if (foldActions) ...actions,
            if (foldPrimary) ...primary,
          ];
          return Row(
            children: [
              ..._groups(context, leading, labelled: false, pass: pass),
              const SizedBox(width: _titleGap),
              Expanded(child: title),
              const SizedBox(width: _titleGap),
              if (!foldActions)
                ..._groups(context, actions, labelled: false, pass: pass),
              if (folded.isNotEmpty)
                pass(_OverflowButton(commands: folded, onRun: onRun)),
              if (!foldPrimary)
                ..._groups(
                  context,
                  primary,
                  labelled: fold.index < _Fold.primaryLabels.index,
                  pass: pass,
                ),
              ..._groups(context, status, labelled: false, pass: pass),
              if (filterField != null) ...[
                const SizedBox(width: _filterGap),
                SizedBox(
                  width: _filterWidthFor(fold),
                  child: pass(filterField!),
                ),
              ],
              if (menuButton != null) ...[
                const SizedBox(width: _menuGap),
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

  double _filterWidthFor(_Fold fold) => switch (fold) {
    _Fold.none => _filterWideWidth,
    _Fold.primary => _filterNarrowWidth,
    _ => _filterWidth,
  };

  /// The width [_groups] lays [commands] out at: per group its gap and
  /// capsule inset, per button its minimum or, when [labelled], its icon
  /// and measured label.
  double _groupsExtent(
    BuildContext context,
    List<RegisteredCommand> commands, {
    bool labelled = false,
  }) {
    var extent = 0.0;
    int? group;
    for (final command in commands) {
      final placement = command.toolbarPlacement!;
      if (placement.group != group) {
        extent += _groupGap + 2 * _capsuleInset;
        group = placement.group;
      }
      extent += labelled && placement.labelled
          ? _labelledButtonWidth(context, command)
          : _buttonMinWidth;
    }
    return extent;
  }

  double _labelledButtonWidth(BuildContext context, RegisteredCommand command) {
    final l10n = AppLocalizations.of(context);
    final painter = TextPainter(
      text: TextSpan(
        text: command.shortLabel?.call(l10n) ?? command.label(l10n),
        style: DefaultTextStyle.of(
          context,
        ).style.merge(_labelStyle(Theme.of(context))),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final label = painter.width.ceilToDouble();
    painter.dispose();
    return 2 * _labelledPadding + _buttonIconSize + _labelGap + label;
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
          padding: const EdgeInsetsDirectional.only(start: _groupGap),
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
        padding: const EdgeInsets.all(_capsuleInset),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// A primary button's label style — shared with the header's fold
/// measurement.
TextStyle? _labelStyle(ThemeData theme) =>
    theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w500);

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
    // D34: a verb's glyph wears its family hue and its label stays in
    // the ink; a toggle keeps the accent it is checked in.
    Widget icon = commandIcon(
      context,
      command,
      size: _buttonIconSize,
      enabled: enabled && !checked,
      ink: color,
    );
    final badge = this.badge;
    final badged = badge != null && badge.count > 0;
    if (badged) {
      icon = CornerCountBadge(
        label: badge.count > 99
            ? l10n.badgeCountOverflow
            : l10n.badgeCount(badge.count),
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
            constraints: const BoxConstraints(minWidth: _buttonMinWidth),
            padding: EdgeInsets.symmetric(
              horizontal: labelled ? _labelledPadding : _buttonPadding,
            ),
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
                  const SizedBox(width: _labelGap),
                  Text(
                    command.shortLabel?.call(l10n) ?? command.label(l10n),
                    maxLines: 1,
                    style: _labelStyle(theme)?.copyWith(color: color),
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
            leadingIcon: commandIcon(
              context,
              command,
              size: 16,
              enabled: command.enabled(),
            ),
            onPressed: command.enabled()
                ? () => unawaited(onRun(command))
                : null,
            child: Text(command.label(l10n)),
          ),
      ],
      builder: (context, controller, _) => Padding(
        padding: const EdgeInsetsDirectional.only(start: _groupGap),
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
