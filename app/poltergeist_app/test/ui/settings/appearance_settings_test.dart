// Adapted from Séance app/seance_app/test/settings_screen_test.dart's
// Appearance group @ 8714859; see docs/PORTS.md. The section runs over a
// fake model here rather than Séance's fake settings backend, and adds the
// cases Poltergeist's port has of its own: a Séance theme pasted with its
// terminal block, coalesced writes, localized preset names, the font field
// and the phone-sized Settings dialog.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/settings_models.dart';
import 'package:poltergeist_app/theme/app_appearance.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/theme/theme_palette.dart';
import 'package:poltergeist_app/theme/theme_presets.dart';
import 'package:poltergeist_app/ui/settings/appearance_settings.dart';
import 'package:poltergeist_app/ui/settings/general_settings.dart';

/// The Appearance section's model, recording every write. It starts from
/// Poltergeist, the all-Automatic preset, rather than the Vapor a new
/// device starts in: most of these tests are about Automatic colours and
/// the mode they follow.
final class _FakeAppearance extends ChangeNotifier
    implements AppearanceSettingsModel {
  _FakeAppearance([AppAppearance? initial])
    : value = initial ?? AppAppearance(palette: ThemePresets.poltergeist);

  @override
  AppAppearance value;

  /// Every theme written, in order.
  final List<AppAppearance> writes = [];

  /// Thrown by every write while set.
  Object? failWith;

  /// While set, each write waits for it, so a test can hold one in flight.
  Completer<void>? gate;

  @override
  Future<void> setAppearance(
    ThemePalette palette,
    ThemeModePreference mode,
  ) async {
    writes.add(AppAppearance(palette: palette, mode: mode));
    await gate?.future;
    final failure = failWith;
    if (failure != null) throw failure;
    value = AppAppearance(palette: palette, mode: mode);
    notifyListeners();
  }
}

void main() {
  late _FakeAppearance model;
  setUp(() => model = _FakeAppearance());

  ThemePalette lastPalette() => model.writes.last.palette;

  /// Tall enough that the whole section is built at once.
  Future<void> pumpSection(WidgetTester tester, {AppAppearance? start}) async {
    if (start != null) model = _FakeAppearance(start);
    tester.view.physicalSize = const Size(1000, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPoltergeistTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: AppearanceSection(model: model),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder automatic(String label) => find.byWidgetPredicate(
    (w) => w is Checkbox && w.semanticLabel == '$label: Automatic',
  );

  /// What the clipboard holds, as the platform channel answers for it.
  String? clipboard;
  setUp(() => clipboard = null);

  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboard = (call.arguments as Map)['text'] as String?;
          case 'Clipboard.getData':
            return clipboard == null ? null : {'text': clipboard};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  testWidgets('picking a preset writes that preset', (tester) async {
    await pumpSection(tester);
    expect(find.text('Using Poltergeist.'), findsOneWidget);

    await tester.tap(find.byTooltip('Use the Midnight theme'));
    await tester.pumpAndSettle();

    expect(model.writes, [AppAppearance(palette: ThemePresets.midnight)]);
    expect(find.text('Using Midnight.'), findsOneWidget);
    // A surface of its own decides the brightness, so the mode is moot.
    final mode = tester.widget<SegmentedButton<ThemeModePreference>>(
      find.byType(SegmentedButton<ThemeModePreference>),
    );
    expect(mode.onSelectionChanged, isNull);
    expect(find.textContaining('always dark'), findsOneWidget);
  });

  testWidgets('every preset is named from the ARB', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final labels = presetLabels(l10n);
    expect(labels.keys, unorderedEquals(ThemePresets.all));
    // English shows the stored names, which is what makes them safe to
    // store: a translation changes what is shown, never what is written.
    for (final preset in ThemePresets.all) {
      expect(labels[preset], preset.name);
    }
    await pumpSection(tester);
    for (final preset in ThemePresets.all) {
      expect(find.byTooltip('Use the ${preset.name} theme'), findsOneWidget);
    }
  });

  testWidgets('the selected preset says so to a screen reader', (tester) async {
    // Released in `finally`, not by a tear-down: the tester checks for a
    // live handle before tear-downs run.
    final handle = tester.ensureSemantics();
    try {
      await pumpSection(
        tester,
        start: AppAppearance(palette: ThemePresets.paper),
      );

      expect(
        tester.getSemantics(find.byTooltip('Use the Paper theme')),
        matchesSemantics(
          label: 'Paper',
          tooltip: 'Use the Paper theme',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
    } finally {
      handle.dispose();
    }
  });

  testWidgets('the mode writes through while the surface is Automatic', (
    tester,
  ) async {
    await pumpSection(tester);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(model.writes.last.mode, ThemeModePreference.dark);
    expect(lastPalette(), ThemePresets.poltergeist);
  });

  testWidgets('Automatic hands a colour back, and back again restores it', (
    tester,
  ) async {
    await pumpSection(
      tester,
      start: AppAppearance(palette: ThemePresets.paper),
    );

    await tester.tap(automatic('Sidebar'));
    await tester.pumpAndSettle();
    expect(lastPalette().sidebar, isNull);
    expect(lastPalette().name, ThemePalette.customName);
    expect(find.text('Using your own colours.'), findsOneWidget);

    await tester.tap(automatic('Sidebar'));
    await tester.pumpAndSettle();
    expect(lastPalette().sidebar, ThemePresets.paper.sidebar);
    // Back to exactly the preset, it is the preset again.
    expect(lastPalette(), ThemePresets.paper);
  });

  testWidgets('leaving Automatic starts from the colour drawn now', (
    tester,
  ) async {
    await pumpSection(tester);

    await tester.tap(automatic('Text'));
    await tester.pumpAndSettle();

    // The test's platform is light, so Automatic text is the light
    // table's, not black and not the dark table's.
    expect(
      lastPalette().text,
      resolvedThemeSlots(
        ThemePresets.poltergeist,
        Brightness.light,
      )[ThemeSlot.text],
    );
  });

  testWidgets('a swatch opens the picker and writes what it returns', (
    tester,
  ) async {
    await pumpSection(tester);

    await tester.tap(find.byTooltip('Choose the Accent colour'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AlertDialog, 'Accent'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '1e90ff',
    );
    await tester.tap(find.text('Use colour'));
    await tester.pumpAndSettle();

    expect(lastPalette().accent, const Color(0xFF1E90FF));
    expect(lastPalette().name, ThemePalette.customName);
  });

  testWidgets('a status colour is picked like any other', (tester) async {
    await pumpSection(tester);

    await tester.tap(
      find.byTooltip('Choose a Failed or offline colour (now Automatic)'),
    );
    await tester.pumpAndSettle();
    // Opaque: a status colour carries the dots' contrast.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Slider),
      ),
      findsNWidgets(3),
    );
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'cc0000',
    );
    await tester.tap(find.text('Use colour'));
    await tester.pumpAndSettle();

    expect(lastPalette().offline, const Color(0xFFCC0000));
  });

  testWidgets('the lines colour may be translucent', (tester) async {
    await pumpSection(tester);

    await tester.tap(find.byTooltip('Choose a Lines colour (now Automatic)'));
    await tester.pumpAndSettle();
    // Hue, saturation, brightness and opacity.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Slider),
      ),
      findsNWidgets(4),
    );
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '11223380',
    );
    await tester.tap(find.text('Use colour'));
    await tester.pumpAndSettle();

    expect(lastPalette().hairline, const Color(0x80112233));
  });

  testWidgets('the interface font writes on submit, blank for the default', (
    tester,
  ) async {
    await pumpSection(tester);
    final font = find.byKey(const ValueKey('appearance.fontFamily'));

    await tester.enterText(font, '  Inter ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(lastPalette().fontFamily, 'Inter');

    await tester.enterText(font, ' ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(lastPalette().fontFamily, isNull);
    expect(lastPalette(), ThemePresets.poltergeist);
  });

  testWidgets('the corners slider writes the scale', (tester) async {
    await pumpSection(tester);
    final slider = find.byWidgetPredicate(
      (w) => w is Slider && w.max == ThemePalette.maxCornerScale,
    );

    await tester.drag(slider, Offset(-tester.getSize(slider).width, 0));
    await tester.pumpAndSettle();

    expect(lastPalette().cornerScale, 0);
    expect(find.text('Square'), findsWidgets);
  });

  testWidgets('writes coalesce: one in flight, then one of what is current', (
    tester,
  ) async {
    await pumpSection(tester);
    model.gate = Completer<void>();

    await tester.tap(find.byTooltip('Use the Graphite theme'));
    await tester.pump();
    await tester.tap(find.byTooltip('Use the Paper theme'));
    await tester.pump();
    await tester.tap(find.byTooltip('Use the Vapor theme'));
    await tester.pump();
    // Only the first is in flight; the two after it wait as one.
    expect(model.writes.map((w) => w.palette), [ThemePresets.graphite]);

    model.gate!.complete();
    model.gate = null;
    await tester.pumpAndSettle();
    expect(model.writes.map((w) => w.palette), [
      ThemePresets.graphite,
      ThemePresets.vapor,
    ]);
  });

  testWidgets('reset asks first, and keeps the mode', (tester) async {
    await pumpSection(
      tester,
      start: AppAppearance(
        palette: ThemePresets.midnight,
        mode: ThemeModePreference.dark,
      ),
    );

    await tester.tap(find.text('Reset to Vapor'));
    await tester.pumpAndSettle();
    expect(find.text('Reset the theme?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(model.writes, isEmpty);

    await tester.tap(find.text('Reset to Vapor'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await tester.pumpAndSettle();
    expect(model.writes, [
      AppAppearance(
        palette: ThemePresets.initial,
        mode: ThemeModePreference.dark,
      ),
    ]);
  });

  testWidgets('copy puts the theme on the clipboard as JSON', (tester) async {
    mockClipboard(tester);
    await pumpSection(
      tester,
      start: AppAppearance(palette: ThemePresets.solarized),
    );

    await tester.tap(find.text('Copy theme'));
    await tester.pumpAndSettle();

    expect(
      ThemePalette.decodeStored(jsonDecode(clipboard!)),
      ThemePresets.solarized,
    );
    expect(find.text('Theme copied.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('pasting something that is not a theme changes nothing', (
    tester,
  ) async {
    mockClipboard(tester);
    clipboard = 'sftp://deploy@web.example.com/var/www';
    await pumpSection(tester);

    await tester.tap(find.text('Paste theme'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('The clipboard does not hold a theme'),
      findsOneWidget,
    );
    expect(model.writes, isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('pasting a theme adopts it whole', (tester) async {
    mockClipboard(tester);
    clipboard = jsonEncode(ThemePresets.terminal.toJson());
    await pumpSection(tester);

    await tester.tap(find.text('Paste theme'));
    await tester.pumpAndSettle();

    expect(lastPalette(), ThemePresets.terminal);
    expect(find.text('Using Terminal.'), findsOneWidget);
  });

  testWidgets('a theme copied in Séance pastes, all but its terminal', (
    tester,
  ) async {
    mockClipboard(tester);
    // Séance's Copy theme for a Custom theme of its own: every key this
    // app knows, plus the terminal block it has no use for.
    clipboard = const JsonEncoder.withIndent('  ').convert({
      'name': 'Custom',
      'accent': '#FF8A4C',
      'surface': '#101418',
      'text': '#EEF2F6',
      'hairline': '#FFFFFF40',
      'offline': '#FF5252',
      'terminal': {
        'background': '#000000',
        'foreground': '#FFFFFF',
        'cursor': '#FF8A4C',
        'selection': '#FF8A4C40',
        'ansi': List.filled(16, '#808080'),
      },
      'fontFamily': 'Inter',
      'cornerScale': 0.6,
    });
    await pumpSection(tester);

    await tester.tap(find.text('Paste theme'));
    await tester.pumpAndSettle();

    final pasted = lastPalette();
    expect(pasted.accent, const Color(0xFFFF8A4C));
    expect(pasted.surface, const Color(0xFF101418));
    expect(pasted.text, const Color(0xFFEEF2F6));
    expect(pasted.hairline, const Color(0x40FFFFFF));
    expect(pasted.offline, const Color(0xFFFF5252));
    expect(pasted.sidebar, isNull);
    expect(pasted.fontFamily, 'Inter');
    expect(pasted.cornerScale, 0.6);
    expect(pasted.toJson().containsKey('terminal'), isFalse);
    // The section shows what it pasted.
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('appearance.fontFamily')),
          )
          .controller!
          .text,
      'Inter',
    );
  });

  testWidgets('a failed write says so', (tester) async {
    model.failWith = StateError('disk full');
    await pumpSection(tester);

    await tester.tap(find.byTooltip('Use the Graphite theme'));
    await tester.pumpAndSettle();

    expect(
      find.text('Appearance not saved: Bad state: disk full'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a failing streak says so once, for the last write', (
    tester,
  ) async {
    model.failWith = StateError('disk full');
    await pumpSection(tester);
    model.gate = Completer<void>();

    await tester.tap(find.byTooltip('Use the Graphite theme'));
    await tester.pump();
    await tester.tap(find.byTooltip('Use the Paper theme'));
    await tester.pump();
    model.gate!.complete();
    await tester.pumpAndSettle();

    expect(model.writes, hasLength(2));
    expect(
      find.text('Appearance not saved: Bad state: disk full'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('fits a phone\'s Settings dialog, after General', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPoltergeistTheme(
          Brightness.light,
          platform: TargetPlatform.android,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showGeneralSettingsDialog(
              context,
              settings: GeneralSettings(
                checkForUpdates: true,
                onCheckForUpdatesChanged: (_) async {},
              ),
              appearance: model,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // General first, then the theme.
    final general = tester.getRect(
      find.byKey(const ValueKey('updates.checkEnabled')),
    );
    final first = find.byTooltip('Use the Poltergeist theme');
    expect(tester.getRect(first).top, greaterThan(general.bottom));
    // Scroll to the end: every part laid out without overflowing.
    await tester.scrollUntilVisible(
      find.text('Reset to Vapor'),
      200,
      // The dialog's own scroll view: its fields hold scrollables too.
      scrollable: find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Reset to Vapor'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
