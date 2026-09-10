import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/probe_status_dot.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

const _minimumDotContrast = 3.0;

Future<void> _pump(WidgetTester tester, ProbeStatus status) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ProbeStatusDot(status)),
    ),
  );
}

Container _dot(WidgetTester tester) =>
    tester.widget<Container>(
      find.descendant(
        of: find.byType(ProbeStatusDot),
        matching: find.byType(Container),
      ),
    );

double _relativeLuminance(Color color) {
  double channel(double value) =>
      value <= 0.03928 ? value / 12.92 : math.pow((value + 0.055) / 1.055, 2.4).toDouble();

  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double _contrast(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  for (final entry in <(ProbeStatus, String, Color Function(ColorScheme))>[
    (ProbeStatus.online, l10n.probeStatusOnline, (_) => ProbeStatusDot.onlineColor),
    (ProbeStatus.offline, l10n.probeStatusOffline, (s) => s.error),
    (ProbeStatus.unknown, l10n.probeStatusUnknown, (s) => s.outline),
  ]) {
    testWidgets('renders ${entry.$1.name} with tooltip and semantics', (
      tester,
    ) async {
      await _pump(tester, entry.$1);

      final scheme = Theme.of(tester.element(find.byType(ProbeStatusDot)))
          .colorScheme;
      final dot = _dot(tester);
      final decoration = dot.decoration! as BoxDecoration;
      expect(decoration.color, entry.$3(scheme));
      expect(find.byTooltip(entry.$2), findsOneWidget);
    });
  }

  testWidgets('dot colors stay above 3:1 on both theme surfaces', (
    tester,
  ) async {
    // 02 §4: status colors are theme-aware and contrast-checked (SEA-019).
    for (final brightness in Brightness.values) {
      final scheme = ColorScheme.fromSeed(
        seedColor: const Color(0xFF3D8A78),
        brightness: brightness,
      );

      expect(
        _contrast(ProbeStatusDot.onlineColor, scheme.surface),
        greaterThanOrEqualTo(_minimumDotContrast),
        reason: 'online on ${brightness.name}',
      );
      expect(
        _contrast(scheme.error, scheme.surface),
        greaterThanOrEqualTo(_minimumDotContrast),
        reason: 'offline on ${brightness.name}',
      );
      expect(
        _contrast(scheme.outline, scheme.surface),
        greaterThanOrEqualTo(_minimumDotContrast),
        reason: 'unknown on ${brightness.name}',
      );
    }
  });

  testWidgets('each state paints its exact color on screen', (tester) async {
    // Pins the rendered pixels, not just the decoration: a golden-capture
    // color-space artifact must never hide a real paint regression.
    for (final status in ProbeStatus.values) {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: const ValueKey('dot-boundary'),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: ProbeStatusDot(status),
                ),
              ),
            ),
          ),
        ),
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
          return data!.buffer.asUint8List(center * 4, 4);
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
      expect(pixel[1], (expected.g * 255).round(), reason: 'green of $status');
      expect(pixel[2], (expected.b * 255).round(), reason: 'blue of $status');
      expect(pixel[3], 255, reason: 'alpha of $status');
    }
  });
}
