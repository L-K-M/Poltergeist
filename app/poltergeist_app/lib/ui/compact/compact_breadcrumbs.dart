import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/pane_controller.dart';
import '../../services/pane_location.dart';
import '../../theme/app_theme.dart';
import 'compact_posture.dart';

/// The folders from the root down to [path], root first — each paired
/// with its chip label (the root labels itself: `/`, `C:\`).
List<({String label, String path})> compactPathSegments(String path) {
  final chain = <String>[path];
  var walking = path;
  while (true) {
    final parent = paneParentPath(walking);
    if (parent == walking || parent.length >= walking.length) break;
    chain.add(parent);
    walking = parent;
  }
  return [
    for (final segment in chain.reversed)
      (label: paneLastSegment(segment), path: segment),
  ];
}

/// D32 §9's breadcrumb chips: every enclosing folder as a chip in one
/// horizontally scrolling row, the current folder last and filled. A tap
/// navigates there — the phone's replacement for the desktop's ▾
/// ancestor menu. The row keeps the current chip in view as the path
/// changes, so a deep path never hides where the user is.
class CompactBreadcrumbs extends StatefulWidget {
  const CompactBreadcrumbs({super.key, required this.controller});

  final PaneController controller;

  @override
  State<CompactBreadcrumbs> createState() => _CompactBreadcrumbsState();
}

class _CompactBreadcrumbsState extends State<CompactBreadcrumbs> {
  final _scroll = ScrollController();
  String? _shownPath;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls the newest chip into view after a path change.
  void _revealEnd(String? path) {
    if (path == _shownPath) return;
    _shownPath = path;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (_scroll.offset == end) return;
      _scroll.animateTo(
        end,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chrome = PoltergeistChrome.of(context);
    final theme = Theme.of(context);
    final controller = widget.controller;
    final path = controller.location?.path;
    _revealEnd(path);
    if (path == null) return const SizedBox(height: 0);
    final segments = compactPathSegments(path);
    final remote = controller.remoteBookmark;
    return Semantics(
      container: true,
      label: l10n.compactBreadcrumbsLabel,
      child: SizedBox(
        key: const ValueKey(CompactKey.breadcrumbs),
        height: 48,
        child: ListView.separated(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: segments.length,
          separatorBuilder: (context, _) =>
              Icon(Icons.chevron_right, size: 18, color: chrome.secondaryText),
          itemBuilder: (context, index) {
            final segment = segments[index];
            final current = index == segments.length - 1;
            // The root chip names the place, not the slash: the server
            // for a remote pane, the volume glyph for a local one.
            final root = index == 0;
            final label = root && remote != null ? remote.label : segment.label;
            return _Crumb(
              key: ValueKey((CompactKey.breadcrumb, segment.path)),
              label: label,
              icon: root
                  ? (remote != null
                        ? Icons.dns_outlined
                        : Icons.storage_outlined)
                  : null,
              current: current,
              onPressed: current || !controller.verbsEnabled
                  ? null
                  : () => controller.navigate(segment.path),
              theme: theme,
              chrome: chrome,
            );
          },
        ),
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({
    super.key,
    required this.label,
    required this.icon,
    required this.current,
    required this.onPressed,
    required this.theme,
    required this.chrome,
  });

  final String label;
  final IconData? icon;
  final bool current;
  final VoidCallback? onPressed;
  final ThemeData theme;
  final PoltergeistChrome chrome;

  @override
  Widget build(BuildContext context) {
    final colors = theme.colorScheme;
    final foreground = current
        ? colors.onSecondaryContainer
        : chrome.secondaryText;
    // The pill is 32 dp; the ink and the hit target span the row's full
    // 48 dp so a thumb never has to aim at the visual chip.
    return Semantics(
      button: !current,
      selected: current,
      child: SizedBox(
        height: 48,
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed,
          child: Center(
            child: Container(
              height: 32,
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: ShapeDecoration(
                color: current ? colors.secondaryContainer : null,
                shape: const StadiumBorder(),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: foreground),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: current ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
