import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/services/workspace_state.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart';

Future<void> settle() => pumpEventQueue();

void main() {
  late FakePaneLanes lanes;
  late PaneTabsController left;
  late PaneTabsController right;
  late WorkspaceController workspace;

  /// The presenter the strips ask per triggered tab. Tests swap the
  /// answer through [confirmAnswer]; each call's triggers land in
  /// [presented] so a test can assert WHICH trigger blocked.
  final presented = <(PaneTab, List<TabCloseTrigger>)>[];
  bool Function(List<TabCloseTrigger>) confirmAnswer = (_) => true;

  setUp(() {
    lanes = FakePaneLanes();
    presented.clear();
    confirmAnswer = (_) => true;
    left = PaneTabsController(
      paneId: PaneTabsController.leftPaneId,
      lanes: lanes,
      confirmClose: (tab, triggers) async {
        presented.add((tab, triggers));
        return confirmAnswer(triggers);
      },
    );
    right = PaneTabsController(
      paneId: PaneTabsController.rightPaneId,
      lanes: lanes,
      confirmClose: (tab, triggers) async {
        presented.add((tab, triggers));
        return confirmAnswer(triggers);
      },
    );
    workspace = WorkspaceController(left: left, right: right);
  });

  tearDown(() {
    workspace.dispose();
    left.dispose();
    right.dispose();
  });

  /// The last channel the lanes minted — a test holds its next listing
  /// to keep a folder-size walk in flight.
  FakePaneChannel? lastChannel;

  /// Opens a bound local tab browsing [path]. `newTab`'s duplicate
  /// target on an empty strip yields an unbound tab; [openLocalAt]
  /// binds it through the lanes' scripted channel.
  Future<PaneController> openLocalTab(
    PaneTabsController strip,
    String path, {
    List<RemoteFileEntry> listing = const [],
    bool holdListing = false,
  }) async {
    final channel = FakePaneChannel('/home/tester')..listings[path] = listing;
    if (holdListing) channel.holdNext = Completer<void>();
    lanes.nextLocalChannel = channel;
    lastChannel = channel;
    final tab = strip.newTab();
    unawaited(tab.controller.openLocalAt(path));
    if (!holdListing) await settle();
    return tab.controller;
  }

  RemoteFileEntry directoryEntry(String name) => RemoteFileEntry(
    path: '/home/tester/$name',
    name: name,
    type: RemoteFileType.directory,
  );

  WorkspacePaneState paneState(
    String paneId,
    List<WorkspaceTabState> tabs, {
    int? activeTab,
  }) => WorkspacePaneState(
    paneId: paneId,
    activeTab: activeTab ?? (tabs.isEmpty ? -1 : tabs.length - 1),
    tabs: tabs,
  );

  WorkspaceTabState localTab(
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

  String? currentPath(PaneTabsController strip, int index) =>
      strip.tabs[index].controller.location?.path;

  group('captureWorkspace', () {
    test('captures both panes, active tabs, and per-tab lenses', () async {
      await openLocalTab(left, '/home/tester');
      await openLocalTab(right, '/srv');
      right.tabs.single.controller.restoreTransientState(
        filterQuery: 'log',
        filterFieldOpen: true,
        showHidden: true,
        viewMode: PaneViewMode.list,
      );

      final snapshot = workspace.captureWorkspace();
      expect(snapshot.left.paneId, PaneTabsController.leftPaneId);
      expect(snapshot.left.tabs.single.session.path, '/home/tester');
      expect(snapshot.left.activeTab, 0);
      expect(snapshot.right.activeTab, 0);
      final lens = snapshot.right.tabs.single;
      expect(lens.filterQuery, 'log');
      expect(lens.filterFieldOpen, isTrue);
      expect(lens.showHidden, isTrue);
      expect(lens.viewMode, PaneViewMode.list);
    });

    test('captures a remote binding for round-trip', () async {
      final bookmark = Bookmark(
        id: 'b1',
        kind: BookmarkKind.remotePath,
        label: 'web',
        server: BookmarkServerRef(
          identity: EmbeddedHostIdentity(
            host: 'web.example.com',
            port: 22,
            username: 'tester',
            authMethod: AuthMethod.password,
          ),
        ),
        remotePath: '/srv/www',
        sortKey: 'b1',
        createdAt: DateTime.utc(2026, 9, 16),
        updatedAt: DateTime.utc(2026, 9, 16),
      );
      // A restored remote tab carries the bookmark binding — the same
      // shape a live remote tab captures as. Keep the auto-reconnect
      // preference off so activation parks the tab instead of
      // connecting through the fake lanes.
      left.reconnectRestoredTabs = false;
      left.addTab(
        PaneController(paneTabId: 'pane.left.tab0', lanes: lanes)..markRestored(
          SessionTabState.remote(
            serverId: 'b1',
            path: '/srv/www',
            bookmark: bookmark,
          ),
        ),
      );

      final tab = workspace.captureWorkspace().left.tabs.single;
      expect(tab.session.kind, SessionTabKind.remote);
      expect(tab.session.serverId, 'b1');
      expect(tab.session.bookmark?.id, 'b1');
    });
  });

  group('guarded apply', () {
    test('replaces both panes and returns the prior snapshot', () async {
      await openLocalTab(left, '/home/tester');
      await openLocalTab(right, '/old-right');

      final prior = await workspace.requestApplyWorkspace(
        WorkspaceSnapshot(
          left: paneState('pane.left', [localTab('/new-left')]),
          right: paneState('pane.right', [localTab('/new-right')]),
        ),
      );
      // Rebind the lanes so the restored tabs' activation listing
      // answers (restored local tabs rebind on activation).
      await settle();

      expect(prior, isNotNull);
      expect(prior!.left.tabs.single.session.path, '/home/tester');
      expect(prior.right.tabs.single.session.path, '/old-right');
      expect(left.tabs.single.controller.location?.path, '/new-left');
      expect(right.tabs.single.controller.location?.path, '/new-right');
    });

    test('restores per-tab lenses through restoreTransientState', () async {
      await workspace.requestApplyWorkspace(
        WorkspaceSnapshot(
          left: paneState('pane.left', [
            localTab(
              '/work',
              filterQuery: 'dart',
              filterFieldOpen: true,
              showHidden: true,
              viewMode: PaneViewMode.list,
            ),
          ]),
          right: paneState('pane.right', const []),
        ),
      );

      final controller = left.tabs.single.controller;
      expect(controller.filterQuery, 'dart');
      expect(controller.filterFieldOpen, isTrue);
      expect(controller.showHidden, isTrue);
      expect(controller.viewMode, PaneViewMode.list);
    });

    test('restores the saved active tab, not the appended default', () async {
      await workspace.requestApplyWorkspace(
        WorkspaceSnapshot(
          left: paneState('pane.left', [
            localTab('/a'),
            localTab('/b'),
            localTab('/c'),
          ], activeTab: 1),
          right: paneState('pane.right', const []),
        ),
      );

      expect(identical(left.activeTab, left.tabs[1]), isTrue);
      expect(left.activeTab?.controller.location?.path, '/b');
    });
  });

  group('the replacement guard', () {
    test('an in-flight navigation blocks replacement and a decline '
        'leaves everything untouched', () async {
      final controller = await openLocalTab(left, '/home/tester');
      // A settled tab with a held navigation answer → the navigation
      // trigger armed deterministically.
      lastChannel!.holdNext = Completer<void>();
      controller.navigate('/home/tester/docs');

      confirmAnswer = (_) => false;
      final prior = await workspace.requestApplyWorkspace(
        WorkspaceSnapshot(
          left: paneState('pane.left', [localTab('/new')]),
          right: paneState('pane.right', const []),
        ),
      );

      expect(prior, isNull);
      expect(presented, hasLength(1));
      expect(presented.single.$2, [TabCloseTrigger.navigation]);
      expect(left.tabs.single.controller, same(controller));
      expect(right.tabs, isEmpty);
    });

    test('a right-pane decline leaves the left pane untouched too', () async {
      final leftTab = await openLocalTab(
        left,
        '/left',
        listing: [directoryEntry('d')],
      );
      leftTab.setCursorIndex(0);
      leftTab.startRename();
      final rightTab = await openLocalTab(
        right,
        '/right',
        listing: [directoryEntry('d')],
      );
      rightTab.setCursorIndex(0);
      rightTab.startRename();

      var calls = 0;
      confirmAnswer = (_) => ++calls < 2;
      final prior = await workspace.requestApplyWorkspace(
        WorkspaceSnapshot(
          left: paneState('pane.left', [localTab('/new-left')]),
          right: paneState('pane.right', [localTab('/new-right')]),
        ),
      );

      expect(prior, isNull);
      expect(calls, 2);
      expect(currentPath(left, 0), '/left');
      expect(currentPath(right, 0), '/right');
    });

    test('each remaining trigger blocks replacement', () async {
      // navigation is covered above; sweep rename, folder-size, and
      // sync-anchor — the three other live probes.
      for (final arm in [
        TabCloseTrigger.inlineRename,
        TabCloseTrigger.folderSize,
        TabCloseTrigger.syncAnchor,
      ]) {
        final controller = await openLocalTab(
          left,
          '/home/tester',
          listing: [directoryEntry('docs')],
        );
        switch (arm) {
          case TabCloseTrigger.inlineRename:
            controller.setCursorIndex(0);
            controller.startRename();
          case TabCloseTrigger.folderSize:
            controller.setCursorIndex(0);
            // Hold the walk's first listing so the trigger is still
            // armed when the guard probes.
            lastChannel!.holdNext = Completer<void>();
            controller.startFolderSize();
          case TabCloseTrigger.syncAnchor:
            controller.syncAnchorActive = true;
          default:
            fail('unexpected trigger $arm');
        }

        confirmAnswer = (_) => false;
        final prior = await workspace.requestApplyWorkspace(
          WorkspaceSnapshot(
            left: paneState('pane.left', [localTab('/new')]),
            right: paneState('pane.right', const []),
          ),
        );

        expect(prior, isNull, reason: '$arm');
        expect(presented, hasLength(1), reason: '$arm');
        expect(presented.single.$2, [arm], reason: '$arm');
        expect(controller.location?.path, '/home/tester', reason: '$arm');

        // Disarm the trigger, then clear the strip for the next leg.
        presented.clear();
        confirmAnswer = (_) => true;
        switch (arm) {
          case TabCloseTrigger.inlineRename:
            controller.cancelRename();
          case TabCloseTrigger.folderSize:
            controller.cancelFolderSize();
          case TabCloseTrigger.syncAnchor:
            controller.syncAnchorActive = false;
          default:
            fail('unexpected trigger $arm');
        }
        await left.requestCloseTab(left.tabs.single);
        await settle();
      }
    });

    test('fails closed with no presenter wired', () async {
      final errors = <Object>[];
      final bare = PaneTabsController(
        paneId: 'pane.bare',
        lanes: lanes,
        onError: (error, _) => errors.add(error),
      );
      addTearDown(bare.dispose);
      final bareWorkspace = WorkspaceController(
        left: bare,
        right: PaneTabsController(
          paneId: PaneTabsController.rightPaneId,
          lanes: lanes,
        ),
      );
      addTearDown(bareWorkspace.dispose);

      final controller = await openLocalTab(
        bare,
        '/home/tester',
        listing: [directoryEntry('d')],
      );
      controller.setCursorIndex(0);
      controller.startRename();

      final prior = await bareWorkspace.requestApplyWorkspace(
        WorkspaceSnapshot(
          left: paneState('pane.bare', [localTab('/new')]),
          right: paneState('pane.right', const []),
        ),
      );

      expect(prior, isNull);
      expect(errors, hasLength(1));
      expect(controller.location?.path, '/home/tester');
    });

    test(
      'confirmed guards replace and pass the fired triggers through',
      () async {
        final controller = await openLocalTab(
          left,
          '/home/tester',
          listing: [directoryEntry('docs')],
        );
        controller.setCursorIndex(0);
        controller.startRename();
        await openLocalTab(right, '/right');

        final prior = await workspace.requestApplyWorkspace(
          WorkspaceSnapshot(
            left: paneState('pane.left', [localTab('/new-left')]),
            right: paneState('pane.right', [localTab('/new-right')]),
          ),
        );
        await settle();

        expect(presented, hasLength(1));
        expect(presented.single.$2, [TabCloseTrigger.inlineRename]);
        expect(prior!.left.tabs.single.session.path, '/home/tester');
        expect(currentPath(left, 0), '/new-left');
        expect(currentPath(right, 0), '/new-right');
      },
    );
  });

  group('undo', () {
    test(
      'applying the prior snapshot restores the replaced tab sets',
      () async {
        await openLocalTab(left, '/original');
        await openLocalTab(right, '/old-right');

        final prior = await workspace.requestApplyWorkspace(
          WorkspaceSnapshot(
            left: paneState('pane.left', [localTab('/new-left')]),
            right: paneState('pane.right', const []),
          ),
        );
        await settle();
        expect(currentPath(left, 0), '/new-left');
        expect(right.tabs, isEmpty);

        final undone = await workspace.requestApplyWorkspace(prior!);
        await settle();
        expect(undone, isNotNull);
        expect(currentPath(left, 0), '/original');
        expect(currentPath(right, 0), '/old-right');
      },
    );

    test(
      'undo is itself guarded — a decline keeps the applied state',
      () async {
        await openLocalTab(left, '/original');
        final prior = await workspace.requestApplyWorkspace(
          WorkspaceSnapshot(
            left: paneState('pane.left', [localTab('/new-left')]),
            right: paneState('pane.right', const []),
          ),
        );
        await settle();
        expect(currentPath(left, 0), '/new-left');

        // Something new went in-flight on the applied tab: undo's guard
        // must see it and honor a decline. The anchor flag arms
        // regardless of the tab's listing state.
        left.tabs.single.controller.syncAnchorActive = true;
        presented.clear();
        confirmAnswer = (_) => false;
        final undone = await workspace.requestApplyWorkspace(prior!);

        expect(undone, isNull);
        expect(presented.single.$2, [TabCloseTrigger.syncAnchor]);
        expect(currentPath(left, 0), '/new-left');
      },
    );
  });
}
