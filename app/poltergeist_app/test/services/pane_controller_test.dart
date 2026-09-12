import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_engine_lanes.dart';
import 'package:poltergeist_app/services/pane_location.dart';

/// Scripted lanes recording call order so ordering assertions (subscribe
/// before connect) can run against the fake.
class FakePaneLanes implements PaneEngineLanes {
  FakePaneLanes();

  final calls = <String>[];
  final statesControllers = <String, StreamController<ServerStatus>>{};

  FakePaneChannel? nextLocalChannel;
  FakePaneChannel? nextRemoteChannel;
  Object? remoteOpenFailure;
  Object? localOpenFailure;

  /// When set, the next remote open parks on this completer before
  /// answering — the connecting-state UI is testable without races.
  Completer<void>? holdRemoteOpen;

  @override
  Future<AppBrowseChannel> openLocalChannel({required String rootPath}) async {
    calls.add('openLocal:$rootPath');
    final failure = localOpenFailure;
    if (failure != null) throw failure;
    final channel = nextLocalChannel ?? FakePaneChannel('/home/tester');
    nextLocalChannel = null;
    return channel;
  }

  @override
  Future<AppBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  }) async {
    calls.add('openBrowse:$serverId:$paneTabId');
    final failure = remoteOpenFailure;
    if (failure != null) throw failure;
    final hold = holdRemoteOpen;
    if (hold != null) {
      holdRemoteOpen = null;
      await hold.future;
      if (remoteOpenFailure != null) throw remoteOpenFailure!;
    }
    final channel = nextRemoteChannel ?? FakePaneChannel('/srv/home');
    nextRemoteChannel = null;
    return channel;
  }

  StreamController<ServerStatus> _statesOf(String serverId) =>
      statesControllers.putIfAbsent(
        serverId,
        () => StreamController<ServerStatus>.broadcast(),
      );

  @override
  Stream<ServerStatus> watchServer(String serverId) {
    calls.add('watch:$serverId');
    return _statesOf(serverId).stream;
  }

  final disconnects = <String>[];

  @override
  Future<void> disconnectServer(String serverId) async {
    disconnects.add(serverId);
    // Mirrors the engine's teardown fan-out: the watch reports the drop.
    _statesOf(serverId).add(
      const ServerStatus(ServerConnectionState.disconnected),
    );
  }

  void emitState(String serverId, ServerStatus status) {
    statesControllers[serverId]?.add(status);
  }
}

/// A scripted browse channel: listings answer from [listings] by path, and
/// in-flight answers can be held back with [holdNext] to test stale
/// generations.
class FakePaneChannel implements AppBrowseChannel {
  FakePaneChannel(this.homePath);

  @override
  final String homePath;

  final listings = <String, List<RemoteFileEntry>>{};
  final listCalls = <String>[];
  int closeCalls = 0;
  Completer<void>? holdNext;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    listCalls.add(path);
    final hold = holdNext;
    if (hold != null) {
      holdNext = null;
      await hold.future;
    }
    final entries = listings[path];
    if (entries == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'list',
        path: path,
        message: 'Could not list "$path": no such directory',
      );
    }
    return entries;
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
  DateTime? modified,
}) {
  return RemoteFileEntry(
    path: '/parent/$name',
    name: name,
    type: type,
    size: size,
    modifiedAt: modified,
  );
}

Bookmark _remoteBookmark({String remotePath = '/', String id = 'srv-1'}) {
  final now = DateTime.utc(2026, 9, 12);
  return Bookmark(
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
    remotePath: remotePath,
    sortKey: 'k',
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  /// The controller's opens resolve at navigation issue; the fake's
  /// listings answer one microtask later, so tests settle before
  /// asserting on listing state.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('openLocalHome binds home, lists it, sorts directories first', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('zebra.txt'),
      _entry('alpha', type: RemoteFileType.directory, size: null),
      _entry('Beta.txt', size: 12),
    ];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);

    await controller.openLocalHome();
    await settle();

    expect(lanes.calls.first, 'openLocal:~');
    expect(channel.listCalls, ['/home/tester']);
    expect(controller.phase, PanePhase.browsing);
    expect(controller.location, const LocalPaneLocation('/home/tester'));
    expect(controller.loading, isFalse);
    expect(
      controller.entries.map((e) => e.name).toList(),
      ['alpha', 'Beta.txt', 'zebra.txt'],
    );
    controller.dispose();
  });

  test('dotfiles are hidden by default', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('.hidden'),
      _entry('visible.txt'),
      _entry('.config', type: RemoteFileType.directory),
    ];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);

    await controller.openLocalHome();
    await settle();

    expect(controller.entries.map((e) => e.name), ['visible.txt']);
    controller.dispose();
  });

  test('navigation issues optimistically and accepts current listings',
      () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('sub', type: RemoteFileType.directory),
    ];
    channel.listings['/home/tester/sub'] = [_entry('inner.txt')];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await settle();

    controller.navigate('/home/tester/sub');

    expect(controller.loading, isTrue);
    expect(controller.location, const LocalPaneLocation('/home/tester/sub'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.loading, isFalse);
    expect(controller.entries.single.name, 'inner.txt');
    expect(controller.verbsEnabled, isTrue);
    controller.dispose();
  });

  test('stale listing responses are dropped on arrival', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('a', type: RemoteFileType.directory),
      _entry('b', type: RemoteFileType.directory),
    ];
    channel.listings['/home/tester/a'] = [_entry('in-a')];
    channel.listings['/home/tester/b'] = [_entry('in-b')];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();

    // Hold the listing for a, then navigate away to b before it answers.
    final hold = Completer<void>();
    channel.holdNext = hold;
    controller.navigate('/home/tester/a');
    controller.navigate('/home/tester/b');
    await Future<void>.delayed(Duration.zero);

    // b answered; a is still held. Location is b with b's entries.
    expect(controller.location, const LocalPaneLocation('/home/tester/b'));
    expect(controller.entries.single.name, 'in-b');
    expect(controller.loading, isFalse);

    // a's late answer must not replace b's listing.
    hold.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.entries.single.name, 'in-b');
    expect(controller.location, const LocalPaneLocation('/home/tester/b'));
    controller.dispose();
  });

  test('error answers keep stale entries and disable verbs until retry',
      () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('here.txt')];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    // The cached listing is proven visible before the failing navigation
    // snapshots it (02 §2.7's cached-data rule).
    await Future<void>.delayed(Duration.zero);
    expect(controller.entries.single.name, 'here.txt');
    final before = controller.entries;

    controller.navigate('/home/tester/gone');
    await Future<void>.delayed(Duration.zero);

    expect(controller.error, isA<RemoteFileException>());
    expect(
      (controller.error as RemoteFileException).kind,
      RemoteFileErrorKind.notFound,
    );
    expect(controller.loading, isFalse);
    expect(controller.verbsEnabled, isFalse);
    // Cached data stays visible (02 §2.7's cached-data rule) — but it is
    // the OLD directory's listing, so the location stays where it was
    // going and verbs stay disabled until a listing is accepted.
    expect(controller.entries, same(before));
    expect(
      controller.location,
      const LocalPaneLocation('/home/tester/gone'),
      reason: 'the optimistic location stays after the error (02 §2.7)',
    );

    // Retry clears the error and re-accepts a listing.
    channel.listings['/home/tester/gone'] = [_entry('back.txt')];
    controller.retry();
    await Future<void>.delayed(Duration.zero);
    expect(controller.error, isNull);
    expect(controller.verbsEnabled, isTrue);
    expect(controller.entries.single.name, 'back.txt');
    controller.dispose();
  });

  test('Esc cancel restores the last quiescent snapshot, including errors',
      () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('root.txt')];
    channel.listings['/home/tester/slow'] = [_entry('slow.txt')];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await Future<void>.delayed(Duration.zero);

    // A cancelled navigation returns to the quiescent listing.
    final hold = Completer<void>();
    channel.holdNext = hold;
    controller.navigate('/home/tester/slow');
    controller.cancelNavigation();

    expect(controller.loading, isFalse);
    expect(controller.location, const LocalPaneLocation('/home/tester'));
    expect(controller.entries.single.name, 'root.txt');
    expect(channel.listCalls, ['/home/tester', '/home/tester/slow']);

    // The engine-side listing still completes; its answer must be stale.
    hold.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.entries.single.name, 'root.txt');
    expect(controller.loading, isFalse);

    // Cancelling a navigation issued over an errored pane restores the
    // error too (a cancelled Retry returns to its inline error, 02 §2.8).
    channel.listings.remove('/home/tester'); // the next navigation fails
    controller.navigate('/home/tester'); // fails: notFound
    await Future<void>.delayed(Duration.zero);
    expect(controller.error, isNotNull);

    channel.listings['/home/tester'] = [_entry('root.txt')];
    final hold2 = Completer<void>();
    channel.holdNext = hold2;
    controller.retry(); // in flight, will succeed when released
    expect(controller.error, isNull);
    controller.cancelNavigation();
    expect(controller.error, isNotNull, reason: 'the snapshot error returns');
    expect(controller.entries.single.name, 'root.txt');

    // Releasing the still-held retry must not overwrite the restored
    // snapshot: its generation was cancelled.
    hold2.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.entries.single.name, 'root.txt');
    expect(controller.error, isNotNull);
    controller.dispose();
  });

  test('connectRemote subscribes to state before opening the channel',
      () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('srv-file.txt')];
    lanes.nextRemoteChannel = channel;
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);

    await controller.connectRemote(_remoteBookmark());
    await settle();

    // The watch (subscribe) precedes the channel open in the call log.
    expect(lanes.calls, ['watch:srv-1', 'openBrowse:srv-1:pane.right']);
    expect(controller.phase, PanePhase.browsing);
    expect(
      controller.location,
      const RemotePaneLocation('srv-1', '/srv/home'),
    );
    expect(channel.listCalls, ['/srv/home']);
    controller.dispose();
  });

  test('connectRemote navigates to the bookmark remotePath, not home',
      () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/www'] = [_entry('index.html')];
    lanes.nextRemoteChannel = channel;
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);

    await controller.connectRemote(_remoteBookmark(remotePath: '/srv/www'));

    expect(channel.listCalls, ['/srv/www']);
    expect(
      controller.location,
      const RemotePaneLocation('srv-1', '/srv/www'),
    );
    controller.dispose();
  });

  test('a connect failure surfaces the typed error and retry reopens',
      () async {
    final lanes = FakePaneLanes();
    lanes.remoteOpenFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: 'connect',
      message: 'Authentication failed for tester@web.example.com:22',
    );
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);

    await controller.connectRemote(_remoteBookmark());

    expect(controller.phase, PanePhase.connectingRemote);
    expect(controller.verbsEnabled, isFalse);
    final error = controller.error!;
    expect(error.kind, RemoteFileErrorKind.disconnected);
    expect(error.message, contains('Authentication failed'));

    lanes.remoteOpenFailure = null;
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('ok.txt')];
    lanes.nextRemoteChannel = channel;
    await controller.retry();
    await Future<void>.delayed(Duration.zero);

    expect(controller.error, isNull);
    expect(controller.phase, PanePhase.browsing);
    expect(controller.entries.single.name, 'ok.txt');
    controller.dispose();
  });

  test('rebinding closes the previous channel and drops its server watch',
      () async {
    final lanes = FakePaneLanes();
    final local = FakePaneChannel('/home/tester');
    local.listings['/home/tester'] = [_entry('local.txt')];
    lanes.nextLocalChannel = local;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await settle();

    final remote = FakePaneChannel('/srv/home');
    remote.listings['/srv/home'] = [_entry('remote.txt')];
    lanes.nextRemoteChannel = remote;
    await controller.connectRemote(_remoteBookmark());
    await settle();

    expect(local.closeCalls, 1);
    expect(controller.location, const RemotePaneLocation('srv-1', '/srv/home'));
    expect(controller.entries.single.name, 'remote.txt');

    // A second remote target closes the first remote channel too.
    final second = FakePaneChannel('/other/home');
    second.listings['/other/home'] = [_entry('other.txt')];
    lanes.nextRemoteChannel = second;
    await controller.connectRemote(_remoteBookmark(id: 'srv-2'));
    await settle();
    expect(remote.closeCalls, 1);
    expect(
      lanes.statesControllers['srv-1']?.hasListener,
      isFalse,
      reason: 'rebinding must drop the previous server watch',
    );
    expect(
      lanes.statesControllers['srv-2']?.hasListener,
      isTrue,
      reason: 'rebinding must watch the new server',
    );
    expect(controller.location, const RemotePaneLocation('srv-2', '/other/home'));
    controller.dispose();
  });

  test('verbsEnabled requires a live browsing phase', () async {
    // No engine at all: never verbs.
    final engineless = PaneController(paneTabId: 'pane.left');
    expect(engineless.phase, PanePhase.unbound);
    expect(engineless.verbsEnabled, isFalse);
    engineless.dispose();

    // Mid-open phases carry no listing to act on.
    final lanes = FakePaneLanes();
    lanes.nextLocalChannel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = const [];
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    expect(controller.phase, PanePhase.unbound);
    expect(controller.verbsEnabled, isFalse);

    await controller.openLocalHome();
    // openLocalHome resolves once the channel is open and the first
    // navigation issued: the phase is browsing and, after the listing
    // lands, verbs are live.
    expect(controller.phase, PanePhase.browsing);
    expect(controller.verbsEnabled, isFalse, reason: 'still loading');
    await settle();
    expect(controller.phase, PanePhase.browsing);
    expect(controller.verbsEnabled, isTrue);
    controller.dispose();
  });

  test('a bookmark without a server identity fails the bind fast', () async {
    final lanes = FakePaneLanes();
    final faults = <Object>[];
    final controller = PaneController(
      paneTabId: 'pane.right',
      lanes: lanes,
      onError: (error, _) => faults.add(error),
    );
    final now = DateTime.utc(2026, 9, 12);
    final identityless = Bookmark(
      id: 'srv-1',
      kind: BookmarkKind.remotePath,
      label: 'web.example.com',
      remotePath: '/',
      sortKey: 'k',
      createdAt: now,
      updatedAt: now,
    );

    await controller.connectRemote(identityless);

    expect(controller.phase, PanePhase.connectingRemote);
    expect(controller.error, isNotNull);
    expect(controller.error!.kind, RemoteFileErrorKind.other);
    // The underlying ArgumentError was reported as a fault, and no
    // channel open was ever attempted against an empty host.
    expect(faults.single, isA<ArgumentError>());
    expect(lanes.calls.where((c) => c.startsWith('openBrowse')), isEmpty);
    controller.dispose();
  });

  test('dispose closes the channel', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = const [];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await settle();

    controller.dispose();

    expect(channel.closeCalls, 1);
  });

  test('openEntry navigates directories only', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('folder', type: RemoteFileType.directory),
      _entry('file.txt'),
      _entry('link', type: RemoteFileType.symbolicLink),
    ];
    channel.listings['/parent/folder'] = const [];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await settle();

    controller.openEntry(controller.entries[1]);
    expect(channel.listCalls, ['/home/tester']);

    // A symlink is not a directory from listing metadata alone (02
    // §2.3): opening it must never navigate.
    controller.openEntry(
      controller.entries.firstWhere((e) => e.name == 'link'),
    );
    expect(channel.listCalls, ['/home/tester']);

    controller.openEntry(controller.entries[0]);
    await Future<void>.delayed(Duration.zero);
    expect(channel.listCalls, ['/home/tester', '/parent/folder']);
    controller.dispose();
  });

  test('goUp navigates to the parent and stops at the root', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('sub', type: RemoteFileType.directory)];
    channel.listings['/home'] = const [];
    channel.listings['/'] = const [];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await settle();

    controller.goUp();
    await Future<void>.delayed(Duration.zero);
    expect(controller.location, const LocalPaneLocation('/home'));

    controller.goUp();
    await Future<void>.delayed(Duration.zero);
    expect(controller.location, const LocalPaneLocation('/'));

    controller.goUp();
    await Future<void>.delayed(Duration.zero);
    expect(controller.location, const LocalPaneLocation('/'));
    controller.dispose();
  });

  test('cursor moves within the listing and resets on navigation', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('a'),
      _entry('b'),
      _entry('c'),
    ];
    channel.listings['/other'] = [_entry('x')];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await settle();

    expect(controller.cursorIndex, isNull);

    controller.moveCursorBy(1);
    expect(controller.cursorIndex, 0);
    controller.moveCursorBy(1);
    expect(controller.cursorIndex, 1);
    controller.moveCursorBy(10);
    expect(controller.cursorIndex, 2);
    controller.moveCursorBy(-10);
    expect(controller.cursorIndex, 0);
    controller.setCursorIndex(2);
    expect(controller.cursorIndex, 2);

    controller.navigate('/other');
    await Future<void>.delayed(Duration.zero);
    expect(controller.cursorIndex, isNull);
    controller.dispose();
  });

  test('cancelRecovery after dispose is a no-op', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = const [];
    lanes.nextRemoteChannel = channel;
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);
    await controller.connectRemote(_remoteBookmark());
    await settle();

    controller.dispose();
    await controller.cancelRecovery();

    expect(lanes.disconnects, isEmpty);
  });

  test('a cancelled first listing keeps the remote kind for navigation', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('root.txt')];
    channel.listings['/srv/www'] = [_entry('www.txt')];
    lanes.nextRemoteChannel = channel;
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);
    await controller.connectRemote(_remoteBookmark());

    // Esc during the FIRST listing restores the null-location snapshot
    // while the remote channel stays live.
    controller.cancelNavigation();
    expect(controller.location, isNull);

    // A navigation after that must stay a REMOTE location — the binding,
    // not the cancelled location, decides the kind.
    controller.navigate('/srv/www');
    await Future<void>.delayed(Duration.zero);
    expect(controller.location, const RemotePaneLocation('srv-1', '/srv/www'));
    expect(controller.entries.single.name, 'www.txt');
    controller.dispose();
  });

  test('detaching a shared server leaves the pool for the sibling', () async {
    final lanes = FakePaneLanes();
    final a = FakePaneChannel('/srv/home')..listings['/srv/home'] = const [];
    final b = FakePaneChannel('/srv/home')..listings['/srv/home'] = const [];
    lanes.nextRemoteChannel = a;
    final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await left.connectRemote(_remoteBookmark());
    await settle();
    lanes.nextRemoteChannel = b;
    final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    await right.connectRemote(_remoteBookmark());
    await settle();

    // The shell-level cancel path detaches the pane without dropping
    // the shared server reference the sibling still browses on.
    unawaited(left.detachRemote());
    expect(a.closeCalls, 1);
    expect(lanes.disconnects, isEmpty);
    expect(left.phase, PanePhase.unbound);
    // The sibling keeps its binding and can still list.
    right.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(b.listCalls, ['/srv/home', '/srv/home']);
    left.dispose();
    right.dispose();
  });

  test('verbs stay disabled after cancelling the first listing', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('x.txt')];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();

    // Esc during the FIRST listing restores the quiescent snapshot,
    // whose location is null — verbs must stay off with no location.
    controller.cancelNavigation();
    expect(controller.phase, PanePhase.browsing);
    expect(controller.location, isNull);
    expect(controller.loading, isFalse);
    expect(controller.verbsEnabled, isFalse);
    controller.dispose();
  });

  test('arrow up from no cursor selects the last row', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('a'),
      _entry('b'),
      _entry('c'),
    ];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await settle();

    controller.moveCursorBy(-1);
    expect(controller.cursorIndex, 2);
    controller.moveCursorBy(-1);
    expect(controller.cursorIndex, 1);
    controller.moveCursorBy(-1);
    controller.moveCursorBy(-1);
    expect(controller.cursorIndex, 0);
    controller.dispose();
  });

  test('a failing local open never rejects the future', () async {
    final lanes = FakePaneLanes()
      ..localOpenFailure = StateError('no local browse channel scripted');
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);

    await controller.openLocalHome();

    expect(controller.phase, PanePhase.openingLocal);
    expect(controller.error, isNotNull);
    expect(controller.error!.kind, RemoteFileErrorKind.other);
    controller.dispose();
  });

  test('the post-first-cancel remote state can still unbind', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('root.txt')];
    lanes.nextRemoteChannel = channel;
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);
    await controller.connectRemote(_remoteBookmark());

    // Esc during the first listing: live remote channel, no location.
    controller.cancelNavigation();
    expect(controller.location, isNull);
    expect(controller.remoteBookmark, isNotNull);

    // The banner-cancel paths must not dead-end on the null location.
    await controller.cancelRecovery();
    expect(lanes.disconnects, ['srv-1']);

    // Detach in the same state closes the channel and resets the pane.
    await controller.detachRemote();
    expect(channel.closeCalls, 1);
    expect(controller.phase, PanePhase.unbound);
    expect(controller.remoteBookmark, isNull);
    controller.dispose();
  });

  test('cancelRecovery on a local pane is a no-op', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = const [];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await settle();

    await controller.cancelRecovery();
    await controller.detachRemote();

    expect(lanes.disconnects, isEmpty);
    expect(controller.phase, PanePhase.browsing);
    controller.dispose();
  });

  test('reconnecting state raises the connection-lost banner', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('file.txt')];
    lanes.nextRemoteChannel = channel;
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);
    await controller.connectRemote(_remoteBookmark());
    await settle();
    expect(controller.connectionLost, isFalse);

    lanes.emitState('srv-1', const ServerStatus(ServerConnectionState.connected));
    await Future<void>.delayed(Duration.zero);
    expect(controller.connectionLost, isFalse);

    lanes.emitState(
      'srv-1',
      const ServerStatus(ServerConnectionState.reconnecting),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.connectionLost, isTrue);

    lanes.emitState(
      'srv-1',
      const ServerStatus(ServerConnectionState.connected),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.connectionLost, isFalse);
    controller.dispose();
  });
}
