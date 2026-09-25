import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_kit.dart';
import 'package:poltergeist_app/ui/sidebar/sidebar_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// 10 §5's server-row dot, one truth table: connected solid green,
/// connecting amber, failed solid red, a blocked host key the red
/// no-entry dot, reachable-but-idle a green ring and unreachable a red
/// one (D33: three states no longer share one glyph), and nothing at all
/// for unknown or idle — with the state always in words for the row's
/// semantics and tooltip.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  for (final brightness in Brightness.values) {
    group('${brightness.name} theme', () {
      final theme = buildPoltergeistTheme(brightness);
      final chrome = theme.extension<PoltergeistChrome>()!;
      final scheme = theme.colorScheme;

      ({SidebarStatusDot? dot, String label}) resolve({
        ServerStatus? status,
        ProbeStatus? probe,
      }) {
        final indicator = sidebarServerIndicator(
          l10n,
          chrome,
          scheme,
          status: status,
          probe: probe,
        );
        return (dot: indicator.dot, label: indicator.appearance.label);
      }

      const connected = ServerStatus(ServerConnectionState.connected);
      const connecting = ServerStatus(ServerConnectionState.connecting);
      const reconnecting = ServerStatus(ServerConnectionState.reconnecting);
      const idle = ServerStatus(ServerConnectionState.disconnected);
      const failed = ServerStatus(
        ServerConnectionState.disconnected,
        detail: 'Connection refused',
      );
      const blocked = ServerStatus(ServerConnectionState.blocked);

      test('a connection is a solid green dot, whatever the probe says', () {
        for (final probe in [null, ...ProbeStatus.values]) {
          final r = resolve(status: connected, probe: probe);
          expect(r.dot, SidebarStatusDot(chrome.statusConnected));
          expect(r.label, l10n.connectionStateConnected);
        }
      });

      test('connecting and reconnecting are amber, never the probe', () {
        for (final status in [connecting, reconnecting]) {
          for (final probe in [null, ...ProbeStatus.values]) {
            final r = resolve(status: status, probe: probe);
            expect(r.dot, SidebarStatusDot(chrome.statusConnecting));
          }
        }
        expect(
          resolve(status: connecting, probe: ProbeStatus.online).label,
          l10n.connectionStateConnecting,
        );
      });

      test('a failure is a solid red dot', () {
        final r = resolve(status: failed, probe: ProbeStatus.online);
        expect(r.dot, SidebarStatusDot(scheme.error));
      });

      test('a host-key block is the red no-entry dot, never a failure', () {
        for (final probe in [null, ...ProbeStatus.values]) {
          final r = resolve(status: blocked, probe: probe);
          expect(
            r.dot,
            SidebarStatusDot(scheme.error, style: SidebarDotStyle.blocked),
          );
        }
        expect(resolve(status: blocked).label, l10n.connectionBlockedTitle);
      });

      test('reachable without a connection is a hollow green ring', () {
        for (final status in [null, idle]) {
          final r = resolve(status: status, probe: ProbeStatus.online);
          expect(
            r.dot,
            SidebarStatusDot(
              chrome.statusConnected,
              style: SidebarDotStyle.ring,
            ),
          );
          expect(r.label, l10n.probeStatusOnline);
        }
      });

      test('unknown and idle paint no dot but keep their words', () {
        final unknown = resolve(probe: ProbeStatus.unknown);
        expect(unknown.dot, isNull);
        expect(unknown.label, l10n.probeStatusUnknown);

        final idleRow = resolve(status: idle);
        expect(idleRow.dot, isNull);
        expect(idleRow.label, l10n.connectionStateNotConnected);

        expect(resolve().dot, isNull);
      });

      test('an unreachable probe is a hollow red ring, as in Séance', () {
        for (final status in [null, idle]) {
          final r = resolve(status: status, probe: ProbeStatus.offline);
          expect(
            r.dot,
            SidebarStatusDot(scheme.error, style: SidebarDotStyle.ring),
          );
          expect(r.label, l10n.probeStatusOffline);
        }
      });
    });
  }
}
