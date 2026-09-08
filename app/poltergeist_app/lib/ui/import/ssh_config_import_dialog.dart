import 'package:flutter/material.dart';

import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';

/// Shows the ssh_config import preview (D22; 07 §3.3): one row per host
/// parsed through the pinned importer, import/skip per row, duplicates
/// (against [existingBookmarks] or earlier rows) starting skipped, and a
/// "won't behave as in ssh" chip per limitation. Returns the imported
/// bookmarks, or null when cancelled — persistence is the caller's
/// (M5's BookmarkStore owns it once the wiring slice composes this).
Future<List<Bookmark>?> showSshConfigImportDialog(
  BuildContext context, {
  required SshConfigImportService service,
  required String configPath,
  List<Bookmark> existingBookmarks = const [],
  DateTime Function() clock = DateTime.now,
}) {
  return showDialog<List<Bookmark>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _SshConfigImportDialog(
      service: service,
      configPath: configPath,
      existingBookmarks: existingBookmarks,
      clock: clock,
    ),
  );
}

class _SshConfigImportDialog extends StatefulWidget {
  const _SshConfigImportDialog({
    required this.service,
    required this.configPath,
    required this.existingBookmarks,
    required this.clock,
  });

  final SshConfigImportService service;
  final String configPath;
  final List<Bookmark> existingBookmarks;
  final DateTime Function() clock;

  @override
  State<_SshConfigImportDialog> createState() => _SshConfigImportDialogState();
}

enum _LoadPhase { loading, ready, failed }

class _SshConfigImportDialogState extends State<_SshConfigImportDialog> {
  _LoadPhase _phase = _LoadPhase.loading;
  SshConfigImportPreview? _preview;
  final Set<String> _selectedRowIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _phase = _LoadPhase.loading);

    SshConfigImportPreview preview;
    try {
      preview = await widget.service.loadPreview(
        configPath: widget.configPath,
        existingBookmarks: widget.existingBookmarks,
      );
    } on SshConfigUnreadableException {
      if (!mounted) return;
      setState(() => _phase = _LoadPhase.failed);
      return;
    } on Exception {
      // An unexpected importer failure shows the retry surface instead
      // of parking on the spinner forever; Errors still crash loudly.
      if (!mounted) return;
      setState(() => _phase = _LoadPhase.failed);
      return;
    }

    // The load window is exactly when dismissal can dispose this dialog;
    // a stale load must not paint after dispose (09 §3.1).
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _phase = _LoadPhase.ready;
      _selectedRowIds
        ..clear()
        ..addAll(
          preview.rows
              .where((row) => row.importByDefault)
              .map((row) => row.id),
        );
    });
  }

  void _toggle(SshConfigImportRow row, bool? value) {
    if (value == null) return;
    setState(() {
      value ? _selectedRowIds.add(row.id) : _selectedRowIds.remove(row.id);
    });
  }

  void _import() {
    final preview = _preview;
    if (preview == null || _selectedRowIds.isEmpty) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;

    final now = widget.clock();
    Navigator.pop(
      context,
      preview.rows
          // The checkbox keeps unimportable rows out of the selection;
          // the filter keeps the commit path from trusting that UI state.
          .where(
            (row) => row.importable && _selectedRowIds.contains(row.id),
          )
          .map((row) => row.toBookmark(now: now))
          .toList(growable: false),
    );
  }

  void _cancel() {
    if (ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.pop(context, null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AlertDialog(
      scrollable: true,
      title: Text(l10n.sshImportTitle),
      content: switch (_phase) {
        _LoadPhase.loading => _buildLoading(l10n),
        _LoadPhase.failed => _buildFailed(l10n),
        _LoadPhase.ready => _buildPreview(context, l10n, _preview!),
      },
      actions: [
        TextButton(onPressed: _cancel, child: Text(l10n.sshImportCancel)),
        if (_phase == _LoadPhase.ready)
          FilledButton(
            onPressed: _selectedRowIds.isEmpty ? null : _import,
            child: Text(
              _selectedRowIds.isEmpty
                  ? l10n.sshImportAction
                  : l10n.sshImportActionCount(_selectedRowIds.length),
            ),
          ),
      ],
    );
  }

  Widget _buildLoading(AppLocalizations l10n) => SizedBox(
    width: 420,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          widget.configPath,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        const SizedBox(height: 16),
        const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ],
    ),
  );

  Widget _buildFailed(AppLocalizations l10n) => SizedBox(
    width: 420,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          widget.configPath,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        const SizedBox(height: 12),
        Text(l10n.sshImportLoadFailed(widget.configPath)),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: _load,
          child: Text(l10n.sshImportRetry),
        ),
      ],
    ),
  );

  Widget _buildPreview(
    BuildContext context,
    AppLocalizations l10n,
    SshConfigImportPreview preview,
  ) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 640,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            widget.configPath,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 12),
          if (preview.rows.isEmpty)
            Text(l10n.sshImportEmpty(widget.configPath))
          else
            // One table: per-row tables would compute column widths
            // independently and misalign every column against the header.
            Table(
              columnWidths: const {
                0: IntrinsicColumnWidth(),
                1: FixedColumnWidth(150),
                2: FlexColumnWidth(),
                3: FixedColumnWidth(100),
                4: FixedColumnWidth(110),
                5: FlexColumnWidth(1.4),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                _headerRow(l10n),
                for (final row in preview.rows) _row(context, l10n, row),
              ],
            ),
          if (preview.notices.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              l10n.sshImportUnresolvedIncludes,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            for (final notice in preview.notices)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  switch (notice.note) {
                    SshConfigIncludeNote.cycle =>
                      l10n.sshImportNoteCycle(notice.path),
                    SshConfigIncludeNote.depthExceeded =>
                      l10n.sshImportNoteDepth(notice.path),
                    SshConfigIncludeNote.unreadable =>
                      l10n.sshImportNoteUnreadable(notice.path),
                  },
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  TableRow _headerRow(AppLocalizations l10n) => TableRow(
    children: [
      _headerCell(l10n.sshImportColumnImport),
      _headerCell(l10n.sshImportColumnHost),
      _headerCell(l10n.sshImportColumnEndpoint),
      _headerCell(l10n.sshImportColumnUser),
      _headerCell(l10n.sshImportColumnAuth),
      _headerCell(l10n.sshImportColumnNotes),
    ],
  );

  Widget _headerCell(String text) => Padding(
    padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
      maxLines: 1,
      overflow: TextOverflow.fade,
    ),
  );

  TableRow _row(
    BuildContext context,
    AppLocalizations l10n,
    SshConfigImportRow row,
  ) {
    final keyPath = row.host.identityFile;

    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: MergeSemantics(
            child: Semantics(
              label: l10n.sshImportRowSemantics(row.host.alias),
              child: Checkbox(
                value: _selectedRowIds.contains(row.id),
                // Rows that can never build a bookmark stay unchecked and
                // inert rather than toggleable-and-doomed.
                onChanged: row.importable
                    ? (value) => _toggle(row, value)
                    : null,
              ),
            ),
          ),
        ),
        _cell(Text(row.host.alias, maxLines: 1, overflow: TextOverflow.ellipsis)),
        _cell(
          SelectableText(
            '${row.host.effectiveHost}:${row.port}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        _cell(Text(row.username, maxLines: 1, overflow: TextOverflow.fade)),
        _cell(
          Text(
            keyPath == null || keyPath.trim().isEmpty
                ? l10n.sshImportAuthPassword
                : l10n.sshImportAuthKey(keyPath),
            style: keyPath == null || keyPath.trim().isEmpty
                ? null
                : const TextStyle(fontFamily: 'monospace', fontSize: 12),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        _cell(_buildNotes(l10n, row)),
      ],
    );
  }

  Widget _cell(Widget child) => Padding(
    padding: const EdgeInsets.only(left: 8, right: 8, top: 4, bottom: 4),
    child: Align(alignment: Alignment.centerLeft, child: child),
  );

  Widget _buildNotes(AppLocalizations l10n, SshConfigImportRow row) {
    final chips = <Widget>[];

    if (row.matchesExistingBookmark) {
      chips.add(_noteChip(l10n, l10n.sshImportDuplicateExisting(
        row.existingBookmarkLabel ?? '',
      )));
    } else if (row.matchesEarlierImportRow) {
      chips.add(
        _noteChip(
          l10n,
          l10n.sshImportDuplicateEarlier(row.earlierImportRowAlias ?? ''),
        ),
      );
    }

    for (final limitation in row.limitations) {
      chips.add(_noteChip(l10n, _limitationText(l10n, limitation)));
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    return Wrap(spacing: 4, runSpacing: 2, children: chips);
  }

  Widget _noteChip(AppLocalizations l10n, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(4),
      color: Theme.of(context).colorScheme.secondaryContainer,
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.onSecondaryContainer,
      ),
    ),
  );

  String _limitationText(
    AppLocalizations l10n,
    SshConfigImportLimitation limitation,
  ) => switch (limitation) {
    SshConfigImportLimitation.proxyJump => l10n.sshImportLimitProxyJump,
    SshConfigImportLimitation.proxyCommand => l10n.sshImportLimitProxyCommand,
    SshConfigImportLimitation.matchBlock => l10n.sshImportLimitMatch,
    SshConfigImportLimitation.hostInclude => l10n.sshImportLimitHostInclude,
    SshConfigImportLimitation.invalidPort => l10n.sshImportLimitInvalidPort,
  };
}
