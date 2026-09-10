import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/probe_status_dot.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'contrast_math.dart';

/// The shared localization harness: a production-theme MaterialApp with
/// [child] centered in the scaffold body.
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPoltergeistTheme(brightness),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

Container _dot(WidgetTester tester) => tester.widget<Container>(
  find.descendant(
    of: find.byType(ProbeStatusDot),
    matching: find.byType(Container),
  ),
);

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  for (final entry in <(ProbeStatus, String, Color Function(ColorScheme))>[
    (
      ProbeStatus.online,
      l10n.probeStatusOnline,
      (_) => ProbeStatusDot.onlineColor,
    ),
    (ProbeStatus.offline, l10n.probeStatusOffline, (s) => s.error),
    (ProbeStatus.unknown, l10n.probeStatusUnknown, (s) => s.outline),
  ]) {
    testWidgets('renders ${entry.$1.name} with tooltip and semantics', (
      tester,
    ) async {
      await _pump(tester, ProbeStatusDot(entry.$1));

      final scheme = Theme.of(
        tester.element(find.byType(ProbeStatusDot)),
      ).colorScheme;
      final dot = _dot(tester);
      final decoration = dot.decoration! as BoxDecoration;
      expect(decoration.color, entry.$3(scheme));
      expect(find.byTooltip(entry.$2), findsOneWidget);

      final semantics = tester.ensureSemantics();
      try {
        expect(find.bySemanticsLabel(entry.$2), findsOneWidget);
      } finally {
        // Release the handle even on failure: a leaked semantics mode
        // would poison every later test in this file.
        semantics.dispose();
      }
    });
  }

  test('dot colors stay above 3:1 on both theme surfaces', () {
    // 02 §4: status colors are theme-aware and contrast-checked (SEA-019).
    // Uses the production theme builder: the demo app bar paints
    // scheme.surface (pinned at the widget level above; M3's default
    // AppBar background). The demo body scrolls under the bar, so the
    // scrolled-under tint (scrolledUnderElevation 3) is pinned too.
    for (final brightness in Brightness.values) {
      final scheme = buildPoltergeistTheme(brightness).colorScheme;
      final scrolled = ElevationOverlay.applySurfaceTint(
        scheme.surface,
        scheme.surfaceTint,
        3,
      );

      for (final background in <(String, Color)>[
        ('resting', scheme.surface),
        ('scrolled-under', scrolled),
      ]) {
        expect(
          contrast(ProbeStatusDot.onlineColor, background.$2),
          greaterThanOrEqualTo(minimumNonTextContrast),
          reason: 'online on ${background.$1} (${brightness.name})',
        );
        expect(
          contrast(scheme.error, background.$2),
          greaterThanOrEqualTo(minimumNonTextContrast),
          reason: 'offline on ${background.$1} (${brightness.name})',
        );
        expect(
          contrast(scheme.outline, background.$2),
          greaterThanOrEqualTo(minimumNonTextContrast),
          reason: 'unknown on ${background.$1} (${brightness.name})',
        );
      }
    }
  });

  testWidgets('the demo app bar paints scheme.surface in both themes', (
    tester,
  ) async {
    // The contrast pin's chrome assumption, pinned at the widget level:
    // a Flutter upgrade that repaints the M3 AppBar (e.g. to
    // surfaceContainer) must fail here loudly.
    for (final brightness in Brightness.values) {
      final theme = buildPoltergeistTheme(brightness);
      final scheme = theme.colorScheme;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            appBar: AppBar(title: const Text('x')),
            body: const SizedBox.expand(),
          ),
        ),
      );

      // The AppBar paints its resolved background through an interior
      // Material; read the resolved color instead of sampling pixels.
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(AppBar),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(
        material.color,
        scheme.surface,
        reason: 'app bar background on ${brightness.name}',
      );
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('each state paints its exact color on screen', (tester) async {
    // Pins the rendered pixels, not just the decoration: a golden-capture
    // color-space artifact must never hide a real paint regression.
    // Deliberately exact (no ±1 tolerance): an SDK color-pipeline change
    // SHOULD fail this pin and be triaged as such, not absorbed silently.
    for (final status in ProbeStatus.values) {
      for (final brightness in Brightness.values) {
        await _pump(
          tester,
          RepaintBoundary(
            key: const ValueKey('dot-boundary'),
            child: SizedBox(
              width: 40,
              height: 40,
              child: ProbeStatusDot(status),
            ),
          ),
          brightness: brightness,
        );

        // The tight 40x40 parent stretches the dot's container to a 40 px
        // circle, so the box center is the dot center. toImage needs a real
        // event loop; runAsync provides one inside the test zone.
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('dot-boundary')),
        );
        final pixel = (await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 3);
          try {
            final data = await image.toByteData();
            final width = image.width;
            final center = (width ~/ 2) * width + width ~/ 2;
            // Honor the view's offset: a view-backed ByteData must sample
            // from its own start, never the underlying buffer's zero.
            return data!.buffer.asUint8List(data.offsetInBytes + center * 4, 4);
          } finally {
            image.dispose();
          }
        }))!;
        final expected = switch (status) {
          ProbeStatus.online => ProbeStatusDot.onlineColor,
          ProbeStatus.offline => Theme.of(
            tester.element(find.byType(ProbeStatusDot)),
          ).colorScheme.error,
          ProbeStatus.unknown => Theme.of(
            tester.element(find.byType(ProbeStatusDot)),
          ).colorScheme.outline,
        };

        expect(pixel[0], (expected.r * 255).round(), reason: 'red of $status');
        expect(
          pixel[1],
          (expected.g * 255).round(),
          reason: 'green of $status',
        );
        expect(pixel[2], (expected.b * 255).round(), reason: 'blue of $status');
        expect(pixel[3], 255, reason: 'alpha of $status');
        // Same retained-layer caveat as the app bar pin: a fresh tree per
        // iteration keeps the captured picture current.
        await tester.pumpWidget(const SizedBox());
      }
    }
  });
}
