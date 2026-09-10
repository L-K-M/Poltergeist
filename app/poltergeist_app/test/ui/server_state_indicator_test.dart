import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/probe_status_dot.dart';
import 'package:poltergeist_app/ui/server_state_indicator.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'contrast_math.dart';

final _l10n = lookupAppLocalizations(const Locale('en'));

const _blocked = ServerStatus(
  ServerConnectionState.blocked,
  detail: 'Host key changed for web.example.com:22.',
);

const _failedConnect = ServerStatus(
  ServerConnectionState.disconnected,
  detail: 'Authentication failed for deploy@web.example.com:22.',
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPoltergeistTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  group('the composed indicator mapping', () {
    ServerIndicatorGlyph glyphOf({ServerStatus? status, ProbeStatus? probe}) {
      return serverIndicatorOf(_l10n, status: status, probe: probe).glyph;
    }

    test('no truth paints nothing', () {
      final appearance = serverIndicatorOf(_l10n);

      expect(appearance.glyph, ServerIndicatorGlyph.none);
      expect(appearance.label, isEmpty);
    });

    test('probe truth alone renders the tri-state dot', () {
      for (final (probe, label) in [
        (ProbeStatus.online, _l10n.probeStatusOnline),
        (ProbeStatus.offline, _l10n.probeStatusOffline),
        (ProbeStatus.unknown, _l10n.probeStatusUnknown),
      ]) {
        final appearance = serverIndicatorOf(_l10n, probe: probe);

        expect(appearance.glyph, ServerIndicatorGlyph.probe, reason: '$probe');
        expect(appearance.label, label);
      }
    });

    test('each connection state maps to one glyph and label', () {
      for (final (status, glyph, label) in [
        (
          const ServerStatus(ServerConnectionState.connecting),
          ServerIndicatorGlyph.pending,
          _l10n.connectionStateConnecting,
        ),
        (
          const ServerStatus(ServerConnectionState.reconnecting),
          ServerIndicatorGlyph.pending,
          _l10n.connectionStateReconnecting,
        ),
        (
          const ServerStatus(ServerConnectionState.connected),
          ServerIndicatorGlyph.connected,
          _l10n.connectionStateConnected,
        ),
        (
          const ServerStatus(ServerConnectionState.disconnected),
          ServerIndicatorGlyph.idle,
          _l10n.connectionStateNotConnected,
        ),
        (
          _failedConnect,
          ServerIndicatorGlyph.failed,
          _l10n.connectionFailedTitle,
        ),
        (_blocked, ServerIndicatorGlyph.blocked, _l10n.connectionBlockedTitle),
      ]) {
        final appearance = serverIndicatorOf(_l10n, status: status);

        expect(appearance.glyph, glyph, reason: status.state.name);
        expect(appearance.label, label, reason: status.state.name);
      }
    });

    test('a block outranks a reachable probe', () {
      // The audit finding: a green "reachable" dot rendered next to a
      // blocked panel. Live truth outranks probes (02 §4).
      expect(
        glyphOf(status: _blocked, probe: ProbeStatus.online),
        ServerIndicatorGlyph.blocked,
      );
    });

    test('a failure the state explains outranks a reachable probe', () {
      expect(
        glyphOf(status: _failedConnect, probe: ProbeStatus.online),
        ServerIndicatorGlyph.failed,
      );
    });

    test('a connected server outranks an offline probe', () {
      // The reverse contradiction of the audit finding: authenticated
      // transports prove reachability, so a stale offline result cannot
      // paint beside a session the user is actively using (02 §4).
      expect(
        glyphOf(
          status: const ServerStatus(ServerConnectionState.connected),
          probe: ProbeStatus.offline,
        ),
        ServerIndicatorGlyph.connected,
      );
    });

    test('a connected server outranks an unknown probe', () {
      // "Unknown" reachability beside an authenticated transport is the
      // same contradiction: the transport proves reachability, so the
      // glyph answers instead of the grey dot.
      expect(
        glyphOf(
          status: const ServerStatus(ServerConnectionState.connected),
          probe: ProbeStatus.unknown,
        ),
        ServerIndicatorGlyph.connected,
      );
    });

    test('a truth that does not contradict leaves the probe dot', () {
      // 02 §4 gives the favorite row its tri-state probe dot, and 07 §3.3
      // requires it to render in the interim list: a healthy or pending
      // connection does not contradict a reachability result.
      expect(
        glyphOf(
          status: const ServerStatus(ServerConnectionState.connected),
          probe: ProbeStatus.online,
        ),
        ServerIndicatorGlyph.probe,
      );
      expect(
        glyphOf(
          status: const ServerStatus(ServerConnectionState.connecting),
          probe: ProbeStatus.offline,
        ),
        ServerIndicatorGlyph.probe,
      );
      expect(
        glyphOf(
          status: const ServerStatus(ServerConnectionState.disconnected),
          probe: ProbeStatus.unknown,
        ),
        ServerIndicatorGlyph.probe,
      );
    });

    test('connection truth renders when no probe result exists', () {
      expect(
        glyphOf(status: const ServerStatus(ServerConnectionState.connected)),
        ServerIndicatorGlyph.connected,
      );
    });
  });

  group('the labeled indicator widget', () {
    testWidgets('delegates to the probe dot without a second label', (
      tester,
    ) async {
      await _pump(
        tester,
        const ServerStateIndicator(status: null, probe: ProbeStatus.online),
      );

      expect(find.byType(ProbeStatusDot), findsOneWidget);
      expect(find.byTooltip(_l10n.probeStatusOnline), findsOneWidget);

      final semantics = tester.ensureSemantics();
      try {
        // One announcement: the dot owns the label, the wrapper adds none.
        expect(find.bySemanticsLabel(_l10n.probeStatusOnline), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('a blocked connection replaces the reachable probe dot', (
      tester,
    ) async {
      await _pump(
        tester,
        const ServerStateIndicator(status: _blocked, probe: ProbeStatus.online),
      );

      expect(find.byType(ProbeStatusDot), findsNothing);
      expect(find.byTooltip(_l10n.connectionBlockedTitle), findsOneWidget);
      expect(find.byIcon(Icons.gpp_bad), findsOneWidget);

      final semantics = tester.ensureSemantics();
      try {
        expect(
          find.bySemanticsLabel(_l10n.connectionBlockedTitle),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(_l10n.probeStatusOnline), findsNothing);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('a connected server replaces the offline probe dot', (
      tester,
    ) async {
      await _pump(
        tester,
        const ServerStateIndicator(
          status: ServerStatus(ServerConnectionState.connected),
          probe: ProbeStatus.offline,
        ),
      );

      expect(find.byType(ProbeStatusDot), findsNothing);
      expect(find.byTooltip(_l10n.connectionStateConnected), findsOneWidget);

      final semantics = tester.ensureSemantics();
      try {
        expect(
          find.bySemanticsLabel(_l10n.connectionStateConnected),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel(_l10n.probeStatusOffline), findsNothing);
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('paints nothing when neither truth exists', (tester) async {
      await _pump(tester, const ServerStateIndicator(status: null));

      expect(find.byType(ProbeStatusDot), findsNothing);
      expect(find.byType(ServerStateGlyph), findsNothing);
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('a pending attempt spins', (tester) async {
      await _pump(
        tester,
        const ServerStateIndicator(
          status: ServerStatus(ServerConnectionState.connecting),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byTooltip(_l10n.connectionStateConnecting), findsOneWidget);
    });
  });

  test('indicator colors stay above 3:1 on both theme surfaces', () {
    // The composed indicator inherits the probe dot's contrast floor
    // (02 §4, SEA-019) for every color it can paint. The delegated probe
    // offline/unknown states reuse the scheme colors already pinned below
    // (`error`/`outline`), so no delegated color escapes the pin. The
    // backgrounds mirror the probe dot's own floor: the resting surface
    // (the app bar is pinned to paint it) and the scrolled-under tint.
    for (final brightness in Brightness.values) {
      final scheme = buildPoltergeistTheme(brightness).colorScheme;
      final scrolled = ElevationOverlay.applySurfaceTint(
        scheme.surface,
        scheme.surfaceTint,
        3,
      );

      for (final (name, color) in <(String, Color)>[
        ('connected', ProbeStatusDot.onlineColor),
        ('failed', scheme.error),
        ('blocked', scheme.error),
        ('idle', scheme.outline),
        ('pending', scheme.primary),
      ]) {
        for (final background in <(String, Color)>[
          ('surface', scheme.surface),
          ('scrolled-under', scrolled),
        ]) {
          expect(
            contrast(color, background.$2),
            greaterThanOrEqualTo(minimumNonTextContrast),
            reason: '$name on ${background.$1} (${brightness.name})',
          );
        }
      }
    }
  });
}
