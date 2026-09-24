// The sync plan view (05 §7): a first-class pane-tab surface that
// scans on mount, renders the diff as an item table grouped by action
// class (sync_plan_table.dart, D32 §7), and runs the reviewed plan
// through the controller's rails. D32 puts the Sync sheet in front of
// it; Simulate lands here, and so does Synchronize whenever the plan
// needs review. Everything reads through [SyncPlanController]; this
// file is layout, filters, selection, and dialogs only.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show RemoteFileErrorKind;
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../l10n/app_localizations.dart';
import '../../services/sync_plan_controller.dart';
import 'rsync_copy.dart';
import 'sync_plan_format.dart';
import 'sync_plan_table.dart';

/// One filter chip's bucket over effective actions.
enum SyncFilter { all, newFiles, updates, deletes, conflicts, skipped }

/// The mode picker's three positions (05 §7): direction × deletion
/// policy projected onto the user-facing vocabulary.
enum SyncMode { update, mirror, additive }

/// The plan view widget. The owning tab builds and disposes the
/// controller; this widget only renders it.
final class SyncPlanView extends StatefulWidget {
  const SyncPlanView({
    super.key,
    required this.controller,
    this.onSaveAsFavorite,
    this.onEditRules,
    this.clock,
  });

  final SyncPlanController controller;

  /// `sync.saveAsFavorite` — the shell opens the name dialog and
  /// persists the pair as a savedSync bookmark.
  final VoidCallback? onSaveAsFavorite;

  /// The pair/rules editor affordance (options sheet / pair editor).
  final VoidCallback? onEditRules;

  /// Injectable clock for the reason column's age labels.
  final DateTime Function()? clock;

  @override
  State<SyncPlanView> createState() => _SyncPlanViewState();
}

class _SyncPlanViewState extends State<SyncPlanView> {
  SyncFilter _filter = SyncFilter.all;
  String _filterText = '';
  bool _onlyActions = true; // §7: default enabled
  final _filterField = TextEditingController();
  final _selected = <SyncItem>{};
  SyncItem? _selectionAnchor;

  /// The keyboard's row (Space toggles it, the arrows move it).
  SyncItem? _focusedRow;
  final _collapsedSections = <SyncSection>{};
  final _tableFocus = FocusNode(debugLabel: 'sync.plan.table');

  /// The rows in on-screen order (sections, collapsed ones skipped) —
  /// shift-range selection and the arrow keys walk this, not the
  /// plan's own order.
  List<SyncItem> _rowOrder = const [];
  bool _warningsExpanded = false;
  String? _bulkSkipNotice;

  SyncPlanController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.start();
  }

  @override
  void dispose() {
    _filterField.dispose();
    _tableFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(controller: _controller, l10n: l10n),
            if (_controller.phase == SyncPlanPhase.scanning)
              const LinearProgressIndicator(minHeight: 2),
            _WarningsStrip(
              controller: _controller,
              l10n: l10n,
              expanded: _warningsExpanded,
              onToggle: () =>
                  setState(() => _warningsExpanded = !_warningsExpanded),
            ),
            _SuggestionBanner(controller: _controller, l10n: l10n),
            _RefusalBanner(
              controller: _controller,
              l10n: l10n,
              onEditRules: widget.onEditRules,
            ),
            _ReviewHoldBanner(controller: _controller, l10n: l10n),
            if (_bulkSkipNotice != null)
              MaterialBanner(
                content: Text(_bulkSkipNotice!),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _bulkSkipNotice = null),
                    child: Text(l10n.paneNoticeDismiss),
                  ),
                ],
              ),
            _FilterBar(
              controller: _controller,
              l10n: l10n,
              filter: _filter,
              filterField: _filterField,
              onlyActions: _onlyActions,
              onFilterChanged: (filter) => setState(() => _filter = filter),
              onFilterTextChanged: (text) =>
                  setState(() => _filterText = text),
              onOnlyActionsChanged: (value) =>
                  setState(() => _onlyActions = value),
            ),
            _ConflictBar(
              controller: _controller,
              l10n: l10n,
              onResolved: () => setState(() {}),
            ),
            Expanded(child: _buildBody(context, l10n)),
            _ActionBar(
              controller: _controller,
              l10n: l10n,
              onSaveAsFavorite: widget.onSaveAsFavorite,
              onRun: _onRun,
              onRetry: () => unawaited(_controller.retryFailed()),
              onRestore: _onRestore,
            ),
          ],
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    switch (_controller.phase) {
      case SyncPlanPhase.scanning:
        return Center(
          child: Text(
            l10n.syncScanning(
              _controller.leftScanned,
              _controller.rightScanned,
            ),
          ),
        );
      case SyncPlanPhase.error:
        final remote =
            _controller.errorKind == RemoteFileErrorKind.unsupported;
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              remote
                  ? l10n.syncRemoteUnavailable
                  : l10n.syncScanFailed(_controller.errorMessage ?? ''),
              textAlign: TextAlign.center,
            ),
          ),
        );
      case SyncPlanPhase.ready:
      case SyncPlanPhase.running:
      case SyncPlanPhase.completed:
      case SyncPlanPhase.failed:
      case SyncPlanPhase.cancelled:
        return _buildTable(context, l10n);
    }
  }

  Widget _buildTable(BuildContext context, AppLocalizations l10n) {
    final plan = _controller.plan;
    if (plan == null) return const SizedBox.shrink();
    final visible = _visibleItems(plan.items);
    if (visible.isEmpty) {
      _rowOrder = const [];
      return Center(child: Text(l10n.syncHeaderNothingToDo));
    }
    _rowOrder = [
      for (final group in syncSections(visible))
        if (!_collapsedSections.contains(group.section)) ...group.items,
    ];
    return Focus(
      focusNode: _tableFocus,
      onFocusChange: (_) => setState(() {}),
      onKeyEvent: _onTableKey,
      child: SyncPlanTable(
        controller: _controller,
        items: visible,
        selected: _selected,
        focused: _focusedRow,
        collapsed: _collapsedSections,
        tableFocused: _tableFocus.hasFocus,
        now: widget.clock?.call(),
        onRowTap: _onRowTap,
        onGlyphTap: _cycleAction,
        onContextMenu: (position, item) =>
            _showOverrideMenu(context, position, item),
        onSetIncluded: _setIncluded,
        onToggleCollapsed: (section) => setState(() {
          _collapsedSections.contains(section)
              ? _collapsedSections.remove(section)
              : _collapsedSections.add(section);
        }),
      ),
    );
  }

  /// Checked = the row acts (D32 §7): unchecking overrides to skip,
  /// re-checking returns the row to the engine's suggestion.
  void _setIncluded(Iterable<SyncItem> items, bool include) {
    final targets = items.where(syncRowToggleable).toList();
    if (include) {
      _controller.resetOverrides(
        targets.where((item) => !syncRowIncluded(item)),
      );
      return;
    }
    _applyBulk(targets.where(syncRowIncluded).toSet(), SyncActionType.skip);
  }

  /// Space toggles the focused row (or the selection holding it); the
  /// arrows move the focused row and select it.
  KeyEventResult _onTableKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space && event is KeyDownEvent) {
      final row = _focusedRow;
      if (row == null || _controller.isRunning) {
        return KeyEventResult.ignored;
      }
      final targets = _selected.contains(row) ? _selected.toList() : [row];
      _setIncluded(targets, !syncRowIncluded(row));
      return KeyEventResult.handled;
    }
    final step = key == LogicalKeyboardKey.arrowDown
        ? 1
        : key == LogicalKeyboardKey.arrowUp
        ? -1
        : 0;
    if (step == 0 || _rowOrder.isEmpty) return KeyEventResult.ignored;
    final current = _focusedRow == null ? -1 : _rowOrder.indexOf(_focusedRow!);
    final next = current < 0
        ? (step > 0 ? 0 : _rowOrder.length - 1)
        : (current + step).clamp(0, _rowOrder.length - 1);
    final row = _rowOrder[next];
    setState(() {
      _focusedRow = row;
      _selected
        ..clear()
        ..add(row);
      _selectionAnchor = row;
    });
    return KeyEventResult.handled;
  }

  List<SyncItem> _visibleItems(List<SyncItem> items) {
    bool bucket(SyncItem item) => switch (_filter) {
      SyncFilter.all => true,
      SyncFilter.newFiles =>
        item.effective == SyncActionType.copyLeftToRight ||
            item.effective == SyncActionType.copyRightToLeft ||
            item.effective == SyncActionType.makeDirLeft ||
            item.effective == SyncActionType.makeDirRight,
      SyncFilter.updates =>
        item.effective == SyncActionType.updateLeftToRight ||
            item.effective == SyncActionType.updateRightToLeft,
      SyncFilter.deletes =>
        // §7's badge groups file removals AND rule-4 pre-deletes —
        // a replace row whose destination subtree the run removes
        // belongs in this bucket too.
        item.effective == SyncActionType.deleteLeft ||
            item.effective == SyncActionType.deleteRight ||
            _controller.itemCarriesPreDelete(item),
      SyncFilter.conflicts =>
        item.effective == SyncActionType.conflict,
      SyncFilter.skipped => item.effective == SyncActionType.skip,
    };
    final query = _filterText.trim().toLowerCase();
    return items.where((item) {
      if (_onlyActions &&
          item.effective == SyncActionType.skip &&
          !item.userOverridden) {
        return false;
      }
      if (!bucket(item)) return false;
      if (query.isNotEmpty &&
          !item.relativePath.toLowerCase().contains(query)) {
        return false;
      }
      return true;
    }).toList();
  }

  void _onRowTap(SyncItem item) {
    _tableFocus.requestFocus();
    setState(() {
      _focusedRow = item;
      final modifiers = HardwareKeyboard.instance;
      final multi =
          modifiers.isControlPressed || modifiers.isMetaPressed;
      final range = modifiers.isShiftPressed;
      if (range && _selectionAnchor != null) {
        final items = _rowOrder;
        final a = items.indexOf(_selectionAnchor!);
        final b = items.indexOf(item);
        if (a >= 0 && b >= 0) {
          _selected
            ..clear()
            ..addAll(items.sublist(a < b ? a : b, (a > b ? a : b) + 1));
        }
      } else if (multi) {
        _selected.contains(item)
            ? _selected.remove(item)
            : _selected.add(item);
      } else {
        _selected
          ..clear()
          ..add(item);
        _selectionAnchor = item;
      }
    });
  }

  /// Tap on the action glyph cycles through the valid overrides (§7).
  void _cycleAction(SyncItem item) {
    final options = _controller.availableOverrides(item);
    if (options.length < 2) return;
    final index = options.indexOf(item.effective);
    final next = options[(index + 1) % options.length];
    final targets = _selected.contains(item) && _selected.length > 1
        ? _selected
        : {item};
    _applyBulk(targets, next);
  }

  void _applyBulk(Set<SyncItem> targets, SyncActionType action) {
    final skipped = _controller.applyOverrideTo(targets, action);
    if (skipped.isNotEmpty) {
      setState(() {
        _bulkSkipNotice = AppLocalizations.of(
          context,
        ).syncOverrideSkippedTypeDiffers(skipped.length);
      });
    }
  }

  /// The per-row override menu (§7): skip, both copy directions,
  /// delete (mirror rows only), reset — plus a bulk application when
  /// the row sits inside a multi-selection.
  Future<void> _showOverrideMenu(
    BuildContext context,
    Offset position,
    SyncItem item,
  ) async {
    final l10n = AppLocalizations.of(context);
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final actions = _controller.availableOverrides(item);
    final entries = <PopupMenuEntry<SyncActionType>>[
      for (final action in actions)
        PopupMenuItem(
          value: action,
          child: Text(_actionMenuLabel(l10n, action)),
        ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: item.suggested,
        enabled: item.userOverridden,
        child: Text(l10n.syncOverrideReset),
      ),
    ];
    final chosen = await showMenu<SyncActionType>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: entries,
    );
    if (chosen == null || !mounted) return;
    final targets = _selected.contains(item) && _selected.length > 1
        ? _selected
        : {item};
    if (chosen == item.suggested && targets.length == 1) {
      _controller.resetOverride(item);
    } else {
      _applyBulk(targets, chosen);
    }
  }

  String _actionMenuLabel(AppLocalizations l10n, SyncActionType action) =>
      switch (action) {
        SyncActionType.skip => l10n.syncOverrideSkip,
        SyncActionType.copyLeftToRight ||
        SyncActionType.updateLeftToRight ||
        SyncActionType.makeDirRight => l10n.syncOverrideCopyLeftToRight,
        SyncActionType.copyRightToLeft ||
        SyncActionType.updateRightToLeft ||
        SyncActionType.makeDirLeft => l10n.syncOverrideCopyRightToLeft,
        SyncActionType.deleteLeft || SyncActionType.deleteRight =>
          l10n.syncOverrideDelete,
        SyncActionType.conflict => l10n.syncOverrideReset,
      };

  /// Run — rail 3's typed DELETE dialog interposes when the gate
  /// trips; rail 4 never reaches here (the button is disabled).
  Future<void> _onRun() async {
    if (_controller.needsTypedConfirmation) {
      final confirmed = await _showDeleteConfirm();
      if (!confirmed) return;
      await _controller.run(deleteConfirmed: true);
      return;
    }
    await _controller.run();
  }

  Future<bool> _showDeleteConfirm() async {
    final gate = _controller.gate;
    if (gate is! SyncRunNeedsConfirmation) return false;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteConfirmDialog(
        gate: gate,
        deleteFractionWarn: _controller.pair.rules.deleteFractionWarn,
      ),
    );
    return result ?? false;
  }

  /// Rail 9's restore — a small summary dialog, then the report line.
  Future<void> _onRestore() async {
    final l10n = AppLocalizations.of(context);
    final journal = _controller.lastRun?.journal;
    if (journal == null) return;
    final count =
        journal.trashLines.length +
        journal.items.where((line) => line.trashLocation != null).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.syncRestoreDialogTitle),
        content: Text(l10n.syncRestoreSummary(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.syncCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.syncRestoreButton),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final report = await _controller.restoreTrashed();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          l10n.syncRestoreResult(
            report.restored.length,
            report.skipped.length,
          ),
        ),
      ),
    );
  }
}

/// Rail 3's typed-DELETE dialog (05 §8). Stateful because the field's
/// TextEditingController must outlive the exit animation — disposing it
/// in `showDialog`'s continuation still leaves the transition building
/// against a dead controller.
class _DeleteConfirmDialog extends StatefulWidget {
  const _DeleteConfirmDialog({
    required this.gate,
    required this.deleteFractionWarn,
  });

  final SyncRunNeedsConfirmation gate;
  final double deleteFractionWarn;

  @override
  State<_DeleteConfirmDialog> createState() => _DeleteConfirmDialogState();
}

class _DeleteConfirmDialogState extends State<_DeleteConfirmDialog> {
  final _field = TextEditingController();
  var _typed = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.syncDeleteConfirmTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final trigger in widget.gate.triggers)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                syncDeleteConfirmTrigger(
                  l10n,
                  trigger,
                  widget.deleteFractionWarn,
                ),
              ),
            ),
          TextField(
            controller: _field,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l10n.syncDeleteConfirmFieldHint,
            ),
            onChanged: (value) =>
                setState(() => _typed = value.trim() == 'DELETE'),
            onSubmitted: (_) {
              if (_typed) Navigator.of(context).pop(true);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.syncCancel),
        ),
        FilledButton(
          onPressed: _typed ? () => Navigator.of(context).pop(true) : null,
          child: Text(l10n.syncDeleteConfirmButton),
        ),
      ],
    );
  }
}

/// The header strip: mode picker + the verbatim consequence sentence.
class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.l10n});

  final SyncPlanController controller;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rules = controller.pair.rules;
    final mode = rules.direction == SyncDirection.bidirectional
        ? SyncMode.additive
        : rules.deletions == DeletionPolicy.none
        ? SyncMode.update
        : SyncMode.mirror;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // A narrow pane (D32's three columns) scrolls the mode
              // controls instead of overflowing them.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      Text(
                        l10n.syncModeLabel,
                        style: theme.textTheme.labelMedium,
                      ),
                      const SizedBox(width: 8),
                      SegmentedButton<SyncMode>(
                        segments: [
                          ButtonSegment(
                            value: SyncMode.update,
                            label: Text(l10n.syncModeUpdate),
                          ),
                          ButtonSegment(
                            value: SyncMode.mirror,
                            label: Text(l10n.syncModeMirror),
                          ),
                          ButtonSegment(
                            value: SyncMode.additive,
                            label: Text(l10n.syncModeAdditive),
                          ),
                        ],
                        selected: {mode},
                        onSelectionChanged: controller.isRunning
                            ? null
                            : (modes) => unawaited(_setMode(modes.first)),
                      ),
                      const SizedBox(width: 8),
                      if (mode != SyncMode.additive)
                        IconButton(
                          tooltip:
                              '${l10n.syncSideLeft} ⇄ ${l10n.syncSideRight}',
                          icon: const Icon(Icons.swap_horiz, size: 18),
                          onPressed: controller.isRunning
                              ? null
                              : () => unawaited(_flipDirection()),
                        ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: l10n.syncRescan,
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: controller.isRunning
                    ? null
                    : () => unawaited(controller.rescan()),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final clause in syncHeaderClauses(l10n, controller))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                clause,
                key: const ValueKey('sync.header.clause'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          if (_sizeOnlyNotice)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                l10n.syncHeaderSizeOnlyNotice,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.secondary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  bool get _sizeOnlyNotice =>
      !controller.pair.rules.preserveMtime ||
      controller.pairState.mtimeUnreliableLeft ||
      controller.pairState.mtimeUnreliableRight;

  Future<void> _setMode(SyncMode mode) => switch (mode) {
    SyncMode.update => controller.setMode(
      deletions: DeletionPolicy.none,
    ),
    SyncMode.mirror => controller.setMode(
      direction: controller.pair.rules.direction ==
              SyncDirection.bidirectional
          ? SyncDirection.leftToRight
          : controller.pair.rules.direction,
      deletions: DeletionPolicy.trash,
    ),
    SyncMode.additive => controller.setMode(
      direction: SyncDirection.bidirectional,
      deletions: DeletionPolicy.none,
    ),
  };

  Future<void> _flipDirection() => controller.setMode(
    direction:
        controller.pair.rules.direction == SyncDirection.leftToRight
        ? SyncDirection.rightToLeft
        : SyncDirection.leftToRight,
  );
}

/// The scan-warning strip (§7) — collapsed to a count line, expanding
/// to the verbatim warning texts.
class _WarningsStrip extends StatelessWidget {
  const _WarningsStrip({
    required this.controller,
    required this.l10n,
    required this.expanded,
    required this.onToggle,
  });

  final SyncPlanController controller;
  final AppLocalizations l10n;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final warnings = controller.plan?.warnings ?? const <ScanWarning>[];
    if (warnings.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.4),
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.warning_amber_outlined,
                    size: 16,
                    color: theme.colorScheme.secondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.syncWarningsTitle(warnings.length),
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                  ),
                ],
              ),
              if (expanded)
                for (final warning in warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 22),
                    child: Text(
                      warning.message,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// §9's heavy-directory suggestion banner.
class _SuggestionBanner extends StatelessWidget {
  const _SuggestionBanner({required this.controller, required this.l10n});

  final SyncPlanController controller;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final suggestion = controller.heavySuggestion;
    if (suggestion == null) return const SizedBox.shrink();
    return MaterialBanner(
      content: Text(
        l10n.syncHeavySuggestion(suggestion.name, suggestion.itemCount),
      ),
      leading: const Icon(Icons.folder_delete_outlined),
      actions: [
        TextButton(
          onPressed: controller.dismissHeavySuggestion,
          child: Text(l10n.paneNoticeDismiss),
        ),
        FilledButton.tonal(
          onPressed: () => unawaited(controller.acceptHeavySuggestion()),
          child: Text(l10n.syncHeavySuggestionAccept),
        ),
      ],
    );
  }
}

/// Rail 4's refusal banner — the plan stays, the run does not.
class _RefusalBanner extends StatelessWidget {
  const _RefusalBanner({
    required this.controller,
    required this.l10n,
    this.onEditRules,
  });

  final SyncPlanController controller;
  final AppLocalizations l10n;
  final VoidCallback? onEditRules;

  @override
  Widget build(BuildContext context) {
    final refusal = controller.refusal;
    if (refusal == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.block,
              size: 18,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.syncMaxDeleteTitle,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  Text(
                    l10n.syncMaxDeleteBody(
                      refusal.deleteCount,
                      refusal.side == SyncSide.left
                          ? l10n.syncSideLeft
                          : l10n.syncSideRight,
                      refusal.maxDelete,
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
            if (onEditRules != null)
              TextButton(
                onPressed: onEditRules,
                child: Text(l10n.syncMaxDeleteSaveAdjust),
              ),
          ],
        ),
      ),
    );
  }
}

/// D32 §7's Synchronize stop: the plan needs a look before it runs,
/// and the banner says exactly why — live over the effective actions,
/// so skipping the deletions in the review shrinks it.
class _ReviewHoldBanner extends StatelessWidget {
  const _ReviewHoldBanner({required this.controller, required this.l10n});

  final SyncPlanController controller;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final hold = controller.reviewHold;
    if (hold == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final reasons = [
      if (hold.deletes > 0) l10n.syncHoldDeletes(hold.deletes),
      if (hold.emptyFolders > 0) l10n.syncHoldEmptyFolders(hold.emptyFolders),
      if (hold.replaces > 0) l10n.syncHoldReplaces(hold.replaces),
      if (hold.conflicts > 0) l10n.syncHoldConflicts(hold.conflicts),
    ].join(', ');
    final destructive = hold.deletes > 0 || hold.emptyFolders > 0;
    return Material(
      key: const ValueKey('sync.plan.holdBanner'),
      color: destructive
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Icon(
              destructive ? Icons.warning_amber_rounded : Icons.info_outline,
              size: 18,
              color: destructive
                  ? theme.colorScheme.onErrorContainer
                  : theme.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.syncHoldBanner(reasons),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: destructive
                      ? theme.colorScheme.onErrorContainer
                      : theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: controller.dismissReviewHold,
              child: Text(l10n.paneNoticeDismiss),
            ),
          ],
        ),
      ),
    );
  }
}

/// The filter chip row + text filter + only-actions toggle.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.controller,
    required this.l10n,
    required this.filter,
    required this.filterField,
    required this.onlyActions,
    required this.onFilterChanged,
    required this.onFilterTextChanged,
    required this.onOnlyActionsChanged,
  });

  final SyncPlanController controller;
  final AppLocalizations l10n;
  final SyncFilter filter;
  final TextEditingController filterField;
  final bool onlyActions;
  final ValueChanged<SyncFilter> onFilterChanged;
  final ValueChanged<String> onFilterTextChanged;
  final ValueChanged<bool> onOnlyActionsChanged;

  @override
  Widget build(BuildContext context) {
    final stats = controller.stats;
    final chips = <(SyncFilter, String)>[
      (SyncFilter.all, l10n.syncFilterAll(stats == null ? 0 : _total(stats))),
      (
        SyncFilter.newFiles,
        l10n.syncFilterNew(
          stats == null
              ? 0
              : stats.countOf(SyncActionType.copyLeftToRight) +
                    stats.countOf(SyncActionType.copyRightToLeft) +
                    stats.countOf(SyncActionType.makeDirLeft) +
                    stats.countOf(SyncActionType.makeDirRight),
        ),
      ),
      (
        SyncFilter.updates,
        l10n.syncFilterUpdates(
          stats == null
              ? 0
              : stats.countOf(SyncActionType.updateLeftToRight) +
                    stats.countOf(SyncActionType.updateRightToLeft),
        ),
      ),
      (
        SyncFilter.deletes,
        // §7's Deletes badge counts every FILE the plan removes —
        // §6 rule-4 pre-deletes included, matching the rail
        // consequences and the header's delete clause.
        l10n.syncFilterDeletes(
          stats == null
              ? 0
              : stats.deletesOn(SyncSide.left) +
                    stats.deletesOn(SyncSide.right) +
                    stats.replacedFiles,
        ),
      ),
      (
        SyncFilter.conflicts,
        l10n.syncFilterConflicts(stats?.conflicts ?? 0),
      ),
      (
        SyncFilter.skipped,
        l10n.syncFilterSkipped(
          stats?.countOf(SyncActionType.skip) ?? 0,
        ),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (value, label) in chips)
            FilterChip(
              label: Text(label),
              selected: filter == value,
              onSelected: (_) => onFilterChanged(value),
            ),
          SizedBox(
            width: 180,
            child: TextField(
              controller: filterField,
              decoration: InputDecoration(
                hintText: l10n.syncFilterFieldHint,
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
              ),
              onChanged: onFilterTextChanged,
            ),
          ),
          FilterChip(
            label: Text(l10n.syncFilterOnlyActions),
            selected: onlyActions,
            onSelected: onOnlyActionsChanged,
          ),
        ],
      ),
    );
  }

  int _total(SyncEffectiveStats stats) =>
      stats.counts.values.fold(0, (sum, count) => sum + count);
}

/// §7's bulk conflict bar — mounts while conflict rows exist.
class _ConflictBar extends StatelessWidget {
  const _ConflictBar({
    required this.controller,
    required this.l10n,
    required this.onResolved,
  });

  final SyncPlanController controller;
  final AppLocalizations l10n;
  final VoidCallback onResolved;

  @override
  Widget build(BuildContext context) {
    final conflicts = controller.stats?.conflicts ?? 0;
    if (conflicts == 0 || controller.isRunning) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              l10n.syncResolveConflictsLabel,
              style: theme.textTheme.labelMedium,
            ),
            if (controller.offersNewerWins)
              ActionChip(
                label: Text(l10n.syncResolveNewerWins),
                onPressed: () {
                  controller.resolveConflicts(SyncConflictChoice.newerWins);
                  onResolved();
                },
              ),
            ActionChip(
              label: Text(l10n.syncResolveKeepLeft),
              onPressed: () {
                controller.resolveConflicts(SyncConflictChoice.keepLeft);
                onResolved();
              },
            ),
            ActionChip(
              label: Text(l10n.syncResolveKeepRight),
              onPressed: () {
                controller.resolveConflicts(SyncConflictChoice.keepRight);
                onResolved();
              },
            ),
            ActionChip(
              label: Text(l10n.syncResolveSkipAll),
              onPressed: () {
                controller.resolveConflicts(SyncConflictChoice.skip);
                onResolved();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The bottom action bar (§7): favorite, retry/restore/report
/// affordances, run controls, and the consequence-labeled Run button.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.controller,
    required this.l10n,
    required this.onRun,
    required this.onRetry,
    required this.onRestore,
    this.onSaveAsFavorite,
  });

  final SyncPlanController controller;
  final AppLocalizations l10n;
  final VoidCallback onRun;
  final VoidCallback onRetry;
  final VoidCallback onRestore;
  final VoidCallback? onSaveAsFavorite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = controller.stats;
    return Material(
      elevation: 2,
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // §7's action-bar order: Copy as rsync Command · Save as
            // Favorite… · the Run cluster — the first two render the
            // registered commands (D21).
            TextButton.icon(
              icon: const Icon(Icons.terminal, size: 16),
              label: Text(l10n.syncCopyRsyncCommand),
              onPressed: controller.canExportRsync
                  ? () => unawaited(copyRsyncCommand(context, controller))
                  : null,
            ),
            if (controller.lastRun != null)
              TextButton.icon(
                icon: const Icon(Icons.summarize_outlined, size: 16),
                label: Text(l10n.syncCopyReport),
                onPressed: () => unawaited(
                  Clipboard.setData(
                    ClipboardData(
                      text: syncReportText(l10n, controller),
                    ),
                  ),
                ),
              ),
            TextButton.icon(
              icon: const Icon(Icons.star_outline, size: 16),
              label: Text(l10n.syncSaveAsFavorite),
              onPressed: onSaveAsFavorite,
            ),
            // Wrap can't host a Spacer — the gap keeps the run cluster
            // visually separate from the left-hand affordances.
            const SizedBox(width: 24),
            if (controller.canRetryFailed)
              TextButton.icon(
                icon: const Icon(Icons.replay, size: 16),
                label: Text(l10n.syncRetryFailed),
                onPressed: onRetry,
              ),
            if (controller.canRestore)
              TextButton.icon(
                icon: const Icon(Icons.restore_from_trash, size: 16),
                label: Text(l10n.syncRestoreTrashed),
                onPressed: onRestore,
              ),
            // §10's run controls — the activity panel exposes the same
            // verbs through the task row; the view mirrors them here so
            // a run is steerable without leaving the tab.
            if (controller.isRunning) ...[
              TextButton.icon(
                icon: Icon(
                  controller.isPaused ? Icons.play_arrow : Icons.pause,
                  size: 16,
                ),
                label: Text(
                  controller.isPaused ? l10n.syncResume : l10n.syncPause,
                ),
                onPressed: () =>
                    controller.setPaused(!controller.isPaused),
              ),
              TextButton.icon(
                icon: const Icon(Icons.stop, size: 16),
                label: Text(l10n.syncCancel),
                onPressed: controller.cancelRun,
              ),
            ],
            FilledButton.icon(
              icon: controller.isRunning
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow, size: 18),
              label: Text(_runLabel(l10n, stats)),
              onPressed: _runEnabled ? onRun : null,
            ),
          ],
        ),
      ),
    );
  }

  bool get _runEnabled =>
      !controller.isRunning &&
      controller.phase == SyncPlanPhase.ready &&
      controller.refusal == null &&
      (controller.stats?.hasWork ?? false) &&
      (controller.stats?.conflicts ?? 0) == 0;

  /// The Run button's consequence label (§7): "Copy N · Delete M" —
  /// the same figures the header spells out, compressed.
  String _runLabel(AppLocalizations l10n, SyncEffectiveStats? stats) {
    if (controller.isRunning) return l10n.syncCancel;
    if (stats == null || !stats.hasWork) return l10n.syncRunNothingToDo;
    final parts = <String>[
      for (final side in SyncSide.values) ...[
        if (stats.newFilesTo(side) + stats.updatesTo(side) > 0)
          l10n.syncRunCopyPart(
            stats.newFilesTo(side) + stats.updatesTo(side),
          ),
        if (stats.foldersTo(side) > 0)
          l10n.syncRunCreateFolders(stats.foldersTo(side)),
        if (stats.deletesOn(side) + (stats.replacedBySide[side] ?? 0) > 0)
          l10n.syncRunDeletePart(
            stats.deletesOn(side) + (stats.replacedBySide[side] ?? 0),
          ),
      ],
    ];
    return parts.isEmpty ? l10n.syncRunNothingToDo : parts.join(' · ');
  }
}

/// The post-run report's clipboard text (05 §7's "Copy Report"): one
/// line per executed item — path, action, outcome, error — followed by
/// the done/failed/skipped roll-up.
String syncReportText(
  AppLocalizations l10n,
  SyncPlanController controller,
) {
  final run = controller.lastRun;
  if (run == null) return '';
  final buffer = StringBuffer();
  for (final item in run.plan.items) {
    if (item.status == SyncItemStatus.pending) continue;
    buffer.writeln(
      '${item.relativePath}\t${item.effective.name}\t'
      '${item.status.name}${item.error != null ? '\t${item.error}' : ''}',
    );
  }
  var done = 0;
  var failed = 0;
  var skipped = 0;
  for (final item in run.plan.items) {
    switch (item.status) {
      case SyncItemStatus.done:
        done++;
      case SyncItemStatus.failed || SyncItemStatus.conflicted:
        failed++;
      case SyncItemStatus.skipped:
        skipped++;
      default:
        break;
    }
  }
  buffer.writeln('—');
  buffer.writeln(l10n.syncSummaryCounts(done, failed, skipped));
  return buffer.toString();
}
