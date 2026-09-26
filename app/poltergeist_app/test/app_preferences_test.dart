import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/app_preferences.dart';
import 'package:poltergeist_app/services/double_click_action.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_app/theme/app_appearance.dart';
import 'package:poltergeist_app/theme/theme_palette.dart';
import 'package:poltergeist_app/theme/theme_presets.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show TransferConcurrency;

import 'support/fake_bookmark_store.dart';

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_preferences_test_',
    );
    settingsFile = File(p.join(temporaryDirectory.path, 'settings.json'));
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('accepts integer-valued persisted geometry and pane ratio', () async {
    await settingsFile.writeAsString(
      '{"layout.paneRatio":1,"window.left":80,"window.top":60,'
      '"window.width":1180,"window.height":760}',
    );
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );

    expect(await preferences.loadPaneRatio(), 1);
    expect(
      await preferences.loadWindowBounds(),
      const Rect.fromLTWH(80, 60, 1180, 760),
    );
  });

  test('uses the default pane ratio while settings recover', () async {
    await settingsFile.writeAsBytes([0xff]);
    final errors = <Object>[];
    final preferences = AppPreferences(
      store: SettingsStore(
        path: settingsFile.path,
        onError: (error, _) => errors.add(error),
      ),
    );

    expect(await preferences.loadPaneRatio(), 0.5);
    expect(errors, hasLength(1));

    await settingsFile.writeAsString('{"layout.paneRatio":0.7}');

    expect(await preferences.loadPaneRatio(), 0.7);
  });

  test('uses default window placement while settings recover', () async {
    final blockedParent = File(p.join(temporaryDirectory.path, 'blocked'));
    await blockedParent.writeAsString('not a directory');
    final preferences = AppPreferences(
      store: SettingsStore(
        path: p.join(blockedParent.path, 'settings.json'),
      ),
    );

    expect(await preferences.loadWindowBounds(), isNull);
  });

  test('persists every Double-click action value and reads it back',
      () async {
    for (final action in DoubleClickAction.values) {
      final preferences = AppPreferences(
        store: SettingsStore(path: settingsFile.path),
      );
      await preferences.saveDoubleClickAction(action);
      expect(await preferences.loadDoubleClickAction(), action);
    }
  });

  test('the restored-tab reconnect setting defaults ON and persists',
      () async {
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );

    expect(await preferences.loadReconnectRestoredTabs(), isTrue);

    await preferences.saveReconnectRestoredTabs(false);
    expect(await preferences.loadReconnectRestoredTabs(), isFalse);

    // A non-bool stored value reads as the spec default, not a failure.
    // SettingsStore caches after first load, so a fresh store observes
    // the externally written file.
    await settingsFile.writeAsString(
      '{"tabs.reconnectRestored":"yes"}',
    );
    final reloaded = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );
    expect(await reloaded.loadReconnectRestoredTabs(), isTrue);
  });

  test('the Double-click action defaults to Open and falls back on an '
      'unknown stored value', () async {
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );

    expect(
      await preferences.loadDoubleClickAction(),
      DoubleClickAction.open,
    );

    await settingsFile.writeAsString(
      '{"panes.doubleClickAction":"teleport"}',
    );
    expect(
      await preferences.loadDoubleClickAction(),
      DoubleClickAction.open,
    );
  });

  test('the sidebar density defaults to comfortable, persists, and falls '
      'back on an unknown stored value', () async {
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );

    // D33: comfortable on every platform until the user picks.
    expect(await preferences.loadSidebarDensity(), SidebarDensity.comfortable);

    await preferences.saveSidebarDensity(SidebarDensity.compact);
    expect(await preferences.loadSidebarDensity(), SidebarDensity.compact);

    for (final stored in ['"roomy"', '3', 'null']) {
      await settingsFile.writeAsString('{"sidebar.density":$stored}');
      final reloaded = AppPreferences(
        store: SettingsStore(path: settingsFile.path),
      );
      expect(
        await reloaded.loadSidebarDensity(),
        SidebarDensity.comfortable,
        reason: 'stored $stored',
      );
    }
  });

  group('the device theme', () {
    AppPreferences fresh() =>
        AppPreferences(store: SettingsStore(path: settingsFile.path));

    test('defaults to the first preset, following the system', () async {
      expect(await fresh().loadAppearance(), AppAppearance.initial);
      // A settings file from before themes existed reads the same.
      await settingsFile.writeAsString('{"sidebar.density":"compact"}');
      expect(await fresh().loadAppearance(), AppAppearance.initial);
    });

    test(
      'round-trips through the settings file, as Séance writes it',
      () async {
        final appearance = AppAppearance(
          palette: ThemePresets.solarized.copyWith(cornerScale: 0.3),
          mode: ThemeModePreference.dark,
        );
        await fresh().saveAppearance(appearance);

        expect(await fresh().loadAppearance(), appearance);
        final stored =
            jsonDecode(await settingsFile.readAsString())
                as Map<String, Object?>;
        // One JSON object in Séance's format, so it reads as a pasted theme
        // would, and the mode beside it.
        expect(
          ThemePalette.decodeStored(stored['theme.palette']),
          appearance.palette,
        );
        expect((stored['theme.palette']! as Map)['surface'], '#002B36');
        expect(stored['theme.mode'], 'dark');
      },
    );

    test(
      'a garbage theme reads as the default and costs nothing else',
      () async {
        for (final bad in ['"solarized"', '7', '[1, 2]', 'null', '{"1": 2}']) {
          await settingsFile.writeAsString(
            '{"theme.palette":$bad,"theme.mode":"sepia",'
            '"sidebar.density":"compact"}',
          );
          final preferences = fresh();
          expect(
            await preferences.loadAppearance(),
            AppAppearance.initial,
            reason: bad,
          );
          expect(
            await preferences.loadSidebarDensity(),
            SidebarDensity.compact,
            reason: bad,
          );
        }
      },
    );

    test('a hand-edited theme costs only its own bad values', () async {
      await settingsFile.writeAsString(
        '{"theme.palette":{"accent":"crimson","surface":"#102030",'
        '"cornerScale":"round"},"theme.mode":"light"}',
      );
      final appearance = await fresh().loadAppearance();
      // The gaps fill from Poltergeist, the all-Automatic preset.
      expect(appearance.palette.accent, ThemePresets.poltergeist.accent);
      expect(appearance.palette.surface, const Color(0xFF102030));
      expect(appearance.palette.cornerScale, 1);
      expect(appearance.mode, ThemeModePreference.light);
    });

    test('an unreadable store reads as the default theme', () async {
      await settingsFile.writeAsBytes([0xff]);
      final preferences = AppPreferences(
        store: SettingsStore(path: settingsFile.path, onError: (_, _) {}),
      );
      expect(await preferences.loadAppearance(), AppAppearance.initial);
    });

    test('saving it touches only its own keys', () async {
      await fresh().saveSidebarDensity(SidebarDensity.compact);
      await fresh().saveAppearance(AppAppearance(palette: ThemePresets.paper));
      final stored =
          jsonDecode(await settingsFile.readAsString()) as Map<String, Object?>;
      expect(
        stored.keys,
        unorderedEquals(['sidebar.density', 'theme.palette', 'theme.mode']),
      );
    });
  });

  test('pinned servers persist; a malformed value reads empty', () async {
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );

    expect(await preferences.loadSidebarPinnedServers(), isEmpty);
    expect(await preferences.setSidebarServerPinned('s1', pinned: true), {
      's1',
    });
    await preferences.setSidebarServerPinned('s2', pinned: true);
    expect(await preferences.loadSidebarPinnedServers(), {'s1', 's2'});
    expect(await preferences.setSidebarServerPinned('s1', pinned: false), {
      's2',
    });
    expect(jsonDecode(await settingsFile.readAsString()), {
      'sidebar.pinnedServers': ['s2'],
    });

    for (final stored in ['"s1"', '{"s1":true}', '[1, "s3"]']) {
      await settingsFile.writeAsString('{"sidebar.pinnedServers":$stored}');
      final reloaded = AppPreferences(
        store: SettingsStore(path: settingsFile.path),
      );
      expect(
        await reloaded.loadSidebarPinnedServers(),
        stored == '[1, "s3"]' ? {'s3'} : isEmpty,
        reason: 'stored $stored',
      );
    }

    // A malformed value is corrupt data, not a failed read: a pin change
    // replaces it with a well-formed list.
    await settingsFile.writeAsString('{"sidebar.pinnedServers":"s1"}');
    final malformed = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );
    expect(await malformed.setSidebarServerPinned('s4', pinned: true), {'s4'});
  });

  group('a startup read that failed', () {
    // The file is unreadable at launch (invalid UTF-8 here, an IO error
    // in the field) and readable again by the user's first edit: the
    // store resets its failed load, so that edit's access retries it.
    late SettingsStore store;
    late AppPreferences preferences;

    setUp(() async {
      await settingsFile.writeAsBytes([0xff]);
      store = SettingsStore(path: settingsFile.path, onError: (_, _) {});
      preferences = AppPreferences(store: store);
    });

    Future<Object?> stored(String key) async =>
        (jsonDecode(await settingsFile.readAsString()) as Map)[key];

    test('a pin change keeps the pins it could not read', () async {
      final pinned = await preferences.loadSidebarPinnedServers();
      expect(pinned, isEmpty);
      await settingsFile.writeAsString('{"sidebar.pinnedServers":["a","b"]}');
      final bookmarks = FakeBookmarkStore();
      addTearDown(bookmarks.close);
      // main.dart's wiring.
      final controller = SidebarController(
        store: bookmarks,
        initiallyPinned: pinned,
        onPinnedChanged: preferences.setSidebarServerPinned,
      );
      addTearDown(controller.dispose);

      controller.togglePinned('c');
      await store.flush();
      await pumpEventQueue();

      expect(await stored('sidebar.pinnedServers'), ['a', 'b', 'c']);
      // The first edit brings the unread pins back on screen too.
      expect(controller.pinnedServers, {'a', 'b', 'c'});
    });

    test('a fold keeps the folds it could not read', () async {
      final collapsed = await preferences.loadSidebarCollapsedGroups();
      expect(collapsed, isEmpty);
      await settingsFile.writeAsString(
        '{"sidebar.collapsedGroups":["sec:devices","fav:work"]}',
      );
      final bookmarks = FakeBookmarkStore();
      addTearDown(bookmarks.close);
      final controller = SidebarController(
        store: bookmarks,
        initiallyCollapsed: collapsed,
        onCollapsedChanged: preferences.setSidebarGroupCollapsed,
      );
      addTearDown(controller.dispose);

      controller.toggleCollapsed('srv:prod');
      await store.flush();
      await pumpEventQueue();

      expect(await stored('sidebar.collapsedGroups'), [
        'sec:devices',
        'fav:work',
        'srv:prod',
      ]);
      expect(controller.collapsedGroups, {
        'sec:devices',
        'fav:work',
        'srv:prod',
      });
    });

    test('a pin or a fold fails, writing nothing, while the store stays '
        'unreadable', () async {
      expect(await preferences.loadSidebarPinnedServers(), isEmpty);

      await expectLater(
        preferences.setSidebarServerPinned('c', pinned: true),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        preferences.setSidebarGroupCollapsed('srv:prod', collapsed: true),
        throwsA(isA<FileSystemException>()),
      );
      expect(await settingsFile.readAsBytes(), [0xff]);
    });
  });

  test('pin changes issued together all land', () async {
    await settingsFile.writeAsString('{"sidebar.pinnedServers":["a"]}');
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );

    // Neither change waits for the other: each still starts from the
    // value the one before it stored.
    await Future.wait([
      preferences.setSidebarServerPinned('b', pinned: true),
      preferences.setSidebarServerPinned('a', pinned: false),
      preferences.setSidebarServerPinned('c', pinned: true),
    ]);

    expect(await preferences.loadSidebarPinnedServers(), {'b', 'c'});
  });

  test('a fold migrates the legacy keys it writes back', () async {
    await settingsFile.writeAsString(
      '{"sidebar.collapsedGroups":["sidebar.catalog","work"]}',
    );
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );

    // SERVERS was folded under its pre-D32 key; unfolding it must not
    // leave that spelling behind to fold it again next launch.
    expect(
      await preferences.setSidebarGroupCollapsed(
        SidebarCollapseKeys.section(SidebarSection.servers),
        collapsed: false,
      ),
      {'fav:work'},
    );
    expect(jsonDecode(await settingsFile.readAsString()), {
      'sidebar.collapsedGroups': ['fav:work'],
    });
  });

  test('the per-server transfer caps persist and clear', () async {
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );
    expect(
      await preferences.loadTransferConcurrency(),
      const TransferConcurrency.automatic(),
    );
    expect(await preferences.loadServerTransferConcurrency(), isEmpty);

    await preferences.saveTransferConcurrency(
      const TransferConcurrency.fixed(2),
    );
    await preferences.setServerTransferConcurrency(
      'fast',
      const TransferConcurrency.automatic(),
    );
    expect(
      await preferences.setServerTransferConcurrency(
        'fussy',
        const TransferConcurrency.fixed(1),
      ),
      {
        'fast': const TransferConcurrency.automatic(),
        'fussy': const TransferConcurrency.fixed(1),
      },
    );

    final reread = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );
    expect(
      await reread.loadTransferConcurrency(),
      const TransferConcurrency.fixed(2),
    );
    expect(await reread.loadServerTransferConcurrency(), {
      'fast': const TransferConcurrency.automatic(),
      'fussy': const TransferConcurrency.fixed(1),
    });

    expect(await reread.setServerTransferConcurrency('fast', null), {
      'fussy': const TransferConcurrency.fixed(1),
    });
    await reread.saveTransferConcurrency(
      const TransferConcurrency.automatic(),
    );
    final again = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );
    expect(
      await again.loadTransferConcurrency(),
      const TransferConcurrency.automatic(),
    );
  });

  test('a hand-edited cap that is not a positive whole number is '
      'dropped', () async {
    // 1e999 decodes to infinity: jsonDecode saturates over-range literals.
    await settingsFile.writeAsString(
      '{"transfer.perServerConcurrency":1e999,'
      '"transfer.serverConcurrency":{"a":2.5,"b":-1,"c":"fast","d":3,'
      '"e":"automatic","f":null,"g":0,"h":1e999,"i":6,"j":1e300}}',
    );
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );
    expect(
      await preferences.loadTransferConcurrency(),
      const TransferConcurrency.automatic(),
    );
    // A cap at or above the app-wide total never binds, so it reads as the
    // Automatic it behaves as rather than a number no chip offers.
    expect(await preferences.loadServerTransferConcurrency(), {
      'd': const TransferConcurrency.fixed(3),
      'e': const TransferConcurrency.automatic(),
      'i': const TransferConcurrency.automatic(),
      'j': const TransferConcurrency.automatic(),
    });

    // A change rewrites only what decodes; the rest is not carried along.
    // (Finite values here: the store re-encodes the whole file on a write,
    // and an infinity cannot be encoded wherever it sits.)
    await settingsFile.writeAsString(
      '{"transfer.serverConcurrency":{"a":2.5,"d":3,"e":"automatic","f":null}}',
    );
    await AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    ).setServerTransferConcurrency('d', const TransferConcurrency.fixed(4));
    final stored =
        jsonDecode(await settingsFile.readAsString()) as Map<String, Object?>;
    expect(stored['transfer.serverConcurrency'], {'d': 4, 'e': 'automatic'});
  });

  test('a non-finite persisted transfer limit decodes as unlimited',
      () async {
    // jsonDecode saturates an over-range literal to Infinity, and
    // toInt() throws on it outside the get's try — a corrupt settings
    // file must not crash the loader (the panel-height loader already
    // guards the same way).
    await settingsFile.writeAsString(
      '{"transfer.downloadLimitBytesPerSecond":1e999}',
    );
    final preferences = AppPreferences(
      store: SettingsStore(path: settingsFile.path),
    );

    expect(await preferences.loadDownloadLimit(), isNull);
  });

  test('does not persist invalid window bounds', () async {
    const invalidBounds = <({String name, Rect bounds})>[
      (
        name: 'non-finite origin',
        bounds: Rect.fromLTWH(double.nan, 60, 1180, 760),
      ),
      (
        name: 'non-finite size',
        bounds: Rect.fromLTWH(80, 60, double.infinity, 760),
      ),
      (name: 'zero width', bounds: Rect.fromLTWH(80, 60, 0, 760)),
      (name: 'negative height', bounds: Rect.fromLTWH(80, 60, 1180, -1)),
    ];

    for (final fixture in invalidBounds) {
      final fixtureFile = File(p.join(temporaryDirectory.path, fixture.name));
      final preferences = AppPreferences(
        store: SettingsStore(path: fixtureFile.path),
      );

      await expectLater(
        preferences.saveWindowBounds(fixture.bounds),
        completes,
        reason: fixture.name,
      );
      expect(fixtureFile.existsSync(), isFalse, reason: fixture.name);
    }
  });
}
