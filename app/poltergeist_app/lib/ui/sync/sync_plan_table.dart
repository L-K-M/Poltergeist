// The plan review's item table (D32 §7 over 05 §7): rows grouped by
// action class — Copy, Update, Delete, Conflicts, Skipped — each
// section headed by a tri-state checkbox, each row carrying its own
// checkbox (checked = the row will act), under one column header of
// path, source size and date, destination size and date, and reason.
//
// Sections group by the engine's SUGGESTED action, so unchecking a row
// (an override to skip) leaves it in place, unchecked, instead of
// jumping into Skipped; the glyph keeps showing the EFFECTIVE action.
// The view owns selection, focus, and the override verbs; this file is
// the grouping rules (pure) and the layout.
import 'package:flutter/material.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../l10n/app_localizations.dart';
import '../../services/sync_plan_controller.dart';
import '../../theme/app_theme.dart';
import '../panes/pane_format.dart' show formatPaneModified;
import 'sync_plan_format.dart';
import 'sync_policy_sentence.dart' show syncEndpointFolderName;

/// The review's sections, in display order.
enum SyncSection { copy, update, delete, conflicts, skipped }

/// A row's section: its suggested action's class.
SyncSection syncSectionOf(SyncItem item) => switch (item.suggested) {
  SyncActionType.copyLeftToRight ||
  SyncActionType.copyRightToLeft ||
  SyncActionType.makeDirLeft ||
  SyncActionType.makeDirRight => SyncSection.copy,
  SyncActionType.updateLeftToRight ||
  SyncActionType.updateRightToLeft => SyncSection.update,
  SyncActionType.deleteLeft || SyncActionType.deleteRight => SyncSection.delete,
  SyncActionType.conflict => SyncSection.conflicts,
  SyncActionType.skip => SyncSection.skipped,
};

/// Checked means the row will act — anything but skip.
bool syncRowIncluded(SyncItem item) => item.effective != SyncActionType.skip;

/// Whether the row's checkbox can change anything: a row the engine
/// itself skips has nothing to include unless the user overrode it.
bool syncRowToggleable(SyncItem item) =>
    item.suggested != SyncActionType.skip || item.userOverridden;

/// A section header's tri-state over its toggleable rows: all checked
/// (true), none (false), or a mix (null). A section with nothing to
/// toggle reads unchecked.
bool? syncSectionState(Iterable<SyncItem> items) {
  var checked = 0;
  var total = 0;
  for (final item in items) {
    if (!syncRowToggleable(item)) continue;
    total++;
    if (syncRowIncluded(item)) checked++;
  }
  if (total == 0 || checked == 0) return false;
  return checked == total ? true : null;
}

/// [items] (already filtered) grouped into non-empty sections in
/// display order, each keeping the plan's own row order.
List<({SyncSection section, List<SyncItem> items})> syncSections(
  Iterable<SyncItem> items,
) {
  final bySection = <SyncSection, List<SyncItem>>{};
  for (final item in items) {
    bySection.putIfAbsent(syncSectionOf(item), () => []).add(item);
  }
  return [
    for (final section in SyncSection.values)
      if (bySection[section] case final rows?) (section: section, items: rows),
  ];
}

String syncSectionLabel(AppLocalizations l10n, SyncSection section) =>
    switch (section) {
      SyncSection.copy => l10n.syncSectionCopy,
      SyncSection.update => l10n.syncSectionUpdate,
      SyncSection.delete => l10n.syncSectionDelete,
      SyncSection.conflicts => l10n.syncSectionConflicts,
      SyncSection.skipped => l10n.syncSectionSkipped,
    };

/// The screen-reader phrase for a row's effective action, naming the
/// side it writes.
String syncRowActionLabel(
  AppLocalizations l10n,
  SyncPair pair,
  SyncActionType action,
) {
  final left = syncEndpointFolderName(pair.left);
  final right = syncEndpointFolderName(pair.right);
  return switch (action) {
    SyncActionType.copyLeftToRight => l10n.syncRowActionCopy(right),
    SyncActionType.copyRightToLeft => l10n.syncRowActionCopy(left),
    SyncActionType.updateLeftToRight => l10n.syncRowActionUpdate(right),
    SyncActionType.updateRightToLeft => l10n.syncRowActionUpdate(left),
    SyncActionType.makeDirRight => l10n.syncRowActionMakeDir(right),
    SyncActionType.makeDirLeft => l10n.syncRowActionMakeDir(left),
    SyncActionType.deleteRight => l10n.syncRowActionDelete(right),
    SyncActionType.deleteLeft => l10n.syncRowActionDelete(left),
    SyncActionType.conflict => l10n.syncRowActionConflict,
    SyncActionType.skip => l10n.syncRowActionSkip,
  };
}

/// Which optional columns fit the table's width — the path always
/// shows; dates go first, then the sizes, then the reason.
final class _Columns {
  const _Columns({
    required this.sizes,
    required this.dates,
    required this.reason,
  });

  factory _Columns.forWidth(double width) =>
      _Columns(sizes: width >= 520, dates: width >= 820, reason: width >= 420);

  final bool sizes;
  final bool dates;
  final bool reason;

  static const double checkWidth = 28;
  static const double glyphWidth = 30;
  static const double sizeWidth = 72;
  static const double dateWidth = 132;
  double get sideWidth => sizeWidth + (dates ? dateWidth + 8 : 0);
}

/// The item table. Stateless: the view passes the filtered rows and its
/// selection/focus/collapse state and receives every gesture back.
final class SyncPlanTable extends StatelessWidget {
  const SyncPlanTable({
    super.key,
    required this.controller,
    required this.items,
    required this.selected,
    required this.focused,
    required this.collapsed,
    required this.tableFocused,
    required this.onRowTap,
    required this.onGlyphTap,
    required this.onContextMenu,
    required this.onSetIncluded,
    required this.onToggleCollapsed,
    this.now,
  });

  final SyncPlanController controller;

  /// The filtered rows, plan order.
  final List<SyncItem> items;
  final Set<SyncItem> selected;
  final SyncItem? focused;
  final Set<SyncSection> collapsed;

  /// The active-selection tint only while the table holds focus.
  final bool tableFocused;
  final ValueChanged<SyncItem> onRowTap;
  final ValueChanged<SyncItem> onGlyphTap;
  final void Function(Offset position, SyncItem item) onContextMenu;
  final void Function(Iterable<SyncItem> items, bool include) onSetIncluded;
  final ValueChanged<SyncSection> onToggleCollapsed;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sections = syncSections(items);
    final entries = <Object>[
      for (final group in sections) ...[
        group,
        if (!collapsed.contains(group.section)) ...group.items,
      ],
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _Columns.forWidth(constraints.maxWidth);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ColumnHeader(controller: controller, columns: columns),
            Expanded(
              child: ListView.builder(
                key: const ValueKey('sync.plan.table'),
                itemCount: entries.length,
                itemBuilder: (context, index) => switch (entries[index]) {
                  final ({SyncSection section, List<SyncItem> items}) group =>
                    _SectionHeader(
                      key: ValueKey('sync.section.${group.section.name}'),
                      checkKey: ValueKey(
                        'sync.section.${group.section.name}.check',
                      ),
                      label: syncSectionLabel(l10n, group.section),
                      items: group.items,
                      collapsed: collapsed.contains(group.section),
                      running: controller.isRunning,
                      onToggleCollapsed: () => onToggleCollapsed(group.section),
                      onSetIncluded: onSetIncluded,
                    ),
                  final SyncItem item => _SyncItemRow(
                    key: ValueKey('sync.row.${item.relativePath}'),
                    item: item,
                    pair: controller.pair,
                    columns: columns,
                    selected: selected.contains(item),
                    focused: identical(item, focused),
                    tableFocused: tableFocused,
                    running: controller.isRunning,
                    now: now,
                    onTap: () => onRowTap(item),
                    onGlyphTap: () => onGlyphTap(item),
                    onContextMenu: (position) => onContextMenu(position, item),
                    onSetIncluded: (include) => onSetIncluded([item], include),
                  ),
                  _ => const SizedBox.shrink(),
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The table's one header row: path, then the SOURCE side before the
/// destination (left before right for Both Ways), each named by its
/// folder, then the reason.
class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader({required this.controller, required this.columns});

  final SyncPlanController controller;
  final _Columns columns;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final pair = controller.pair;
    final (first, second) = _sideOrder(pair);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: chrome.secondaryText,
      fontWeight: FontWeight.w600,
    );
    Widget side(SyncEndpoint endpoint) => SizedBox(
      width: columns.sideWidth,
      child: Text(
        syncEndpointFolderName(endpoint),
        textAlign: columns.dates ? TextAlign.start : TextAlign.end,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
    return Container(
      key: const ValueKey('sync.plan.columns'),
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: chrome.separator)),
      ),
      child: Row(
        children: [
          const SizedBox(width: _Columns.checkWidth + _Columns.glyphWidth),
          Expanded(flex: 3, child: Text(l10n.syncColumnPath, style: style)),
          if (columns.sizes) ...[
            const SizedBox(width: 8),
            side(first),
            const SizedBox(width: 8),
            side(second),
          ],
          if (columns.reason) ...[
            const SizedBox(width: 12),
            Expanded(flex: 2, child: Text(l10n.syncColumnReason, style: style)),
          ],
        ],
      ),
    );
  }
}

/// Source first: a right-to-left pair shows its right side first.
(SyncEndpoint, SyncEndpoint) _sideOrder(SyncPair pair) =>
    pair.rules.direction == SyncDirection.rightToLeft
    ? (pair.right, pair.left)
    : (pair.left, pair.right);

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    super.key,
    required this.checkKey,
    required this.label,
    required this.items,
    required this.collapsed,
    required this.running,
    required this.onToggleCollapsed,
    required this.onSetIncluded,
  });

  final Key checkKey;
  final String label;
  final List<SyncItem> items;
  final bool collapsed;
  final bool running;
  final VoidCallback onToggleCollapsed;
  final void Function(Iterable<SyncItem> items, bool include) onSetIncluded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final state = syncSectionState(items);
    final toggleable = !running && items.any(syncRowToggleable);
    return Semantics(
      container: true,
      label: l10n.syncSectionSemantics(label, items.length),
      child: Container(
        height: 28,
        color: chrome.headerBackground,
        padding: const EdgeInsets.only(left: 12, right: 12),
        child: Row(
          children: [
            SizedBox(
              width: _Columns.checkWidth,
              child: _CompactCheckbox(
                checkKey: checkKey,
                value: state,
                tristate: true,
                // A mixed or full section unchecks everything; an
                // empty one checks everything back to the suggestion.
                onChanged: toggleable
                    ? (_) => onSetIncluded(
                        items.where(syncRowToggleable),
                        state == false,
                      )
                    : null,
              ),
            ),
            Expanded(
              child: InkWell(
                onTap: onToggleCollapsed,
                child: Row(
                  children: [
                    Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 16,
                      color: chrome.secondaryText,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${items.length}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: chrome.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A checkbox that fits a 22 px desktop row.
class _CompactCheckbox extends StatelessWidget {
  const _CompactCheckbox({
    required this.checkKey,
    required this.value,
    required this.onChanged,
    this.tristate = false,
  });

  /// Rides the Checkbox itself so tests and tools find the control.
  final Key checkKey;
  final bool? value;
  final bool tristate;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 18,
    child: Checkbox(
      key: checkKey,
      value: value,
      tristate: tristate,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      onChanged: onChanged,
    ),
  );
}

/// One plan row: checkbox, action glyph (the override affordance),
/// path, both sides' size and date (source first), and the reason.
class _SyncItemRow extends StatelessWidget {
  const _SyncItemRow({
    super.key,
    required this.item,
    required this.pair,
    required this.columns,
    required this.selected,
    required this.focused,
    required this.tableFocused,
    required this.running,
    required this.onTap,
    required this.onGlyphTap,
    required this.onContextMenu,
    required this.onSetIncluded,
    this.now,
  });

  final SyncItem item;
  final SyncPair pair;
  final _Columns columns;
  final bool selected;
  final bool focused;
  final bool tableFocused;
  final bool running;
  final DateTime? now;
  final VoidCallback onTap;
  final VoidCallback onGlyphTap;
  final void Function(Offset position) onContextMenu;
  final ValueChanged<bool> onSetIncluded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    final tone = switch (syncActionTone(item.effective)) {
      SyncActionTone.create => theme.colorScheme.primary,
      SyncActionTone.update => theme.colorScheme.tertiary,
      SyncActionTone.delete => theme.colorScheme.error,
      SyncActionTone.conflict => theme.colorScheme.secondary,
      SyncActionTone.skip => theme.colorScheme.outline,
    };
    final activeSelection = selected && tableFocused;
    final text = activeSelection ? chrome.onSelection : null;
    final secondary = activeSelection
        ? chrome.onSelection
        : chrome.secondaryText;
    final included = syncRowIncluded(item);
    final reason = item.error ?? syncReasonText(l10n, item, now: now);
    final statusIcon = switch (item.status) {
      SyncItemStatus.running => const SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(strokeWidth: 1.5),
      ),
      SyncItemStatus.done => Icon(
        Icons.check,
        size: 14,
        color: theme.colorScheme.primary,
      ),
      SyncItemStatus.failed || SyncItemStatus.conflicted => Icon(
        Icons.error_outline,
        size: 14,
        color: theme.colorScheme.error,
      ),
      _ => null,
    };
    final (first, second) = pair.rules.direction == SyncDirection.rightToLeft
        ? (item.right, item.left)
        : (item.left, item.right);
    Widget side(EntrySnapshot? snapshot) => SizedBox(
      width: columns.sideWidth,
      child: Row(
        children: [
          SizedBox(
            width: _Columns.sizeWidth,
            child: Text(
              snapshot == null
                  ? ''
                  : snapshot.kind == EntryKind.directory
                  ? '—'
                  : formatSyncSize(snapshot.size),
              textAlign: TextAlign.end,
              style: theme.textTheme.labelSmall?.copyWith(color: secondary),
            ),
          ),
          if (columns.dates) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _dateText(l10n, snapshot),
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: secondary),
              ),
            ),
          ],
        ],
      ),
    );
    final actionLabel = syncRowActionLabel(l10n, pair, item.effective);
    return Semantics(
      container: true,
      label: l10n.syncRowSemantics(item.relativePath, actionLabel, reason),
      selected: selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) => onContextMenu(details.globalPosition),
        onTapDown: (_) => onTap(),
        child: Container(
          height: chrome.rowExtent,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected
                ? (tableFocused
                      ? chrome.selectionFill
                      : chrome.inactiveSelectionFill)
                : null,
            border: focused && tableFocused
                ? Border.all(color: chrome.activePaneIndicator)
                : null,
          ),
          child: Row(
            children: [
              SizedBox(
                width: _Columns.checkWidth,
                child: Tooltip(
                  message: l10n.syncRowToggleHint,
                  child: _CompactCheckbox(
                    checkKey: ValueKey('sync.row.${item.relativePath}.check'),
                    value: included,
                    onChanged: running || !syncRowToggleable(item)
                        ? null
                        : (value) => onSetIncluded(value ?? false),
                  ),
                ),
              ),
              SizedBox(
                width: _Columns.glyphWidth,
                child: Row(
                  children: [
                    // The glyph is the override affordance — tap cycles,
                    // right click opens the menu (handled at row level).
                    Semantics(
                      container: true,
                      button: true,
                      label: actionLabel,
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: running ? null : onGlyphTap,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Text(
                            syncActionGlyph(item.effective),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: tone,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (item.userOverridden)
                      Icon(
                        Icons.circle,
                        size: 6,
                        color: theme.colorScheme.primary,
                      ),
                  ],
                ),
              ),
              if (statusIcon != null) ...[statusIcon, const SizedBox(width: 4)],
              // The row's own label already speaks the path, action,
              // and reason — the cells stay out of the tree.
              Expanded(
                flex: 3,
                child: ExcludeSemantics(
                  child: Text(
                    item.relativePath,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: included ? text : secondary,
                    ),
                  ),
                ),
              ),
              if (columns.sizes) ...[
                const SizedBox(width: 8),
                ExcludeSemantics(child: side(first)),
                const SizedBox(width: 8),
                ExcludeSemantics(child: side(second)),
              ],
              if (columns.reason) ...[
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ExcludeSemantics(
                    child: Text(
                      reason,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: item.error != null
                            ? theme.colorScheme.error
                            : secondary,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _dateText(AppLocalizations l10n, EntrySnapshot? snapshot) {
    final secs = snapshot?.mtimeSecs;
    if (snapshot == null || secs == null) return '';
    return formatPaneModified(
      DateTime.fromMillisecondsSinceEpoch(secs * 1000),
      now: now ?? DateTime.now(),
      localeName: l10n.localeName,
      today: l10n.paneDateToday,
      yesterday: l10n.paneDateYesterday,
    );
  }
}
