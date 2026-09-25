import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/settings_window/remote_settings.dart';
import 'package:poltergeist_app/services/settings_window/settings_window_host.dart';
import 'package:poltergeist_app/services/settings_window/settings_window_link.dart';
import 'package:poltergeist_app/settings_window_app.dart';
import 'package:poltergeist_app/ui/settings/general_settings.dart';
import 'package:poltergeist_app/ui/settings/preview_settings.dart';

const _appLink = MethodChannel('test/settings_window_app/app');
const _windowLink = MethodChannel('test/settings_window_app/window');
const _control = MethodChannel('test/settings_window_app/control');

/// The Settings window's own app over a real host: the tabs follow the
/// sections the app has, a tab request switches them, and a window that
/// loses the app says so.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SettingsWindowHost host;

  void relay(MethodChannel from, MethodChannel to) {
    messenger.setMockMessageHandler(from.name, (message) {
      final reply = Completer<ByteData?>();
      ServicesBinding.instance.channelBuffers.push(
        to.name,
        message,
        reply.complete,
      );
      return reply.future;
    });
  }

  setUp(() {
    relay(_appLink, _windowLink);
    relay(_windowLink, _appLink);
    messenger.setMockMethodCallHandler(_control, (_) async => null);
    host = SettingsWindowHost(control: _control, link: _appLink)
      ..attach(
        SettingsWindowSources(
          general: () => GeneralSettings(
            checkForUpdates: true,
            onCheckForUpdatesChanged: (_) async {},
          ),
          previewDownloads: () => PreviewDownloadsSettings(
            available: true,
            capacityBytes: 512 << 20,
            thresholdBytes: 100 << 20,
            onCapacityChanged: (_) async {},
            onThresholdChanged: (_) async {},
            onClearCache: () async => 0,
          ),
        ),
      );
  });

  tearDown(() {
    host.dispose();
    for (final channel in [_appLink, _windowLink]) {
      messenger.setMockMessageHandler(channel.name, null);
    }
    messenger.setMockMethodCallHandler(_control, null);
  });

  Future<RemoteSettings> pumpWindow(
    WidgetTester tester,
    SettingsWindowTab tab,
  ) async {
    final remote = (await tester.runAsync(() async {
      await host.open(tab);
      return RemoteSettings.connect(link: _windowLink);
    }))!;
    addTearDown(remote.dispose);
    await tester.pumpWidget(SettingsWindowApp(remote: remote));
    await tester.pumpAndSettle();
    return remote;
  }

  testWidgets('shows a tab per section the app has, on the one asked for', (
    tester,
  ) async {
    await pumpWindow(tester, SettingsWindowTab.editing);

    expect(find.widgetWithText(Tab, 'General'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Editing'), findsOneWidget);
    // No backup service in this app, so no Sync tab.
    expect(find.widgetWithText(Tab, 'Sync'), findsNothing);
    expect(find.text('Preview cache limit'), findsOneWidget);
  });

  testWidgets('a tab request switches the showing window', (tester) async {
    await pumpWindow(tester, SettingsWindowTab.editing);

    await tester.runAsync(() => host.open(SettingsWindowTab.general));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('updates.checkEnabled')), findsOneWidget);
  });

  testWidgets('a window with no sections says so and closes cleanly', (
    tester,
  ) async {
    host.attach(const SettingsWindowSources());
    await pumpWindow(tester, SettingsWindowTab.general);
    expect(find.text('Nothing to set here yet.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('a window that loses the app says so', (tester) async {
    final remote = await pumpWindow(tester, SettingsWindowTab.general);

    messenger.setMockMessageHandler(_windowLink.name, (_) async => null);
    await tester.runAsync(remote.requestAppExit);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Settings could not reach Poltergeist. Close this window and open '
        'Settings again.',
      ),
      findsOneWidget,
    );
  });
}
