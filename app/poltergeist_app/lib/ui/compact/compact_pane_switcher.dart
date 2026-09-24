import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/workspace_controller.dart';
import '../../theme/app_theme.dart';
import 'compact_posture.dart';

/// The pane letters in the compact posture: pane A is the left strip on
/// wide windows, pane B the right.
String compactPaneLetter(AppLocalizations l10n, bool leftPane) =>
    leftPane ? l10n.compactPaneLetterA : l10n.compactPaneLetterB;

/// D32 §9's "A · B" pane switcher for the browser's app bar: both
/// letters in one capsule, the showing pane's letter on an accent disc
/// that slides across on a flip. One tap flips to the other pane — the
/// phone keeps both panes (and so Copy/Move to Other Pane) without two
/// columns. The whole capsule is one 48 dp target.
class CompactPaneSwitcher extends StatelessWidget {
  const CompactPaneSwitcher({
    super.key,
    required this.workspace,
    required this.onSwitch,
  });

  final WorkspaceController workspace;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final chrome = PoltergeistChrome.of(context);
    final showingLeft = identical(workspace.activePane, workspace.left);
    final shownName = showingLeft ? l10n.paneAName : l10n.paneBName;
    final otherName = showingLeft ? l10n.paneBName : l10n.paneAName;
    const disc = 28.0;

    Widget letter(bool left) {
      final active = left == showingLeft;
      return SizedBox(
        width: disc,
        height: disc,
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: theme.textTheme.labelLarge!.copyWith(
              color: active ? colors.onPrimary : chrome.secondaryText,
              fontWeight: FontWeight.w700,
            ),
            child: Text(compactPaneLetter(l10n, left)),
          ),
        ),
      );
    }

    return Tooltip(
      message: l10n.compactPaneSwitchTooltip(otherName),
      child: Semantics(
        button: true,
        label: l10n.compactPaneSwitcherSemantics(shownName),
        hint: l10n.compactPaneSwitchTooltip(otherName),
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey(CompactKey.paneSwitcher),
          customBorder: const StadiumBorder(),
          onTap: onSwitch,
          child: SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: ShapeDecoration(
                    color: chrome.capsuleFill,
                    shape: const StadiumBorder(),
                  ),
                  child: Stack(
                    children: [
                      AnimatedPositionedDirectional(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        start: showingLeft ? 0 : disc,
                        top: 0,
                        width: disc,
                        height: disc,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [letter(true), letter(false)],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
