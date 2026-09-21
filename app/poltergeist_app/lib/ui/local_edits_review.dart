import 'dart:async';

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/checkout_session.dart';

/// 06 §3.7's resume surface: while a bound server's managed checkouts
/// hold dirty or missing local edits, every pane bound to that server
/// carries this persistent banner — a relaunch must not silently bury
/// an edit that never uploaded. `Review…` opens
/// [LocalEditsReviewDialog]. The toast in the shell covers the
/// just-saved edge; this banner covers the previous session's.
class LocalEditsBanner extends StatelessWidget {
  const LocalEditsBanner({
    super.key,
    required this.session,
    required this.serverId,
    required this.onReview,
  });

  /// The managed-checkout truth the count reads — the banner rebuilds
  /// on every record change (a clean upload drops it on the spot).
  final CheckoutSession session;

  /// The server this pane is bound to — checkout ownership is
  /// per-server (D17), never per pane.
  final String serverId;

  /// Opens the §3.7 review dialog — the shell owns the modal.
  final VoidCallback onReview;

  /// The §3.7 trigger: this server's live copies holding a dirty or
  /// missing local edit. Displaced records keep their slot's edit but
  /// read through [CheckoutSession.displacedFor] — the dialog lists
  /// them; the banner's trigger stays the spec's dirty-or-missing.
  static int localEditCount(CheckoutSession session, String serverId) {
    var count = 0;
    for (final record in session.copiesFor(serverId).values) {
      if (record.dirty || record.missing) count++;
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final count = localEditCount(session, serverId);
        if (count == 0) return const SizedBox.shrink();
        final l10n = AppLocalizations.of(context);
        final colors = Theme.of(context).colorScheme;
        return Semantics(
          // Same announcement posture as the pane notice strip: a
          // persistent banner must not interrupt on every reconcile.
          liveRegion: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border(bottom: BorderSide(color: colors.outlineVariant)),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 8, 6),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: ExcludeSemantics(
                      child: Icon(
                        Icons.edit_note,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      l10n.checkoutLocalEditsBanner(count),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('localEdits.review'),
                    onPressed: onReview,
                    child: Text(l10n.checkoutLocalEditsReview),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Opens the §3.7 review dialog for [serverId] — the banner's
/// `Review…`, the remotePath favorite's `Local Edits…`, both land here.
Future<void> showLocalEditsReview(
  BuildContext context, {
  required CheckoutSession session,
  required String serverId,
  required String serverLabel,
  required bool Function() connected,
  required Listenable? connections,
  required Future<void> Function(ManagedRemoteFile record) onOpen,
  required Future<void> Function(ManagedRemoteFile record) onUpload,
  required Future<void> Function(ManagedRemoteFile record) onDiscard,
  required Future<void> Function(RecoveredCheckout recovered, String name)
  onOpenRecovered,
  required Future<void> Function(RecoveredCheckout recovered, String name)
  onDiscardRecovered,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => LocalEditsReviewDialog(
    session: session,
    serverId: serverId,
    serverLabel: serverLabel,
    connected: connected,
    connections: connections,
    onOpen: onOpen,
    onUpload: onUpload,
    onDiscard: onDiscard,
    onOpenRecovered: onOpenRecovered,
    onDiscardRecovered: onDiscardRecovered,
  ),
);

/// 06 §3.7's review dialog: the server's dirty, missing, and displaced
/// records (the remote path each was checked out from, plus per-row
/// `Open` / `Upload` / `Discard…`), then the preserved recovered
/// payloads (file rows with `Open` / `Discard…` only — a recordless
/// payload has no upload lane). `Upload` is disabled while the server
/// is disconnected; every row stays reachable offline.
class LocalEditsReviewDialog extends StatefulWidget {
  const LocalEditsReviewDialog({
    super.key,
    required this.session,
    required this.serverId,
    required this.serverLabel,
    required this.connected,
    required this.connections,
    required this.onOpen,
    required this.onUpload,
    required this.onDiscard,
    required this.onOpenRecovered,
    required this.onDiscardRecovered,
  });

  final CheckoutSession session;
  final String serverId;
  final String serverLabel;

  /// Live connection truth for the Upload gate — read per build so a
  /// mid-dialog drop disables in place.
  final bool Function() connected;

  /// The connection-state listenable that re-reads [connected]; null
  /// leaves the gate reading once per session notification.
  final Listenable? connections;

  /// The shell's open/upload/discard lanes — the dialog never touches
  /// the store or the queue directly.
  final Future<void> Function(ManagedRemoteFile record) onOpen;
  final Future<void> Function(ManagedRemoteFile record) onUpload;
  final Future<void> Function(ManagedRemoteFile record) onDiscard;

  /// Recovered payload rows: [onOpenRecovered] opens the file, and
  /// [onDiscardRecovered] drops just that file (external editors leave
  /// siblings beside the plaintext — the dir survives until its last
  /// file goes).
  final Future<void> Function(RecoveredCheckout recovered, String name)
  onOpenRecovered;
  final Future<void> Function(RecoveredCheckout recovered, String name)
  onDiscardRecovered;

  @override
  State<LocalEditsReviewDialog> createState() => _LocalEditsReviewDialogState();
}

class _LocalEditsReviewDialogState extends State<LocalEditsReviewDialog> {
  // Recovered payloads read through the store's serialized index —
  // refreshed on every session/connection notification (a record's
  // discard can preserve its payload as a recovered row, and a
  // connection flip re-gates Upload). Awaited rather than stored as a
  // Future: an errored refetch outliving an unmounted FutureBuilder
  // would surface as an unhandled async error. The generation counter
  // drops stale completions — overlapping fetches must never let an
  // older listing overwrite a newer one.
  List<RecoveredCheckout>? _recovered;
  bool _recoveredLoaded = false;
  int _reloadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
    widget.session.addListener(_onChange);
    widget.connections?.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onChange);
    widget.connections?.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) unawaited(_reload());
  }

  Future<void> _reload() async {
    final generation = ++_reloadGeneration;
    try {
      final next = await widget.session.recoveredCheckouts();
      if (!mounted || generation != _reloadGeneration) return;
      setState(() {
        _recovered = next;
        _recoveredLoaded = true;
      });
    } on Object {
      // A teardown-time notification can race the store's close — the
      // dialog dies with the shell; keep the last listing. Never mark
      // loaded without one: a failed first fetch must not render the
      // "no local edits" empty state while payloads may exist.
    }
  }

  Future<void> _confirmAndRun(
    BuildContext context,
    String title,
    Future<void> Function() action,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (confirmContext) => AlertDialog(
        title: Text(title),
        content: Text(l10n.checkoutLocalEditsDiscardBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(confirmContext).pop(false),
            child: Text(l10n.checkoutLocalEditsDiscardCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(confirmContext).pop(true),
            child: Text(l10n.checkoutLocalEditsDiscardConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await action();
    } on Object {
      // The shell lanes own their error surface (report + toast); this
      // guard keeps a rejecting lane from escaping a fire-and-forget
      // onPressed closure as an unhandled async error.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.checkoutLocalEditsTitle(widget.serverLabel)),
      content: SizedBox(
        width: 480,
        child: Builder(
          builder: (context) {
            final records =
                widget.session
                    .copiesFor(widget.serverId)
                    .values
                    .where((r) => r.dirty || r.missing)
                    .toList()
                  ..sort((a, b) => a.remotePath.compareTo(b.remotePath));
            final displaced = widget.session.displacedFor(widget.serverId)
              ..sort((a, b) => a.remotePath.compareTo(b.remotePath));
            final isConnected = widget.connected();
            final recovered = _recovered ?? const <RecoveredCheckout>[];
            if (records.isEmpty &&
                displaced.isEmpty &&
                recovered.isEmpty &&
                _recoveredLoaded) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(l10n.checkoutLocalEditsEmpty),
              );
            }
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final record in records)
                    _RecordRow(
                      key: ValueKey('localEdits.record.${record.id}'),
                      record: record,
                      connected: isConnected,
                      onOpen: widget.onOpen,
                      onUpload: widget.onUpload,
                      onDiscard: (record) => _confirmAndRun(
                        context,
                        l10n.checkoutLocalEditsDiscardTitle,
                        () => widget.onDiscard(record),
                      ),
                    ),
                  for (final record in displaced)
                    _RecordRow(
                      key: ValueKey('localEdits.record.${record.id}'),
                      record: record,
                      connected: isConnected,
                      recovered: true,
                      onOpen: widget.onOpen,
                      onUpload: widget.onUpload,
                      onDiscard: (record) => _confirmAndRun(
                        context,
                        l10n.checkoutLocalEditsDiscardTitle,
                        () => widget.onDiscard(record),
                      ),
                    ),
                  if (recovered.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 4),
                      child: Text(
                        l10n.checkoutLocalEditsRecoveredSection,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    // 06 §3.7's pinned copy — a recordless payload
                    // has no checkout lane to ride.
                    Text(
                      l10n.checkoutLocalEditsRecoveredHint,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    for (final entry in recovered)
                      for (final name in entry.files)
                        _RecoveredRow(
                          key: ValueKey(
                            'localEdits.recovered.${entry.directory}/$name',
                          ),
                          name: name,
                          onOpen: () => widget.onOpenRecovered(entry, name),
                          onDiscard: () => _confirmAndRun(
                            context,
                            l10n.checkoutLocalEditsDiscardTitle,
                            () => widget.onDiscardRecovered(entry, name),
                          ),
                        ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.checkoutLocalEditsClose),
        ),
      ],
    );
  }
}

/// One managed-copy row: remote path plus the honest state badge
/// (Modified locally / Local file missing / Recovered), then the row's
/// verbs. `Upload` disables with a tooltip while the server is
/// disconnected (06 §3.7's "Connect to upload"); Open and Discard…
/// stay reachable offline — both are purely local.
class _RecordRow extends StatelessWidget {
  const _RecordRow({
    super.key,
    required this.record,
    required this.connected,
    required this.onOpen,
    required this.onUpload,
    required this.onDiscard,
    this.recovered = false,
  });

  final ManagedRemoteFile record;
  final bool connected;

  /// §3.5's displaced record — listed marked Recovered, still
  /// uploadable toward its original remotePath under CAS.
  final bool recovered;
  final Future<void> Function(ManagedRemoteFile record) onOpen;
  final Future<void> Function(ManagedRemoteFile record) onUpload;
  final Future<void> Function(ManagedRemoteFile record) onDiscard;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final badge = recovered
        ? l10n.checkoutLocalEditsRecoveredRecord
        : record.missing
        ? l10n.checkoutLocalEditsMissing
        : record.dirty
        ? l10n.checkoutLocalEditsDirty
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(remoteBasename(record.remotePath)),
                    Text(
                      record.remotePath,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (badge != null)
                Text(
                  badge,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          Row(
            children: [
              TextButton(
                onPressed: () => onOpen(record),
                child: Text(l10n.checkoutLocalEditsOpen),
              ),
              if (connected)
                TextButton(
                  onPressed: () => onUpload(record),
                  child: Text(l10n.checkoutLocalEditsUpload),
                )
              else
                Tooltip(
                  message: l10n.checkoutLocalEditsConnectToUpload,
                  child: TextButton(
                    onPressed: null,
                    child: Text(l10n.checkoutLocalEditsUpload),
                  ),
                ),
              TextButton(
                onPressed: () => onDiscard(record),
                child: Text(l10n.checkoutLocalEditsDiscard),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One recovered-payload row: the file's name with Open / Discard…
/// only — no Upload verb exists for a recordless payload (06 §3.7).
class _RecoveredRow extends StatelessWidget {
  const _RecoveredRow({
    super.key,
    required this.name,
    required this.onOpen,
    required this.onDiscard,
  });

  final String name;
  final Future<void> Function() onOpen;
  final Future<void> Function() onDiscard;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(name)),
          TextButton(
            onPressed: () => onOpen(),
            child: Text(l10n.checkoutLocalEditsOpen),
          ),
          TextButton(
            onPressed: () => onDiscard(),
            child: Text(l10n.checkoutLocalEditsDiscard),
          ),
        ],
      ),
    );
  }
}
