import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart';

/// Every scripted future in the fakes completes immediately, so one event-
/// loop turn drains the bind+list chain end to end.
Future<void> settle() => Future<void>.delayed(Duration.zero);

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

void main() {
  late FakePaneLanes lanes;

  PaneTabsController tabs({
    NewTabTarget newTabTarget = NewTabTarget.duplicate,
    Future<bool> Function(PaneTab, List<TabCloseTrigger>)? confirmClose,
    bool Function(String serverId, PaneController excluding)?
        serverStillShared,
  }) => PaneTabsController(
    paneId: 'pane.left',
    lanes: lanes,
    newTabTarget: newTabTarget,
    confirmClose: confirmClose,
    serverStillShared: serverStillShared,
  );

  setUp(() {
    lanes = FakePaneLanes();
    lanes.nextLocalChannel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('a.txt')];
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

      // The engine canonicalizes the requested root into the channel's
      // homePath — the fake scripts the channel it would return.
      lanes.nextLocalChannel = FakePaneChannel('/home/tester/docs');
      final second = controller.newTab();
      await settle();

      expect(controller.tabs, hasLength(2));
      expect(controller.activeTab, same(second));
      expect(
        second.controller.location,
        const LocalPaneLocation('/home/tester/docs'),
      );
      expect(lanes.calls, contains('openLocal:/home/tester/docs'));
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
      final tab = controller.newTab(target: NewTabTarget.launcher);
      tab.controller.inlineRenameActive = true;

      final outcome = await controller.requestCloseTab(tab);
      expect(outcome, TabCloseOutcome.declined);
      expect(seen, [TabCloseTrigger.inlineRename]);

      tab.controller.inlineRenameActive = false;
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

      final reopened = await controller.reopenClosedTab();
      await settle();

      expect(reopened, isNotNull);
      expect(reopened!.controller.location, const LocalPaneLocation('/home/tester'));
      expect(reopened.controller.filterQuery, 'a');
      expect(reopened.controller.showHidden, isTrue);
      expect(reopened.controller.viewMode, PaneViewMode.list);
      // The reopened tab re-lists at the ghost's path — nothing
      // in-flight is carried over and the old channel is gone.
      expect(channel.closeCalls, 1);
      expect(lanes.calls, contains('openLocal:/home/tester'));
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
      for (var i = 0; i < 11; i++) {
        await controller.requestCloseTab(
          controller.newTab(target: NewTabTarget.launcher),
        );
      }
      for (var i = 0; i < 10; i++) {
        expect(await controller.reopenClosedTab(), isNotNull);
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

    test('an in-flight navigation is not restorable — the ghost freezes '
        'the last committed view, reopened fresh', () async {
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

      lanes.nextLocalChannel = FakePaneChannel('/home/tester/sub');
      final reopened = await controller.reopenClosedTab();
      await settle();
      expect(
        reopened!.controller.location,
        const LocalPaneLocation('/home/tester/sub'),
      );
      expect(reopened.controller.loading, isFalse);
    });

    test('reopen with an empty ring is a no-op', () async {
      final controller = tabs();
      expect(await controller.reopenClosedTab(), isNull);
      expect(controller.canReopen, isFalse);
    });
  });

  group('dispose', () {
    test('disposes every tab controller and clears the ring', () async {
      final controller = tabs();
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
