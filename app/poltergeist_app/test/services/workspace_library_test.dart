import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/workspace_library.dart';
import 'package:poltergeist_app/services/workspace_list_store.dart';
import 'package:poltergeist_app/services/workspace_state.dart';

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;
  late WorkspaceLibrary library;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'poltergeist_workspace_library_test_',
    );
    settingsFile = File(p.join(temporaryDirectory.path, 'settings.json'));
    library = WorkspaceLibrary(
      store: WorkspaceListStore(store: SettingsStore(path: settingsFile.path)),
    );
  });

  tearDown(() {
    library.dispose();
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  WorkspaceSnapshot emptySnapshot() => WorkspaceSnapshot(
    left: WorkspacePaneState(
      paneId: sessionLeftPaneId,
      activeTab: -1,
      tabs: const [],
    ),
    right: WorkspacePaneState(
      paneId: sessionRightPaneId,
      activeTab: -1,
      tabs: const [],
    ),
  );

  group('load', () {
    test('starts empty when nothing was persisted', () async {
      await library.load();
      expect(library.workspaces, isEmpty);
    });

    test('fails closed on an undecodable document', () async {
      settingsFile.writeAsStringSync('{"workspaces.saved":{"version":99}}');
      await expectLater(library.load(), throwsFormatException);
      expect(library.workspaces, isEmpty);
    });
  });

  group('save', () {
    test('returns a stable record, reorders newest-saved first, and '
        'persists', () async {
      await library.load();
      final first = await library.save(
        label: 'Client X',
        snapshot: emptySnapshot(),
      );
      final second = await library.save(
        label: 'Archive',
        snapshot: emptySnapshot(),
      );

      expect(first.id, isNot(second.id));
      expect(first.label, 'Client X');
      expect(first.lastOpenedAt, isNull);
      expect(library.workspaces.map((w) => w.label), ['Archive', 'Client X']);

      final reloaded = WorkspaceLibrary(
        store: WorkspaceListStore(
          store: SettingsStore(path: settingsFile.path),
        ),
      );
      await reloaded.load();
      expect(reloaded.workspaces.map((w) => w.id), [second.id, first.id]);
      reloaded.dispose();
    });

    test('saving over an existing label keeps its id and resets the '
        'open stamp', () async {
      await library.load();
      final first = await library.save(
        label: 'Client X',
        snapshot: emptySnapshot(),
      );
      await library.markOpened(first.id);
      expect(library.workspaces.single.lastOpenedAt, isNotNull);

      final saved = await library.save(
        label: 'client x', // case-insensitive save-over
        snapshot: emptySnapshot(),
      );
      expect(saved.id, first.id);
      expect(library.workspaces, hasLength(1));
      expect(saved.lastOpenedAt, isNull);
    });

    test('notifies listeners so the menu re-derives', () async {
      await library.load();
      var notified = 0;
      library.addListener(() => notified++);

      await library.save(label: 'Client X', snapshot: emptySnapshot());
      expect(notified, 1);
    });
  });

  group('markOpened', () {
    test('moves the opened workspace to newest-opened order', () async {
      await library.load();
      final a = await library.save(label: 'A', snapshot: emptySnapshot());
      final b = await library.save(label: 'B', snapshot: emptySnapshot());
      await library.save(label: 'C', snapshot: emptySnapshot());

      await library.markOpened(a.id);
      expect(library.workspaces.map((w) => w.label), ['A', 'C', 'B']);
      expect(library.workspaces.first.lastOpenedAt, isNotNull);
      expect(
        library.workspaces.first.lastOpenedAt!.compareTo(a.savedAt) >= 0,
        isTrue,
      );

      await library.markOpened(b.id);
      expect(library.workspaces.map((w) => w.label), ['B', 'A', 'C']);

      // Unknown ids are a no-op rather than a crash — a menu built from
      // a stale list must still resolve safely.
      await library.markOpened('ws-missing');
      expect(library.workspaces.map((w) => w.label), ['B', 'A', 'C']);
    });
  });

  group('id resolution', () {
    test('the menu keys on the persisted id, never the label', () async {
      await library.load();
      final saved = await library.save(
        label: 'Client X',
        snapshot: emptySnapshot(),
      );
      expect(
        library.workspaces.where((w) => w.id == saved.id).single.label,
        'Client X',
      );
      expect(library.workspaces.where((w) => w.id == 'Client X'), isEmpty);
    });
  });

  group('dispose', () {
    test('makes later opens a no-op and later saves a programming '
        'error', () async {
      await library.load();
      library.dispose();
      await library.markOpened('ws-any');
      expect(library.workspaces, isEmpty);
      expect(
        () => library.save(label: 'X', snapshot: emptySnapshot()),
        throwsAssertionError,
      );
    });
  });
}
