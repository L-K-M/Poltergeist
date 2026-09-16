import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart';

final _now = DateTime.utc(2026, 9, 12);

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

RemoteFileEntry _row(String name) => RemoteFileEntry(
  path: '/srv/www/$name',
  name: name,
  type: RemoteFileType.file,
  size: 10,
);

SessionTabState _remoteTab(String serverId, {List<RemoteFileEntry>? rows}) =>
    SessionTabState.remote(
      serverId: serverId,
      path: '/srv/www',
      bookmark: _bookmark(serverId),
      listing: rows ?? [_row('a.txt'), _row('b.txt')],
    );

SessionPaneState _pane(List<SessionTabState> tabs, {int activeTab = 0}) =>
    SessionPaneState(
      paneId: PaneTabsController.leftPaneId,
      activeTab: activeTab,
      nextTabOrdinal: tabs.length + 1,
      tabs: tabs,
    );

void main() {
  late FakePaneLanes lanes;

  setUp(() {
    lanes = FakePaneLanes();
  });

  group('markRestored', () {
    test('adopts location, bookmark, and cached rows — inert, no channel',
        () {
      final controller = PaneController(
        paneTabId: 'pane.left.tab1',
        lanes: lanes,
      );
      addTearDown(controller.dispose);

      controller.markRestored(_remoteTab('b1'));

      expect(controller.phase, PanePhase.restored);
      expect(controller.restoredPending, isTrue);
      expect(controller.location,
          const RemotePaneLocation('b1', '/srv/www'));
      expect(controller.remoteBookmark?.id, 'b1');
      expect(controller.hasLiveRemoteBinding, isFalse);
      // The persisted snapshot renders as stale presentation, never
      // interactive rows, and no channel ever opened.
      expect(controller.staleRows, isTrue);
      expect(controller.entries.map((e) => e.name), ['a.txt', 'b.txt']);
      expect(lanes.calls, isEmpty);
      expect(controller.verbsEnabled, isFalse);
      expect(controller.loading, isFalse);
    });

    test('a local record restores the location without binding', () {
      final controller = PaneController(
        paneTabId: 'pane.left.tab1',
        lanes: lanes,
      );
      addTearDown(controller.dispose);

      controller.markRestored(
        const SessionTabState.local(path: '/home/tester/docs'),
      );

      expect(controller.phase, PanePhase.restored);
      expect(controller.location,
          const LocalPaneLocation('/home/tester/docs'));
      expect(controller.remoteBookmark, isNull);
      expect(lanes.calls, isEmpty);
    });

    test('an unbound record leaves the tab on the launcher', () {
      final controller = PaneController(
        paneTabId: 'pane.left.tab1',
        lanes: lanes,
      );
      addTearDown(controller.dispose);

      controller.markRestored(const SessionTabState.unbound());

      expect(controller.phase, PanePhase.unbound);
      expect(controller.restoredPending, isFalse);
      expect(controller.location, isNull);
    });
  });

  group('resumeRestored', () {
    test('a remote tab reconnects on the restored path', () async {
      final remoteChannel = FakePaneChannel('/srv');
      remoteChannel.listings['/srv/www'] = [_row('live.txt')];
      lanes.nextRemoteChannel = remoteChannel;
      final controller = PaneController(
        paneTabId: 'pane.left.tab1',
        lanes: lanes,
      );
      addTearDown(controller.dispose);
      controller.markRestored(_remoteTab('b1'));

      await controller.resumeRestored();
      await Future<void>.delayed(Duration.zero);

      expect(lanes.calls,
          containsAllInOrder(['watch:b1', 'openBrowse:b1:pane.left.tab1']));
      expect(controller.phase, PanePhase.browsing);
      expect(controller.hasLiveRemoteBinding, isTrue);
      expect(controller.staleRows, isFalse);
      expect(remoteChannel.listCalls, ['/srv/www']);
      expect(controller.entries.map((e) => e.name), ['live.txt']);
    });

    test('a local tab rebinds live on its restored path', () async {
      final localChannel = FakePaneChannel('/home/tester');
      localChannel.listings['/home/tester/docs'] = [_row('doc.md')];
      lanes.nextLocalChannel = localChannel;
      final controller = PaneController(
        paneTabId: 'pane.left.tab1',
        lanes: lanes,
      );
      addTearDown(controller.dispose);
      controller.markRestored(
        const SessionTabState.local(path: '/home/tester/docs'),
      );

      await controller.resumeRestored();
      await Future<void>.delayed(Duration.zero);

      expect(lanes.calls, ['openLocal:~']);
      expect(localChannel.listCalls, ['/home/tester/docs']);
      expect(controller.entries.map((e) => e.name), ['doc.md']);
    });
  });

  group('captureSessionTab', () {
    test('round-trips a restored remote tab unchanged', () {
      final controller = PaneController(
        paneTabId: 'pane.left.tab1',
        lanes: lanes,
      );
      addTearDown(controller.dispose);
      controller.markRestored(_remoteTab('b1'));

      final captured = controller.captureSessionTab();
      expect(captured.kind, SessionTabKind.remote);
      expect(captured.serverId, 'b1');
      expect(captured.path, '/srv/www');
      expect(captured.bookmark?.id, 'b1');
      expect(captured.listing.map((e) => e.name), ['a.txt', 'b.txt']);
    });

    test('captures a live remote tab with its sorted listing', () async {
      final remoteChannel = FakePaneChannel('/srv');
      remoteChannel.listings['/srv/www'] = [_row('z.txt'), _row('a.txt')];
      lanes.nextRemoteChannel = remoteChannel;
      final controller = PaneController(
        paneTabId: 'pane.left.tab1',
        lanes: lanes,
      );
      addTearDown(controller.dispose);
      await controller.connectRemote(_bookmark('b1'),
          initialPath: '/srv/www');
      await Future<void>.delayed(Duration.zero);

      final captured = controller.captureSessionTab();
      expect(captured.kind, SessionTabKind.remote);
      expect(captured.path, '/srv/www');
      // The §2.3 sort owns capture order — restore replays it as shown.
      expect(captured.listing.map((e) => e.name), ['a.txt', 'z.txt']);
    });

    test('captures a launcher tab as unbound', () {
      final controller = PaneController(
        paneTabId: 'pane.left.tab1',
        lanes: lanes,
      );
      addTearDown(controller.dispose);

      expect(controller.captureSessionTab().kind, SessionTabKind.unbound);
    });
  });

  group('restoreSession', () {
    test('rebuilds the strip — tabs, active index, id counter', () async {
      final strip = PaneTabsController(
        paneId: PaneTabsController.leftPaneId,
        lanes: lanes,
        // Auto-reconnect OFF keeps the restore inert for these asserts.
      )..reconnectRestoredTabs = false;
      addTearDown(strip.dispose);

      strip.restoreSession(
        SessionPaneState(
          paneId: PaneTabsController.leftPaneId,
          activeTab: 1,
          nextTabOrdinal: 5,
          tabs: [
            _remoteTab('b1'),
            const SessionTabState.local(path: '/home/tester'),
          ],
        ),
      );

      expect(strip.tabs.map((t) => t.id),
          ['pane.left.tab1', 'pane.left.tab2']);
      expect(strip.activeTab?.id, 'pane.left.tab2');
      // A later mint cannot collide with the persisted ids.
      expect(strip.newTab(target: NewTabTarget.launcher).id,
          'pane.left.tab5');
      // Activation of the restored remote tab with auto-reconnect OFF
      // must not have connected anything.
      expect(lanes.calls, isEmpty);
    });

    test('auto-reconnect ON resumes the active restored remote tab',
        () async {
      lanes.nextRemoteChannel = FakePaneChannel('/srv')
        ..listings['/srv/www'] = [_row('live.txt')];
      final strip = PaneTabsController(
        paneId: PaneTabsController.leftPaneId,
        lanes: lanes,
      );
      addTearDown(strip.dispose);

      strip.restoreSession(_pane([_remoteTab('b1')]));
      await Future<void>.delayed(Duration.zero);

      expect(
        lanes.calls,
        containsAllInOrder(['watch:b1', 'openBrowse:b1:pane.left.tab1']),
      );
    });

    test(
      'auto-reconnect OFF: activation alone never reconnects — '
      'the bar button does',
      () async {
        lanes.nextRemoteChannel = FakePaneChannel('/srv')
          ..listings['/srv/www'] = [_row('live.txt')];
        final strip = PaneTabsController(
          paneId: PaneTabsController.leftPaneId,
          lanes: lanes,
        )..reconnectRestoredTabs = false;
        addTearDown(strip.dispose);

        strip.restoreSession(
          _pane([
            const SessionTabState.local(path: '/home/tester'),
            _remoteTab('b1'),
          ], activeTab: 0),
        );
        await Future<void>.delayed(Duration.zero);
        // The LOCAL active tab rebinds regardless of the setting.
        expect(lanes.calls, ['openLocal:~']);
        lanes.calls.clear();

        // Activating the restored remote tab — still nothing.
        strip.activateTab(strip.tabs[1]);
        await Future<void>.delayed(Duration.zero);
        expect(lanes.calls, isEmpty);
        expect(strip.activeTab!.controller.restoredPending, isTrue);

        // The explicit gesture is what reconnects.
        await strip.activeTab!.controller.resumeRestored();
        await Future<void>.delayed(Duration.zero);
        expect(
          lanes.calls,
          containsAllInOrder(['watch:b1', 'openBrowse:b1:pane.left.tab2']),
        );
      },
    );

    test('a restored empty pane stays on the launcher', () {
      final strip = PaneTabsController(
        paneId: PaneTabsController.leftPaneId,
        lanes: lanes,
      );
      addTearDown(strip.dispose);

      strip.restoreSession(
        const SessionPaneState(
          paneId: PaneTabsController.leftPaneId,
          activeTab: -1,
          nextTabOrdinal: 2,
          tabs: [],
        ),
      );

      expect(strip.tabs, isEmpty);
      expect(strip.activeTab, isNull);
      expect(lanes.calls, isEmpty);
    });

    test('a persisted unbound tab restores as a launcher tab', () {
      final strip = PaneTabsController(
        paneId: PaneTabsController.leftPaneId,
        lanes: lanes,
      );
      addTearDown(strip.dispose);

      strip.restoreSession(
        const SessionPaneState(
          paneId: PaneTabsController.leftPaneId,
          activeTab: 0,
          nextTabOrdinal: 2,
          tabs: [SessionTabState.unbound()],
        ),
      );

      expect(strip.tabs, hasLength(1));
      expect(strip.activeTab?.controller.phase, PanePhase.unbound);
      expect(lanes.calls, isEmpty);
    });
  });

  group('restored-tab lifecycle', () {
    test('closing a restored remote tab drops no pool reference',
        () async {
      final strip = PaneTabsController(
        paneId: PaneTabsController.leftPaneId,
        lanes: lanes,
      )..reconnectRestoredTabs = false;
      addTearDown(strip.dispose);
      strip.restoreSession(_pane([_remoteTab('b1')]));

      await strip.requestCloseTab(strip.tabs.single);

      expect(strip.tabs, isEmpty);
      expect(lanes.disconnects, isEmpty);
    });

    test('a restored remote tab does not count as a live sibling', () {
      final workspace = WorkspaceController(
        left: PaneTabsController(
          paneId: PaneTabsController.leftPaneId,
          lanes: lanes,
        )..reconnectRestoredTabs = false,
        right: PaneTabsController(
          paneId: PaneTabsController.rightPaneId,
          lanes: lanes,
        )..reconnectRestoredTabs = false,
      );
      addTearDown(workspace.dispose);
      workspace.left.restoreSession(
        SessionPaneState(
          paneId: PaneTabsController.leftPaneId,
          activeTab: 0,
          nextTabOrdinal: 2,
          tabs: [_remoteTab('b1')],
        ),
      );
      workspace.right.restoreSession(
        SessionPaneState(
          paneId: PaneTabsController.rightPaneId,
          activeTab: 0,
          nextTabOrdinal: 2,
          tabs: [_remoteTab('b1')],
        ),
      );

      // Both panes restored the same server offline: neither counts the
      // other as a live binding (no pool reference exists to protect),
      // so the workspace's last-binding check answers false.
      expect(
        workspace.serverStillBound(
          'b1',
          workspace.left.tabs.single.controller,
        ),
        isFalse,
      );
    });
  });

  group('captureSession', () {
    test('round-trips strip shape: order, active index, counter', () async {
      final strip = PaneTabsController(
        paneId: PaneTabsController.leftPaneId,
        lanes: lanes,
      )..reconnectRestoredTabs = false;
      addTearDown(strip.dispose);
      strip.restoreSession(
        SessionPaneState(
          paneId: PaneTabsController.leftPaneId,
          activeTab: 1,
          nextTabOrdinal: 4,
          tabs: [
            _remoteTab('b1'),
            const SessionTabState.local(path: '/home/tester'),
            const SessionTabState.unbound(),
          ],
        ),
      );

      final captured = strip.captureSession();
      expect(captured.paneId, PaneTabsController.leftPaneId);
      expect(captured.activeTab, 1);
      expect(captured.nextTabOrdinal, 4);
      expect(captured.tabs.map((t) => t.kind), [
        SessionTabKind.remote,
        SessionTabKind.local,
        SessionTabKind.unbound,
      ]);
    });
  });
}
