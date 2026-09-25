import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/activity_panel_controller.dart';
import '../../theme/app_theme.dart';
import '../server_label_scope.dart';
import 'activity_format.dart';

/// The History tab (02 §6): the queue's persisted, capped history —
/// newest first — behind a filter field, with Clear History in the
/// strip. A row's lines ellipsize to the inspector's width; the log stays
/// copyable verbatim through the row's context menu, which copies the
/// whole record, the part the ellipsis hides included.
class ActivityHistoryView extends StatefulWidget {
  const ActivityHistoryView({super.key, required this.controller});

  final ActivityPanelController controller;

  @override
  State<ActivityHistoryView> createState() => _ActivityHistoryViewState();
}

class _ActivityHistoryViewState extends State<ActivityHistoryView> {
  final _filter = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  bool _matches(TransferHistoryEntry entry, String query) {
    if (query.isEmpty) return true;
    final haystack = [
      ...entry.rootPaths,
      entry.destinationDir,
      entry.error ?? '',
      switch (entry.destination) {
        ServerFsLocation(:final serverId) => serverId,
        _ => '',
      },
      switch (entry.source) {
        ServerFsLocation(:final serverId) => serverId,
        _ => '',
      },
    ].join('\n').toLowerCase();
    return haystack.contains(query);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = PoltergeistChrome.of(context);
    // The header filter's capsule (D32 §4), at the size Clear History's
    // label reads at (labelLarge and bodyMedium are both 13 px on desktop).
    final fieldText = theme.textTheme.bodyMedium;
    final history = widget.controller.history;
    final query = _query;
    final rows = [
      for (final entry in history.reversed)
        if (_matches(entry, query)) entry,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 10, 4),
          // On one baseline: the hint and Clear History read as one line
          // whatever the font's metrics do inside the field's capsule.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: SizedBox(
                  height: 28,
                  child: TextField(
                    key: const ValueKey('history.filter'),
                    controller: _filter,
                    style: fieldText,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: chrome.capsuleFill,
                      hintText: l10n.activityHistoryFilter,
                      hintStyle: fieldText?.copyWith(
                        color: chrome.secondaryText,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 6,
                      ),
                      prefixIcon: Icon(
                        Icons.search,
                        size: 16,
                        color: chrome.secondaryText,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 28,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(7),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (value) =>
                        setState(() => _query = value.toLowerCase()),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('history.clear'),
                onPressed:
                    history.isEmpty ? null : widget.controller.clearHistory,
                child: Text(l10n.activityHistoryClear),
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(child: Text(l10n.activityHistoryEmpty))
              : ListView.builder(
                  key: const ValueKey('history.list'),
                  itemCount: rows.length,
                  itemBuilder: (context, index) =>
                      _HistoryRow(entry: rows[index]),
                ),
        ),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry});

  final TransferHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final localeName = Localizations.localeOf(context).toString();
    final time = DateFormat.yMd(localeName)
        .add_jm()
        .format(entry.finishedAt.toLocal());
    final verb = switch (entry.operation) {
      TransferOperation.copy => l10n.historyVerbCopy,
      TransferOperation.move => l10n.historyVerbMove,
      TransferOperation.delete => l10n.historyVerbDelete,
    };
    final outcome = switch (entry.outcome) {
      TransferTaskState.completed => l10n.transferStateCompleted,
      TransferTaskState.cancelled => l10n.transferStateCancelled,
      _ => l10n.transferStateFailed,
    };
    final serverLabel = ServerLabelScope.maybeOf(context);
    final route =
        '${transferEndpointLabel(entry.source, localLabel: l10n.activityTaskRouteLocal, serverLabel: serverLabel)}'
        ' → '
        '${transferEndpointLabel(entry.destination, localLabel: l10n.activityTaskRouteLocal, serverLabel: serverLabel)}'
        ':${entry.destinationDir}';
    final names = entry.rootPaths.map(pathBasename).join(', ');
    final title = '$time · $verb · $names';
    final details =
        '$route · $outcome'
        '${entry.error == null ? '' : ' · ${entry.error}'}';
    // Right-click (long-press on touch) copies the record whole: its
    // lines ellipsize, so a selection could never reach what they hide.
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          key: ValueKey('history.copy.${entry.taskId}'),
          leadingIcon: const Icon(Icons.copy_outlined, size: 16),
          onPressed: () => unawaited(
            Clipboard.setData(ClipboardData(text: '$title\n$details')),
          ),
          child: Text(l10n.activityHistoryCopy),
        ),
      ],
      builder: (context, menu, child) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (tap) => menu.open(position: tap.localPosition),
        onLongPressStart: (press) =>
            menu.open(position: press.localPosition),
        child: child,
      ),
      child: _content(context, title, details, colors),
    );
  }

  Widget _content(
    BuildContext context,
    String title,
    String details,
    ColorScheme colors,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The hover shows what the ellipsis hides.
          Tooltip(
            message: title,
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          Text(
            details,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: entry.outcome == TransferTaskState.failed
                  ? colors.error
                  : colors.onSurfaceVariant,
            ),
          ),
          const Divider(height: 8),
        ],
      ),
    );
  }
}
