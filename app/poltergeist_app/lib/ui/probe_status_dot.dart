import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// Tri-state probe dot for the interim server list (02 §4): `unknown`
/// grey, `online` green, `offline` error red. Colors are theme-aware and
/// contrast-checked against both theme surfaces (pinned by tests — the
/// SEA-019 fix), and a theme palette's status colours replace them
/// (the chrome's status fields). Display-only; live connection state
/// renders separately and outranks these results.
class ProbeStatusDot extends StatelessWidget {
  const ProbeStatusDot(this.status, {super.key});

  /// The theme's connected green ([PoltergeistChrome.statusConnected]):
  /// one per palette, so it clears 3:1 on the slate dark and
  /// Finder-light surfaces alike, the sidebar's selection pill included.
  static Color onlineColorOf(BuildContext context) =>
      PoltergeistChrome.of(context).statusConnected;

  /// The dot's painted diameter and the padded box holding it — the one
  /// geometry every server indicator shares ([ServerStateGlyph] references
  /// both), so a server's indicator is the same size whichever truth
  /// produced it.
  static const dotSize = 10.0;
  static const boxSize = 24.0;

  final ProbeStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chrome = PoltergeistChrome.of(context);
    final label = switch (status) {
      ProbeStatus.online => l10n.probeStatusOnline,
      ProbeStatus.offline => l10n.probeStatusOffline,
      ProbeStatus.unknown => l10n.probeStatusUnknown,
    };
    final color = switch (status) {
      ProbeStatus.online => onlineColorOf(context),
      ProbeStatus.offline => chrome.statusFailed,
      ProbeStatus.unknown => chrome.statusUnknown,
    };

    return Tooltip(
      message: label,
      // The Semantics node below is the single screen-reader source; the
      // tooltip stays visual-only (long-press/hover) so the label is not
      // announced twice.
      excludeFromSemantics: true,
      // The padded hit area keeps the hover/long-press tooltip reachable:
      // a 10 px painted dot alone is not a practical touch target.
      child: Semantics(
        label: label,
        container: true,
        child: SizedBox(
          width: boxSize,
          height: boxSize,
          child: Center(
            child: Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}
