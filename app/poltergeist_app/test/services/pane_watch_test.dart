import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart' show FakePaneLanes;
import '../support/fake_pane_channel.dart';

// The pane side of 03 §7.5: the visible tab watches the local directory
// it shows, and the watch's signals turn into quiet re-lists.

Future<void> _settle() => Future<void>.delayed(Duration.zero);

RemoteFileEntry _entry(String name, {String parent = '/home/tester'}) =>
    RemoteFileEntry(
      path: '$parent/$name',
      name: name,
      type: RemoteFileType.file,
    );

Bookmark _remoteBookmark() {
  final now = DateTime.utc(2026, 9, 24);
  return Bookmark(
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
    remotePath: '/srv/home',
    sortKey: 'k',
    createdAt: now,
    updatedAt: now,
  );
}

/// A pane browsing `/home/tester` on a local channel, watch armed.
Future<(PaneController, FakePaneChannel, FakePaneLanes)> _watchedPane({
  List<String> dirs = const [],
  void Function(Object error, StackTrace stackTrace)? onError,
}) async {
  final lanes = FakePaneLanes();
  final channel = FakePaneChannel('/home/tester')
    ..listings['/home/tester'] = [_entry('a.txt')];
  for (final dir in dirs) {
    channel.listings[dir] = [_entry('in-${dir.split('/').last}', parent: dir)];
  }
  lanes.nextLocalChannel = channel;
  final controller = PaneController(
    paneTabId: 'pane.left.tab1',
    lanes: lanes,
    onError: onError,
  );
  addTearDown(controller.dispose);
  await controller.openLocalHome();
  await _settle();
  return (controller, channel, lanes);
}

void main() {
  test('arms the shown directory before listing it', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('a.txt')];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(
      paneTabId: 'pane.left.tab1',
      lanes: lanes,
    );
    addTearDown(controller.dispose);
    final watch = Completer<void>();
    channel.heldWatch = watch;

    await controller.openLocalHome();
    await _settle();
    expect(channel.watchCalls, ['/home/tester']);
    expect(channel.listCalls, isEmpty);
    expect(channel.hasWatchListener, isTrue);

    watch.complete();
    await _settle();
    expect(channel.listCalls, ['/home/tester']);
    expect(controller.entries.single.name, 'a.txt');
  });

  test('a same-directory refresh keeps the watch; navigation retargets it',
      () async {
    final (controller, channel, _) =
        await _watchedPane(dirs: ['/home/tester/docs']);

    controller.refresh();
    await _settle();
    expect(channel.watchCalls, ['/home/tester']);
    expect(channel.listCalls, ['/home/tester', '/home/tester']);

    controller.navigate('/home/tester/docs');
    await _settle();
    expect(channel.watchCalls, ['/home/tester', '/home/tester/docs']);
    // The engine retargets atomically: nothing is released in between.
    expect(channel.unwatchCalls, 0);
  });

  test('a change re-lists quietly: no recents visit, no history entry',
      () async {
    final (controller, channel, _) = await _watchedPane();
    final commits = <PaneLocation>[];
    controller.onLocationCommitted =
        (location, {remoteBookmark}) => commits.add(location);

    channel.listings['/home/tester'] = [_entry('a.txt'), _entry('b.txt')];
    channel.emitWatch(DirectoryWatchSignal.changed);
    expect(controller.loading, isTrue);
    expect(controller.navigationInFlight, isFalse);
    await _settle();
    expect(controller.entries.map((e) => e.name), ['a.txt', 'b.txt']);
    expect(commits, isEmpty);
    expect(controller.canGoBack, isFalse);

    // A refresh the user asked for still records the visit.
    controller.refresh();
    expect(controller.navigationInFlight, isTrue);
    await _settle();
    expect(commits, [const LocalPaneLocation('/home/tester')]);
  });

  test('changes during an in-flight listing coalesce into one re-list',
      () async {
    final (controller, channel, _) = await _watchedPane();
    final hold = Completer<void>();
    channel.holdNext = hold;
    controller.refresh();
    await _settle();

    channel.emitWatch(DirectoryWatchSignal.changed);
    channel.emitWatch(DirectoryWatchSignal.changed);
    expect(channel.listCalls, hasLength(2));

    hold.complete();
    await _settle();
    await _settle();
    expect(channel.listCalls, hasLength(3));
    expect(controller.loading, isFalse);
  });

  test('an open Quick Select session holds the re-list until it ends',
      () async {
    final (controller, channel, _) = await _watchedPane();
    controller.openQuickSelect();
    channel.emitWatch(DirectoryWatchSignal.changed);
    await _settle();
    expect(channel.listCalls, hasLength(1));
    expect(controller.quickSelectActive, isTrue);

    controller.cancelQuickSelect();
    await _settle();
    expect(channel.listCalls, hasLength(2));
  });

  test('a pending type-ahead buffer holds the re-list until it clears',
      () async {
    final (controller, channel, _) = await _watchedPane();
    controller.typeAhead('a');
    channel.emitWatch(DirectoryWatchSignal.changed);
    await _settle();
    expect(channel.listCalls, hasLength(1));
    expect(controller.typeAheadBuffer, 'a');

    controller.clearTypeAhead();
    await _settle();
    expect(channel.listCalls, hasLength(2));
  });

  test('a lost watch rescans at once and re-arms', () async {
    final (_, channel, _) = await _watchedPane();

    channel.emitWatch(DirectoryWatchSignal.lost);
    await _settle();
    expect(channel.watchCalls, ['/home/tester', '/home/tester']);
    expect(channel.listCalls, hasLength(2));

    // The re-armed watch delivers again.
    channel.emitWatch(DirectoryWatchSignal.changed);
    await _settle();
    expect(channel.listCalls, hasLength(3));
  });

  test('a watch that keeps dying stops re-arming and says so', () async {
    final (controller, channel, _) = await _watchedPane();
    // Every arm dies at subscribe: the engine's immediate lost lands
    // before the reply.
    channel.onWatch = (_) => channel.emitWatch(DirectoryWatchSignal.lost);

    channel.emitWatch(DirectoryWatchSignal.lost);
    await _settle();
    expect(controller.notice, PaneNotice.watchStopped);
    expect(channel.watchCalls, hasLength(3));
    // The rescan still ran; the listing just is not watched any more.
    expect(channel.listCalls, hasLength(2));
    expect(controller.entries.single.name, 'a.txt');

    // An explicit refresh restores the budget.
    channel.onWatch = null;
    controller.refresh();
    await _settle();
    expect(channel.watchCalls, hasLength(4));
    channel.emitWatch(DirectoryWatchSignal.changed);
    await _settle();
    expect(channel.listCalls, hasLength(4));
  });

  test('a lost reply trailing a retarget is re-checked, not believed',
      () async {
    final (controller, channel, _) =
        await _watchedPane(dirs: ['/home/tester/docs']);
    // The replaced target's last words land before the new reply.
    var first = true;
    channel.onWatch = (_) {
      if (!first) return;
      first = false;
      channel.emitWatch(DirectoryWatchSignal.lost, path: '/home/tester');
    };

    controller.navigate('/home/tester/docs');
    await _settle();
    expect(channel.watchCalls, [
      '/home/tester',
      '/home/tester/docs',
      '/home/tester/docs',
    ]);
    expect(controller.notice, isNull);
    channel.emitWatch(DirectoryWatchSignal.changed);
    await _settle();
    expect(channel.listCalls.last, '/home/tester/docs');
    expect(channel.listCalls, hasLength(3));
  });

  test('a stream that ends while no watch stands costs nothing', () async {
    final (controller, channel, _) =
        await _watchedPane(dirs: ['/home/tester/docs']);
    // A refused arm leaves the subscription but no standing watch.
    channel.watchFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.other,
      operation: 'watch',
      message: 'The watch target is not a directory.',
    );
    controller.navigate('/home/tester/docs');
    await _settle();
    expect(channel.listCalls, hasLength(2));

    await channel.closeWatchStream();
    await _settle();
    // No loss to count, so no rescan.
    expect(channel.listCalls, hasLength(2));
    expect(controller.notice, isNull);
  });

  test('cancelling a watch re-list leaves the pane dirty', () async {
    final (controller, channel, _) = await _watchedPane();
    final hold = Completer<void>();
    channel.holdNext = hold;
    channel.emitWatch(DirectoryWatchSignal.changed);
    await _settle();
    expect(channel.listCalls, hasLength(2));

    controller.cancelNavigation();
    hold.complete();
    await _settle();
    // No re-list on the cancel itself...
    expect(channel.listCalls, hasLength(2));
    expect(controller.loading, isFalse);

    // ...but the restored rows predate a reported change, so the next
    // flush point re-lists.
    controller.typeAhead('a');
    controller.clearTypeAhead();
    await _settle();
    expect(channel.listCalls, hasLength(3));
  });

  test('a listing that answers notFound drops the watch', () async {
    final (controller, channel, _) = await _watchedPane();
    channel.listings.remove('/home/tester');

    channel.emitWatch(DirectoryWatchSignal.changed);
    await _settle();
    expect(controller.error?.kind, RemoteFileErrorKind.notFound);
    expect(channel.unwatchCalls, 1);
    expect(channel.hasWatchListener, isFalse);
  });

  test('a refused watch leaves the listing unwatched; an untyped fault '
      'reports', () async {
    final errors = <Object>[];
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('a.txt')]
      ..watchFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: 'watch',
        message: 'The watch target is not a directory.',
      );
    lanes.nextLocalChannel = channel;
    final controller = PaneController(
      paneTabId: 'pane.left.tab1',
      lanes: lanes,
      onError: (error, _) => errors.add(error),
    );
    addTearDown(controller.dispose);

    await controller.openLocalHome();
    await _settle();
    expect(controller.entries.single.name, 'a.txt');
    expect(controller.error, isNull);
    // A refused request can leave an older target installed.
    expect(channel.unwatchCalls, 1);
    expect(errors, isEmpty);

    channel.watchFailure = StateError('broken seam');
    controller.refresh();
    await _settle();
    expect(errors, hasLength(1));
    expect(controller.entries.single.name, 'a.txt');
  });

  test('a background tab releases its watch and re-lists on activation',
      () async {
    final (controller, channel, _) = await _watchedPane();
    final commits = <PaneLocation>[];
    controller.onLocationCommitted =
        (location, {remoteBookmark}) => commits.add(location);

    controller.setTabActive(false);
    expect(channel.unwatchCalls, 1);
    expect(channel.hasWatchListener, isFalse);
    channel.emitWatch(DirectoryWatchSignal.changed);
    await _settle();
    expect(channel.listCalls, hasLength(1));

    controller.setTabActive(true);
    await _settle();
    expect(channel.watchCalls, hasLength(2));
    expect(channel.listCalls, hasLength(2));
    expect(commits, isEmpty);
  });

  test('Esc re-arms the restored directory without re-listing it',
      () async {
    final (controller, channel, _) =
        await _watchedPane(dirs: ['/home/tester/slow']);
    final hold = Completer<void>();
    channel.holdNext = hold;
    controller.navigate('/home/tester/slow');
    await _settle();
    expect(channel.watchCalls.last, '/home/tester/slow');

    controller.cancelNavigation();
    expect(channel.watchCalls.last, '/home/tester');
    hold.complete();
    await _settle();
    expect(channel.listCalls, ['/home/tester', '/home/tester/slow']);
    expect(controller.entries.single.name, 'a.txt');

    channel.emitWatch(DirectoryWatchSignal.changed);
    await _settle();
    expect(channel.listCalls, [
      '/home/tester',
      '/home/tester/slow',
      '/home/tester',
    ]);
  });

  group('a cancelled replacement', () {
    Future<(PaneController, FakePaneChannel, Completer<void>)>
        parkLocal() async {
      final (controller, local, lanes) = await _watchedPane();
      final remoteOpen = Completer<void>();
      lanes.holdRemoteOpen = remoteOpen;
      unawaited(controller.connectRemote(_remoteBookmark()));
      await _settle();
      return (controller, local, remoteOpen);
    }

    test('keeps the parked watch and restores without a re-list',
        () async {
      final (controller, local, remoteOpen) = await parkLocal();
      expect(local.unwatchCalls, 0);

      controller.cancelNavigation();
      await _settle();
      expect(controller.location, const LocalPaneLocation('/home/tester'));
      expect(local.listCalls, hasLength(1));
      expect(local.watchCalls, hasLength(1));
      remoteOpen.complete();
    });

    test('re-lists on restore when the parked watch signalled', () async {
      final (controller, local, remoteOpen) = await parkLocal();
      local.emitWatch(DirectoryWatchSignal.changed);
      expect(local.listCalls, hasLength(1));

      controller.cancelNavigation();
      await _settle();
      expect(local.listCalls, hasLength(2));
      // The parked watch stood throughout.
      expect(local.watchCalls, hasLength(1));
      remoteOpen.complete();
    });
  });

  test('a remote binding never asks for a watch', () async {
    final lanes = FakePaneLanes();
    final remote = FakePaneChannel('/srv/home')
      ..listings['/srv/home'] = [_entry('r.txt', parent: '/srv/home')];
    lanes.nextRemoteChannel = remote;
    final controller = PaneController(
      paneTabId: 'pane.left.tab1',
      lanes: lanes,
    );
    addTearDown(controller.dispose);

    await controller.connectRemote(_remoteBookmark());
    await _settle();
    expect(remote.listCalls, isNotEmpty);
    expect(remote.watchCalls, isEmpty);
    expect(remote.hasWatchListener, isFalse);
  });

  test('dispose lets go of the stream; the close releases the watch',
      () async {
    final (controller, channel, _) = await _watchedPane();
    controller.dispose();
    await _settle();
    expect(channel.hasWatchListener, isFalse);
    expect(channel.closeCalls, 1);
    expect(channel.unwatchCalls, 0);
  });

  group('the tab strip (03 §7.5: the visible tab only)', () {
    test('switching tabs moves the watch and re-lists the arrival',
        () async {
      final lanes = FakePaneLanes();
      final first = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('a.txt')];
      lanes.nextLocalChannel = first;
      final strip = PaneTabsController(
        paneId: PaneTabsController.leftPaneId,
        lanes: lanes,
        newTabTarget: NewTabTarget.home,
      );
      addTearDown(strip.dispose);

      final tabA = strip.newTab();
      await _settle();
      expect(first.watchCalls, ['/home/tester']);

      final second = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('b.txt')];
      lanes.nextLocalChannel = second;
      final tabB = strip.newTab();
      await _settle();
      expect(tabA.controller.tabActive, isFalse);
      expect(first.unwatchCalls, 1);
      expect(second.watchCalls, ['/home/tester']);

      strip.activateTab(tabA);
      await _settle();
      expect(tabB.controller.tabActive, isFalse);
      expect(second.unwatchCalls, 1);
      expect(first.watchCalls, hasLength(2));
      expect(first.listCalls, hasLength(2));
    });

    test('adopting a browsing tab keeps its watch and re-lists nothing',
        () async {
      final (controller, channel, _) = await _watchedPane();
      final strip = PaneTabsController(paneId: PaneTabsController.leftPaneId)
        ..addTab(controller);
      addTearDown(strip.dispose);
      await _settle();
      expect(controller.tabActive, isTrue);
      expect(channel.unwatchCalls, 0);
      expect(channel.listCalls, hasLength(1));
    });

    test('a watch re-list never holds a tab close', () async {
      final (controller, channel, _) = await _watchedPane();
      final strip = PaneTabsController(paneId: PaneTabsController.leftPaneId)
        ..addTab(controller);
      addTearDown(strip.dispose);
      final hold = Completer<void>();
      channel.holdNext = hold;

      channel.emitWatch(DirectoryWatchSignal.changed);
      await _settle();
      expect(controller.loading, isTrue);
      expect(strip.closeTriggers(strip.tabs.single), isEmpty);
      hold.complete();
    });
  });
}
