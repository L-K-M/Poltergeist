import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/sync_browsing_controller.dart';

/// The suspended chip's cause copy (02 §7): '"foo" missing on right' or
/// 'outside the anchor subtree' — the two named causes worded as a
/// state, never a bare side word. The re-visibility and diverged cases
/// carry the plain suspended line.
String syncBrowseCauseText(AppLocalizations l10n, SyncBrowseCause cause) {
  return switch (cause.kind) {
    SyncBrowseSuspension.mirrorMissing => l10n.syncBrowsingSuspendedMissing(
      cause.missingName ?? '',
      (cause.missingOnLeftPane ?? false)
          ? l10n.syncBrowsingSideLeft
          : l10n.syncBrowsingSideRight,
    ),
    SyncBrowseSuspension.outsideAnchor =>
      l10n.syncBrowsingSuspendedOutside,
    SyncBrowseSuspension.pairNotVisible ||
    SyncBrowseSuspension.diverged => l10n.syncBrowsingSuspended,
  };
}

/// 02 §7's link chip, shared by both path bars and the global status
/// bar: the quiet linked state while the pair replays, the amber
/// link-broken chip while suspended. Amber is the theme's server-amber —
/// one warning family, not a new hue. The chip reads the link state
/// itself, so callers mount it unconditionally while the link is
/// enabled.
class SyncBrowseChip extends StatelessWidget {
  const SyncBrowseChip({super.key, required this.link});

  /// The workspace's Sync Browsing link.
  final SyncBrowsingController link;

  @override
  Widget build(BuildContext context) {
    // Self-listening: the path bars merge the link into their pane
    // listenable, but the status bar mounts this bare — suspension
    // transitions must repaint it wherever it stands.
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final cause = link.cause;
    final suspended = cause != null;
    const amber = Color(0xFFD9A404); // ServerColor.amber — the warning family.
    final label = suspended
        ? syncBrowseCauseText(l10n, cause)
        : l10n.syncBrowsingChip;
    final foreground = suspended ? amber : colors.onSecondaryContainer;

    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: 7,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: suspended
              ? amber.withValues(alpha: 0.16)
              : colors.secondaryContainer,
          borderRadius: BorderRadius.circular(10),
          border: suspended ? Border.all(color: amber) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              suspended ? Icons.link_off : Icons.link,
              size: 13,
              color: foreground,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: suspended ? colors.onSurface : foreground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
