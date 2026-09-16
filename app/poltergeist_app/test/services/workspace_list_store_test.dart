import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_app/services/workspace_list_store.dart';
import 'package:poltergeist_app/services/workspace_state.dart';

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;
  late WorkspaceListStore store;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_workspace_store_test_',
    );
    settingsFile = File(p.join(temporaryDirectory.path, 'settings.json'));
    store = WorkspaceListStore(store: SettingsStore(path: settingsFile.path));
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  WorkspacePaneState pane(String paneId) =>
      WorkspacePaneState(paneId: paneId, activeTab: -1, tabs: const []);

  final fixture = WorkspaceListDocument(
    workspaces: [
      SavedWorkspace(
        id: 'ws-1',
        label: 'Client X',
        savedAt: DateTime.utc(2026, 9, 16),
        lastOpenedAt: null,
        snapshot: WorkspaceSnapshot(
          left: WorkspacePaneState(
            paneId: sessionLeftPaneId,
            activeTab: 0,
            tabs: [
              WorkspaceTabState(
                session: const SessionTabState.local(path: '/home/tester'),
                filterQuery: 'log',
                filterFieldOpen: true,
                showHidden: true,
                viewMode: PaneViewMode.list,
              ),
            ],
          ),
          right: pane(sessionRightPaneId),
        ),
      ),
    ],
  );

  Map<String, dynamic> settingsJson() =>
      jsonDecode(settingsFile.readAsStringSync()) as Map<String, dynamic>;

  test('loads null when no workspaces were persisted', () async {
    expect(await store.load(), isNull);
  });

  test('round-trips the document under its own settings.json key', () async {
    await store.save(fixture);

    final stored = settingsJson()['workspaces.saved'];
    expect(stored, isA<Map>());
    expect((stored! as Map)['version'], WorkspaceListDocument.schemaVersion);

    final loaded = await store.load();
    final saved = loaded!.workspaces.single;
    expect(saved.id, 'ws-1');
    expect(saved.snapshot.left.tabs.single.filterQuery, 'log');
  });

  test('stays clearly separated from the auto-session key', () async {
    // A session document and the workspace list coexist in one
    // settings.json without sharing a key — the safe-point writer can
    // never displace a named workspace.
    await settingsFile.writeAsString('{"session.state":{"version":1}}');
    await store.save(fixture);

    final json = settingsJson();
    expect(json['session.state'], {'version': 1});
    expect(json['workspaces.saved'], isA<Map>());
  });

  test('load rejects a newer schema without touching the file', () async {
    final newer = fixture.toJson()..['version'] = 99;
    await settingsFile.writeAsString(jsonEncode({'workspaces.saved': newer}));

    await expectLater(store.load(), throwsFormatException);
    expect(settingsJson()['workspaces.saved'], newer);
  });

  test('save fails closed over an undecodable stored document', () async {
    await settingsFile.writeAsString(
      jsonEncode({
        'workspaces.saved': {...fixture.toJson(), 'version': 99},
      }),
    );

    await expectLater(store.save(fixture), throwsFormatException);
    expect((settingsJson()['workspaces.saved'] as Map)['version'], 99);
  });

  test(
    'save rejects a malformed stored document rather than masking it',
    () async {
      await settingsFile.writeAsString(
        jsonEncode({'workspaces.saved': 'not-a-map'}),
      );

      await expectLater(store.save(fixture), throwsFormatException);
      expect(settingsJson()['workspaces.saved'], 'not-a-map');
    },
  );
}
