import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/theme/app_theme.dart';

import 'contrast_math.dart';

/// 02 §13's contrast floor as an explicit foreground × surface token
/// matrix per theme — including the composite surfaces the widgets
/// actually paint (selected rows, badges, banners, tooltips), kept in
/// lockstep with the widget inventory: a new tinted surface joining the
/// app gets a row here, or a bare token-set check could never see it.
const _minimumTextContrast = 4.5;

void main() {
  for (final brightness in Brightness.values) {
    group('${brightness.name} theme', () {
      final theme = buildPoltergeistTheme(brightness);
      final scheme = theme.colorScheme;
      final chrome = theme.extension<PoltergeistChrome>()!;

      test('text tokens stay ≥ 4.5:1 on their surfaces', () {
        final pairs = <(String, Color, Color)>[
          // Body text on the listing surface.
          ('body on surface', scheme.onSurface, scheme.surface),
          // Secondary captions (subtitles, hints, empty states).
          ('caption on surface', scheme.onSurfaceVariant, scheme.surface),
          // Selected/hover rows paint surfaceContainerHighest.
          (
            'body on selected row',
            scheme.onSurface,
            scheme.surfaceContainerHighest,
          ),
          (
            'caption on selected row',
            scheme.onSurfaceVariant,
            scheme.surfaceContainerHighest,
          ),
          // Filled buttons (Quick Connect's Connect, dialog actions).
          ('filled button', scheme.onPrimary, scheme.primary),
          // Badge chips (favorite accents, sync chips).
          ('primary badge', scheme.onPrimaryContainer, scheme.primaryContainer),
          (
            'secondary badge',
            scheme.onSecondaryContainer,
            scheme.secondaryContainer,
          ),
          // Error banners and import/error surfaces.
          ('error banner', scheme.onErrorContainer, scheme.errorContainer),
          ('error text', scheme.error, scheme.surface),
          (
            'error text on selected row',
            scheme.error,
            scheme.surfaceContainerHighest,
          ),
          // Tooltips paint the inverse surface pair.
          ('tooltip', scheme.onInverseSurface, scheme.inverseSurface),
          // D32 §6: the active pane's selected rows (name and caption
          // columns both paint on-accent) and the linked sync chip.
          (
            'text on active selection',
            chrome.onSelection,
            chrome.selectionFill,
          ),
          (
            'caption on inactive selection',
            chrome.secondaryText,
            chrome.inactiveSelectionFill,
          ),
          ('caption on capsule', chrome.secondaryText, chrome.capsuleFill),
          // The sync plan's selected row in the focused table: its action
          // glyph (a character) and a failure's reason paint on-accent,
          // not in their tones — those fall to about 1:1 on the fill.
          (
            'sync plan glyph and reason on active selection',
            chrome.onSelection,
            chrome.selectionFill,
          ),
          // D32 §8's menu rows: the shortcut hint on the menu panel.
          (
            'menu shortcut hint',
            chrome.secondaryText,
            scheme.surfaceContainer,
          ),
        ];
        for (final (name, fg, bg) in pairs) {
          expect(
            contrast(fg, bg),
            greaterThanOrEqualTo(_minimumTextContrast),
            reason: '$name (${brightness.name})',
          );
        }
      });

      test('non-text tokens stay ≥ 3:1 on their surfaces', () {
        final pairs = <(String, Color, Color)>[
          // The §13 2 px focus outline, on resting and selected rows.
          ('focus ring on surface', scheme.primary, scheme.surface),
          (
            'focus ring on selected row',
            scheme.primary,
            scheme.surfaceContainerHighest,
          ),
          // Icons and the unknown-state dot.
          ('icon on surface', scheme.onSurfaceVariant, scheme.surface),
          (
            'icon on selected row',
            scheme.onSurfaceVariant,
            scheme.surfaceContainerHighest,
          ),
          // outlineVariant's hairline divider is deliberately exempt:
          // WCAG 1.4.11's floor covers meaningful indicators, not
          // decorative separators — D11's quiet chrome stays quiet.
          // The unknown-dot/semantic `outline` IS meaningful, so it is
          // pinned instead.
          ('outline', scheme.outline, scheme.surface),
          // D32 §6's kind-glyph tints on the listing surface.
          ('folder glyph', scheme.primary, chrome.paneBackground),
          ('image/media glyph', scheme.tertiary, chrome.paneBackground),
          ('archive glyph', scheme.secondary, chrome.paneBackground),
          ('pdf glyph', scheme.error, chrome.paneBackground),
          ('generic glyph', chrome.secondaryText, chrome.paneBackground),
          // The sync plan's status marks and override dot on a selected
          // row in the focused table (on-accent, as the glyph above).
          (
            'sync plan status marks on active selection',
            chrome.onSelection,
            chrome.selectionFill,
          ),
          // The active pane's 2 px marker against the strip it underlines.
          (
            'active pane line',
            chrome.activePaneIndicator,
            chrome.headerBackground,
          ),
          // theme.disabledColor (the dimmed glyph/text on inactive rows)
          // is deliberately exempt: WCAG exempts inactive UI components
          // from the contrast floor, and §13's readable element on a
          // disabled row is the reason line — pinned as error text at
          // 4.5:1 above.
        ];
        for (final (name, fg, bg) in pairs) {
          expect(
            contrast(fg, bg),
            greaterThanOrEqualTo(minimumNonTextContrast),
            reason: '$name (${brightness.name})',
          );
        }
      });

      test('sidebar status dots stay ≥ 3:1 on every row state', () {
        // D32 §5: the 7 px dot composed into a row's mark sits on the
        // rail at rest, on the 6 % hover fill, and on the selection
        // pill of the row the active pane shows — the pill is where a
        // single green once fell below the floor.
        final rail = chrome.sidebarBackground;
        final rowStates = <(String, Color)>[
          ('rail', rail),
          ('hover', Color.alphaBlend(chrome.hoverFill, rail)),
          ('pill', Color.alphaBlend(chrome.inactiveSelectionFill, rail)),
        ];
        final dots = <(String, Color)>[
          ('connected', chrome.statusConnected),
          ('connecting', chrome.statusConnecting),
          ('failed', scheme.error),
        ];
        for (final (dot, color) in dots) {
          for (final (state, surface) in rowStates) {
            expect(
              contrast(color, surface),
              greaterThanOrEqualTo(minimumNonTextContrast),
              reason: '$dot dot on $state (${brightness.name})',
            );
          }
        }
      });
    });
  }
}
