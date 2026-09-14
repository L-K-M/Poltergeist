import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_engine_lanes.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/quick_select_state.dart';

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

  /// When set, every listing throws this non-VFS error (drives the
  /// typed PaneFault list path).
  Object? listingFailure;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    listCalls.add(path);
    final hold = holdNext;
    if (hold != null) {
      holdNext = null;
      await hold.future;
    }
    final fault = listingFailure;
    if (fault != null) throw fault;
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

  test('digit runs order naturally on the accepted listing', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    final listed = [
      _entry('file10'),
      _entry('file1'),
      _entry('file2'),
    ];
    channel.listings['/home/tester'] = listed;
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);

    await controller.openLocalHome();
    await settle();

    // 02 §2.3: digit runs compare numerically, so file2 precedes file10
    // (lexical lowercase order would interleave file10 after file1).
    expect(
      controller.entries.map((e) => e.name).toList(),
      ['file1', 'file2', 'file10'],
    );
    // The sorted pane listing is a new order: the VFS-returned list keeps
    // the server's order and its entries keep their identity.
    expect(
      listed.map((e) => e.name).toList(),
      ['file10', 'file1', 'file2'],
    );
    expect(
      controller.entries,
      everyElement(isIn(listed)),
    );
    expect(controller.entries, isNot(same(listed)));
    // The §2.3 wiring must keep the old List.unmodifiable contract:
    // mutating the accepted listing has to throw.
    expect(
      () => controller.entries[0] = listed.first,
      throwsUnsupportedError,
    );
    controller.dispose();
  });

  test('Unicode simple fold orders names lowercase comparison would not',
      () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    // ς (final sigma) folds to σ and ſ (long s) folds to s under 02 §2.3's
    // simple fold, while toLowerCase leaves both untouched: lowercase
    // lexical order would put sz before ſb and ςa before σz.
    channel.listings['/home/tester'] = [
      _entry('ςa'),
      _entry('sz'),
      _entry('ſb'),
      _entry('σz'),
    ];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);

    await controller.openLocalHome();
    await settle();

    expect(
      controller.entries.map((e) => e.name).toList(),
      ['ſb', 'sz', 'ςa', 'σz'],
    );
    controller.dispose();
  });

  test('directories group first with natural names below', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('file10'),
      _entry('.hidden'),
      _entry('Dir 2', type: RemoteFileType.directory),
      _entry('file2'),
      _entry('Dir 10', type: RemoteFileType.directory),
    ];
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);

    await controller.openLocalHome();
    await settle();

    // Dotfiles stay hidden; directories group ahead of files, and the
    // files below them still sort naturally (file2 before file10).
    expect(
      controller.entries.map((e) => e.name).toList(),
      ['Dir 2', 'Dir 10', 'file2', 'file10'],
    );
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

    channel.listings['/home/tester'] = [_entry('fresh.txt')];
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

  group('quick select', () {
    /// A controller already browsing a scripted local listing.
    Future<PaneController> browsing(
      FakePaneLanes lanes,
      List<RemoteFileEntry> entries,
    ) async {
      final channel = FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = entries;
      lanes.nextLocalChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
      );
      await controller.openLocalHome();
      await settle();
      return controller;
    }

    test('opens over the listing and Enter keeps the preview', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
        _entry('gamma.md'),
      ]);
      expect(controller.quickSelectActive, isFalse);

      controller.setCursorIndex(2); // the opening selection: gamma.md
      controller.openQuickSelect();
      expect(controller.quickSelectActive, isTrue);
      expect(controller.quickSelectMode, QuickSelectMode.add);

      // A fragment preview adds matches to the opening selection.
      controller.changeQuickSelectQuery('.txt');
      expect(controller.isRowSelected(0), isTrue);
      expect(controller.isRowSelected(1), isTrue);
      expect(controller.isRowSelected(2), isTrue);

      // Narrowing recomputes from the baseline: alpha.txt drops back out.
      controller.changeQuickSelectQuery('beta');
      expect(controller.isRowSelected(0), isFalse);
      expect(controller.isRowSelected(1), isTrue);
      expect(controller.isRowSelected(2), isTrue);

      controller.confirmQuickSelect();
      expect(controller.quickSelectActive, isFalse);
      expect(controller.isRowSelected(1), isTrue);
      expect(controller.isRowSelected(2), isTrue);

      // Edits after close are ignored (02 §2.5's session boundary).
      controller.changeQuickSelectQuery('alpha');
      controller.changeQuickSelectMode(QuickSelectMode.remove);
      expect(controller.isRowSelected(0), isFalse);
      expect(controller.isRowSelected(1), isTrue);
      controller.dispose();
    });

    test('Esc restores the opening selection and closes', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
        _entry('gamma.md'),
      ]);
      controller.setCursorIndex(2);
      controller.openQuickSelect();
      controller.changeQuickSelectQuery('*.txt');
      expect(controller.selectedCount, 3);

      controller.cancelQuickSelect();

      expect(controller.quickSelectActive, isFalse);
      expect(controller.selectedCount, 1);
      expect(controller.isRowSelected(2), isTrue);
      controller.dispose();
    });

    test('Remove mode recomputes from the baseline too', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
        _entry('gamma.md'),
      ]);
      controller.selectAll();
      controller.openQuickSelect();
      controller.changeQuickSelectMode(QuickSelectMode.remove);
      controller.changeQuickSelectQuery('.txt');

      expect(controller.isRowSelected(0), isFalse);
      expect(controller.isRowSelected(1), isFalse);
      expect(controller.isRowSelected(2), isTrue);

      // Back to Add recomputes from the baseline, so the removed rows
      // return without a fresh query.
      controller.changeQuickSelectMode(QuickSelectMode.add);
      expect(controller.isRowSelected(0), isTrue);
      expect(controller.isRowSelected(1), isTrue);
      controller.dispose();
    });

    test('an empty query is a no-op on the opening selection', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
      ]);
      controller.setCursorIndex(0);
      controller.openQuickSelect();
      controller.changeQuickSelectQuery('beta');
      controller.changeQuickSelectQuery('');

      expect(controller.isRowSelected(0), isTrue);
      expect(controller.isRowSelected(1), isFalse);
      controller.dispose();
    });

    test('glob characters other than * stay literal through the pane', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('a?b.txt'),
        _entry('axb.txt'),
        _entry('a[b.txt'),
        _entry('zz.txt'),
      ]);
      int rowOf(String name) =>
          controller.entries.indexWhere((e) => e.name == name);

      controller.openQuickSelect();
      controller.changeQuickSelectQuery('a?b'); // ? is literal, not a wildcard
      expect(controller.isRowSelected(rowOf('a?b.txt')), isTrue);
      expect(controller.isRowSelected(rowOf('axb.txt')), isFalse);
      expect(controller.isRowSelected(rowOf('a[b.txt')), isFalse);

      controller.changeQuickSelectQuery('a[b'); // brackets literal too
      expect(controller.isRowSelected(rowOf('a?b.txt')), isFalse);
      expect(controller.isRowSelected(rowOf('a[b.txt')), isTrue);

      // Consecutive stars match identically to one (02 §2.5): a**b.txt
      // selects every name starting 'a' and ending 'b.txt', like a*b.txt.
      controller.changeQuickSelectQuery('a**b.txt');
      expect(controller.isRowSelected(rowOf('a?b.txt')), isTrue);
      expect(controller.isRowSelected(rowOf('axb.txt')), isTrue);
      expect(controller.isRowSelected(rowOf('a[b.txt')), isTrue);
      expect(controller.isRowSelected(rowOf('zz.txt')), isFalse);
      controller.dispose();
    });

    test('flagged (U+FFFD) rows never match but a preselected one survives',
        () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('good.txt'),
        _entry('bad\uFFFDname.txt'),
        _entry('other.txt'),
      ]);
      int rowOf(String name) =>
          controller.entries.indexWhere((e) => e.name == name);
      final flagged = rowOf('bad\uFFFDname.txt');
      final good = rowOf('good.txt');
      final other = rowOf('other.txt');

      // The flagged row is manually selected BEFORE the field opens.
      controller.setCursorIndex(flagged);
      controller.openQuickSelect();
      controller.changeQuickSelectQuery('*.txt');

      expect(controller.isRowSelected(good), isTrue);
      expect(controller.isRowSelected(flagged), isTrue,
          reason: 'baseline survives');
      expect(controller.isRowSelected(other), isTrue);

      // Remove mode cannot touch the excluded row either.
      controller.changeQuickSelectMode(QuickSelectMode.remove);
      expect(controller.isRowSelected(good), isFalse);
      expect(controller.isRowSelected(flagged), isTrue);
      expect(controller.isRowSelected(other), isFalse);
      controller.dispose();
    });

    test('hidden rows are filtered before matching', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('.secret.txt'),
        _entry('visible.txt'),
      ]);
      // The hidden-policy filter already ran at listing accept, so the
      // matcher's universe is exactly the visible rows.
      expect(controller.entries.map((e) => e.name), ['visible.txt']);
      controller.openQuickSelect();
      controller.changeQuickSelectQuery('*.txt');

      expect(controller.selectedCount, 1);
      expect(controller.isRowSelected(0), isTrue);
      controller.dispose();
    });

    test('navigation ends the session before the listing is replaced',
        () async {
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('alpha.txt'),
        _entry('sub', type: RemoteFileType.directory),
      ];
      channel.listings['/parent/sub'] = [_entry('nested.txt')];
      lanes.nextLocalChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
      );
      await controller.openLocalHome();
      await settle();

      controller.setCursorIndex(0);
      controller.openQuickSelect();
      controller.changeQuickSelectQuery('*');
      expect(controller.selectedCount, 2);

      controller.navigate('/parent/sub');
      expect(controller.quickSelectActive, isFalse,
          reason: 'the session ends at navigation issue, not on arrival');

      await settle();
      // The new listing pruned the restored baseline: no stale restore.
      expect(controller.entries.single.name, 'nested.txt');
      expect(controller.selectedCount, 0);
      controller.dispose();
    });

    test('a listing replacement restores the baseline before pruning',
        () async {
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('alpha.txt'),
        _entry('beta.txt'),
      ];
      lanes.nextLocalChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
      );
      await controller.openLocalHome();
      await settle();

      controller.setCursorIndex(0); // baseline: alpha.txt only
      controller.openQuickSelect();
      controller.changeQuickSelectQuery('*');
      expect(controller.selectedCount, 2);

      // A refresh re-lists the same directory: the row identities are
      // stable (same paths), so the restored baseline — not the preview
      // — is what survives pruning.
      controller.refresh();
      expect(controller.quickSelectActive, isFalse);
      await settle();
      expect(controller.selectedCount, 1);
      expect(controller.isRowSelected(0), isTrue);
      expect(controller.isRowSelected(1), isFalse);
      controller.dispose();
    });

    test('a stale listing answer cannot resurrect or corrupt the session',
        () async {
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [_entry('a.txt'), _entry('b.txt')];
      channel.listings['/other'] = [_entry('x.txt')];
      lanes.nextLocalChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
      );
      await controller.openLocalHome();
      await settle();

      controller.openQuickSelect();
      controller.changeQuickSelectQuery('*');
      expect(controller.selectedCount, 2);

      // A held navigation ends the session synchronously; its late
      // answer lands in a new listing with no session attached.
      final hold = Completer<void>();
      channel.holdNext = hold;
      controller.navigate('/other');
      expect(controller.quickSelectActive, isFalse);
      hold.complete();
      await settle();
      expect(controller.quickSelectActive, isFalse);
      expect(controller.entries.single.name, 'x.txt');
      expect(controller.selectedCount, 0);
      controller.dispose();
    });

    test('open requires verbs, and a second open never re-baselines',
        () async {
      // Verbs off (no binding at all): the open is a no-op.
      final unbound = PaneController(paneTabId: 'pane.left');
      unbound.openQuickSelect();
      expect(unbound.quickSelectActive, isFalse);
      unbound.dispose();

      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
      ]);
      controller.openQuickSelect();
      controller.setCursorIndex(0); // a manual edit mid-session
      controller.openQuickSelect(); // must not re-capture the baseline
      controller.cancelQuickSelect();
      expect(
        controller.selectedCount,
        0,
        reason:
            'Esc restores the FIRST baseline (empty), not the mid-session edit',
      );
      controller.dispose();
    });
  });
}
