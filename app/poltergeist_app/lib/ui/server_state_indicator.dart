import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import 'probe_status_dot.dart';

/// What the one composed server indicator paints (02 §4: exactly one
/// indicator per server — SEA-021).
enum ServerIndicatorGlyph {
  /// Neither truth exists: paint nothing.
  none,

  /// Probe truth only: delegate to [ProbeStatusDot].
  probe,

  /// A connect or recovery attempt is running.
  pending,

  /// Authenticated transports exist.
  connected,

  /// No transport and no failure the state explains.
  idle,

  /// No transport and a failure one-liner.
  failed,

  /// Host-key block (D18): every operation fails until an explicit review.
  blocked,
}

/// One server's resolved indicator: the glyph to paint plus its ARB label.
/// Tooltip, semantics, and list copy all read this same pair, so a state can
/// never be announced with wording its glyph contradicts.
typedef ServerIndicatorAppearance = ({
  ServerIndicatorGlyph glyph,
  String label,
});

/// Resolves the single indicator a server renders.
///
/// [status] is live connection truth (`EngineClient.watchServer`), [probe]
/// reachability truth. Adverse connection truth — a block or a failure the
/// state explains — outranks the probe result: a probe reports only that
/// host:port answered a TCP connect, so a green "reachable" dot beside a
/// blocked panel contradicts the connection it sits next to (02 §4 — "live
/// truth outranks probes"). Where the two truths do not contradict, 02 §4's
/// tri-state probe dot stays the favorite row's indicator, which is what
/// 07 §3.3 requires the interim list to render.
ServerIndicatorAppearance serverIndicatorOf(
  AppLocalizations l10n, {
  ServerStatus? status,
  ProbeStatus? probe,
}) {
  final connection = status == null
      ? null
      : _connectionAppearance(l10n, status);
  if (connection != null && _outranksProbe(connection.glyph, probe)) {
    return connection;
  }

  final reachability = probe == null ? null : _probeAppearance(l10n, probe);
  if (reachability != null) return reachability;

  return connection ?? (glyph: ServerIndicatorGlyph.none, label: '');
}

/// The glyphs that contradict a probe result and therefore replace it:
/// adverse truth (a block, a failure the state explains) always, and
/// authenticated transports over any non-online result — the reverse of
/// the audit finding's contradiction, since connected transports prove
/// reachability (an "unknown" claim beside them is just as wrong).
bool _outranksProbe(ServerIndicatorGlyph glyph, ProbeStatus? probe) =>
    switch (glyph) {
      ServerIndicatorGlyph.blocked || ServerIndicatorGlyph.failed => true,
      ServerIndicatorGlyph.connected => probe != ProbeStatus.online,
      _ => false,
    };

/// A `detail` on the status means the state explains a failure (03 §3.2);
/// cancellation and idle teardown carry none, so `disconnected` splits into
/// [ServerIndicatorGlyph.failed] and [ServerIndicatorGlyph.idle].
ServerIndicatorAppearance _connectionAppearance(
  AppLocalizations l10n,
  ServerStatus status,
) {
  final failed = status.detail != null;
  return switch (status.state) {
    ServerConnectionState.connecting => (
      glyph: ServerIndicatorGlyph.pending,
      label: l10n.connectionStateConnecting,
    ),
    ServerConnectionState.reconnecting => (
      glyph: ServerIndicatorGlyph.pending,
      label: l10n.connectionStateReconnecting,
    ),
    ServerConnectionState.connected => (
      glyph: ServerIndicatorGlyph.connected,
      label: l10n.connectionStateConnected,
    ),
    ServerConnectionState.disconnected =>
      failed
          ? (
              glyph: ServerIndicatorGlyph.failed,
              label: l10n.connectionFailedTitle,
            )
          : (
              glyph: ServerIndicatorGlyph.idle,
              label: l10n.connectionStateNotConnected,
            ),
    ServerConnectionState.blocked => (
      glyph: ServerIndicatorGlyph.blocked,
      label: l10n.connectionBlockedTitle,
    ),
  };
}

ServerIndicatorAppearance _probeAppearance(
  AppLocalizations l10n,
  ProbeStatus probe,
) {
  return switch (probe) {
    ProbeStatus.online => (
      glyph: ServerIndicatorGlyph.probe,
      label: l10n.probeStatusOnline,
    ),
    ProbeStatus.offline => (
      glyph: ServerIndicatorGlyph.probe,
      label: l10n.probeStatusOffline,
    ),
    ProbeStatus.unknown => (
      glyph: ServerIndicatorGlyph.probe,
      label: l10n.probeStatusUnknown,
    ),
  };
}

/// The labeled composed indicator for a server, resolved by
/// [serverIndicatorOf]: the probe dot while no connection truth outranks
/// it, else the connection glyph, else nothing.
///
/// Used where the indicator is the row's only state wording (the interim
/// list's app bar; M5's sidebar badge corner). A list that renders the state
/// as text uses [ServerStateGlyph] instead, so the label is announced once.
class ServerStateIndicator extends StatelessWidget {
  const ServerStateIndicator({required this.status, this.probe, super.key});

  /// Live connection truth; null when no engine reports this server.
  final ServerStatus? status;

  /// Reachability truth; rendered while [status] is null or its resolved
  /// glyph does not outrank it (see [serverIndicatorOf]).
  final ProbeStatus? probe;

  @override
  Widget build(BuildContext context) {
    final appearance = serverIndicatorOf(
      AppLocalizations.of(context),
      status: status,
      probe: probe,
    );

    // The probe dot owns its own tooltip and semantics: wrapping it would
    // announce the same state twice.
    final probeStatus = probe;
    if (appearance.glyph == ServerIndicatorGlyph.probe && probeStatus != null) {
      return ProbeStatusDot(probeStatus);
    }
    if (appearance.glyph == ServerIndicatorGlyph.none) {
      return const SizedBox.shrink();
    }

    return Tooltip(
      message: appearance.label,
      excludeFromSemantics: true,
      child: Semantics(
        label: appearance.label,
        container: true,
        child: ServerStateGlyph(appearance.glyph),
      ),
    );
  }
}

/// The composed indicator's paint, without a label: for rows that render the
/// state as text beside it.
class ServerStateGlyph extends StatelessWidget {
  const ServerStateGlyph(this.glyph, {super.key});

  /// The dot diameter [ProbeStatusDot] paints, so one server's indicator is
  /// the same size whichever truth produced it.
  static const dotSize = ProbeStatusDot.dotSize;

  /// The padded box [ProbeStatusDot] keeps its dot in: a 10 px paint alone is
  /// not a practical hover or touch target.
  static const boxSize = ProbeStatusDot.boxSize;

  final ServerIndicatorGlyph glyph;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: Center(
        child: switch (glyph) {
          ServerIndicatorGlyph.none ||
          ServerIndicatorGlyph.probe => const SizedBox.shrink(),
          ServerIndicatorGlyph.pending => SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.primary,
            ),
          ),
          // The same green the probe dot uses: one "connected" color per app.
          ServerIndicatorGlyph.connected => _dot(ProbeStatusDot.onlineColor),
          ServerIndicatorGlyph.idle => _dot(scheme.outline),
          ServerIndicatorGlyph.failed => _dot(scheme.error),
          ServerIndicatorGlyph.blocked => Icon(
            Icons.gpp_bad,
            size: 14,
            color: scheme.error,
          ),
        },
      ),
    );
  }

  static Widget _dot(Color color) => Container(
    width: dotSize,
    height: dotSize,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
