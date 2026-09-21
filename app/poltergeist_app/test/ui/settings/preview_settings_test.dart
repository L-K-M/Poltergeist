import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/app_preferences.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/ui/settings/preview_settings.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  group('AppPreferences preview keys', () {
    late Directory dir;
    late File file;
    late AppPreferences prefs;

    AppPreferences reopened() =>
        AppPreferences(store: SettingsStore(path: file.path));

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('preview_prefs_test');
      file = File(p.join(dir.path, 'settings.json'));
      prefs = AppPreferences(store: SettingsStore(path: file.path));
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('defaults: 512 MiB cache cap, 100 MiB threshold', () async {
      expect(
        await prefs.loadPreviewCacheCapacityBytes(),
        defaultPreviewCacheCapacityBytes,
      );
      expect(
        await prefs.loadPreviewThresholdBytes(),
        defaultLargeDownloadThresholdBytes,
      );
    });

    test('values round-trip through a reopened store', () async {
      await prefs.savePreviewCacheCapacityBytes(64 << 20);
      await prefs.savePreviewThresholdBytes(8 << 20);
      expect(
        await reopened().loadPreviewCacheCapacityBytes(),
        64 << 20,
      );
      expect(await reopened().loadPreviewThresholdBytes(), 8 << 20);
    });

    test('non-positive writes normalize to the defaults', () async {
      await prefs.savePreviewCacheCapacityBytes(0);
      await prefs.savePreviewThresholdBytes(-5);
      expect(
        await reopened().loadPreviewCacheCapacityBytes(),
        defaultPreviewCacheCapacityBytes,
      );
      expect(
        await reopened().loadPreviewThresholdBytes(),
        defaultLargeDownloadThresholdBytes,
      );
    });
  });

  group('PreviewDownloadsSection', () {
    Widget wrap(PreviewDownloadsSettings settings) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: PreviewDownloadsSection(settings: settings),
          ),
        ),
      ),
    );

    PreviewDownloadsSettings settings({
      PreviewCache? cache,
      int capacityBytes = 512 << 20,
      int thresholdBytes = 100 << 20,
      Future<void> Function(int)? onCapacityChanged,
      Future<void> Function(int)? onThresholdChanged,
      Future<int> Function()? onClearCache,
    }) {
      return PreviewDownloadsSettings(
        cache: cache,
        capacityBytes: capacityBytes,
        thresholdBytes: thresholdBytes,
        onCapacityChanged: onCapacityChanged ?? (_) async {},
        onThresholdChanged: onThresholdChanged ?? (_) async {},
        onClearCache: onClearCache ?? () async => 0,
      );
    }

    testWidgets('fields seed from live values; submit commits bytes', (
      tester,
    ) async {
      final committed = <int>[];
      await tester.pumpWidget(
        wrap(
          settings(
            cache: _fakeCache(),
            onCapacityChanged: (b) async => committed.add(b),
          ),
        ),
      );
      final field = find.byKey(const ValueKey('preview.cacheLimitField'));
      expect(field, findsOneWidget);
      expect(find.widgetWithText(TextField, '512'), findsOneWidget);
      expect(find.widgetWithText(TextField, '100'), findsOneWidget);

      await tester.enterText(field, '256');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(committed, [256 * 1024 * 1024]);
    });

    testWidgets('invalid input reverts the field, writes nothing', (
      tester,
    ) async {
      final committed = <int>[];
      await tester.pumpWidget(
        wrap(
          settings(
            cache: _fakeCache(),
            onCapacityChanged: (b) async => committed.add(b),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('preview.cacheLimitField')),
        '0',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(committed, isEmpty);
      expect(find.widgetWithText(TextField, '512'), findsOneWidget);
    });

    testWidgets('threshold field commits independently', (tester) async {
      final committed = <int>[];
      await tester.pumpWidget(
        wrap(
          settings(
            cache: _fakeCache(),
            onThresholdChanged: (b) async => committed.add(b),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('preview.thresholdField')),
        '42',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(committed, [42 * 1024 * 1024]);
    });

    testWidgets('clear cache invokes the sink and shows reclaimed MiB', (
      tester,
    ) async {
      var clears = 0;
      await tester.pumpWidget(
        wrap(
          settings(
            cache: _fakeCache(),
            onClearCache: () async {
              clears++;
              return 7 << 20;
            },
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('preview.clearCache')));
      await tester.pumpAndSettle();
      expect(clears, 1);
      // The toast reports the reclaimed count.
      expect(find.textContaining('7'), findsWidgets);
    });

    testWidgets('a null cache renders the section disabled', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(settings(cache: null)));
      final clear = tester.widget<TextButton>(
        find.byKey(const ValueKey('preview.clearCache')),
      );
      expect(clear.onPressed, isNull);
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('preview.cacheLimitField')),
      );
      expect(field.enabled, isFalse);
    });
  });
}

/// The section only checks nullness — a cache over a path that is
/// never opened suffices.
PreviewCache _fakeCache() => PreviewCache(
  directory: Directory('${Directory.systemTemp.path}/unused_preview_test'),
);
