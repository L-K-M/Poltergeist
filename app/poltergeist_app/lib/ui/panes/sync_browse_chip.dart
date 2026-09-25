import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/sync_browsing_controller.dart';
import '../../theme/app_theme.dart';

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

/// Which anchored header's chip is the screen-reader announcer: both
/// anchored panes mount a chip, and a live region on each would read
/// every link change twice. The active pane's chip announces; while the
/// active pane shows none (its visible tab is not anchored), the other
/// pane's chip, then the only one on screen, does.
bool syncChipAnnounces({
  required bool paneActive,
  required bool otherPaneShowsChip,
}) => paneActive || !otherPaneShowsChip;

/// 02 §7's link chip in the location headers (D32 §6): the quiet
/// linked state while the pair replays, the link-broken chip while
/// suspended. Both states paint scheme roles — the capsule neutral for
/// linked, the error container for a broken link that needs the user —
/// so the chip follows the theme instead of carrying its own hue. The
/// chip reads the link state itself, so callers mount it
/// unconditionally while the link is enabled.
class SyncBrowseChip extends StatelessWidget {
  const SyncBrowseChip({
    super.key,
    required this.link,
    this.announce = true,
  });

  /// The workspace's Sync Browsing link.
  final SyncBrowsingController link;

  /// Whether this instance is the screen-reader announcer — both
  /// anchored headers mount a chip while the link is enabled, and only
  /// one may announce a state change.
  final bool announce;

  @override
  Widget build(BuildContext context) {
    // Self-listening: a host that does not merge the link into its own
    // listenable must still repaint on suspension transitions.
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final chrome = PoltergeistChrome.of(context);
    final l10n = AppLocalizations.of(context);
    final cause = link.cause;
    final suspended = cause != null;
    final label = suspended
        ? syncBrowseCauseText(l10n, cause)
        : l10n.syncBrowsingChip;
    final background = suspended ? colors.errorContainer : chrome.capsuleFill;
    final foreground = suspended
        ? colors.onErrorContainer
        : chrome.secondaryText;

    return Semantics(
      container: true,
      liveRegion: announce,
      child: Container(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: 7,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              suspended ? Icons.link_off : Icons.link,
              size: 13,
              color: suspended ? foreground : colors.primary,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
