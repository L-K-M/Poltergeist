import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';

/// Tri-state probe dot for the interim server list (02 §4): `unknown`
/// grey, `online` green, `offline` error red. Colors are theme-aware and
/// contrast-checked against both theme surfaces (pinned by tests — the
/// SEA-019 fix). Display-only; live connection state renders separately
/// and outranks these results.
class ProbeStatusDot extends StatelessWidget {
  const ProbeStatusDot(this.status, {super.key});

  /// Material green 600: ≥ 3:1 on the seeded light and dark surfaces.
  static const onlineColor = Color(0xFF2E7D32);

  final ProbeStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final label = switch (status) {
      ProbeStatus.online => l10n.probeStatusOnline,
      ProbeStatus.offline => l10n.probeStatusOffline,
      ProbeStatus.unknown => l10n.probeStatusUnknown,
    };
    final color = switch (status) {
      ProbeStatus.online => onlineColor,
      ProbeStatus.offline => scheme.error,
      ProbeStatus.unknown => scheme.outline,
    };

    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        container: true,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
