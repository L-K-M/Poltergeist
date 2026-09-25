import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final _now = DateTime.utc(2026, 9, 12);

Bookmark _bookmark(String id, {String? remotePath = '/srv'}) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: 'web.example.com',
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: 'web.example.com',
      port: 22,
      username: 'tester',
      authMethod: AuthMethod.password,
      secretRef: 'secret-$id',
    ),
  ),
  remotePath: remotePath,
  sortKey: id,
  createdAt: _now,
  updatedAt: _now,
);

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
  int? mode,
}) => RemoteFileEntry(
  path: '/srv/www/$name',
  name: name,
  type: type,
  size: size,
  uid: 1000,
  gid: 1000,
  modifiedAt: DateTime.utc(2026, 9, 1, 12),
  mode: mode,
);

/// The two-pane multi-tab session 02 §3's round trip builds: remote +
/// local tabs on the left, one local tab on the right, pane B hidden,
/// the left pane active.
SessionState _fixture() => SessionState(
  activePaneId: PaneTabsController.leftPaneId,
  secondPaneHidden: true,
  panes: [
    SessionPaneState(
      paneId: PaneTabsController.leftPaneId,
      activeTab: 1,
      nextTabOrdinal: 4,
      tabs: [
        SessionTabState.remote(
          serverId: 'b1',
          path: '/srv/www',
          bookmark: _bookmark('b1'),
          listing: [
            _entry('assets', type: RemoteFileType.directory, mode: 0x41ED),
            _entry('index.html', size: 2048, mode: 0x81A4),
          ],
        ),
        const SessionTabState.local(path: '/home/tester/docs'),
        const SessionTabState.unbound(),
      ],
    ),
    SessionPaneState(
      paneId: PaneTabsController.rightPaneId,
      activeTab: 0,
      nextTabOrdinal: 2,
      tabs: const [SessionTabState.local(path: '/home/tester')],
    ),
  ],
);

/// [tab] alone in the left pane, beside an empty right pane.
SessionState _single(SessionTabState tab) => SessionState(
  activePaneId: PaneTabsController.leftPaneId,
  secondPaneHidden: true,
  panes: [
    SessionPaneState(
      paneId: PaneTabsController.leftPaneId,
      activeTab: 0,
      nextTabOrdinal: 2,
      tabs: [tab],
    ),
    const SessionPaneState(
      paneId: PaneTabsController.rightPaneId,
      activeTab: -1,
      nextTabOrdinal: 1,
      tabs: [],
    ),
  ],
);

void main() {
  // A Quick Connect to `sftp://user@host` and a SERVERS catalog open
  // both bind a bookmark that names no landing path (the server's home).
  // The Bookmark model requires one on decode, so writing that record
  // verbatim froze every later save and dropped the session on relaunch.
  group('a remote tab whose bookmark names no path', () {
    test('round-trips, landing at the server\'s home', () {
      final state = _single(
        SessionTabState.remote(
          serverId: 'adhoc:1',
          path: '/home/tester/www',
          bookmark: _bookmark('adhoc:1', remotePath: null),
        ),
      );
      final tab = SessionState.fromJson(state.toJson()).panes.first.tabs.single;
      expect(tab.path, '/home/tester/www');
      // "/" is the pane's own spelling of "the server's home" on bind.
      expect(tab.bookmark?.remotePath, '/');
    });

    test('decodes from a document already written without it', () {
      final json = _single(
        SessionTabState.remote(
          serverId: 'b1',
          path: '/srv/www',
          bookmark: _bookmark('b1'),
        ),
      ).toJson();
      final panes = json['panes']! as List<Object?>;
      final tabs =
          (panes.first! as Map<String, Object?>)['tabs']! as List<Object?>;
      final bookmark =
          (tabs.single! as Map<String, Object?>)['bookmark']!
              as Map<String, Object?>;
      bookmark.remove('remotePath');

      final tab = SessionState.fromJson(json).panes.first.tabs.single;
      expect(tab.bookmark?.remotePath, '/');
    });
  });

  test('round-trips a two-pane multi-tab session', () {
    final decoded = SessionState.fromJson(_fixture().toJson());

    expect(decoded.activePaneId, PaneTabsController.leftPaneId);
    expect(decoded.secondPaneHidden, isTrue);
    expect(decoded.panes, hasLength(2));

    final left = decoded.panes[0];
    expect(left.paneId, PaneTabsController.leftPaneId);
    expect(left.activeTab, 1);
    expect(left.nextTabOrdinal, 4);
    expect(left.tabs, hasLength(3));

    final remote = left.tabs[0];
    expect(remote.kind, SessionTabKind.remote);
    expect(remote.serverId, 'b1');
    expect(remote.path, '/srv/www');
    expect(remote.bookmark?.id, 'b1');
    expect(remote.bookmark?.label, 'web.example.com');
    expect(remote.bookmark?.server?.identity?.host, 'web.example.com');
    expect(remote.bookmark?.server?.identity?.secretRef, 'secret-b1');
    expect(remote.listing, hasLength(2));
    expect(remote.listing[0].name, 'assets');
    expect(remote.listing[0].type, RemoteFileType.directory);
    expect(remote.listing[0].mode, 0x41ED);
    expect(remote.listing[1].size, 2048);

    expect(left.tabs[1].kind, SessionTabKind.local);
    expect(left.tabs[1].path, '/home/tester/docs');
    expect(left.tabs[2].kind, SessionTabKind.unbound);

    final right = decoded.panes[1];
    expect(right.activeTab, 0);
    expect(right.tabs.single.path, '/home/tester');
  });

  test('round-trips an empty session — zero tabs per pane is legal', () {
    final decoded = SessionState.fromJson(
      const SessionState(
        activePaneId: PaneTabsController.leftPaneId,
        secondPaneHidden: false,
        panes: [
          SessionPaneState(
            paneId: PaneTabsController.leftPaneId,
            activeTab: -1,
            nextTabOrdinal: 3,
            tabs: [],
          ),
          SessionPaneState(
            paneId: PaneTabsController.rightPaneId,
            activeTab: -1,
            nextTabOrdinal: 1,
            tabs: [],
          ),
        ],
      ).toJson(),
    );

    expect(decoded.panes[0].tabs, isEmpty);
    expect(decoded.panes[0].activeTab, -1);
    expect(decoded.panes[1].tabs, isEmpty);
  });

  test('rejects a newer schema version', () {
    final json = _fixture().toJson()..['version'] = 2;
    expect(() => SessionState.fromJson(json), throwsFormatException);
  });

  test('rejects a malformed document and malformed present fields', () {
    expect(() => SessionState.fromJson('nope'), throwsFormatException);
    expect(() => SessionState.fromJson(<String, Object?>{}),
        throwsFormatException);

    final fixturePanes =
        _fixture().toJson()['panes']! as List<Object?>;
    for (final mutation in <Map<String, Object?>>[
      {..._fixture().toJson(), 'activePane': 7},
      {..._fixture().toJson(), 'secondPaneHidden': 'yes'},
      {..._fixture().toJson(), 'panes': 'not-a-list'},
      {
        ..._fixture().toJson(),
        'panes': [
          {'paneId': PaneTabsController.leftPaneId},
        ],
      },
      {
        ..._fixture().toJson(),
        'panes': [
          {
            'paneId': PaneTabsController.leftPaneId,
            'activeTab': 0,
            'nextTabOrdinal': 1,
            'tabs': [
              {'kind': 'teleport', 'path': '/x'},
            ],
          },
        ],
      },
      {
        ..._fixture().toJson(),
        'panes': [
          {
            'paneId': PaneTabsController.leftPaneId,
            'activeTab': 0,
            'nextTabOrdinal': 1,
            'tabs': [
              {'kind': 'remote', 'serverId': 'b1'},
            ],
          },
        ],
      },
      {
        ..._fixture().toJson(),
        'panes': [
          {
            'paneId': PaneTabsController.leftPaneId,
            'activeTab': 0,
            'nextTabOrdinal': 1,
            'tabs': [
              {
                'kind': 'local',
                'path': '/x',
                'listing': [
                  {'path': '/x/a', 'name': 'a', 'type': 'bogon'},
                ],
              },
            ],
          },
        ],
      },
      // Counter ranges and document shape are schema too: an active
      // index outside the tab list, an id counter below the first mint,
      // a truncated or padded pane list, and an active pane naming no
      // restored strip are all corrupt documents.
      {
        ..._fixture().toJson(),
        'panes': [
          {
            'paneId': PaneTabsController.leftPaneId,
            'activeTab': 5,
            'nextTabOrdinal': 4,
            'tabs': [
              {'kind': 'local', 'path': '/x'},
            ],
          },
          fixturePanes[1],
        ],
      },
      {
        ..._fixture().toJson(),
        'panes': [
          {
            'paneId': PaneTabsController.leftPaneId,
            'activeTab': -1,
            'nextTabOrdinal': 0,
            'tabs': [],
          },
          fixturePanes[1],
        ],
      },
      {
        ..._fixture().toJson(),
        'panes': [fixturePanes[0]],
      },
      {
        ..._fixture().toJson(),
        'activePane': 'pane.middle',
      },
      // A foreign pane id is corrupt even when it isn't the active
      // pane, and a duplicated pane id is not a pane pair.
      {
        ..._fixture().toJson(),
        'panes': [
          fixturePanes[0],
          {...fixturePanes[1]! as Map, 'paneId': 'pane.middle'},
        ],
      },
      {
        ..._fixture().toJson(),
        'panes': [fixturePanes[0], fixturePanes[0]],
      },
      // Three entries whose id-set still collapses to {left, right}:
      // set validation alone would pass and decode a pane twice.
      {
        ..._fixture().toJson(),
        'panes': [fixturePanes[0], fixturePanes[1], fixturePanes[0]],
      },
      // The id counter must sit above the tab count: restored tabs
      // mint positionally, so counter <= tabs.length would collide.
      {
        ..._fixture().toJson(),
        'panes': [
          {...fixturePanes[0]! as Map, 'nextTabOrdinal': 3},
          fixturePanes[1],
        ],
      },
    ]) {
      expect(() => SessionState.fromJson(mutation), throwsFormatException);
    }
  });

  test('the D32 inspector fields round-trip and stay optional', () {
    final base = _fixture();
    final withInspector = SessionState(
      activePaneId: base.activePaneId,
      secondPaneHidden: base.secondPaneHidden,
      inspectorHidden: true,
      inspectorTab: 'transfers',
      panes: base.panes,
    );
    final decoded = SessionState.fromJson(withInspector.toJson());
    expect(decoded.inspectorHidden, isTrue);
    expect(decoded.inspectorTab, 'transfers');

    // A document written before the inspector existed decodes them as
    // null — the shell derives them from the legacy activity flag.
    final legacy = base.toJson()
      ..remove('inspectorHidden')
      ..remove('inspectorTab');
    final old = SessionState.fromJson(legacy);
    expect(old.inspectorHidden, isNull);
    expect(old.inspectorTab, isNull);

    // Present fields are strictly typed like the rest of the root.
    for (final mutation in <Map<String, Object?>>[
      {...legacy, 'inspectorHidden': 'yes'},
      {...legacy, 'inspectorTab': 3},
    ]) {
      expect(() => SessionState.fromJson(mutation), throwsFormatException);
    }
  });

  test('ignores unknown fields — forward-compatible inside the version', () {
    final json = _fixture().toJson();
    json['futureField'] = {'nested': true};
    final panes = json['panes']! as List<Object?>;
    final pane0 = Map<String, Object?>.from(panes[0]! as Map);
    pane0['paneExtra'] = 42;
    final tabs = List<Object?>.from(pane0['tabs']! as List);
    tabs[0] = {...(tabs[0]! as Map), 'tabExtra': 'kept-out'};
    pane0['tabs'] = tabs;
    panes[0] = pane0;

    final decoded = SessionState.fromJson(json);
    expect(decoded.panes[0].tabs, hasLength(3));
    expect(decoded.panes[0].tabs[0].kind, SessionTabKind.remote);
  });
}
