import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_app/services/workspace_state.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final _now = DateTime.utc(2026, 9, 16, 12);

Bookmark _bookmark(String id) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: 'web.example.com',
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: 'web.example.com',
      port: 22,
      username: 'tester',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/srv',
  sortKey: id,
  createdAt: _now,
  updatedAt: _now,
);

WorkspaceTabState _localTab(
  String path, {
  String filterQuery = '',
  bool filterFieldOpen = false,
  bool showHidden = false,
  PaneViewMode viewMode = PaneViewMode.details,
}) => WorkspaceTabState(
  session: SessionTabState.local(path: path),
  filterQuery: filterQuery,
  filterFieldOpen: filterFieldOpen,
  showHidden: showHidden,
  viewMode: viewMode,
);

final _fixture = WorkspaceListDocument(
  workspaces: [
    SavedWorkspace(
      id: 'ws-1',
      label: 'Client X',
      savedAt: _now,
      lastOpenedAt: null,
      snapshot: WorkspaceSnapshot(
        left: WorkspacePaneState(
          paneId: sessionLeftPaneId,
          activeTab: 1,
          tabs: [
            _localTab('/home/tester'),
            WorkspaceTabState(
              session: SessionTabState.remote(
                serverId: 'b1',
                path: '/srv/www',
                bookmark: _bookmark('b1'),
              ),
              filterQuery: 'log',
              filterFieldOpen: true,
              showHidden: true,
              viewMode: PaneViewMode.list,
            ),
          ],
        ),
        right: WorkspacePaneState(
          paneId: sessionRightPaneId,
          activeTab: -1,
          tabs: const [],
        ),
      ),
    ),
  ],
);

void main() {
  group('document round-trip', () {
    test('both panes, active tabs, and per-tab lenses survive', () {
      final decoded = WorkspaceListDocument.fromJson(_fixture.toJson());
      final saved = decoded.workspaces.single;
      expect(saved.id, 'ws-1');
      expect(saved.label, 'Client X');
      expect(saved.savedAt, _now);
      expect(saved.lastOpenedAt, isNull);

      final left = saved.snapshot.left;
      expect(left.paneId, sessionLeftPaneId);
      expect(left.activeTab, 1);
      expect(left.tabs, hasLength(2));
      expect(left.tabs[0].session.kind, SessionTabKind.local);
      expect(left.tabs[0].session.path, '/home/tester');
      final remote = left.tabs[1];
      expect(remote.session.kind, SessionTabKind.remote);
      expect(remote.session.serverId, 'b1');
      expect(remote.session.bookmark?.id, 'b1');
      expect(remote.filterQuery, 'log');
      expect(remote.filterFieldOpen, isTrue);
      expect(remote.showHidden, isTrue);
      expect(remote.viewMode, PaneViewMode.list);

      expect(saved.snapshot.right.tabs, isEmpty);
      expect(saved.snapshot.right.activeTab, -1);
    });

    test('json can re-encode to identical output', () {
      final decoded = WorkspaceListDocument.fromJson(_fixture.toJson());
      expect(decoded.toJson(), _fixture.toJson());
    });
  });

  group('strict decode', () {
    test('rejects a newer schema version', () {
      final json = _fixture.toJson()..['version'] = 2;
      expect(() => WorkspaceListDocument.fromJson(json), throwsFormatException);
    });

    test('rejects a non-map root and a missing list', () {
      expect(() => WorkspaceListDocument.fromJson('x'), throwsFormatException);
      expect(
        () => WorkspaceListDocument.fromJson({'version': 1}),
        throwsFormatException,
      );
    });

    test('rejects duplicate workspace ids — menu commands key on them', () {
      final dupe = _fixture.workspaces.single;
      final json = WorkspaceListDocument(workspaces: [dupe, dupe]).toJson();
      expect(() => WorkspaceListDocument.fromJson(json), throwsFormatException);
    });

    test('rejects an empty id or label', () {
      final json = _fixture.toJson();
      final workspace = (json['workspaces']! as List).first as Map;
      workspace['id'] = '';
      expect(() => WorkspaceListDocument.fromJson(json), throwsFormatException);
      workspace['id'] = 'ws-1';
      workspace['label'] = '  ';
      expect(() => WorkspaceListDocument.fromJson(json), throwsFormatException);
    });

    test('rejects a malformed timestamp', () {
      final json = _fixture.toJson();
      final workspace = (json['workspaces']! as List).first as Map;
      workspace['savedAt'] = 'not-ms';
      expect(() => WorkspaceListDocument.fromJson(json), throwsFormatException);
      workspace['savedAt'] = _now.millisecondsSinceEpoch;
      workspace['lastOpenedAt'] = 'soon';
      expect(() => WorkspaceListDocument.fromJson(json), throwsFormatException);
    });

    test('rejects a snapshot missing a canonical pane', () {
      final json = _fixture.toJson();
      final workspace = (json['workspaces']! as List).first as Map;
      final snapshot = workspace['snapshot'] as Map;
      snapshot['panes'] = [
        WorkspacePaneState(
          paneId: sessionLeftPaneId,
          activeTab: -1,
          tabs: const [],
        ).toJson(),
      ];
      expect(() => WorkspaceListDocument.fromJson(json), throwsFormatException);
    });

    test('rejects a duplicated pane id', () {
      final json = _fixture.toJson();
      final workspace = (json['workspaces']! as List).first as Map;
      final snapshot = workspace['snapshot'] as Map;
      final left = WorkspacePaneState(
        paneId: sessionLeftPaneId,
        activeTab: -1,
        tabs: const [],
      ).toJson();
      snapshot['panes'] = [left, left];
      expect(() => WorkspaceListDocument.fromJson(json), throwsFormatException);
    });

    test('rejects an out-of-range active tab index', () {
      final pane = WorkspacePaneState(
        paneId: sessionLeftPaneId,
        activeTab: 2,
        tabs: [_localTab('/a')],
      );
      expect(
        () => WorkspacePaneState.fromJson(pane.toJson()),
        throwsFormatException,
      );
    });

    test('rejects malformed lens fields', () {
      final json = _localTab('/a').toJson();
      for (final key in ['filterQuery', 'filterFieldOpen', 'hiddenFiles']) {
        final mutated = Map.of(json)..[key] = 42;
        expect(
          () => WorkspaceTabState.fromJson(mutated),
          throwsFormatException,
          reason: key,
        );
      }
      final badMode = Map.of(json)..['viewMode'] = 'grid';
      expect(() => WorkspaceTabState.fromJson(badMode), throwsFormatException);
    });

    test('rejects a malformed session half', () {
      final json = _localTab('/a').toJson()..['kind'] = 'fog';
      expect(() => WorkspaceTabState.fromJson(json), throwsFormatException);
    });

    test('ignores unknown fields (forward-compat posture)', () {
      final json = _fixture.toJson();
      json['future'] = true;
      final workspace = (json['workspaces']! as List).first as Map;
      workspace['extra'] = 1;
      final snapshot = workspace['snapshot'] as Map;
      final tab = (snapshot['panes']! as List).first as Map;
      (tab['tabs'] as List).cast<Map>().first['novel'] = 'x';
      expect(WorkspaceListDocument.fromJson(json).workspaces.single.id, 'ws-1');
    });
  });
}
