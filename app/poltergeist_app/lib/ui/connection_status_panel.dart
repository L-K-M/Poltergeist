// Adapted from Séance app/seance_app/lib/ui/terminal_pane.dart @ a9add15
// (the connecting view, the failed view, and _ConnectionLogView); see
// docs/PORTS.md. Divergence: driven by the engine protocol's streams (03
// §5) instead of an app-side session object, strings localize through ARB
// (D20), and states cover the pool's full lifecycle (reconnecting, blocked).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';

/// Mirrors the per-attempt transcript bound (seance_core's
/// `SshConnectionLog` and the engine-side coalescer both cap at 400).
const _maxLines = 400;

/// One server's connection surface (07 §3.3): the live state — spinner while
/// connecting or reconnecting, the failure one-liner and the transcript on a
/// dead connection, the block reason under a changed-key block — plus the
/// live `SshConnectionLog` transcript, which renders during connect and
/// stays visible on failure.
///
/// Listens only to the streams it is given (split-notifier rule, 09 §3.4):
/// transcript batches arrive coalesced to ≤ 30/s per server (03 §5), so this
/// widget repaints itself, never an ancestor.
class ConnectionStatusPanel extends StatefulWidget {
  const ConnectionStatusPanel({
    required this.serverId,
    required this.states,
    required this.log,
    this.onRetry,
    super.key,
  });

  final String serverId;

  /// `EngineClient.watchServer(serverId)` — current value first.
  final Stream<ServerStatus> states;

  /// `EngineClient.connectionLog`, filtered by this panel to [serverId].
  final Stream<ConnectionLogEvent> log;

  /// Optional manual reconnect affordance for dead states; absent while no
  /// composition can trigger one.
  final VoidCallback? onRetry;

  @override
  State<ConnectionStatusPanel> createState() => _ConnectionStatusPanelState();
}

class _ConnectionStatusPanelState extends State<ConnectionStatusPanel> {
  // Connecting until the first status arrives: a panel mounted during a
  // connect flow must not flash the failure view first.
  ServerStatus _status = const ServerStatus(ServerConnectionState.connecting);
  final List<String> _lines = [];
  StreamSubscription<ServerStatus>? _states;
  StreamSubscription<ConnectionLogEvent>? _log;
  int _statesGeneration = 0;
  int _logGeneration = 0;

  @override
  void initState() {
    super.initState();
    _listenToStates();
    _listenToLog();
  }

  @override
  void didUpdateWidget(ConnectionStatusPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final serverChanged = widget.serverId != oldWidget.serverId;

    // A replacement server starts honest and empty until its current-state
    // event arrives; stale status and transcript belong to the old server.
    if (serverChanged) {
      _status = const ServerStatus(ServerConnectionState.connecting);
      _lines.clear();
    }
    if (widget.states != oldWidget.states || serverChanged) {
      _statesGeneration++;
      unawaited(_states?.cancel());
      _listenToStates();
    }
    if (widget.log != oldWidget.log || serverChanged) {
      _logGeneration++;
      unawaited(_log?.cancel());
      _listenToLog();
    }
  }

  void _listenToStates() {
    final generation = ++_statesGeneration;
    _states = widget.states.listen((status) {
      if (!mounted || generation != _statesGeneration) return;
      setState(() => _status = status);
    });
  }

  void _listenToLog() {
    final generation = ++_logGeneration;
    _log = widget.log.listen((event) {
      if (!mounted ||
          generation != _logGeneration ||
          event.serverId != widget.serverId) {
        return;
      }

      setState(() {
        _lines.addAll(event.lines);
        if (_lines.length > _maxLines) {
          _lines.removeRange(0, _lines.length - _maxLines);
        }
      });
    });
  }

  @override
  void dispose() {
    _statesGeneration++;
    _logGeneration++;
    unawaited(_states?.cancel());
    unawaited(_log?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return switch (_status.state) {
      ServerConnectionState.connecting ||
      ServerConnectionState.reconnecting => _pending(context),
      ServerConnectionState.connected => const SizedBox.shrink(),
      ServerConnectionState.disconnected => _dead(context),
      ServerConnectionState.blocked => _blocked(context),
    };
  }

  Widget _pending(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _status.state == ServerConnectionState.reconnecting
                  ? l10n.connectionStateReconnecting
                  : l10n.connectionStateConnecting,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _ConnectionLogView(
              lines: List.unmodifiable(_lines),
              onCopied: _copyLog,
            ),
          ],
        ),
      ),
    );
  }

  Widget _dead(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final detail = _status.detail;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.power_off_outlined, size: 40),
            const SizedBox(height: 12),
            Text(
              l10n.connectionFailedTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(detail, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 16),
            _retryButton(context, l10n),
            const SizedBox(height: 12),
            // The transcript stays visible on failure with the summarized
            // one-liner above it (07 §3.3).
            _ConnectionLogView(
              lines: List.unmodifiable(_lines),
              onCopied: _copyLog,
            ),
          ],
        ),
      ),
    );
  }

  Widget _blocked(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final detail = _status.detail;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.gpp_bad, size: 40, color: scheme.error),
            const SizedBox(height: 12),
            Text(
              l10n.connectionBlockedTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Text(detail, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 12),
            _ConnectionLogView(
              lines: List.unmodifiable(_lines),
              onCopied: _copyLog,
            ),
          ],
        ),
      ),
    );
  }

  Widget _retryButton(BuildContext context, AppLocalizations l10n) {
    final onRetry = widget.onRetry;
    if (onRetry == null) return const SizedBox.shrink();
    return FilledButton.icon(
      onPressed: onRetry,
      icon: const Icon(Icons.refresh),
      label: Text(l10n.connectionRetry),
    );
  }

  Future<void> _copyLog() async {
    await Clipboard.setData(ClipboardData(text: _lines.join('\n')));
  }
}

/// A collapsible view of the raw connection transcript, with a copy button.
class _ConnectionLogView extends StatelessWidget {
  final List<String> lines;
  final Future<void> Function() onCopied;

  const _ConnectionLogView({required this.lines, required this.onCopied});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final text = lines.join('\n');

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(l10n.connectionLogTitle),
        childrenPadding: EdgeInsets.zero,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: text.isEmpty ? null : () => onCopied(),
              icon: const Icon(Icons.copy, size: 16),
              label: Text(l10n.connectionLogCopy),
            ),
          ),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 260),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              reverse: true,
              child: SelectableText(
                text.isEmpty ? l10n.connectionLogEmpty : text,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
