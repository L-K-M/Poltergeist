import 'dart:async';

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/connection_status_controller.dart';
import '../server_state_indicator.dart';

/// No engine reported this server. The app then holds no transport for it,
/// which is exactly what `disconnected` means (03 §3.2: "never connected,
/// torn down, or connect failed"), and no failure is known — so the row reads
/// "not connected" instead of inventing a fourth state.
const _noLiveConnection = ServerStatus(ServerConnectionState.disconnected);

/// The Connections surface (02 §4): the servers the app holds references to,
/// each with its live pool state, the state's failure one-liner, and per-pane
/// attribution where the recovery lane carries it.
///
/// Interim route. M5 renders the same rows as the sidebar's Connections
/// section with its context menu (Disconnect, Open in other pane); nothing
/// here owns a sidebar layout.
class ConnectionsView extends StatefulWidget {
  const ConnectionsView(
    this.controller, {
    this.onReviewBlocked,
    this.onOpenInPane,
    super.key,
  });

  final ConnectionStatusController controller;

  /// Leads a blocked server to the changed-key review, which the pool raises
  /// through the existing prompt path at the next connect attempt (D18: the
  /// block ends only at an explicit review or a restored pinned key).
  ///
  /// Null where no composition can start a connect yet; the blocked row then
  /// carries the warning copy alone, which names that path.
  final void Function(ConnectionServer server)? onReviewBlocked;

  /// Opens the row's bookmark in the active pane (the M3 window's remote
  /// entry point: the interim list stays until M5's sidebar). Null leaves
  /// the rows without the affordance (no engine, tests).
  final void Function(ConnectionServer server)? onOpenInPane;

  @override
  State<ConnectionsView> createState() => _ConnectionsViewState();
}

class _ConnectionsViewState extends State<ConnectionsView> {
  @override
  void initState() {
    super.initState();
    // Fresh store truth per open; the controller drops a superseded load on
    // its generation counter, so a slow read cannot land over a newer one.
    unawaited(widget.controller.loadServers());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.connectionsTitle)),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) => _body(context, l10n),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    final controller = widget.controller;

    return switch (controller.load) {
      ConnectionListLoad.idle ||
      ConnectionListLoad.loading => _loading(context, l10n),
      ConnectionListLoad.failed => _failed(context, l10n),
      ConnectionListLoad.ready =>
        controller.servers.isEmpty
            ? _empty(context, l10n)
            : _list(context, controller.servers),
    };
  }

  Widget _loading(BuildContext context, AppLocalizations l10n) {
    return Center(
      child: Semantics(
        label: l10n.connectionsLoading,
        container: true,
        child: const CircularProgressIndicator(),
      ),
    );
  }

  Widget _empty(BuildContext context, AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          l10n.connectionsEmpty,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// A store the app cannot read is reported inline with a retry: the list is
  /// the surface's whole content, so a transient snack bar would leave an
  /// empty page with no way back.
  Widget _failed(BuildContext context, AppLocalizations l10n) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(l10n.connectionsLoadFailed, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('connections-retry'),
              onPressed: () => unawaited(widget.controller.loadServers()),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.connectionRetry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context, List<ConnectionServer> servers) {
    final divider = Divider(
      height: 1,
      color: Theme.of(context).colorScheme.outlineVariant,
    );

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: servers.length,
      separatorBuilder: (_, _) => divider,
      itemBuilder: (context, index) => _ConnectionRow(
        server: servers[index],
        onReviewBlocked: widget.onReviewBlocked,
        onOpenInPane: widget.onOpenInPane,
      ),
    );
  }
}

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({
    required this.server,
    required this.onReviewBlocked,
    this.onOpenInPane,
  });

  final ConnectionServer server;
  final void Function(ConnectionServer server)? onReviewBlocked;
  final void Function(ConnectionServer server)? onOpenInPane;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // The section shows pool state, not probe state (02 §4), so the row
    // resolves its indicator from connection truth alone.
    final appearance = serverIndicatorOf(
      l10n,
      status: server.status ?? _noLiveConnection,
    );
    final detail = server.status?.detail;
    final paneFailure = server.paneFailure;
    final blocked = appearance.glyph == ServerIndicatorGlyph.blocked;

    return Padding(
      key: ValueKey('connection.${server.serverId}'),
      padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ServerStateGlyph(appearance.glyph),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(server.label, style: text.titleSmall),
                Text(
                  '${server.username}@${server.host}:${server.port}',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (detail != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(top: 6),
                    child: Text(
                      detail,
                      style: text.bodySmall?.copyWith(color: scheme.error),
                    ),
                  ),
                if (paneFailure != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(top: 6),
                    child: Text(
                      l10n.connectionsPaneFailure(
                        paneFailure.paneTabId,
                        paneFailure.message,
                      ),
                      style: text.bodySmall?.copyWith(color: scheme.error),
                    ),
                  ),
                if (blocked)
                  _BlockedNotice(server: server, onReview: onReviewBlocked),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(appearance.label, style: text.labelMedium),
          if (onOpenInPane != null) ...[
            const SizedBox(width: 4),
            IconButton(
              key: ValueKey('connection.open.${server.serverId}'),
              tooltip: l10n.connectionsOpenInPane,
              onPressed: () => onOpenInPane?.call(server),
              icon: const Icon(Icons.open_in_new_outlined, size: 18),
            ),
          ],
        ],
      ),
    );
  }
}

/// Why a blocked server is blocked and what leads out of it: the review
/// itself is the existing changed-key dialog, which the pool raises at the
/// next connect attempt (D18 — never auto-repinned, never silently lifted).
class _BlockedNotice extends StatelessWidget {
  const _BlockedNotice({required this.server, required this.onReview});

  final ConnectionServer server;
  final void Function(ConnectionServer server)? onReview;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final review = onReview;

    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.connectionsBlockedWarning,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.error),
                ),
              ),
            ],
          ),
          // Without a connect composition there is no review to offer: the
          // warning above names the path instead of a button that cannot
          // start one (the panel's optional retry is the same posture).
          if (review != null)
            TextButton.icon(
              key: ValueKey('connection.review.${server.serverId}'),
              onPressed: () => review(server),
              icon: const Icon(Icons.key_outlined, size: 18),
              label: Text(l10n.connectionsReviewHostKey),
            ),
        ],
      ),
    );
  }
}
