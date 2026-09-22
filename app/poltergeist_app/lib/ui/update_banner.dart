// The D19 update banner (00 D19/D23, 07 §3.10) — ported from Séance's
// server_list_pane _UpdateBanner: a dismissible strip above the
// workspace that names the newer tag and links out to the releases
// page. The link is the whole affordance — the app never downloads,
// verifies, or installs a release (D23).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';

/// The default "View release" launch: the releases URL to the OS
/// browser as an external application. Injectable so tests can observe
/// the hand-off without the platform channel.
Future<bool> _launchReleasePage(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// The dismissible "newer release exists" strip the workspace shell
/// mounts when [UpdateCheckController.update] is non-null.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    required this.info,
    required this.onDismiss,
    this.launch,
    super.key,
  });

  final UpdateInfo info;

  /// Session dismiss — the next launch re-checks.
  final VoidCallback onDismiss;

  /// How the releases page opens; defaults to url_launcher's external-
  /// browser hand-off.
  final Future<bool> Function(Uri uri)? launch;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              Icons.system_update_outlined,
              size: 20,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.updateBannerText(info.latestVersion),
                style: TextStyle(color: scheme.onSecondaryContainer),
              ),
            ),
            TextButton(
              key: const ValueKey('update.viewRelease'),
              onPressed: () =>
                  unawaited((launch ?? _launchReleasePage)(info.releasesUrl)),
              child: Text(l10n.updateViewRelease),
            ),
            IconButton(
              key: const ValueKey('update.dismiss'),
              tooltip: l10n.updateDismissTooltip,
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
