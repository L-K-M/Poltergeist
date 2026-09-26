// Ported from Séance app/seance_app/test/theme_presets_test.dart @ 8714859; see docs/PORTS.md.
// Divergences: no terminal colours to hold; the selection's label is
// measured over the listing, where Poltergeist paints its active
// selection; the status colours are also held on every row state the
// sidebar's dot sits on, as the contrast matrix holds the default's; and a
// preset with its own surface is shown to draw the same at either system
// brightness, which is why its contrast is checked once.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/theme/family_hues.dart';
import 'package:poltergeist_app/theme/contrast.dart';
import 'package:poltergeist_app/theme/theme_palette.dart';
import 'package:poltergeist_app/theme/theme_presets.dart';

/// WCAG AA for body text, and for non-text marks (the dots, the accent).
const _text = 4.5;
const _mark = 3.0;

/// The shipped themes, held to the thresholds the default neutrals meet.
/// Each preset is checked as it is drawn, through the built theme, at every
/// brightness it can be drawn at: its own surface's, or both for the two
/// that leave the surface Automatic.
void main() {
  test('Poltergeist comes first and changes nothing', () {
    final first = ThemePresets.all.first;
    expect(first, same(ThemePresets.poltergeist));
    expect(first.name, 'Poltergeist');
    expect(first.accent, poltergeistSeedColor);
    for (final slot in ThemeSlot.values) {
      expect(first.slot(slot), isNull, reason: slot.name);
    }
    expect(first.fontFamily, isNull);
    expect(first.cornerScale, 1);
  });

  test('a new device starts in Vapor', () {
    expect(ThemePresets.initial, same(ThemePresets.vapor));
    expect(ThemePresets.all, contains(ThemePresets.initial));
  });

  test('ten presets with unique names, each its own match', () {
    expect(ThemePresets.all, hasLength(10));
    final names = ThemePresets.all.map((p) => p.name).toList();
    expect(names.toSet(), hasLength(names.length));
    expect(names, isNot(contains(ThemePalette.customName)));
    for (final preset in ThemePresets.all) {
      expect(preset.matchingPreset, same(preset), reason: preset.name);
      expect(preset.relabelled(), preset, reason: preset.name);
    }
  });

  test('the shared presets are Séance\'s, by name and in order', () {
    // Séance's list with its own default first; the nine after it must
    // stay the same presets in both apps, so a shared one pastes as itself.
    expect(ThemePresets.all.skip(1).map((p) => p.name), [
      'Graphite',
      'Paper',
      'Newsprint',
      'Solarized',
      'Midnight',
      'Terminal',
      'Vapor',
      'Bubblegum',
      'High contrast',
    ]);
    // Séance moved Bubblegum's accent a shade deeper than Vervellum's.
    expect(ThemePresets.bubblegum.accent, const Color(0xFFE63A91));
  });

  test('every preset with its own surface brings a complete look', () {
    // The default and Graphite leave the surface, and with it every
    // neutral, Automatic; any preset that sets a surface sets them all.
    for (final preset in ThemePresets.all.where((p) => p.surface != null)) {
      for (final slot in ThemeSlot.values) {
        expect(preset.slot(slot), isNotNull, reason: '${preset.name} $slot');
      }
    }
  });

  // Why the contrast below checks a preset with its own surface once: the
  // surface decides the brightness it is drawn at, whatever the system's.
  test('a surface of its own draws the same at either system brightness', () {
    for (final preset in ThemePresets.all.where((p) => p.surface != null)) {
      final light = buildPoltergeistThemeFor(preset, Brightness.light);
      final dark = buildPoltergeistThemeFor(preset, Brightness.dark);
      expect(dark.colorScheme, light.colorScheme, reason: preset.name);
      expect(
        resolvedThemeSlots(preset, Brightness.dark),
        resolvedThemeSlots(preset, Brightness.light),
        reason: preset.name,
      );
      final lightChrome = light.extension<PoltergeistChrome>()!;
      final darkChrome = dark.extension<PoltergeistChrome>()!;
      expect(
        [
          darkChrome.selectionFill,
          darkChrome.onSelection,
          darkChrome.sidebarBackground,
          darkChrome.secondaryText,
        ],
        [
          lightChrome.selectionFill,
          lightChrome.onSelection,
          lightChrome.sidebarBackground,
          lightChrome.secondaryText,
        ],
        reason: preset.name,
      );
    }
  });

  for (final preset in ThemePresets.all) {
    final brightnesses = preset.surface == null
        ? Brightness.values
        : [Brightness.light];
    for (final brightness in brightnesses) {
      final label = preset.surface == null
          ? '${preset.name} (${brightness.name})'
          : preset.name;

      test('$label: text, accent and selection contrast', () {
        final theme = buildPoltergeistThemeFor(preset, brightness);
        final colours = resolvedThemeSlots(preset, brightness);
        final chrome = theme.extension<PoltergeistChrome>()!;
        final surface = colours[ThemeSlot.surface]!;
        final sidebar = colours[ThemeSlot.sidebar]!;

        expect(theme.colorScheme.surface, surface);
        expect(
          contrastRatio(colours[ThemeSlot.text]!, surface),
          greaterThanOrEqualTo(_text),
          reason: 'text on the surface',
        );
        expect(
          contrastRatio(colours[ThemeSlot.text]!, sidebar),
          greaterThanOrEqualTo(_text),
          reason: 'text on the sidebar',
        );
        // Solarized's hierarchy puts secondary text below base0, which is
        // itself only 4.7:1 on base03; the preset documents the exception.
        expect(
          contrastRatio(colours[ThemeSlot.secondaryText]!, surface),
          greaterThanOrEqualTo(
            preset == ThemePresets.solarized ? _mark : _text,
          ),
          reason: 'secondary text on the surface',
        );
        expect(
          contrastRatio(theme.colorScheme.primary, surface),
          greaterThanOrEqualTo(_mark),
          reason: 'the accent as drawn, on the surface',
        );
        final selection = compositeOver(
          chrome.selectionFill,
          chrome.paneBackground,
        );
        expect(
          contrastRatio(chrome.onSelection, selection),
          greaterThanOrEqualTo(_text),
          reason: 'a selected row\'s label on its fill',
        );
      });

      test('$label: four distinct status colours that read', () {
        final theme = buildPoltergeistThemeFor(preset, brightness);
        final chrome = theme.extension<PoltergeistChrome>()!;
        final colours = resolvedThemeSlots(preset, brightness);
        final statuses = [
          colours[ThemeSlot.online]!,
          colours[ThemeSlot.offline]!,
          colours[ThemeSlot.connecting]!,
          colours[ThemeSlot.unknown]!,
        ];
        expect(statuses.toSet(), hasLength(4));
        // What the chrome paints is what the slots say.
        expect([
          chrome.statusConnected,
          chrome.statusFailed,
          chrome.statusConnecting,
          chrome.statusUnknown,
        ], statuses);
        for (final status in statuses) {
          for (final background in [
            colours[ThemeSlot.surface]!,
            colours[ThemeSlot.sidebar]!,
          ]) {
            expect(
              contrastRatio(status, background),
              greaterThanOrEqualTo(_mark),
              reason: '$status on $background',
            );
          }
        }
      });

      test('$label: the sidebar\'s dots read on every row state', () {
        // The contrast matrix's row states for the default theme: a dot
        // sits on the rail at rest, on its hover fill, and on the selected
        // row's pill, and on Home's list and its pill. The unknown colour
        // paints no rail dot (only the probe dot and the idle glyph, on
        // the surface), so it is held above and not here.
        final chrome = buildPoltergeistThemeFor(
          preset,
          brightness,
        ).extension<PoltergeistChrome>()!;
        final rail = chrome.sidebarBackground;
        final home = chrome.paneBackground;
        final rowStates = <(String, Color)>[
          ('rail', rail),
          ('hover', compositeOver(chrome.hoverFill, rail)),
          ('pill', compositeOver(chrome.inactiveSelectionFill, rail)),
          ('home list', home),
          ('home pill', compositeOver(chrome.inactiveSelectionFill, home)),
        ];
        for (final (dot, color) in [
          ('connected', chrome.statusConnected),
          ('connecting', chrome.statusConnecting),
          ('failed', chrome.statusFailed),
        ]) {
          for (final (state, surface) in rowStates) {
            // The one colour under 3:1, measured at 2.80: Solarized's
            // official red on its own selected pill (the rail's and Home's
            // are the same opaque fill). The preset keeps Solarized's red,
            // as Séance's does, and the failed dot is never colour alone (a
            // disc, a ring or a no-entry bar, with its words). Recorded in
            // docs/STATUS.md ("Device themes").
            final exempt =
                preset == ThemePresets.solarized &&
                dot == 'failed' &&
                state.endsWith('pill');
            expect(
              contrastRatio(color, surface),
              greaterThanOrEqualTo(exempt ? 2.8 : _mark),
              reason: '$dot dot on $state',
            );
          }
        }
      });
    }
  }

  // The family hues (lib/theme/family_hues.dart, D34) are tuned against
  // the default neutrals; a preset moves the surfaces they sit on, so
  // every preset is held to the same 3:1 non-text floor for every hue.
  test('the family glyph hues keep 3:1 on every preset', () {
    for (final preset in ThemePresets.all) {
      for (final brightness in Brightness.values) {
        final theme = buildPoltergeistThemeFor(preset, brightness);
        final hues = theme.extension<FamilyPalette>()!;
        final chrome = theme.extension<PoltergeistChrome>()!;
        for (final hue in FamilyHue.values) {
          for (final surface in [
            chrome.paneBackground,
            chrome.sidebarBackground,
            chrome.inspectorBackground,
          ]) {
            expect(
              contrastRatio(hues.glyph(hue), surface),
              greaterThanOrEqualTo(_mark),
              reason: '${preset.name} ${brightness.name} ${hue.name}',
            );
          }
        }
      }
    }
  });
}
