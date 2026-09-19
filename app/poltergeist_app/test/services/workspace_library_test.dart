import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_app/services/workspace_library.dart';
import 'package:poltergeist_app/services/workspace_list_store.dart';
import 'package:poltergeist_app/services/workspace_state.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final _now = DateTime.utc(2026, 9, 16, 12);

/// A remote tab's binding as `captureSessionTab` persists it — the
/// `adhoc:` quick-connect bookmark, embedded identity and a vault
/// reference, never the secret itself.
Bookmark _adhoc(String id) => Bookmark(
  id: 'adhoc:$id',
  kind: BookmarkKind.remotePath,
  label: 'web-$id.example.com',
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: 'web-$id.example.com',
      port: 2222,
      username: 'deploy',
      authMethod: AuthMethod.password,
      secretRef: 'vault://web-$id',
    ),
  ),
  remotePath: '/srv/$id',
  sortKey: 'mm',
  createdAt: _now,
  updatedAt: _now,
);

WorkspaceTabState _localTab(String path) => WorkspaceTabState(
  session: SessionTabState.local(path: path),
  filterQuery: '',
  filterFieldOpen: false,
  showHidden: false,
  viewMode: PaneViewMode.details,
);

WorkspaceTabState _remoteTab(String id, String path) => WorkspaceTabState(
  session: SessionTabState.remote(
    serverId: 'adhoc:$id',
    path: path,
    bookmark: _adhoc(id),
  ),
  filterQuery: '',
  filterFieldOpen: false,
  showHidden: false,
  viewMode: PaneViewMode.details,
);

WorkspacePaneState _pane(
  String paneId,
  List<WorkspaceTabState> tabs, {
  int? activeTab,
}) => WorkspacePaneState(
  paneId: paneId,
  activeTab: activeTab ?? (tabs.isEmpty ? -1 : tabs.length - 1),
  tabs: tabs,
);

WorkspaceSnapshot _snapshot(
  List<WorkspaceTabState> left,
  List<WorkspaceTabState> right,
) => WorkspaceSnapshot(
  left: _pane(sessionLeftPaneId, left),
  right: _pane(sessionRightPaneId, right),
);

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;
  late File bookmarksFile;
  late SettingsStore settingsStore;
  late FileBookmarkStore bookmarks;
  late WorkspaceLibrary library;

  WorkspaceLibrary freshLibrary() => WorkspaceLibrary(
    store: WorkspaceListStore(
      store: SettingsStore(path: settingsFile.path),
    ),
    bookmarks: bookmarks,
  );

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'poltergeist_workspace_library_test_',
    );
    settingsFile = File(p.join(temporaryDirectory.path, 'settings.json'));
    bookmarksFile = File(p.join(temporaryDirectory.path, 'bookmarks.json'));
    settingsStore = SettingsStore(path: settingsFile.path);
    bookmarks = FileBookmarkStore(path: bookmarksFile.path);
    library = WorkspaceLibrary(
      store: WorkspaceListStore(store: settingsStore),
      bookmarks: bookmarks,
    );
  });

  tearDown(() {
    library.dispose();
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  Map<String, dynamic> settingsJson() =>
      jsonDecode(settingsFile.readAsStringSync()) as Map<String, dynamic>;

  /// The stored workspace document — null when the key is absent.
  Map<String, dynamic>? detailDoc() =>
      settingsJson()['workspaces.saved'] as Map<String, dynamic>?;

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
    test('mints one workspace favorite plus its device-local detail', () async {
      await library.load();
      final saved = await library.save(
        label: 'Client X',
        snapshot: _snapshot(
          [_localTab('/home/tester')],
          [_remoteTab('b1', '/srv/b1/www')],
        ),
      );

      // The synced half: one workspace-kind bookmark, same id, each
      // pane's headline endpoint — the active local path left, the
      // remote tab's identity right.
      final stored = await bookmarks.load();
      final favorite = stored.single;
      expect(favorite.id, saved.id);
      expect(favorite.kind, BookmarkKind.workspace);
      expect(favorite.label, 'Client X');
      expect(favorite.left!.path, '/home/tester');
      expect(favorite.left!.server, isNull);
      final rightServer = favorite.right!.server!.identity!;
      expect(favorite.right!.path, '/srv/b1/www');
      expect(rightServer.host, 'web-b1.example.com');
      expect(rightServer.port, 2222);
      expect(rightServer.username, 'deploy');
      expect(rightServer.secretRef, 'vault://web-b1');

      // The detail half: the full snapshot keyed to the favorite's id.
      final doc = detailDoc()!;
      expect(doc['version'], WorkspaceListDocument.schemaVersion);
      final joined = library.workspaces.single;
      expect(joined.id, saved.id);
      expect(joined.snapshot.right.tabs.single.session.path, '/srv/b1/www');
      expect(
        joined.snapshot.right.tabs.single.session.bookmark!.id,
        'adhoc:b1',
      );
    });

    test('a launcher pane records the home endpoint', () async {
      await library.load();
      await library.save(label: 'Empty', snapshot: _snapshot(const [], const []));

      final favorite = (await bookmarks.load()).single;
      expect(favorite.left!.path, '~');
      expect(favorite.left!.server, isNull);
      expect(favorite.right!.path, '~');
      expect(favorite.right!.server, isNull);
      // The detail still holds the true shape: no tabs at all.
      expect(library.workspaces.single.snapshot.left.tabs, isEmpty);
      expect(library.workspaces.single.snapshot.right.tabs, isEmpty);
    });

    test('a remote tab stores its identity — never a secret', () async {
      await library.load();
      await library.save(
        label: 'Remote',
        snapshot: _snapshot([_remoteTab('b1', '/srv/b1')], const []),
      );

      // The whole persisted payload is read back as raw JSON: the
      // payload-purity contract (04 §2.3/§2.4) holds for workspace
      // records too — schema keys only, no secret material anywhere.
      const allowedKeys = {
        'id',
        'kind',
        'label',
        'group',
        'color',
        'icon',
        'server',
        'localPath',
        'remotePath',
        'left',
        'right',
        'sync',
        'preferredPane',
        'sortKey',
        'createdAt',
        'updatedAt',
      };
      const forbiddenKeys = {'secret', 'password', 'passphrase', 'key'};
      void walk(Object? node) {
        if (node is Map) {
          for (final key in node.keys) {
            expect(forbiddenKeys, isNot(contains(key)));
          }
          node.values.forEach(walk);
        } else if (node is List) {
          node.forEach(walk);
        }
      }

      final file = jsonDecode(bookmarksFile.readAsStringSync());
      final record = (file['bookmarks'] as List).single as Map;
      expect(record.keys.toSet(), everyElement(isIn(allowedKeys)));
      walk(record);
    });

    test('persists across a full restart — bookmarks file and detail '
        'document both reloaded', () async {
      await library.load();
      final saved = await library.save(
        label: 'Client X',
        snapshot: _snapshot(
          [_localTab('/home/a'), _remoteTab('b1', '/srv/b1/www')],
          [_localTab('/srv/mirror')],
        ),
      );

      final reloaded = WorkspaceLibrary(
        store: WorkspaceListStore(
          store: SettingsStore(path: settingsFile.path),
        ),
        bookmarks: FileBookmarkStore(path: bookmarksFile.path),
      );
      await reloaded.load();
      addTearDown(reloaded.dispose);

      final ws = reloaded.workspaces.single;
      expect(ws.id, saved.id);
      expect(ws.label, 'Client X');
      final left = ws.snapshot.left;
      expect(left.tabs, hasLength(2));
      expect(left.tabs[0].session.path, '/home/a');
      expect(left.tabs[1].session.kind, SessionTabKind.remote);
      expect(left.tabs[1].session.serverId, 'adhoc:b1');
      expect(
        left.tabs[1].session.bookmark!.server!.identity!.host,
        'web-b1.example.com',
      );
      expect(ws.snapshot.right.tabs.single.session.path, '/srv/mirror');
    });

    test('saving over an existing label keeps the id and updates the '
        'favorite in place', () async {
      await library.load();
      final first = await library.save(
        label: 'Client X',
        snapshot: _snapshot([_localTab('/a')], const []),
      );
      await library.markOpened(first.id);
      expect(library.workspaces.single.lastOpenedAt, isNotNull);

      final saved = await library.save(
        label: 'client x', // case-insensitive save-over
        snapshot: _snapshot([_localTab('/b')], [_localTab('/c')]),
      );
      expect(saved.id, first.id);
      expect(library.workspaces, hasLength(1));
      expect(saved.lastOpenedAt, isNull);
      // One bookmark, not a duplicate.
      expect(await bookmarks.load(), hasLength(1));
      final favorite = (await bookmarks.load()).single;
      expect(favorite.left!.path, '/b');
      expect(favorite.right!.path, '/c');
      expect(
        library.workspaces.single.snapshot.left.tabs.single.session.path,
        '/b',
      );
    });

    test('notifies listeners so the menu and sidebar re-derive', () async {
      await library.load();
      var notified = 0;
      library.addListener(() => notified++);

      await library.save(
        label: 'Client X',
        snapshot: _snapshot(const [], const []),
      );
      // Detail write + bookmark change each publish once.
      expect(notified, greaterThanOrEqualTo(1));
      expect(library.workspaces.single.label, 'Client X');
    });

    test('rejects a blank label before persisting', () async {
      await library.load();
      expect(
        () => library.save(label: '   ', snapshot: _snapshot(const [], const [])),
        throwsArgumentError,
      );
      expect(
        () => library.save(label: '', snapshot: _snapshot(const [], const [])),
        throwsArgumentError,
      );
      expect(library.workspaces, isEmpty);
      expect(await bookmarks.load(), isEmpty);
    });
  });

  group('recapture', () {
    test('re-captures over the favorite — same id, no duplicate', () async {
      await library.load();
      final saved = await library.save(
        label: 'Client X',
        snapshot: _snapshot([_localTab('/a')], const []),
      );
      final createdAt = (await bookmarks.load()).single.createdAt;

      final updated = await library.recapture(
        saved.id,
        _snapshot(const [], [_remoteTab('b2', '/srv/b2')]),
      );

      expect(updated!.id, saved.id);
      expect(updated.label, 'Client X');
      expect(await bookmarks.load(), hasLength(1));
      final favorite = (await bookmarks.load()).single;
      expect(favorite.createdAt, createdAt);
      expect(favorite.right!.server!.identity!.host, 'web-b2.example.com');
      expect(
        library.workspaces.single.snapshot.right.tabs.single.session.path,
        '/srv/b2',
      );
    });

    test('an unknown id is a no-op, not an error', () async {
      await library.load();
      final result = await library.recapture(
        'ws-missing',
        _snapshot(const [], const []),
      );
      expect(result, isNull);
      expect(await bookmarks.load(), isEmpty);
    });
  });

  group('markOpened', () {
    test('stamps the detail record without reordering favorites', () async {
      await library.load();
      final a = await library.save(
        label: 'A',
        snapshot: _snapshot(const [], const []),
      );
      await library.save(label: 'B', snapshot: _snapshot(const [], const []));

      await library.markOpened(a.id);
      expect(
        library.workspaces.firstWhere((w) => w.id == a.id).lastOpenedAt,
        isNotNull,
      );
      // The favorites' order is the store's — an open does not reorder.
      expect(library.workspaces.map((w) => w.label), ['A', 'B']);

      // Unknown ids are a no-op rather than a crash — a menu built from
      // a stale list must still resolve safely.
      await library.markOpened('ws-missing');
      expect(library.workspaces, hasLength(2));
    });
  });

  group('bookmark store edges', () {
    test('a deleted favorite drops its detail — no resurrection on '
        'reload', () async {
      await library.load();
      final saved = await library.save(
        label: 'Client X',
        snapshot: _snapshot([_localTab('/a')], const []),
      );

      await bookmarks.remove(saved.id);
      expect(library.workspaces, isEmpty);
      // The detail write lands on the serialized tail — drain it, then
      // the reloaded pair must not resurrect the row.
      await pumpEventQueue();
      await settingsStore.flush();

      final reloaded = freshLibrary();
      await reloaded.load();
      addTearDown(reloaded.dispose);
      expect(reloaded.workspaces, isEmpty);
      expect(await bookmarks.load(), isEmpty);
    });

    test('a detail-less favorite joins as its own endpoints', () async {
      // A workspace captured elsewhere (or synced in later) has no
      // device-local detail — the reduced snapshot IS the record's
      // left/right endpoints, one tab per pane.
      await bookmarks.upsertAll([
        Bookmark(
          id: 'ws-foreign',
          kind: BookmarkKind.workspace,
          label: 'Shared pair',
          left: BookmarkLocation(
            server: BookmarkServerRef(
              identity: EmbeddedHostIdentity(
                host: 'shared.example.com',
                username: 'ops',
                authMethod: AuthMethod.agent,
                secretRef: 'vault://shared',
              ),
            ),
            path: '/srv/shared',
          ),
          right: const BookmarkLocation(path: '/tmp/out'),
          sortKey: 'm',
          createdAt: _now,
          updatedAt: _now,
        ),
      ]);
      await library.load();

      final ws = library.workspaces.single;
      expect(ws.id, 'ws-foreign');
      expect(ws.label, 'Shared pair');
      final left = ws.snapshot.left;
      expect(left.tabs.single.session.kind, SessionTabKind.remote);
      expect(left.tabs.single.session.path, '/srv/shared');
      final endpoint = left.tabs.single.session.bookmark!;
      expect(endpoint.id, 'ws-foreign:$sessionLeftPaneId');
      expect(endpoint.server!.identity!.host, 'shared.example.com');
      expect(endpoint.server!.identity!.secretRef, 'vault://shared');
      expect(ws.snapshot.right.tabs.single.session.path, '/tmp/out');
      expect(
        ws.snapshot.right.tabs.single.session.kind,
        SessionTabKind.local,
      );
      // A placeholder is still openable: markOpened finds no detail and
      // stays a no-op.
      await library.markOpened('ws-foreign');
      expect(library.workspaces.single.lastOpenedAt, isNull);
    });

    test('a sidebar rename shows through the join immediately', () async {
      await library.load();
      final saved = await library.save(
        label: 'Client X',
        snapshot: _snapshot(const [], const []),
      );

      final stored = await bookmarks.byId(saved.id);
      await bookmarks.save(
        Bookmark(
          id: stored!.id,
          kind: stored.kind,
          label: 'Renamed',
          left: stored.left,
          right: stored.right,
          sortKey: stored.sortKey,
          createdAt: stored.createdAt,
          updatedAt: stored.updatedAt,
        ),
      );

      expect(library.workspaces.single.label, 'Renamed');
      // The detail's snapshot survives untouched.
      expect(library.workspaces.single.id, saved.id);
    });
  });

  group('migration', () {
    test('a version-1 document mints its favorites once, keyed by id', () async {
      // Pre-M5 state: the saved list lived alone in settings.json.
      final legacy = WorkspaceListDocument(
        workspaces: [
          SavedWorkspace(
            id: 'ws-1',
            label: 'Client X',
            savedAt: _now,
            lastOpenedAt: null,
            snapshot: _snapshot(
              [_localTab('/home/a')],
              [_remoteTab('b1', '/srv/b1')],
            ),
          ),
          SavedWorkspace(
            id: 'ws-2',
            label: 'Archive',
            savedAt: _now,
            lastOpenedAt: null,
            snapshot: _snapshot(const [], const []),
          ),
        ],
      ).toJson()
        ..['version'] = 1;
      settingsFile.writeAsStringSync(
        jsonEncode({'workspaces.saved': legacy}),
      );

      await library.load();

      // Every record minted its favorite under the same id — the detail
      // doc stayed linked — with the panes' endpoints on the record.
      final stored = await bookmarks.load();
      expect(stored, hasLength(2));
      expect(stored.map((b) => b.id), containsAll(['ws-1', 'ws-2']));
      final first = stored.singleWhere((b) => b.id == 'ws-1');
      expect(first.kind, BookmarkKind.workspace);
      expect(first.label, 'Client X');
      expect(first.left!.path, '/home/a');
      expect(first.right!.server!.identity!.host, 'web-b1.example.com');
      expect(first.createdAt, _now);
      // The detail doc rewrote at the current schema — the migration
      // runs once.
      expect(detailDoc()!['version'], WorkspaceListDocument.schemaVersion);
      // The join still serves the full tab sets.
      expect(
        library.workspaces
            .firstWhere((w) => w.id == 'ws-1')
            .snapshot
            .left
            .tabs
            .single
            .session
            .path,
        '/home/a',
      );

      // A second load mints nothing new.
      final reloaded = freshLibrary();
      await reloaded.load();
      addTearDown(reloaded.dispose);
      expect(await bookmarks.load(), hasLength(2));
      expect(reloaded.workspaces, hasLength(2));
    });

    test('a v2 detail without its favorite is pruned, not resurrected', () async {
      // A workspace deleted on this device (or tombstoned by sync)
      // leaves its detail behind — the load reconciles it away.
      final doc = WorkspaceListDocument(
        workspaces: [
          SavedWorkspace(
            id: 'ws-orphan',
            label: 'Gone',
            savedAt: _now,
            lastOpenedAt: null,
            snapshot: _snapshot(const [], const []),
          ),
        ],
      );
      await WorkspaceListStore(store: settingsStore).save(doc);
      // Force a v2 write (the ctor's own version) — the orphan prune is
      // the v2 posture, not the v1 migration.
      await library.load();
      expect(library.workspaces, isEmpty);
      expect(
        (detailDoc()!['workspaces'] as List),
        isEmpty,
      );
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
        () => library.save(label: 'X', snapshot: _snapshot(const [], const [])),
        throwsAssertionError,
      );
    });
  });
}
