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
  // Séance v0.9.1's widened icon set; glyph choices mirror upstream's
  // app/seance_app/lib/ui/server_appearance.dart.
  ServerIcon.cluster => Icons.hub_outlined,
  ServerIcon.vm => Icons.memory,
  ServerIcon.desktop => Icons.desktop_windows_outlined,
  ServerIcon.laptop => Icons.laptop_outlined,
  ServerIcon.network => Icons.lan_outlined,
  ServerIcon.vpn => Icons.vpn_lock_outlined,
  ServerIcon.files => Icons.folder_outlined,
  ServerIcon.backup => Icons.backup_outlined,
  ServerIcon.archive => Icons.archive_outlined,
  ServerIcon.dataCenter => Icons.warehouse_outlined,
  ServerIcon.satellite => Icons.satellite_alt_outlined,
  ServerIcon.sensor => Icons.sensors_outlined,
  ServerIcon.printer => Icons.print_outlined,
  ServerIcon.power => Icons.power_outlined,
  ServerIcon.api => Icons.api_outlined,
  ServerIcon.dashboard => Icons.dashboard_outlined,
  ServerIcon.monitoring => Icons.monitor_heart_outlined,
  ServerIcon.analytics => Icons.query_stats,
  ServerIcon.chat => Icons.chat_bubble_outline,
  ServerIcon.forum => Icons.forum_outlined,
  ServerIcon.feed => Icons.rss_feed,
  ServerIcon.media => Icons.ondemand_video_outlined,
  ServerIcon.music => Icons.music_note_outlined,
  ServerIcon.photos => Icons.photo_library_outlined,
  ServerIcon.game => Icons.sports_esports_outlined,
  ServerIcon.voice => Icons.phone_in_talk_outlined,
  ServerIcon.camera => Icons.videocam_outlined,
  ServerIcon.shop => Icons.shopping_cart_outlined,
  ServerIcon.billing => Icons.receipt_long_outlined,
  ServerIcon.calendar => Icons.calendar_month_outlined,
  ServerIcon.docs => Icons.description_outlined,
  ServerIcon.wiki => Icons.menu_book_outlined,
  ServerIcon.ai => Icons.psychology_outlined,
  ServerIcon.code => Icons.code,
  ServerIcon.git => Icons.account_tree_outlined,
  ServerIcon.build => Icons.build_outlined,
  ServerIcon.plugin => Icons.extension_outlined,
  ServerIcon.construction => Icons.construction_outlined,
  ServerIcon.speed => Icons.speed,
  ServerIcon.lock => Icons.lock_outline,
  ServerIcon.key => Icons.key_outlined,
  ServerIcon.admin => Icons.admin_panel_settings_outlined,
  ServerIcon.verified => Icons.verified_user_outlined,
  ServerIcon.office => Icons.business_outlined,
  ServerIcon.plant => Icons.factory_outlined,
  ServerIcon.cottage => Icons.cottage_outlined,
  ServerIcon.public => Icons.public_outlined,
  ServerIcon.favourite => Icons.favorite_outline,
  ServerIcon.pets => Icons.pets,
  ServerIcon.coffee => Icons.coffee_outlined,
  ServerIcon.anchor => Icons.anchor,
  ServerIcon.eco => Icons.eco_outlined,
  ServerIcon.bolt => Icons.bolt,
  ServerIcon.hot => Icons.local_fire_department_outlined,
  ServerIcon.frozen => Icons.ac_unit,
  ServerIcon.watch => Icons.visibility_outlined,
  ServerIcon.caution => Icons.warning_amber_outlined,
  ServerIcon.magic => Icons.auto_awesome_outlined,
  ServerIcon.bot => Icons.smart_toy_outlined,
  ServerIcon.layers => Icons.layers_outlined,
  ServerIcon.widgets => Icons.widgets_outlined,
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
