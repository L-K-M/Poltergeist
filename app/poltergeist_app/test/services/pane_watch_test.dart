import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart' as controller_test;

const _fakeChannelId = 1;

final class _WatchingPaneChannel extends controller_test.FakePaneChannel {
  _WatchingPaneChannel(super.homePath) {
    _changes = StreamController<DirectoryWatchEvent>.broadcast(
      onListen: () => operations.add('subscribe'),
      onCancel: () => operations.add('cancel'),
    );
  }

  late final StreamController<DirectoryWatchEvent> _changes;
  final operations = <String>[];
  final watchedPaths = <String>[];
  int unwatchCalls = 0;
  RemoteFileException? watchFailure;
  Completer<void>? holdNextWatch;

  @override
  Stream<DirectoryWatchEvent> get directoryChanges => _changes.stream;

  @override
  Future<void> watchDirectory(String path) async {
    operations.add('watch:$path');
    watchedPaths.add(path);
    final hold = holdNextWatch;
    holdNextWatch = null;
    if (hold != null) await hold.future;
    final failure = watchFailure;
    if (failure != null) throw failure;
  }

  @override
  Future<void> unwatchDirectory() async {
    operations.add('unwatch');
    unwatchCalls++;
  }

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    operations.add('list:$path');
    return super.listDirectory(path);
  }

  void emit(String path, DirectoryWatchSignal signal) {
    _changes.add(
      DirectoryWatchEvent(
        channelId: _fakeChannelId,
        path: path,
        signal: signal,
      ),
    );
  }

  @override
  Future<void> close() async {
    operations.add('close');
    await super.close();
    await _changes.close();
  }
}

RemoteFileEntry _entry(String parent, String name) => RemoteFileEntry(
  path: '$parent/$name',
  name: name,
  type: RemoteFileType.file,
);

Bookmark _bookmark() {
  final timestamp = DateTime.utc(2026, 9, 14);
  return Bookmark(
    id: 'srv-1',
    kind: BookmarkKind.remotePath,
    label: 'web.example.com',
    server: const BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 22,
        username: 'tester',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/',
    sortKey: 'k',
    createdAt: timestamp,
    updatedAt: timestamp,
  );
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('a local listing subscribes before starting its watch', () async {
    final lanes = controller_test.FakePaneLanes();
    final channel = _WatchingPaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('/home/tester', 'one.txt')];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);

    await controller.openLocalHome();
    await _settle();

    expect(channel.operations, [
      'subscribe',
      'watch:/home/tester',
      'list:/home/tester',
    ]);
    expect(channel.watchedPaths, ['/home/tester']);
    controller.dispose();
    await _settle();
  });

  test(
    'a changed signal refreshes without replacing a healthy watch',
    () async {
      final lanes = controller_test.FakePaneLanes();
      final channel = _WatchingPaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('/home/tester', 'one.txt')];
      lanes.nextLocalChannel = channel;
      final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
      await controller.openLocalHome();
      await _settle();

      channel.listings['/home/tester'] = [_entry('/home/tester', 'two.txt')];
      channel.emit('/home/tester', DirectoryWatchSignal.changed);
      await _settle();

      expect(channel.listCalls, ['/home/tester', '/home/tester']);
      expect(channel.watchedPaths, ['/home/tester']);
      expect(controller.entries.single.name, 'two.txt');
      controller.dispose();
      await _settle();
    },
  );

  test('a lost signal rescans and establishes a replacement watch', () async {
    final lanes = controller_test.FakePaneLanes();
    final channel = _WatchingPaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('/home/tester', 'one.txt')];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await _settle();

    channel.emit('/home/tester', DirectoryWatchSignal.lost);
    await _settle();

    expect(channel.listCalls, ['/home/tester', '/home/tester']);
    expect(channel.watchedPaths, ['/home/tester', '/home/tester']);
    controller.dispose();
    await _settle();
  });

  test('an early lost signal during setup is not missed', () async {
    final lanes = controller_test.FakePaneLanes();
    final watchGate = Completer<void>();
    final channel = _WatchingPaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('/home/tester', 'one.txt')]
      ..holdNextWatch = watchGate;
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);

    await controller.openLocalHome();
    channel.emit('/home/tester', DirectoryWatchSignal.lost);
    await _settle();

    expect(channel.watchedPaths, ['/home/tester', '/home/tester']);
    expect(channel.listCalls, ['/home/tester']);

    watchGate.complete();
    await _settle();
    expect(channel.listCalls, ['/home/tester']);
    controller.dispose();
    await _settle();
  });

  test('navigation arms the new watch before listing the new path', () async {
    final lanes = controller_test.FakePaneLanes();
    final channel = _WatchingPaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('/home/tester', 'one.txt')]
      ..listings['/home/tester/docs'] = [
        _entry('/home/tester/docs', 'two.txt'),
      ];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await _settle();

    final watchGate = Completer<void>();
    channel.holdNextWatch = watchGate;
    controller.navigate('/home/tester/docs');
    await _settle();

    expect(channel.unwatchCalls, 1);
    expect(channel.watchedPaths, ['/home/tester', '/home/tester/docs']);
    expect(channel.listCalls, ['/home/tester']);

    channel.emit('/home/tester', DirectoryWatchSignal.changed);
    await _settle();
    expect(channel.listCalls, ['/home/tester']);

    watchGate.complete();
    await _settle();

    expect(channel.listCalls, ['/home/tester', '/home/tester/docs']);
    expect(channel.watchedPaths, ['/home/tester', '/home/tester/docs']);
    expect(controller.location, const LocalPaneLocation('/home/tester/docs'));
    controller.dispose();
    await _settle();
  });

  test('cancelling navigation restores the prior directory watch', () async {
    final lanes = controller_test.FakePaneLanes();
    final channel = _WatchingPaneChannel('/home/tester')
      ..listings['/home/tester'] = const []
      ..listings['/home/tester/docs'] = const [];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await _settle();

    final watchGate = Completer<void>();
    channel.holdNextWatch = watchGate;
    controller.navigate('/home/tester/docs');
    await _settle();
    controller.cancelNavigation();
    await _settle();

    expect(controller.location, const LocalPaneLocation('/home/tester'));
    expect(controller.loading, isFalse);
    expect(channel.watchedPaths, [
      '/home/tester',
      '/home/tester/docs',
      '/home/tester',
    ]);

    channel.emit('/home/tester/docs', DirectoryWatchSignal.changed);
    await _settle();
    expect(channel.listCalls, ['/home/tester']);

    watchGate.complete();
    await _settle();
    expect(channel.listCalls, ['/home/tester']);
    controller.dispose();
    await _settle();
  });

  test('a stale-path signal cannot refresh the current directory', () async {
    final lanes = controller_test.FakePaneLanes();
    final channel = _WatchingPaneChannel('/home/tester')
      ..listings['/home/tester'] = const []
      ..listings['/home/tester/docs'] = const [];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await _settle();
    controller.navigate('/home/tester/docs');
    await _settle();

    expect(channel.watchedPaths, ['/home/tester', '/home/tester/docs']);
    channel.emit('/home/tester', DirectoryWatchSignal.lost);
    await _settle();

    expect(channel.listCalls, ['/home/tester', '/home/tester/docs']);
    expect(channel.watchedPaths, ['/home/tester', '/home/tester/docs']);

    channel.emit('/home/tester/docs', DirectoryWatchSignal.changed);
    await _settle();

    expect(channel.listCalls, [
      '/home/tester',
      '/home/tester/docs',
      '/home/tester/docs',
    ]);
    controller.dispose();
    await _settle();
  });

  test('a watch setup failure is visible and does not relist-loop', () async {
    final lanes = controller_test.FakePaneLanes();
    final failure = RemoteFileException(
      kind: RemoteFileErrorKind.permissionDenied,
      operation: 'watch',
      path: '/home/tester',
      message: 'watch denied',
    );
    final channel = _WatchingPaneChannel('/home/tester')
      ..listings['/home/tester'] = const []
      ..watchFailure = failure;
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);

    await controller.openLocalHome();
    await _settle();

    expect(controller.error, same(failure));
    expect(channel.listCalls, isEmpty);
    expect(channel.watchedPaths, ['/home/tester']);
    controller.dispose();
    await _settle();
  });

  test('not-found during a watched refresh drops the watch', () async {
    final lanes = controller_test.FakePaneLanes();
    final channel = _WatchingPaneChannel('/home/tester')
      ..listings['/home/tester'] = const [];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await _settle();

    channel.listingFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.notFound,
      operation: 'list',
      path: '/home/tester',
      message: 'gone',
    );
    channel.emit('/home/tester', DirectoryWatchSignal.changed);
    await _settle();

    expect(controller.error?.kind, RemoteFileErrorKind.notFound);
    expect(channel.unwatchCalls, 1);
    controller.dispose();
    await _settle();
  });

  test('rebind releases the local watch and never watches remote', () async {
    final lanes = controller_test.FakePaneLanes();
    final local = _WatchingPaneChannel('/home/tester')
      ..listings['/home/tester'] = const [];
    final remote = _WatchingPaneChannel('/srv/home')
      ..listings['/srv/home'] = const [];
    lanes
      ..nextLocalChannel = local
      ..nextRemoteChannel = remote;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await _settle();

    await controller.connectRemote(_bookmark());
    await _settle();

    expect(local.unwatchCalls, 1);
    expect(local.closeCalls, 1);
    expect(
      local.operations,
      containsAllInOrder(['unwatch', 'cancel', 'close']),
    );
    expect(remote.watchedPaths, isEmpty);
    expect(remote.operations, isNot(contains('subscribe')));
    controller.dispose();
    await _settle();
  });

  test('a background tab unwatches and refreshes when activated', () async {
    final lanes = controller_test.FakePaneLanes();
    final channel = _WatchingPaneChannel('/home/tester')
      ..listings['/home/tester'] = [_entry('/home/tester', 'one.txt')];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await _settle();

    controller.setTabActivity(PaneTabActivity.background);
    channel.emit('/home/tester', DirectoryWatchSignal.changed);
    await _settle();

    expect(channel.unwatchCalls, 1);
    expect(channel.listCalls, ['/home/tester']);

    channel.listings['/home/tester'] = [_entry('/home/tester', 'two.txt')];
    controller.setTabActivity(PaneTabActivity.active);
    await _settle();

    expect(channel.watchedPaths, ['/home/tester', '/home/tester']);
    expect(channel.listCalls, ['/home/tester', '/home/tester']);
    expect(controller.entries.single.name, 'two.txt');
    controller.dispose();
    await _settle();
  });

  test('dispose supersedes a pending watch before any listing', () async {
    final lanes = controller_test.FakePaneLanes();
    final watchGate = Completer<void>();
    final channel = _WatchingPaneChannel('/home/tester')
      ..listings['/home/tester'] = const []
      ..holdNextWatch = watchGate;
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();

    controller.dispose();
    await _settle();

    expect(channel.listCalls, isEmpty);
    expect(
      channel.operations,
      containsAllInOrder(['watch:/home/tester', 'unwatch', 'cancel', 'close']),
    );

    watchGate.complete();
    await _settle();
    expect(channel.listCalls, isEmpty);
  });

  test('dispose releases the local watch before closing its channel', () async {
    final lanes = controller_test.FakePaneLanes();
    final channel = _WatchingPaneChannel('/home/tester')
      ..listings['/home/tester'] = const [];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await _settle();

    controller.dispose();
    await _settle();

    expect(channel.unwatchCalls, 1);
    expect(channel.closeCalls, 1);
    expect(
      channel.operations,
      containsAllInOrder(['unwatch', 'cancel', 'close']),
    );
  });
}
