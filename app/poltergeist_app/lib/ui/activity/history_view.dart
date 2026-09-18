import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/activity_panel_controller.dart';
import 'activity_format.dart';

/// The History tab (02 §6): the queue's persisted, capped history —
/// newest first — behind a filter field, with Clear History in the
/// strip. Rows are SelectableText: the log is copyable verbatim.
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
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: TextField(
                    key: const ValueKey('history.filter'),
                    controller: _filter,
                    decoration: InputDecoration(
                      hintText: l10n.activityHistoryFilter,
                      isDense: true,
                      border: const OutlineInputBorder(),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 8),
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
    final route =
        '${transferEndpointLabel(entry.source, localLabel: l10n.activityTaskRouteLocal)}'
        ' → '
        '${transferEndpointLabel(entry.destination, localLabel: l10n.activityTaskRouteLocal)}'
        ':${entry.destinationDir}';
    final names = entry.rootPaths.map(pathBasename).join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            '$time · $verb · $names',
            maxLines: 1,
            style: Theme.of(context).textTheme.labelMedium,
          ),
          SelectableText(
            '$route · $outcome'
            '${entry.error == null ? '' : ' · ${entry.error}'}',
            maxLines: 2,
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
