import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/double_click_action.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/sync_browsing_controller.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart';
import 'pane_tabs_controller_test.dart' show settle;

RemoteFileEntry _entry(String name, {String parent = '/home/tester'}) =>
    RemoteFileEntry(
      path: '$parent/$name',
      name: name,
      type: RemoteFileType.file,
      size: 10,
    );

Bookmark _bookmark(String id, {String remotePath = '/srv/home'}) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: '$id.example.com',
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: '$id.example.com',
      port: 22,
      username: 'tester',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: remotePath,
  sortKey: id,
  createdAt: DateTime.utc(2026, 9, 16),
  updatedAt: DateTime.utc(2026, 9, 16),
);

/// 02 §3's "drag tabs between panes" at the state layer: the move
/// crosses strips with object identity intact — no close guard (a move
/// is not a close), no ghost, no channel teardown — while the launcher
/// fallback, the hidden-pane no-op, and the §7 anchor rules hold at the
/// workspace seam.
void main() {
  late FakePaneLanes lanes;
  late PaneTabsController left;
  late PaneTabsController right;
  late WorkspaceController workspace;

  setUp(() {
    lanes = FakePaneLanes();
    left = PaneTabsController(
      paneId: PaneTabsController.leftPaneId,
      lanes: lanes,
    );
    right = PaneTabsController(
      paneId: PaneTabsController.rightPaneId,
      lanes: lanes,
    );
    workspace = WorkspaceController(left: left, right: right);
    addTearDown(workspace.dispose);
  });

  /// Binds a fresh left-strip tab to the local home channel.
  Future<PaneTab> openLeftTab({
    String homePath = '/home/tester',
    Map<String, List<RemoteFileEntry>> listings = const {},
  }) async {
    lanes.nextLocalChannel = FakePaneChannel(homePath)
      ..listings.addAll(listings);
    final tab = left.newTab(target: NewTabTarget.home);
    await settle();
    return tab;
  }

  group('the move (02 §3)', () {
    test('carries the tab object — and every per-tab state — across', () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('a.txt'), _entry('b.txt')]
        ..listings['/home/tester/sub'] = [_entry('c.txt', parent: '/home/tester/sub')];
      lanes.nextLocalChannel = channel;
      final tab = left.newTab(target: NewTabTarget.home);
      await settle();
      final controller = tab.controller;

      // Load the tab with the state the move must carry: a walked
      // history, a cursor/selection, a filter lens, the hidden override,
      // and a non-default view mode.
      controller.navigate('/home/tester/sub');
      await settle();
      controller.setCursorIndex(0);
      controller.openFilter();
      controller.changeFilterQuery('c');
      controller.showHidden = true;
      controller.viewMode = PaneViewMode.list;
      right.newTab(target: NewTabTarget.launcher);

      expect(workspace.moveTabToPane(tab, right), isTrue);

      expect(identical(right.activeTab, tab), isTrue);
      expect(identical(tab.controller, controller), isTrue);
      expect(controller.location, const LocalPaneLocation('/home/tester/sub'));
      expect(controller.filterQuery, 'c');
      expect(controller.filterFieldOpen, isTrue);
      expect(controller.showHidden, isTrue);
      expect(controller.viewMode, PaneViewMode.list);
      expect(controller.canGoBack, isTrue, reason: 'history travels');
      // The destination strip owns the forwarding now: a late notify on
      // the moved controller reaches the right strip, not the left.
      var leftNotifies = 0;
      var rightNotifies = 0;
      left.addListener(() => leftNotifies++);
      right.addListener(() => rightNotifies++);
      controller.viewMode = PaneViewMode.details;
      expect(rightNotifies, 1);
      expect(leftNotifies, 0);
    });

    test('a remote tab keeps its browse channel — no close, no reopen',
        () async {
      final channel = FakePaneChannel('/srv/home')
        ..listings['/srv/home'] = [_entry('r.txt', parent: '/srv/home')];
      lanes.nextRemoteChannel = channel;
      final tab = left.newTab(target: NewTabTarget.launcher);
      await tab.controller.connectRemote(_bookmark('srv-1'));
      await settle();
      final opens =
          lanes.calls.where((c) => c.startsWith('openBrowse')).length;

      expect(workspace.moveTabToPane(tab, right), isTrue);

      expect(
        lanes.calls.where((c) => c.startsWith('openBrowse')).length,
        opens,
        reason: 'the channel moves with the tab — the engine never '
            'tears it down and reopens it (03 §3.2)',
      );
      expect(channel.closeCalls, 0);
      expect(lanes.disconnects, isEmpty);
      expect(tab.controller.remoteBookmark?.id, 'srv-1');
      expect(
        tab.controller.location,
        const RemotePaneLocation('srv-1', '/srv/home'),
      );
    });

    test('the dropped tab lands at the requested index and activates',
        () async {
      final moved = left.newTab(target: NewTabTarget.launcher);
      final r1 = right.newTab(target: NewTabTarget.launcher);
      final r2 = right.newTab(target: NewTabTarget.launcher);

      workspace.moveTabToPane(moved, right, index: 1);

      expect(right.tabs, [r1, moved, r2]);
      expect(right.activeTab, same(moved));
      expect(workspace.activePane, same(right));
    });

    test('a null index appends; out-of-range indexes clamp', () async {
      final a = left.newTab(target: NewTabTarget.launcher);
      final b = left.newTab(target: NewTabTarget.launcher);
      right.newTab(target: NewTabTarget.launcher);

      workspace.moveTabToPane(a, right);
      expect(right.tabs.last, same(a));

      workspace.moveTabToPane(b, right, index: 99);
      expect(right.tabs.last, same(b));

      final c = left.newTab(target: NewTabTarget.launcher);
      workspace.moveTabToPane(c, right, index: -3);
      expect(right.tabs.first, same(c));
    });

    test('dragging the last tab away leaves the source on the launcher',
        () async {
      final tab = await openLeftTab();

      expect(workspace.moveTabToPane(tab, right), isTrue);

      expect(left.tabs, isEmpty);
      expect(left.activeTab, isNull, reason: 'the launcher state — never '
          'blank, never an auto-opened replacement (02 §2.7/§3)');
      expect(left.canReopen, isFalse, reason: 'a moved tab is not a '
          'closed tab — no ghost to reopen');
    });

    test('the close guard is not consulted — in-flight work never blocks '
        'the drag', () async {
      var presented = 0;
      final guardedLeft = PaneTabsController(
        paneId: PaneTabsController.leftPaneId,
        lanes: lanes,
        confirmClose: (_, _) async {
          presented++;
          return false;
        },
      );
      final guardedRight = PaneTabsController(
        paneId: PaneTabsController.rightPaneId,
        lanes: lanes,
      );
      final guardedWorkspace = WorkspaceController(
        left: guardedLeft,
        right: guardedRight,
      );
      addTearDown(guardedWorkspace.dispose);

      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('a.txt')];
      lanes.nextLocalChannel = channel;
      final tab = guardedLeft.newTab(target: NewTabTarget.home);
      await settle();

      // In-flight navigation + an open rename: both would fire the
      // close guard — the move must proceed without asking.
      channel.holdNext = Completer<void>();
      tab.controller.navigate('/home/tester/sub');
      expect(tab.controller.loading, isTrue);

      expect(guardedWorkspace.moveTabToPane(tab, guardedRight), isTrue);
      expect(presented, 0);
      expect(guardedRight.tabs, contains(tab));
    });

    test('an in-flight navigation settles on the destination pane',
        () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('a.txt')]
        ..listings['/home/tester/sub'] = [
          _entry('deep.txt', parent: '/home/tester/sub'),
        ];
      lanes.nextLocalChannel = channel;
      final tab = left.newTab(target: NewTabTarget.home);
      await settle();

      final hold = Completer<void>();
      channel.holdNext = hold;
      tab.controller.navigate('/home/tester/sub');
      await settle();
      expect(tab.controller.loading, isTrue);

      workspace.moveTabToPane(tab, right);
      expect(tab.controller.loading, isTrue, reason: 'the move never '
          'cancels the outstanding listing');

      hold.complete();
      await settle();
      expect(tab.controller.loading, isFalse);
      expect(
        tab.controller.location,
        const LocalPaneLocation('/home/tester/sub'),
      );
      expect(tab.controller.entries.single.name, 'deep.txt');
      expect(identical(right.activeTab, tab), isTrue);
    });

    test('an in-flight rename commit completes on the destination pane',
        () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('a.txt')];
      lanes.nextLocalChannel = channel;
      final tab = left.newTab(target: NewTabTarget.home);
      await settle();

      tab.controller.setCursorIndex(0);
      tab.controller.startRename();
      final held = Completer<void>();
      channel.heldRename = held;
      unawaited(tab.controller.submitRename('renamed.txt'));
      await settle();
      expect(tab.controller.inlineRenameActive, isTrue);

      workspace.moveTabToPane(tab, right);
      held.complete();
      await settle();

      expect(
        channel.renameCalls,
        [('/home/tester/a.txt', '/home/tester/renamed.txt')],
      );
      expect(tab.controller.inlineRenameActive, isFalse);
      expect(identical(right.activeTab, tab), isTrue);
    });
  });

  group('no-op drops (02 §3)', () {
    test('a drop on the same strip changes nothing', () async {
      final tab = await openLeftTab();
      final before = left.tabs;

      expect(workspace.moveTabToPane(tab, left), isFalse);

      expect(left.tabs, before);
      expect(left.activeTab, same(tab));
    });

    test('a foreign tab moves nowhere', () async {
      final outsider = PaneTabsController(
        paneId: 'pane.other',
        lanes: lanes,
      ).newTab(target: NewTabTarget.launcher);

      expect(workspace.moveTabToPane(outsider, right), isFalse);
      expect(right.tabs, isNot(contains(outsider)));
    });

    test('a hidden pane takes no drops and starts no drags', () async {
      final leftTab = await openLeftTab();
      final rightTab = right.newTab(target: NewTabTarget.launcher);
      workspace.setSecondPaneHidden(true);

      expect(
        workspace.moveTabToPane(leftTab, right),
        isFalse,
        reason: 'the unmounted strip cannot accept a drop',
      );
      expect(
        workspace.moveTabToPane(rightTab, left),
        isFalse,
        reason: 'a hidden pane\'s tabs never leave it (02 §3)',
      );
      expect(left.tabs, contains(leftTab));
      expect(right.tabs, contains(rightTab));
    });
  });

  group('the Sync Browsing link (02 §7)', () {
    /// Both panes bound local at scripted roots; the link anchors on
    /// their visible tabs.
    Future<({PaneTab leftTab, PaneTab rightTab})> linkedPair() async {
      lanes.nextLocalChannel = FakePaneChannel('/left/home')
        ..listings['/left/home'] = [
          _entry('l.txt', parent: '/left/home'),
        ];
      // nextLocalChannel is consumed inside the async channel open, so
      // each scripted channel must be armed AFTER the previous tab's
      // open has run — not merely after newTab returns.
      final leftTab = left.newTab(target: NewTabTarget.home);
      await settle();
      lanes.nextLocalChannel = FakePaneChannel('/right/home')
        ..listings['/right/home'] = [
          _entry('r.txt', parent: '/right/home'),
        ];
      final rightTab = right.newTab(target: NewTabTarget.home);
      await settle();
      expect(workspace.syncBrowsing.canLink, isTrue);
      workspace.syncBrowsing.toggle();
      expect(workspace.syncBrowsing.enabled, isTrue);
      return (leftTab: leftTab, rightTab: rightTab);
    }

    test('dragging an anchored tab to the other pane drops the link '
        'silently', () async {
      final pair = await linkedPair();

      expect(workspace.moveTabToPane(pair.leftTab, right), isTrue);

      // 02 §7: "both anchors must never share one pane" — the drop is
      // silent, and both anchor flags clear.
      expect(workspace.syncBrowsing.enabled, isFalse);
      expect(pair.leftTab.controller.syncAnchorActive, isFalse);
      expect(pair.rightTab.controller.syncAnchorActive, isFalse);
      expect(right.tabs, contains(pair.leftTab));
    });

    test('a non-anchored tab moving panes suspends, never drops', () async {
      final pair = await linkedPair();
      final second = left.newTab(target: NewTabTarget.launcher);
      await settle();

      expect(workspace.moveTabToPane(second, right), isTrue);

      // The anchored pair is intact but the moved tab displaced the
      // right anchor as the visible tab — the §7 re-visibility
      // suspension, same mechanism as a tab switch.
      expect(workspace.syncBrowsing.enabled, isTrue);
      expect(
        workspace.syncBrowsing.cause?.kind,
        SyncBrowseSuspension.pairNotVisible,
      );
      expect(pair.leftTab.controller.syncAnchorActive, isTrue);
      expect(pair.rightTab.controller.syncAnchorActive, isTrue);
    });
  });

  group('strip settings on arrival', () {
    test('a moved tab takes the destination strip\'s live double-click '
        'action', () async {
      right.doubleClickAction = DoubleClickAction.transfer;
      final tab = left.newTab(target: NewTabTarget.launcher);
      expect(tab.controller.doubleClickAction, DoubleClickAction.open);

      workspace.moveTabToPane(tab, right);

      expect(tab.controller.doubleClickAction, DoubleClickAction.transfer);
    });
  });
}
