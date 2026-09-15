import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/double_click_action.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart';

/// The fakes' scripted futures complete on ordinary microtask turns, so
/// draining the event queue to quiescence — not a single turn — is what
/// keeps this suite honest if the bind+list chain ever grows a hop.
Future<void> settle() => pumpEventQueue();

RemoteFileEntry _entry(String name, {String parent = '/home/tester'}) =>
    RemoteFileEntry(
      path: '$parent/$name',
      name: name,
      type: RemoteFileType.file,
      size: 10,
    );

Bookmark _bookmark(
  String id, {
  String remotePath = '/srv/home',
  ServerColor? color,
  ServerIcon? icon,
}) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: '$id.example.com',
  color: color,
  icon: icon,
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
  createdAt: DateTime.utc(2026, 9, 14),
  updatedAt: DateTime.utc(2026, 9, 14),
);

/// Engine-faithful local lanes: like engine_host, the minted channel's
/// homePath is the canonicalized OPENING root — a tab opened at a
/// non-home path reports that path as its home. Only '~' opens at the
/// real user home.
final class _EngineLikeLocalLanes extends FakePaneLanes {
  final listings = <String, List<RemoteFileEntry>>{};

  @override
  Future<AppBrowseChannel> openLocalChannel({
    required String rootPath,
  }) async {
    calls.add('openLocal:$rootPath');
    final channel = FakePaneChannel(rootPath == '~' ? '/home/tester' : rootPath)
      ..listings.addAll(listings);
    return channel;
  }
}

void main() {
  late FakePaneLanes lanes;

  PaneTabsController tabs({
    NewTabTarget newTabTarget = NewTabTarget.duplicate,
    DoubleClickAction doubleClickAction = DoubleClickAction.open,
    Future<bool> Function(PaneTab, List<TabCloseTrigger>)? confirmClose,
    bool Function(String serverId, PaneController excluding)?
        serverStillShared,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    final controller = PaneTabsController(
      paneId: PaneTabsController.leftPaneId,
      lanes: lanes,
      newTabTarget: newTabTarget,
      doubleClickAction: doubleClickAction,
      confirmClose: confirmClose,
      serverStillShared: serverStillShared,
      onError: onError,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  setUp(() {
    lanes = FakePaneLanes();
    lanes.nextLocalChannel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('a.txt')];
  });

  group('tilde home resolution across duplication and reopen (F8)', () {
    test('~ and ~/child resolve to the user home from original, '
        'duplicated, and reopened tabs', () async {
      final engineLanes = _EngineLikeLocalLanes();
      engineLanes.listings['/home/tester'] = [_entry('a.txt')];
      engineLanes.listings['/home/tester/Documents'] = [_entry('b.txt')];
      engineLanes.listings['/tmp/project'] = [
        _entry('c.txt', parent: '/tmp/project'),
      ];
      final controller = PaneTabsController(
        paneId: PaneTabsController.leftPaneId,
        lanes: engineLanes,
      );
      addTearDown(controller.dispose);

      final original = controller.newTab(target: NewTabTarget.home);
      await settle();
      expect(original.controller.location?.path, '/home/tester');
      original.controller.navigate('/tmp/project');
      await settle();
      expect(original.controller.location?.path, '/tmp/project');

      // Sanity: the original tab already expands ~ to the user home.
      original.controller.editPath();
      original.controller.submitPathField('~');
      await settle();
      expect(
        original.controller.location,
        const LocalPaneLocation('/home/tester'),
      );
      original.controller.navigate('/tmp/project');
      await settle();

      // Duplicate while sitting on /tmp/project.
      final duplicate = controller.newTab();
      await settle();
      expect(duplicate.controller.location?.path, '/tmp/project');
      duplicate.controller.editPath();
      duplicate.controller.submitPathField('~');
      await settle();
      expect(
        duplicate.controller.location,
        const LocalPaneLocation('/home/tester'),
        reason: 'a duplicated tab expands ~ to the user home, '
            'not its opening directory',
      );
      duplicate.controller.editPath();
      duplicate.controller.submitPathField('~/Documents');
      await settle();
      expect(
        duplicate.controller.location,
        const LocalPaneLocation('/home/tester/Documents'),
      );

      // A reopened ghost of a project-rooted tab keeps the true home.
      duplicate.controller.navigate('/tmp/project');
      await settle();
      await controller.requestCloseTab(duplicate);
      await settle();
      final reopened = await controller.reopenClosedTab();
      await settle();
      expect(reopened!.controller.location?.path, '/tmp/project');
      reopened.controller.editPath();
      reopened.controller.submitPathField('~');
      await settle();
      expect(
        reopened.controller.location,
        const LocalPaneLocation('/home/tester'),
        reason: 'a reopened tab expands ~ to the user home too',
      );
    });
  });

  group('new tab targets (02 §3)', () {
    test('duplicate (default) reopens the active tab\'s local path', () async {
      final controller = tabs();
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('a.txt')]
        ..listings['/home/tester/docs'] = [
          _entry('d.txt', parent: '/home/tester/docs'),
        ];
      lanes.nextLocalChannel = channel;
      controller.newTab(target: NewTabTarget.home);
      await settle();
      final first = controller.activeTab!;
      first.controller.navigate('/home/tester/docs');
      await settle();
      expect(first.controller.location?.path, '/home/tester/docs');

      // The duplicate binds the user's home and browses the source's
      // path on it — the engine never opens the browsed directory as
      // the channel's home (F8).
      lanes.nextLocalChannel = FakePaneChannel('/home/tester')
        ..listings['/home/tester/docs'] = [
          _entry('d.txt', parent: '/home/tester/docs'),
        ];
      final second = controller.newTab();
      await settle();

      expect(controller.tabs, hasLength(2));
      expect(controller.activeTab, same(second));
      expect(
        second.controller.location,
        const LocalPaneLocation('/home/tester/docs'),
      );
      expect(second.controller.loading, isFalse);
      expect(lanes.calls, contains('openLocal:~'));
    });

    test('duplicate on a remote tab reconnects the same server and path', () async {
      lanes.nextRemoteChannel = FakePaneChannel('/srv/home')
        ..listings['/srv/home/deep'] = [_entry('r.txt', parent: '/srv/home/deep')];
      final controller = tabs();
      final first = controller.newTab(target: NewTabTarget.launcher);
      await first.controller.connectRemote(
        _bookmark('srv-1'),
        initialPath: '/srv/home/deep',
      );
      await settle();
      expect(first.controller.location?.path, '/srv/home/deep');

      final second = controller.newTab();
      await settle();

      expect(second.controller.remoteBookmark?.id, 'srv-1');
      expect(second.controller.location?.path, '/srv/home/deep');
    });

    test('home lands a local tab at the engine home anchor', () async {
      final controller = tabs(newTabTarget: NewTabTarget.home);
      controller.newTab(target: NewTabTarget.launcher);
      final tab = controller.newTab();
      await settle();

      expect(tab.controller.location, const LocalPaneLocation('/home/tester'));
      expect(lanes.calls, contains('openLocal:~'));
    });

    test('home on a remote tab reconnects the server landing path', () async {
      lanes.nextRemoteChannel = FakePaneChannel('/srv/home');
      final controller = tabs(newTabTarget: NewTabTarget.home);
      final first = controller.newTab(target: NewTabTarget.launcher);
      await first.controller.connectRemote(
        _bookmark('srv-1'),
        initialPath: '/srv/home/deep',
      );
      await settle();

      final second = controller.newTab();
      await settle();

      // The bookmark's own remotePath — the pane's home, not the
      // duplicated deep path.
      expect(second.controller.location?.path, '/srv/home');
      expect(second.controller.remoteBookmark?.id, 'srv-1');
    });

    test('launcher leaves the tab unbound — no channel opens', () async {
      final controller = tabs(newTabTarget: NewTabTarget.launcher);
      final tab = controller.newTab();
      await settle();

      expect(tab.controller.phase, PanePhase.unbound);
      expect(lanes.calls.where((c) => c.startsWith('open')), isEmpty);
    });

    test('duplicate on an empty strip opens an unbound tab', () async {
      // The post-last-close launcher state: duplicate has no source to
      // copy, so the tab falls back to the launcher's unbound surface —
      // it must not throw or no-op.
      final controller = tabs();
      final tab = controller.newTab();
      await settle();

      expect(controller.tabs.single, same(tab));
      expect(tab.controller.phase, PanePhase.unbound);
      expect(lanes.calls.where((c) => c.startsWith('open')), isEmpty);
    });

    test('newTabTarget is read live — the setting applies per invocation', () async {
      final controller = tabs(newTabTarget: NewTabTarget.launcher);
      final launcher = controller.newTab();
      expect(launcher.controller.phase, PanePhase.unbound);

      controller.newTabTarget = NewTabTarget.home;
      final home = controller.newTab();
      await settle();
      expect(home.controller.location, isNotNull);
    });
  });

  group('double-click action propagation (02 §2.6)', () {
    test('the seed lands on every tab', () async {
      final controller = tabs(doubleClickAction: DoubleClickAction.edit);
      final first = controller.newTab(target: NewTabTarget.launcher);
      await settle();
      final second = controller.newTab(target: NewTabTarget.launcher);
      await settle();

      expect(first.controller.doubleClickAction, DoubleClickAction.edit);
      expect(second.controller.doubleClickAction, DoubleClickAction.edit);
    });

    test('writing the live value propagates to open tabs and stamps new '
        'arrivals', () async {
      final controller = tabs();
      final first = controller.newTab(target: NewTabTarget.launcher);
      await settle();
      expect(first.controller.doubleClickAction, DoubleClickAction.open);

      controller.doubleClickAction = DoubleClickAction.transfer;
      expect(first.controller.doubleClickAction, DoubleClickAction.transfer);

      // A later arrival — new or ghost-reopened — opens files under the
      // current value, not the value at its construction.
      final second = controller.newTab(target: NewTabTarget.launcher);
      await settle();
      expect(
        second.controller.doubleClickAction,
        DoubleClickAction.transfer,
      );
    });
  });

  group('activation and cycling', () {
    test('activateTab switches the visible tab', () {
      final controller = tabs();
      final first = controller.newTab(target: NewTabTarget.launcher);
      final second = controller.newTab(target: NewTabTarget.launcher);
      expect(controller.activeTab, same(second));

      controller.activateTab(first);
      expect(controller.activeTab, same(first));
    });

    test('next/previous wrap in both directions and scope to this pane', () {
      final controller = tabs();
      final a = controller.newTab(target: NewTabTarget.launcher);
      controller.newTab(target: NewTabTarget.launcher);
      final c = controller.newTab(target: NewTabTarget.launcher);

      expect(controller.activeTab, same(c));
      controller.activateNextTab();
      expect(controller.activeTab, same(a), reason: 'wraps past the last');
      controller.activatePreviousTab();
      expect(controller.activeTab, same(c), reason: 'wraps past the first');
      controller.activatePreviousTab();
      expect(controller.activeTab, same(controller.tabs[1]));
    });

    test('cycling is a no-op below two tabs', () {
      final controller = tabs();
      final only = controller.newTab(target: NewTabTarget.launcher);
      controller.activateNextTab();
      controller.activatePreviousTab();
      expect(controller.activeTab, same(only));
    });

    test('activating a foreign tab is ignored', () {
      final controller = tabs();
      final own = controller.newTab(target: NewTabTarget.launcher);
      final other = tabs().newTab(target: NewTabTarget.launcher);
      controller.activateTab(other);
      expect(controller.activeTab, same(own));
    });
  });

  group('guarded close (02 §3)', () {
    test('a quiet tab closes silently — no presenter call', () async {
      var presented = 0;
      final controller = tabs(
        confirmClose: (_, _) async {
          presented++;
          return true;
        },
      );
      final tab = controller.newTab(target: NewTabTarget.home);
      await settle();

      final outcome = await controller.requestCloseTab(tab);

      expect(outcome, TabCloseOutcome.closed);
      expect(presented, 0, reason: 'no trigger, no confirmation');
      expect(controller.tabs, isEmpty);
      expect(controller.activeTab, isNull);
    });

    test('an in-flight navigation fires the navigation trigger', () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('a.txt')];
      lanes.nextLocalChannel = channel;
      List<TabCloseTrigger>? seen;
      final controller = tabs(
        confirmClose: (_, triggers) async {
          seen = triggers;
          return false;
        },
      );
      final tab = controller.newTab(target: NewTabTarget.home);
      await settle();

      channel.holdNext = Completer<void>();
      tab.controller.navigate('/home/tester/sub');
      expect(tab.controller.loading, isTrue);

      final outcome = await controller.requestCloseTab(tab);
      expect(outcome, TabCloseOutcome.declined);
      expect(seen, [TabCloseTrigger.navigation]);
      expect(controller.tabs, contains(tab));
    });

    test('an active inline rename fires the rename trigger', () async {
      List<TabCloseTrigger>? seen;
      final controller = tabs(
        confirmClose: (_, triggers) async {
          seen = triggers;
          return false;
        },
      );
      final tab = controller.newTab(target: NewTabTarget.home);
      await settle();
      tab.controller.setCursorIndex(0);
      tab.controller.startRename();

      final outcome = await controller.requestCloseTab(tab);
      expect(outcome, TabCloseOutcome.declined);
      expect(seen, [TabCloseTrigger.inlineRename]);

      tab.controller.cancelRename();
      expect(await controller.requestCloseTab(tab), TabCloseOutcome.closed);
    });

    test('an in-flight rename commit holds the trigger after the field closes', () async {
      final channel = lanes.nextLocalChannel as FakePaneChannel;
      List<TabCloseTrigger>? seen;
      final controller = tabs(
        confirmClose: (_, triggers) async {
          seen = triggers;
          return false;
        },
      );
      final tab = controller.newTab(target: NewTabTarget.home);
      await settle();
      tab.controller.setCursorIndex(0);
      tab.controller.startRename();

      // The submit parks the channel call: the field is already closed,
      // but the in-flight rename is still work the guard must quantify.
      final held = Completer<void>();
      channel.heldRename = held;
      unawaited(tab.controller.submitRename('renamed.txt'));
      await settle();
      expect(tab.controller.renameTarget, isNull);

      final outcome = await controller.requestCloseTab(tab);
      expect(outcome, TabCloseOutcome.declined);
      expect(seen, [TabCloseTrigger.inlineRename]);

      held.complete();
      await settle();
      expect(await controller.requestCloseTab(tab), TabCloseOutcome.closed);
    });

    test('only registered probes can fire — the future triggers stay inert', () async {
      final controller = tabs(confirmClose: (_, _) async => false);
      final tab = controller.newTab(target: NewTabTarget.home);
      await settle();

      // The registry spells the full 02 §3 set, but folder-size,
      // apply-to-enclosed and sync-anchor have no v1 producers: a quiet
      // tab can only ever report navigation/inlineRename.
      expect(
        controller.closeTriggers(tab),
        isNot(contains(TabCloseTrigger.folderSize)),
      );
      expect(
        controller.closeTriggers(tab),
        isNot(contains(TabCloseTrigger.applyToEnclosed)),
      );
      expect(
        controller.closeTriggers(tab),
        isNot(contains(TabCloseTrigger.syncAnchor)),
      );
    });

    test('a guard with no presenter wired is fail-closed', () async {
      final channel = FakePaneChannel('/home/tester');
      lanes.nextLocalChannel = channel;
      final controller = tabs();
      final tab = controller.newTab(target: NewTabTarget.home);
      await settle();

      channel.holdNext = Completer<void>();
      tab.controller.navigate('/x');
      final outcome = await controller.requestCloseTab(tab);
      expect(outcome, TabCloseOutcome.declined);
      expect(controller.tabs, contains(tab));
    });

    test('a fail-closed decline stays retryable once the trigger clears', () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/x'] = const [];
      lanes.nextLocalChannel = channel;
      // No presenter: the triggered guard fails closed — and must not
      // pin the tab to that outcome (the settle-without-await path used
      // to leave a stale in-flight entry that deduped every retry).
      final controller = tabs();
      final tab = controller.newTab(target: NewTabTarget.home);
      await settle();

      final hold = Completer<void>();
      channel.holdNext = hold;
      tab.controller.navigate('/x');
      expect(await controller.requestCloseTab(tab), TabCloseOutcome.declined);
      expect(controller.tabs, contains(tab));

      hold.complete();
      await settle();
      expect(tab.controller.loading, isFalse);
      expect(await controller.requestCloseTab(tab), TabCloseOutcome.closed);
      expect(controller.tabs, isEmpty);
    });

    test('a throwing presenter fails closed and reports the error', () async {
      final reported = <Object>[];
      var throwDialog = true;
      final controller = tabs(
        confirmClose: (_, _) => throwDialog
            ? Future<bool>.error(StateError('dialog gone'))
            : Future<bool>.value(true),
        onError: (error, _) => reported.add(error),
      );
      final tab = controller.newTab(target: NewTabTarget.home);
      await settle();
      tab.controller.setCursorIndex(0);
      tab.controller.startRename();

      expect(await controller.requestCloseTab(tab), TabCloseOutcome.declined);
      expect(reported.single, isA<StateError>());
      expect(controller.tabs, contains(tab));

      // The failed confirm must leave no in-flight residue — fixing the
      // presenter lets the very next close proceed.
      throwDialog = false;
      expect(await controller.requestCloseTab(tab), TabCloseOutcome.closed);
    });

    test('a re-entrant close returns the in-flight operation', () async {
      final channel = FakePaneChannel('/home/tester');
      lanes.nextLocalChannel = channel;
      final gate = Completer<bool>();
      final controller = tabs(confirmClose: (_, _) => gate.future);
      final tab = controller.newTab(target: NewTabTarget.home);
      await settle();
      channel.holdNext = Completer<void>();
      tab.controller.navigate('/x');

      final first = controller.requestCloseTab(tab);
      final second = controller.requestCloseTab(tab);
      expect(identical(first, second), isTrue);

      gate.complete(true);
      expect(await first, TabCloseOutcome.closed);
    });

    test('closing a non-active tab keeps the active tab', () async {
      final controller = tabs();
      final first = controller.newTab(target: NewTabTarget.launcher);
      final second = controller.newTab(target: NewTabTarget.launcher);
      controller.activateTab(first);

      expect(await controller.requestCloseTab(second), TabCloseOutcome.closed);
      expect(controller.activeTab, same(first));
      expect(controller.tabs.single, same(first));
    });

    test('closing the active tab activates the neighbor at its slot', () async {
      final controller = tabs();
      final a = controller.newTab(target: NewTabTarget.launcher);
      final b = controller.newTab(target: NewTabTarget.launcher);
      final c = controller.newTab(target: NewTabTarget.launcher);
      controller.activateTab(b);

      await controller.requestCloseTab(b);
      expect(controller.activeTab, same(c));

      // The last tab in the strip closes to the one now at its slot.
      controller.activateTab(c);
      await controller.requestCloseTab(c);
      expect(controller.activeTab, same(a));

      // The last tab overall leaves the pane on the launcher.
      await controller.requestCloseTab(a);
      expect(controller.tabs, isEmpty);
      expect(controller.activeTab, isNull);
    });

    test('a closed tab\'s controller is disposed and its channel released', () async {
      final channel = FakePaneChannel('/home/tester');
      lanes.nextLocalChannel = channel;
      final controller = tabs();
      final tab = controller.newTab(target: NewTabTarget.home);
      await settle();

      await controller.requestCloseTab(tab);
      await settle();

      expect(channel.closeCalls, 1);
    });

    test('the last binding of a remote server drops its reference', () async {
      lanes.nextRemoteChannel = FakePaneChannel('/srv/home');
      final controller = tabs();
      final tab = controller.newTab(target: NewTabTarget.launcher);
      await tab.controller.connectRemote(_bookmark('srv-1'));
      await settle();

      await controller.requestCloseTab(tab);
      await settle();

      expect(lanes.disconnects, ['srv-1']);
    });

    test('a shared server keeps its reference while a sibling browses it', () async {
      final other = tabs();
      await other.newTab(target: NewTabTarget.launcher).controller
          .connectRemote(_bookmark('srv-1'));
      await settle();

      lanes.nextRemoteChannel = FakePaneChannel('/srv/home');
      final controller = tabs(
        serverStillShared: (serverId, excluding) => other.tabs.any(
          (t) =>
              !identical(t.controller, excluding) &&
              t.controller.remoteBookmark?.id == serverId,
        ),
      );
      final tab = controller.newTab(target: NewTabTarget.launcher);
      await tab.controller.connectRemote(_bookmark('srv-1'));
      await settle();

      await controller.requestCloseTab(tab);
      await settle();

      expect(
        lanes.disconnects,
        isEmpty,
        reason: 'the sibling tab still browses srv-1',
      );
    });
  });

  group('ghost ring (⇧⌘T)', () {
    test('reopen restores the local location and transient lenses', () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('a.txt'), _entry('b.txt')];
      lanes.nextLocalChannel = channel;
      final controller = tabs();
      final tab = controller.newTab(target: NewTabTarget.home);
      await settle();

      tab.controller.openFilter();
      tab.controller.changeFilterQuery('a');
      tab.controller.showHidden = true;
      tab.controller.viewMode = PaneViewMode.list;
      await controller.requestCloseTab(tab);

      lanes.nextLocalChannel = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('a.txt'), _entry('b.txt')];
      final reopened = await controller.reopenClosedTab();
      await settle();

      expect(reopened, isNotNull);
      expect(reopened!.controller.location, const LocalPaneLocation('/home/tester'));
      expect(reopened.controller.filterQuery, 'a');
      expect(reopened.controller.showHidden, isTrue);
      expect(reopened.controller.viewMode, PaneViewMode.list);
      // The reopened tab binds home and re-lists at the ghost's path —
      // nothing in-flight is carried over and the old channel is gone.
      expect(channel.closeCalls, 1);
      expect(lanes.calls, contains('openLocal:~'));
    });

    test('reopen restores the remote binding and its path', () async {
      lanes.nextRemoteChannel = FakePaneChannel('/srv/home');
      final controller = tabs();
      final tab = controller.newTab(target: NewTabTarget.launcher);
      await tab.controller.connectRemote(
        _bookmark('srv-1'),
        initialPath: '/srv/home/deep',
      );
      await settle();
      await controller.requestCloseTab(tab);

      lanes.nextRemoteChannel = FakePaneChannel('/srv/home');
      final reopened = await controller.reopenClosedTab();
      await settle();

      expect(reopened!.controller.remoteBookmark?.id, 'srv-1');
      expect(reopened.controller.location?.path, '/srv/home/deep');
    });

    test('the ring is capped at 10 — the oldest ghost drops first', () async {
      final controller = tabs();
      // The oldest ghost must be distinguishable from the launcher
      // ghosts that follow: a bound home tab carries a location, so if
      // eviction ever dropped the NEWEST ghost instead, one of the ten
      // reopens below would come back bound and fail the unbound check.
      final home = controller.newTab(target: NewTabTarget.home);
      await settle();
      await controller.requestCloseTab(home);
      for (var i = 0; i < 10; i++) {
        await controller.requestCloseTab(
          controller.newTab(target: NewTabTarget.launcher),
        );
      }
      for (var i = 0; i < 10; i++) {
        final reopened = await controller.reopenClosedTab();
        expect(reopened, isNotNull);
        await settle();
        expect(
          reopened!.controller.phase,
          PanePhase.unbound,
          reason: 'the bound home ghost (oldest) must have been evicted',
        );
      }
      expect(await controller.reopenClosedTab(), isNull);
    });

    test('a launcher-tab ghost reopens unbound', () async {
      final controller = tabs();
      final tab = controller.newTab(target: NewTabTarget.launcher);
      await controller.requestCloseTab(tab);

      final reopened = await controller.reopenClosedTab();
      expect(reopened, isNotNull);
      expect(reopened!.controller.phase, PanePhase.unbound);
    });

    test('an in-flight navigation is not restorable — the ghost restores '
        'the pending target, re-listed fresh', () async {
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('a.txt')];
      lanes.nextLocalChannel = channel;
      var asked = 0;
      final controller = tabs(
        confirmClose: (_, _) async {
          asked++;
          return true;
        },
      );
      final tab = controller.newTab(target: NewTabTarget.home);
      await settle();

      // The close guard must still fire — in-flight work is confirmed,
      // then the ghost restores the location the tab pointed at and the
      // reopened tab lists it fresh rather than replaying the pending
      // answer.
      channel.holdNext = Completer<void>();
      tab.controller.navigate('/home/tester/sub');
      expect(tab.controller.loading, isTrue);

      await controller.requestCloseTab(tab);
      expect(asked, 1, reason: 'the guard fired once and accepted');

      lanes.nextLocalChannel = FakePaneChannel('/home/tester')
        ..listings['/home/tester/sub'] = [
          _entry('s.txt', parent: '/home/tester/sub'),
        ];
      final reopened = await controller.reopenClosedTab();
      await settle();
      expect(
        reopened!.controller.location,
        const LocalPaneLocation('/home/tester/sub'),
      );
      expect(reopened.controller.loading, isFalse);
    });

    test('a reopened tab closed mid-bind skips the lens restore', () async {
      lanes.nextRemoteChannel = FakePaneChannel('/srv/home');
      final controller = tabs();
      final tab = controller.newTab(target: NewTabTarget.launcher);
      await tab.controller.connectRemote(_bookmark('srv-1'));
      await settle();
      tab.controller.showHidden = true;
      await controller.requestCloseTab(tab);

      // Park the reopen's remote bind on the held open, then close the
      // reopened tab underneath it: the bind's await resumes onto a
      // disposed controller, so the ghost's lens restore must not run.
      final hold = Completer<void>();
      lanes.holdRemoteOpen = hold;
      lanes.nextRemoteChannel = FakePaneChannel('/srv/home');
      final reopening = controller.reopenClosedTab();
      await settle();
      final reopened = controller.activeTab!;
      expect(reopened, isNot(same(tab)));

      // The parked bind has issued no listing, so no guard trigger is
      // active and the close settles quietly.
      expect(await controller.requestCloseTab(reopened), TabCloseOutcome.closed);
      expect(controller.tabs, isNot(contains(reopened)));

      hold.complete();
      expect(await reopening, same(reopened));
      expect(controller.tabs, isNot(contains(reopened)));
    });

    test('reopen with an empty ring is a no-op', () async {
      final controller = tabs();
      expect(await controller.reopenClosedTab(), isNull);
      expect(controller.canReopen, isFalse);
    });
  });

  group('dispose', () {
    test('disposes every tab controller and clears the ring', () async {
      // Constructed directly, not via tabs(): this test owns the
      // dispose, so the factory's teardown must not see a second one.
      final controller = PaneTabsController(
        paneId: PaneTabsController.leftPaneId,
        lanes: lanes,
      );
      controller.newTab(target: NewTabTarget.launcher);
      controller.newTab(target: NewTabTarget.launcher);
      await controller.requestCloseTab(controller.tabs.first);
      expect(controller.canReopen, isTrue);

      controller.dispose();
      expect(controller.tabs, isEmpty);
      expect(controller.canReopen, isFalse);
    });
  });
}
