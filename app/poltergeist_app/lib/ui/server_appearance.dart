// Ported from Séance app/seance_app/lib/ui/server_appearance.dart @ 2e6d1f1; see docs/PORTS.md.
import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// How a [ServerColor] and [ServerIcon] become pixels.
///
/// The protocol stores *names* (see `ServerColor`'s own doc for why), and this
/// is the only place that turns them into colors and glyphs. Keeping the
/// mapping in one file means a new accent is a seed plus an enum value, and
/// nothing else in the app has to learn about it.

/// The seed each accent is generated from. These are hues, not final colors —
/// what actually gets painted is derived per brightness below.
const Map<ServerColor, Color> _seeds = {
  // The app's own violet, so "no strong opinion, just tag it" lands on
  // something that already belongs to Poltergeist.
  ServerColor.violet: Color(0xFF6B5BD2),
  ServerColor.blue: Color(0xFF2F6FED),
  ServerColor.cyan: Color(0xFF00A3C4),
  ServerColor.teal: Color(0xFF12897E),
  ServerColor.green: Color(0xFF2F9E44),
  ServerColor.amber: Color(0xFFD9A404),
  ServerColor.orange: Color(0xFFE8590C),
  ServerColor.red: Color(0xFFE03131),
  ServerColor.pink: Color(0xFFD6336C),
  ServerColor.slate: Color(0xFF64748B),
};

/// The three colors an accent is drawn with: a [container] to fill, an
/// [onContainer] that is legible on it, and a saturated [line] for rules and
/// borders where a fill would be too much.
class ServerAccent {
  final Color container;
  final Color onContainer;
  final Color line;

  const ServerAccent({
    required this.container,
    required this.onContainer,
    required this.line,
  });
}

/// Derived accents, memoized per (color, brightness).
///
/// The derivation is `ColorScheme.fromSeed` — the same machinery the app
/// theme is built with, so an accent is tonally a Poltergeist color rather
/// than a raw hue dropped on top of one. That machinery is not free (it is
/// real HCT math), and these are read once per server per build of the
/// strip, so the twenty possible results are computed once and kept. The
/// map is bounded by the enum: it cannot grow.
final Map<(ServerColor, Brightness), ServerAccent> _accents = {};

/// The accent for [color] under the current theme brightness, or null when the
/// server has no color and should be drawn neutrally.
ServerAccent? serverAccent(BuildContext context, ServerColor? color) {
  if (color == null) return null;
  final brightness = Theme.of(context).brightness;
  return _accents.putIfAbsent((color, brightness), () {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seeds[color]!,
      brightness: brightness,
    );
    return ServerAccent(
      container: scheme.primaryContainer,
      onContainer: scheme.onPrimaryContainer,
      line: scheme.primary,
    );
  });
}

/// The glyph for [icon]. Every value is a const [IconData] reached through a
/// switch rather than a lookup on a stored codepoint — see `ServerIcon`'s doc
/// for why that distinction survives into the release build.
IconData serverIconData(ServerIcon? icon) => switch (icon) {
  ServerIcon.server || null => Icons.dns_outlined,
  ServerIcon.cloud => Icons.cloud_outlined,
  ServerIcon.database => Icons.storage_outlined,
  ServerIcon.web => Icons.language,
  ServerIcon.terminal => Icons.terminal,
  ServerIcon.shield => Icons.shield_outlined,
  ServerIcon.home => Icons.home_outlined,
  ServerIcon.work => Icons.work_outline,
  ServerIcon.lab => Icons.science_outlined,
  ServerIcon.device => Icons.developer_board,
  ServerIcon.router => Icons.router_outlined,
  ServerIcon.mail => Icons.mail_outline,
  ServerIcon.container => Icons.inventory_2_outlined,
  ServerIcon.rocket => Icons.rocket_launch_outlined,
  ServerIcon.star => Icons.star_outline,
  ServerIcon.bug => Icons.bug_report_outlined,
};

/// A server's icon on its accent: the mark that says *which* box a row is.
///
/// Takes the two values rather than a whole server record so a caller can
/// preview a color and icon before there is a record to preview them on.
class ServerBadge extends StatelessWidget {
  final ServerColor? color;
  final ServerIcon? icon;
  final double size;

  const ServerBadge({
    super.key,
    required this.color,
    required this.icon,
    this.size = 32,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = serverAccent(context, color);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        // No accent: the neutral surface tone, so an untagged server still
        // lines up with a tagged one instead of leaving a hole where the badge
        // would be.
        color: accent?.container ?? scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(
        serverIconData(icon),
        size: size * 0.56,
        color: accent?.onContainer ?? scheme.onSurfaceVariant,
      ),
    );
  }
}
