// Ported from Séance app/seance_app/test/theme_build_test.dart @ e77bb33; see docs/PORTS.md.
// Divergences: the default is compared with the whole ThemeData the app
// built before themes (legacy_theme.dart), not a list of key colours; the
// status colours are the chrome's; and the error colours are pinned to the
// tables.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_appearance.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/theme/theme_palette.dart';
import 'package:poltergeist_app/theme/theme_presets.dart';
import 'package:poltergeist_app/ui/probe_status_dot.dart';
import 'package:poltergeist_app/ui/server_state_indicator.dart';
import 'package:poltergeist_core/poltergeist_core.dart' show ProbeStatus;

import 'legacy_theme.dart';

const _platforms = [
  TargetPlatform.macOS,
  TargetPlatform.linux,
  TargetPlatform.windows,
  TargetPlatform.android,
  TargetPlatform.iOS,
];

Map<String, Object> _chromeValues(PoltergeistChrome c) => {
  'sidebarBackground': c.sidebarBackground,
  'headerBackground': c.headerBackground,
  'paneBackground': c.paneBackground,
  'inspectorBackground': c.inspectorBackground,
  'separator': c.separator,
  'hoverFill': c.hoverFill,
  'capsuleFill': c.capsuleFill,
  'selectionFill': c.selectionFill,
  'onSelection': c.onSelection,
  'inactiveSelectionFill': c.inactiveSelectionFill,
  'activePaneIndicator': c.activePaneIndicator,
  'secondaryText': c.secondaryText,
  'statusConnected': c.statusConnected,
  'statusConnecting': c.statusConnecting,
  'headerHeight': c.headerHeight,
  'rowExtent': c.rowExtent,
  'sidebarRowExtent': c.sidebarRowExtent,
};

void main() {
  group('the default palette draws what the app always drew', () {
    for (final platform in _platforms) {
      for (final brightness in Brightness.values) {
        test('${brightness.name} on ${platform.name}', () {
          final theme = buildPoltergeistTheme(brightness, platform: platform);
          final legacy = legacyTheme(brightness, platform: platform);

          // Everything ThemeData compares: the scheme, the type ramp,
          // density, and every component theme, the shapes included.
          expect(theme.copyWith(extensions: const []), legacy);

          final chrome = theme.extension<PoltergeistChrome>()!;
          expect(_chromeValues(chrome), legacyChrome(brightness, platform));
          // The dots that painted the scheme's colours paint them still.
          expect(chrome.statusFailed, legacy.colorScheme.error);
          expect(chrome.statusUnknown, legacy.colorScheme.outline);
          expect(chrome.cornerScale, 1);
        });
      }
    }

    test('with the host platform too', () {
      for (final brightness in Brightness.values) {
        expect(
          buildPoltergeistTheme(brightness).copyWith(extensions: const []),
          legacyTheme(brightness),
        );
      }
    });

    test('the MaterialApp gets both, following the system', () {
      final themes = poltergeistThemesFor(AppAppearance.initial);
      expect(themes.themeMode, ThemeMode.system);
      expect(
        themes.theme.copyWith(extensions: const []),
        legacyTheme(Brightness.light),
      );
      expect(
        themes.darkTheme.copyWith(extensions: const []),
        legacyTheme(Brightness.dark),
      );
    });

    testWidgets('a chrome looked up without one is the default\'s', (
      tester,
    ) async {
      // PoltergeistChrome.of's fallback, for a harness whose theme carries
      // no extension.
      final built = buildPoltergeistTheme(
        Brightness.dark,
        platform: TargetPlatform.linux,
      ).extension<PoltergeistChrome>()!;
      late PoltergeistChrome looked;
      await tester.pumpWidget(
        Theme(
          data: ThemeData(
            brightness: Brightness.dark,
            platform: TargetPlatform.linux,
          ),
          child: Builder(
            builder: (context) {
              looked = PoltergeistChrome.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(_chromeValues(looked), _chromeValues(built));
      expect(looked.statusFailed, built.statusFailed);
      expect(looked.statusUnknown, built.statusUnknown);
    });
  });

  group('a palette lands where it says', () {
    test('every slot reaches the scheme and the chrome', () {
      final palette = ThemePalette(
        accent: const Color(0xFF2266CC),
        surface: const Color(0xFF101418),
        sidebar: const Color(0xFF0C1014),
        raised: const Color(0xFF182028),
        text: const Color(0xFFEEF2F6),
        secondaryText: const Color(0xFFA0A8B0),
        hairline: const Color(0x40FFFFFF),
        selection: const Color(0xFF1B4F8F),
        online: const Color(0xFF00E676),
        offline: const Color(0xFFFF5252),
        connecting: const Color(0xFFFFD740),
        unknown: const Color(0xFF90A4AE),
      );
      final theme = buildPoltergeistThemeFor(palette, Brightness.light);
      final scheme = theme.colorScheme;
      final chrome = theme.extension<PoltergeistChrome>()!;

      // A dark surface of its own makes the theme dark, whatever was asked.
      expect(theme.brightness, Brightness.dark);
      expect(scheme.primary, palette.accent);
      expect(scheme.onPrimary, const Color(0xFFFFFFFF));
      expect(scheme.surface, palette.surface);
      expect(theme.scaffoldBackgroundColor, palette.surface);
      expect(chrome.paneBackground, palette.surface);
      expect(scheme.surfaceContainerLow, palette.sidebar);
      expect(chrome.sidebarBackground, palette.sidebar);
      expect(chrome.inspectorBackground, palette.sidebar);
      expect(scheme.surfaceContainer, palette.raised);
      expect(chrome.headerBackground, palette.raised);
      expect(scheme.onSurface, palette.text);
      expect(scheme.onSurfaceVariant, palette.secondaryText);
      expect(chrome.secondaryText, palette.secondaryText);
      expect(scheme.outlineVariant, palette.hairline);
      expect(chrome.separator, palette.hairline);
      expect(theme.dividerColor, palette.hairline);
      expect(chrome.selectionFill, palette.selection);
      expect(chrome.onSelection, const Color(0xFFFFFFFF));
      expect(chrome.activePaneIndicator, palette.accent);
      expect(chrome.statusConnected, palette.online);
      expect(chrome.statusFailed, palette.offline);
      expect(chrome.statusConnecting, palette.connecting);
      expect(chrome.statusUnknown, palette.unknown);
      expect(theme.textTheme.bodyMedium?.color, palette.text);
      // A status colour is not the error colour: error text and banners
      // keep the table's red, and its text contrast floor.
      final table = buildPoltergeistTheme(Brightness.dark).colorScheme;
      expect(scheme.error, table.error);
      expect(scheme.errorContainer, table.errorContainer);
      expect(scheme.onErrorContainer, table.onErrorContainer);
    });

    test('Automatic shades follow a surface of its own, in order', () {
      final palette = ThemePalette(
        accent: const Color(0xFF8C5729),
        surface: const Color(0xFFFAF5E8),
        text: const Color(0xFF29241C),
      );
      final scheme = buildPoltergeistThemeFor(
        palette,
        Brightness.dark,
      ).colorScheme;
      expect(scheme.brightness, Brightness.light);
      // Each step further from the surface toward the text.
      double distance(Color c) =>
          (c.computeLuminance() - scheme.surface.computeLuminance()).abs();
      final ladder = [
        scheme.surfaceContainerLow,
        scheme.surfaceContainer,
        scheme.surfaceContainerHigh,
        scheme.surfaceContainerHighest,
      ].map(distance).toList();
      for (var i = 1; i < ladder.length; i++) {
        expect(ladder[i], greaterThan(ladder[i - 1]), reason: 'step $i');
      }
      // Mixed from the palette's own colours, not the slate tables.
      expect(scheme.surfaceContainerLow, isNot(const Color(0xFFF1F2F4)));
      expect(scheme.inverseSurface, palette.text);
      // The unknown dot follows the mixed outline, as it always followed
      // the scheme's.
      final chrome = buildPoltergeistThemeFor(
        palette,
        Brightness.dark,
      ).extension<PoltergeistChrome>()!;
      expect(chrome.statusUnknown, scheme.outline);
    });

    test('a light selection gets a dark label', () {
      final theme = buildPoltergeistThemeFor(
        ThemePresets.highContrast,
        Brightness.light,
      );
      expect(
        theme.extension<PoltergeistChrome>()!.onSelection,
        const Color(0xFF000000),
      );
    });

    test('another accent gets a selection white text reads on', () {
      final chrome = buildPoltergeistThemeFor(
        ThemePresets.initial.copyWith(accent: const Color(0xFF7FD1FF)),
        Brightness.dark,
      ).extension<PoltergeistChrome>()!;
      expect(chrome.onSelection, const Color(0xFFFFFFFF));
      expect(chrome.selectionFill, isNot(const Color(0xFF2F7F6D)));
    });
  });

  group('brightness', () {
    test('a surface decides it; otherwise the mode, then the system', () {
      final automatic = ThemePresets.initial;
      expect(
        resolveBrightness(
          automatic,
          Brightness.dark,
          ThemeModePreference.system,
        ),
        Brightness.dark,
      );
      expect(
        resolveBrightness(
          automatic,
          Brightness.dark,
          ThemeModePreference.light,
        ),
        Brightness.light,
      );
      expect(
        resolveBrightness(
          automatic,
          Brightness.light,
          ThemeModePreference.dark,
        ),
        Brightness.dark,
      );
      expect(
        resolveBrightness(
          ThemePresets.paper,
          Brightness.dark,
          ThemeModePreference.dark,
        ),
        Brightness.light,
      );
      expect(
        resolveBrightness(
          ThemePresets.midnight,
          Brightness.light,
          ThemeModePreference.light,
        ),
        Brightness.dark,
      );
    });

    test('a surface of its own is one theme for the MaterialApp', () {
      final themes = poltergeistThemesFor(
        AppAppearance(
          palette: ThemePresets.midnight,
          mode: ThemeModePreference.light,
        ),
      );
      expect(themes.theme.brightness, Brightness.dark);
      expect(themes.darkTheme.brightness, Brightness.dark);
      expect(themes.theme.colorScheme.surface, ThemePresets.midnight.surface);
    });

    test('the mode picks between the two otherwise', () {
      ThemeMode modeFor(ThemeModePreference mode) => poltergeistThemesFor(
        AppAppearance(palette: ThemePresets.graphite, mode: mode),
      ).themeMode;
      expect(modeFor(ThemeModePreference.system), ThemeMode.system);
      expect(modeFor(ThemeModePreference.light), ThemeMode.light);
      expect(modeFor(ThemeModePreference.dark), ThemeMode.dark);
    });
  });

  group('shape and type', () {
    test('the corner scale reaches the components and the chrome', () {
      final theme = buildPoltergeistThemeFor(
        ThemePresets.initial.copyWith(cornerScale: 0.5),
        Brightness.light,
      );
      expect(
        theme.dialogTheme.shape,
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      );
      expect(
        theme.menuTheme.style?.shape?.resolve({}),
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      );
      expect(
        (theme.tooltipTheme.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(3),
      );
      expect(
        theme.filledButtonTheme.style?.shape?.resolve({}),
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      );
      expect(
        theme.chipTheme.shape,
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      );
      expect(
        theme.bottomSheetTheme.shape,
        const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
      );
      final chrome = theme.extension<PoltergeistChrome>()!;
      expect(chrome.cornerScale, 0.5);
      expect(chrome.corner(6), 3);
    });

    test('square is square', () {
      final theme = buildPoltergeistThemeFor(
        ThemePresets.terminal,
        Brightness.dark,
      );
      expect(
        theme.dialogTheme.shape,
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
      );
    });

    test('the interface font reaches the text theme and tooltips', () {
      final theme = buildPoltergeistThemeFor(
        ThemePresets.initial.withFontFamily('Inter'),
        Brightness.light,
        platform: TargetPlatform.linux,
      );
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Inter');
      expect(theme.textTheme.titleLarge?.fontFamily, 'Inter');
      expect(theme.tooltipTheme.textStyle?.fontFamily, 'Inter');
      expect(theme.dialogTheme.titleTextStyle?.fontFamily, 'Inter');
      // The desktop ramp survives it.
      expect(theme.textTheme.bodyMedium?.fontSize, 13);
      // Code keeps its monospace stack, which names its own family.
      expect(poltergeistMonoTextStyle.fontFamily, 'JetBrains Mono');
    });
  });

  testWidgets('the status dots paint the palette\'s colours', (tester) async {
    final palette = ThemePresets.midnight;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPoltergeistThemeFor(palette, Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Column(
            children: [
              ProbeStatusDot(ProbeStatus.online),
              ProbeStatusDot(ProbeStatus.offline),
              ProbeStatusDot(ProbeStatus.unknown),
              ServerStateGlyph(ServerIndicatorGlyph.failed),
              ServerStateGlyph(ServerIndicatorGlyph.idle),
            ],
          ),
        ),
      ),
    );
    final painted = [
      for (final box in tester.widgetList<Container>(find.byType(Container)))
        if (box.decoration case BoxDecoration(
          shape: BoxShape.circle,
          :final color?,
        ))
          color,
    ];
    expect(painted, [
      palette.online,
      palette.offline,
      palette.unknown,
      palette.offline,
      palette.unknown,
    ]);
  });
}
