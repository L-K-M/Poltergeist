import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/session_state_store.dart';
import 'package:poltergeist_app/services/settings_store.dart';

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;
  late SessionStateStore store;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_session_store_test_',
    );
    settingsFile = File(p.join(temporaryDirectory.path, 'settings.json'));
    store = SessionStateStore(
      store: SettingsStore(path: settingsFile.path),
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  const fixture = SessionState(
    activePaneId: PaneTabsController.leftPaneId,
    secondPaneHidden: false,
    panes: [
      SessionPaneState(
        paneId: PaneTabsController.leftPaneId,
        activeTab: -1,
        nextTabOrdinal: 2,
        tabs: [SessionTabState.local(path: '/home/tester')],
      ),
      SessionPaneState(
        paneId: PaneTabsController.rightPaneId,
        activeTab: -1,
        nextTabOrdinal: 1,
        tabs: [],
      ),
    ],
  );

  Map<String, dynamic> settingsJson() =>
      jsonDecode(settingsFile.readAsStringSync()) as Map<String, dynamic>;

  test('loads null when no session was persisted', () async {
    expect(await store.load(), isNull);
  });

  test('round-trips the document inside settings.json', () async {
    await store.save(fixture);

    final stored = settingsJson()['session.state'];
    expect(stored, isA<Map>());
    expect((stored! as Map)['version'], SessionState.schemaVersion);

    final loaded = await store.load();
    expect(loaded?.activePaneId, PaneTabsController.leftPaneId);
    expect(loaded?.panes[0].tabs.single.path, '/home/tester');
    expect(loaded?.panes[1].tabs, isEmpty);
  });

  test('coexists with the other settings keys', () async {
    await settingsFile.writeAsString('{"layout.paneRatio":0.7}');
    await store.save(fixture);

    final json = settingsJson();
    expect(json['layout.paneRatio'], 0.7);
    expect(json['session.state'], isA<Map>());
  });

  test('load rejects a newer schema without touching the file', () async {
    final newer = fixture.toJson()..['version'] = 99;
    await settingsFile.writeAsString(
      jsonEncode({'session.state': newer}),
    );

    await expectLater(store.load(), throwsFormatException);
    // The document stays on disk untouched — never silently dropped.
    expect(settingsJson()['session.state'], newer);
  });

  test('save fails closed over an undecodable stored document', () async {
    await settingsFile.writeAsString(
      jsonEncode({
        'session.state': {...fixture.toJson(), 'version': 99},
      }),
    );

    await expectLater(store.save(fixture), throwsFormatException);
    // A document this build cannot decode is never overwritten.
    expect((settingsJson()['session.state'] as Map)['version'], 99);
  });

  test('save rejects a malformed stored document rather than masking it',
      () async {
    await settingsFile.writeAsString(
      jsonEncode({'session.state': 'not-a-map'}),
    );

    await expectLater(store.save(fixture), throwsFormatException);
    expect(settingsJson()['session.state'], 'not-a-map');
  });

  group('the windows beside the first (00 D38)', () {
    test('load none when none were persisted', () async {
      expect(await store.loadWindows(), isEmpty);
    });

    test('saveAll writes both documents, and they load back', () async {
      await store.saveAll(fixture, [fixture, fixture]);

      final json = settingsJson();
      expect(json['session.state'], fixture.toJson());
      expect((json['session.windows'] as Map)['version'], 1);
      expect(await store.load(), isNotNull);
      final windows = await store.loadWindows();
      expect(windows, hasLength(2));
      expect(windows.first.toJson(), fixture.toJson());
    });

    test('saveAll with one window empties the list', () async {
      await store.saveAll(fixture, [fixture]);
      await store.saveAll(fixture, []);

      expect(await store.loadWindows(), isEmpty);
    });

    test("a newer build's windows document is neither read nor overwritten",
        () async {
      final newer = {'version': 99, 'windows': <Object>[]};
      await SettingsStore(
        path: settingsFile.path,
      ).set('session.windows', newer);

      await expectLater(store.loadWindows(), throwsFormatException);
      await expectLater(store.saveAll(fixture, []), throwsFormatException);
      expect(settingsJson()['session.windows'], newer);
      expect(settingsJson().containsKey('session.state'), isFalse);
    });
  });
}
