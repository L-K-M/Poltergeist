import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/sync_browsing_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/test_panes.dart';
import 'pane_controller_test.dart';

/// Sync Browsing (02 §7): the workspace-level link that replays a pane's
/// relative navigation at the same path below the other pane's anchor.
/// These tests drive the real PaneControllers end to end — the link may
/// only ever ride the ordinary navigation machinery (02 §2.8), so a
/// committed listing is what moves a pane, a failed one is not.
void main() {
  /// The fakes' listing/probe chain resolves across several microtask
  /// hops (commit → evaluate → mirror probe → mirrored list → commit),
  /// so drain the queue to quiescence rather than counting turns.
  Future<void> settle() => pumpEventQueue();

  RemoteFileEntry entry(
    String name, {
    String parent = '/x',
    RemoteFileType type = RemoteFileType.file,
  }) => RemoteFileEntry(
    path: '$parent/$name',
    name: name,
    type: type,
    size: 10,
  );

  Bookmark remoteBookmark({String remotePath = '/srv/home'}) => Bookmark(
    id: 'srv-1',
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
    remotePath: remotePath,
    sortKey: 'k',
    createdAt: DateTime.utc(2026, 9, 14),
    updatedAt: DateTime.utc(2026, 9, 14),
  );

  /// Both panes bound local at their own roots: the anchor pair is
  /// `/left/home` ↔ `/right/home`, with `docs/` mirrored on both sides
  /// and `leftOnly/` present only on the left.
  ({
    FakePaneLanes lanes,
    FakePaneChannel leftChannel,
    FakePaneChannel rightChannel,
    PaneController left,
    PaneController right,
    PaneTabsController leftStrip,
    PaneTabsController rightStrip,
    WorkspaceController workspace,
    SyncBrowsingController sync,
  })
  rig({TabCloseConfirm? leftConfirmClose}) {
    final lanes = FakePaneLanes();
    final leftChannel = FakePaneChannel('/left/home')
      ..listings['/left/home'] = [
        entry('docs', parent: '/left/home', type: RemoteFileType.directory),
        entry('leftOnly', parent: '/left/home', type: RemoteFileType.directory),
        entry('notes.txt', parent: '/left/home'),
      ]
      ..listings['/left/home/docs'] = [
        entry('inner.txt', parent: '/left/home/docs'),
      ]
      ..listings['/left/home/docs/deep'] = [
        entry('deep.txt', parent: '/left/home/docs/deep'),
      ]
      ..listings['/left/home/leftOnly'] = [
        entry('l.txt', parent: '/left/home/leftOnly'),
      ]
      ..listings['/left'] = [
        entry('home', parent: '/left', type: RemoteFileType.directory),
      ]
      ..listings['/elsewhere'] = [entry('e.txt', parent: '/elsewhere')];
    final rightChannel = FakePaneChannel('/right/home')
      ..listings['/right/home'] = [
        entry('docs', parent: '/right/home', type: RemoteFileType.directory),
        entry('notes.txt', parent: '/right/home'),
      ]
      ..listings['/right/home/docs'] = [
        entry('inner.txt', parent: '/right/home/docs'),
      ]
      ..listings['/right/home/docs/deep'] = [
        entry('deep.txt', parent: '/right/home/docs/deep'),
      ];
    final left = PaneController(paneTabId: 'pane.left.tab1', lanes: lanes);
    final right = PaneController(
      paneTabId: 'pane.right.tab1',
      lanes: lanes,
    );
    final leftStrip = testPaneStrip(
      left,
      lanes: lanes,
      confirmClose: leftConfirmClose,
    );
    final rightStrip = testPaneStrip(right, lanes: lanes);
    final workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    addTearDown(workspace.dispose);
    return (
      lanes: lanes,
      leftChannel: leftChannel,
      rightChannel: rightChannel,
      left: left,
      right: right,
      leftStrip: leftStrip,
      rightStrip: rightStrip,
      workspace: workspace,
      sync: workspace.syncBrowsing,
    );
  }

  /// Binds both panes at their scripted homes.
  Future<void> openHomes(
    ({
      FakePaneLanes lanes,
      FakePaneChannel leftChannel,
      FakePaneChannel rightChannel,
      PaneController left,
      PaneController right,
      PaneTabsController leftStrip,
      PaneTabsController rightStrip,
      WorkspaceController workspace,
      SyncBrowsingController sync,
    })
    r,
  ) async {
    r.lanes.nextLocalChannel = r.leftChannel;
    await r.left.openLocalHome();
    r.lanes.nextLocalChannel = r.rightChannel;
    await r.right.openLocalHome();
    await settle();
  }

  group('enable / drop (02 §7)', () {
    test('toggling on records both current directories as the anchor pair',
        () async {
      final r = rig();
      await openHomes(r);

      expect(r.sync.enabled, isFalse);
      expect(r.sync.canLink, isTrue);

      r.sync.toggle();
      expect(r.sync.enabled, isTrue);
      expect(r.sync.suspended, isFalse);
      expect(r.sync.leftAnchor, const LocalPaneLocation('/left/home'));
      expect(r.sync.rightAnchor, const LocalPaneLocation('/right/home'));
      expect(r.left.syncAnchorActive, isTrue);
      expect(r.right.syncAnchorActive, isTrue);
    });

    test('toggling off drops the link and clears the anchor flags', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();

      r.sync.toggle();
      expect(r.sync.enabled, isFalse);
      expect(r.left.syncAnchorActive, isFalse);
      expect(r.right.syncAnchorActive, isFalse);
    });

    test('cannot link while a pane stands nowhere (02 §7 needs two '
        'committed directories)', () async {
      final r = rig();
      r.lanes.nextLocalChannel = r.leftChannel;
      await r.left.openLocalHome();
      await settle();
      expect(r.sync.canLink, isFalse);
      r.sync.toggle();
      expect(r.sync.enabled, isFalse);
    });
  });

  group('replay (02 §7)', () {
    test('navigating into a child replays the same relative path on the '
        'other pane', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();

      r.left.navigate('/left/home/docs');
      await settle();
      await settle();

      expect(r.left.location?.path, '/left/home/docs');
      expect(r.right.location?.path, '/right/home/docs');
      expect(r.sync.suspended, isFalse);
    });

    test('navigating to a parent inside the subtree replays', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();
      r.left.navigate('/left/home/docs');
      await settle();
      await settle();

      r.left.goUp();
      await settle();
      await settle();

      expect(r.left.location?.path, '/left/home');
      expect(r.right.location?.path, '/right/home');
      expect(r.sync.suspended, isFalse);
    });

    test('a path-bar jump inside the subtree replays at the same '
        'relative depth', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();

      r.left.navigate('/left/home/docs/deep');
      await settle();
      await settle();

      expect(r.right.location?.path, '/right/home/docs/deep');
      expect(r.sync.suspended, isFalse);
    });

    test('a failed navigation never drags the mirror — the pane did not '
        'commit anywhere', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();

      // No scripted listing at /left/home/ghost: the pane's location
      // moves optimistically and errors; nothing committed, so the link
      // stays linked and the other pane stays put.
      r.left.navigate('/left/home/ghost');
      await settle();
      await settle();

      expect(r.left.location?.path, '/left/home/ghost');
      expect(r.left.committedLocation?.path, '/left/home');
      expect(r.right.location?.path, '/right/home');
      expect(r.sync.enabled, isTrue);
      expect(r.sync.suspended, isFalse);
    });

    test('the link works across endpoints — a local pane mirrors a '
        'remote pane', () async {
      final lanes = FakePaneLanes();
      lanes.nextLocalChannel = FakePaneChannel('/left/home')
        ..listings['/left/home'] = [
          entry('docs', parent: '/left/home', type: RemoteFileType.directory),
        ]
        ..listings['/left/home/docs'] = [
          entry('inner.txt', parent: '/left/home/docs'),
        ];
      lanes.nextRemoteChannel = FakePaneChannel('/srv/home')
        ..listings['/srv/home'] = [
          entry('docs', parent: '/srv/home', type: RemoteFileType.directory),
        ]
        ..listings['/srv/home/docs'] = [
          entry('inner.txt', parent: '/srv/home/docs'),
        ];
      final left = PaneController(paneTabId: 'pane.left.tab1', lanes: lanes);
      final right = PaneController(
        paneTabId: 'pane.right.tab1',
        lanes: lanes,
      );
      final workspace = WorkspaceController(
        left: testPaneStrip(left, lanes: lanes),
        right: testPaneStrip(right, lanes: lanes),
      );
      addTearDown(workspace.dispose);
      await left.openLocalHome();
      await right.connectRemote(remoteBookmark());
      await settle();

      workspace.syncBrowsing.toggle();
      left.navigate('/left/home/docs');
      await settle();
      await settle();

      expect(
        right.location,
        const RemotePaneLocation('srv-1', '/srv/home/docs'),
      );
    });
  });

  group('suspension (02 §7)', () {
    test('going above the anchor suspends; the mover completes, the '
        'other pane stays put', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();

      r.left.goUp(); // '/left/home' → '/left': escapes the anchor root.
      await settle();
      await settle();

      expect(r.left.location?.path, '/left');
      expect(r.right.location?.path, '/right/home');
      expect(r.sync.enabled, isTrue);
      expect(r.sync.cause?.kind, SyncBrowseSuspension.outsideAnchor);
    });

    test('a jump outside the subtree suspends the same way — no `..` '
        'replay', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();

      r.left.navigate('/elsewhere');
      await settle();
      await settle();

      expect(r.left.location?.path, '/elsewhere');
      expect(r.right.location?.path, '/right/home');
      expect(r.sync.cause?.kind, SyncBrowseSuspension.outsideAnchor);
    });

    test('a missing mirror suspends and names the side it is missing '
        'on', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();

      // `leftOnly` exists on the left only: the mirror probe fails on
      // the right pane, which stays put while the mover completes.
      r.left.navigate('/left/home/leftOnly');
      await settle();
      await settle();

      expect(r.left.location?.path, '/left/home/leftOnly');
      expect(r.right.location?.path, '/right/home');
      expect(r.sync.cause?.kind, SyncBrowseSuspension.mirrorMissing);
      expect(r.sync.cause?.missingName, 'leftOnly');
      expect(r.sync.cause?.missingOnLeftPane, isFalse);
    });
  });

  group('auto-resume (02 §7)', () {
    test('a pane navigating to the matching relative path resumes the '
        'link without the other pane moving', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();
      r.left.navigate('/left/home/leftOnly');
      await settle();
      await settle();
      expect(r.sync.cause?.kind, SyncBrowseSuspension.mirrorMissing);

      // The mover walks back to the anchor — both panes now stand at
      // the same relative path, so the link resumes. The right pane
      // never moved: resume is not a snap-into-place.
      r.left.navigate('/left/home');
      await settle();
      await settle();

      expect(r.sync.suspended, isFalse);
      expect(r.right.location?.path, '/right/home');
      expect(r.left.location?.path, '/left/home');
    });

    test('the resume predicate is the single gate: mismatched or '
        'outside states stay suspended', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();
      r.left.goUp(); // escapes: suspended outsideAnchor.
      await settle();
      await settle();

      // Back inside but not at the other's relative path: no resume.
      r.left.navigate('/left/home/docs');
      await settle();
      await settle();
      expect(r.sync.suspended, isTrue);
      expect(r.right.location?.path, '/right/home');

      // The right pane's own navigation to the same relative path is
      // the re-evaluation that resumes the link.
      r.right.navigate('/right/home/docs');
      await settle();
      await settle();
      expect(r.sync.suspended, isFalse);
      expect(r.left.location?.path, '/left/home/docs');
    });
  });

  group('server changes (02 §7)', () {
    test('a committed server change drops the link silently', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();

      r.lanes.nextRemoteChannel = FakePaneChannel('/srv/home')
        ..listings['/srv/home'] = [entry('r.txt', parent: '/srv/home')];
      await r.right.connectRemote(remoteBookmark());
      await settle();

      expect(r.sync.enabled, isFalse);
      expect(r.left.syncAnchorActive, isFalse);
      expect(r.right.syncAnchorActive, isFalse);
    });

    test('an Esc-cancelled server change keeps the link — the drop is '
        'commit-gated', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();
      // 'notes.txt' at index 1 — non-default, so the restored cursor
      // and selection are observable rather than the fresh-listing 0.
      r.right.setCursorIndex(1);
      final oldChannel = r.rightChannel;

      // Rebind starts: the pane stands nowhere until the new channel's
      // first listing commits. Esc during the landing listing is
      // §2.8's navigation cancel — no commit, no drop, and the prior
      // pane snapshot comes back with no manual rebuild.
      final held = Completer<void>();
      final candidate = FakePaneChannel('/srv/home')
        ..listings['/srv/home'] = [entry('r.txt', parent: '/srv/home')]
        ..holdNext = held;
      r.lanes.nextRemoteChannel = candidate;
      await r.right.connectRemote(remoteBookmark());
      await settle();
      expect(r.right.loading, isTrue);

      r.right.cancelNavigation();
      await settle();

      // The §2.8 restore is immediate: old location, committed marker,
      // rows, and selection — still browsing the OLD channel while only
      // the candidate retires.
      expect(r.right.location, const LocalPaneLocation('/right/home'));
      expect(
        r.right.committedLocation,
        const LocalPaneLocation('/right/home'),
      );
      expect(r.right.entries.map((e) => e.name), ['docs', 'notes.txt']);
      expect(r.right.loading, isFalse);
      expect(r.right.cursorIndex, 1);
      expect(r.right.isRowSelected(1), isTrue);
      expect(r.sync.enabled, isTrue);
      expect(r.sync.suspended, isFalse);
      expect(oldChannel.closeCalls, 0);
      expect(candidate.closeCalls, 1);

      // The restored binding is usable: a navigation lands on the old
      // channel and replays across the kept link like any commit.
      r.right.navigate('/right/home/docs');
      await settle(); // commit lands on the restored channel
      await settle(); // sync replay propagates to the left pane
      expect(oldChannel.listCalls, contains('/right/home/docs'));
      expect(
        r.right.committedLocation,
        const LocalPaneLocation('/right/home/docs'),
      );
      expect(r.left.location, const LocalPaneLocation('/left/home/docs'));
      expect(r.sync.suspended, isFalse);

      // The cancelled candidate's late listing must not alter the
      // restored pane or the link.
      held.complete();
      await settle();
      expect(
        r.right.location,
        const LocalPaneLocation('/right/home/docs'),
      );
      expect(r.right.entries.map((e) => e.name), ['inner.txt']);
      expect(candidate.listCalls, ['/srv/home']);
      // The restored binding outlives the late candidate answer.
      expect(oldChannel.closeCalls, 0);
      expect(r.sync.enabled, isTrue);
      expect(r.sync.suspended, isFalse);
    });

    test('cancelling a server change before the channel opens restores '
        'the prior binding too', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();
      r.right.setCursorIndex(1); // non-default, restore is observable
      final oldChannel = r.rightChannel;

      // The open itself is held: the §2.7 Cancel (the shell's
      // sibling-aware path) restores the browsing session instead of
      // detaching to the launcher.
      final heldOpen = Completer<void>();
      r.lanes.holdRemoteOpen = heldOpen;
      final candidate = FakePaneChannel('/srv/home')
        ..listings['/srv/home'] = [entry('r.txt', parent: '/srv/home')];
      r.lanes.nextRemoteChannel = candidate;
      final connecting = r.right.connectRemote(remoteBookmark());
      await settle();
      expect(r.right.phase, PanePhase.connectingRemote);

      await r.right.cancelRecovery();
      await settle();

      expect(r.right.phase, PanePhase.browsing);
      expect(r.right.location, const LocalPaneLocation('/right/home'));
      expect(
        r.right.committedLocation,
        const LocalPaneLocation('/right/home'),
      );
      expect(r.right.entries.map((e) => e.name), ['docs', 'notes.txt']);
      expect(r.right.cursorIndex, 1);
      expect(r.sync.enabled, isTrue);
      expect(r.sync.suspended, isFalse);
      expect(oldChannel.closeCalls, 0);
      expect(
        r.lanes.disconnects,
        ['srv-1'],
        reason: 'the cancelled server reference still drops',
      );

      // The late open retires the candidate only: its channel closes
      // unlisted and the restored pane is untouched.
      heldOpen.complete();
      await connecting;
      await settle();
      expect(candidate.closeCalls, 1);
      expect(candidate.listCalls, isEmpty);
      expect(r.right.location, const LocalPaneLocation('/right/home'));
      expect(r.right.entries.map((e) => e.name), ['docs', 'notes.txt']);
      expect(oldChannel.closeCalls, 0);
      expect(r.sync.enabled, isTrue);
      expect(r.sync.suspended, isFalse);
    });

    test('a committed server change drops the link even while the pair '
        'is suspended — the drop is not visibility-gated', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();

      // Suspended pairNotVisible: the right pane is hidden. Its tab's
      // rebind still commits — the endpoint check runs on every pass,
      // so the link drops now rather than on re-visibility.
      r.workspace.setSecondPaneHidden(true);
      expect(r.sync.cause?.kind, SyncBrowseSuspension.pairNotVisible);

      r.lanes.nextRemoteChannel = FakePaneChannel('/srv/home')
        ..listings['/srv/home'] = [entry('r.txt', parent: '/srv/home')];
      await r.right.connectRemote(remoteBookmark());
      await settle();

      expect(r.sync.enabled, isFalse);
      expect(r.left.syncAnchorActive, isFalse);
      expect(r.right.syncAnchorActive, isFalse);
    });
  });

  group('anchored-tab close (02 §7 → §3 guard)', () {
    test('closing an anchored tab fires the syncAnchor trigger through '
        'the registry; a declined close keeps the link', () async {
      final seen = <List<TabCloseTrigger>>[];
      final r = rig(
        leftConfirmClose: (tab, triggers) async {
          seen.add(triggers);
          return false; // decline
        },
      );
      await openHomes(r);
      r.sync.toggle();

      final outcome = await r.leftStrip.requestCloseTab(
        r.leftStrip.activeTab!,
      );

      expect(outcome, TabCloseOutcome.declined);
      expect(seen.single, contains(TabCloseTrigger.syncAnchor));
      expect(r.sync.enabled, isTrue);
      expect(r.left.syncAnchorActive, isTrue);
    });

    test('a confirmed close removes the anchor and drops the link',
        () async {
      final r = rig(leftConfirmClose: (tab, triggers) async => true);
      await openHomes(r);
      r.sync.toggle();

      final outcome = await r.leftStrip.requestCloseTab(
        r.leftStrip.activeTab!,
      );

      expect(outcome, TabCloseOutcome.closed);
      expect(r.sync.enabled, isFalse);
      // The surviving pane's anchor flag is cleared — a stale probe
      // must not guard an unanchored tab's close.
      expect(r.right.syncAnchorActive, isFalse);
    });
  });

  group('visibility (02 §7)', () {
    test('switching a pane\'s active tab suspends; re-showing the '
        'anchored pair resumes', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();

      // The duplicate tab activates itself, hiding the anchored tab.
      r.lanes.nextLocalChannel = FakePaneChannel('/left/home')
        ..listings['/left/home'] = [entry('a.txt', parent: '/left/home')];
      r.leftStrip.newTab();
      await settle();
      expect(r.sync.suspended, isTrue);
      expect(r.sync.cause?.kind, SyncBrowseSuspension.pairNotVisible);

      // While the anchored pair is off screen, navigating the visible
      // tab does not replay anywhere.
      r.leftStrip.activeTab!.controller.navigate('/left/home/docs');
      await settle();
      await settle();
      expect(r.right.location?.path, '/right/home');

      // Switching back to the anchored tab re-evaluates: both panes are
      // still at their anchors, so the link resumes.
      r.leftStrip.activateTab(r.leftStrip.tabs.first);
      await settle();
      expect(r.sync.suspended, isFalse);
    });

    test('hiding the second pane suspends exactly like a tab switch and '
        'never replays into the hidden pane', () async {
      final r = rig();
      await openHomes(r);
      r.sync.toggle();

      r.workspace.setSecondPaneHidden(true);
      expect(r.sync.cause?.kind, SyncBrowseSuspension.pairNotVisible);

      r.left.navigate('/left/home/docs');
      await settle();
      await settle();
      // The replay never reached the hidden pane's tab.
      expect(r.right.location?.path, '/right/home');

      r.workspace.setSecondPaneHidden(false);
      await settle();
      expect(r.sync.suspended, isTrue);
      // The re-visibility pass reclassifies the stale cause: the pair
      // IS visible now — what keeps it suspended is the divergence.
      expect(r.sync.cause?.kind, SyncBrowseSuspension.diverged);
      r.right.navigate('/right/home/docs');
      await settle();
      await settle();
      expect(r.sync.suspended, isFalse);
    });
  });
}
