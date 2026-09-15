import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_app/services/double_click_action.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_engine_lanes.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/quick_select_state.dart';
import 'package:poltergeist_app/services/view_preferences.dart';

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

  /// Recorded rename calls (oldPath, newPath) and a scripted failure —
  /// null renames succeed silently.
  final renameCalls = <(String, String)>[];
  Object? renameFailure;
  Completer<void>? heldRename;

  @override
  Future<void> rename(String oldPath, String newPath) async {
    renameCalls.add((oldPath, newPath));
    final held = heldRename;
    if (held != null) {
      heldRename = null;
      await held.future;
    }
    final failure = renameFailure;
    if (failure != null) throw failure;
  }

  /// Recorded default-app opens (paths) and a scripted failure — null
  /// opens succeed silently.
  final openCalls = <String>[];
  Object? openFailure;

  @override
  Future<void> openInDefaultApp(String path) async {
    openCalls.add(path);
    final failure = openFailure;
    if (failure != null) throw failure;
  }

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

  test('openEntry navigates directories and routes files by the '
      'preference', () async {
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

    // A file under the default Open launches through the channel's
    // default-app seam — never a navigation (02 §2.6).
    await controller.openEntry(controller.entries[1]);
    expect(channel.listCalls, ['/home/tester']);
    expect(channel.openCalls, ['/parent/file.txt']);

    // A symlink is not a directory from listing metadata alone (02
    // §2.3): it routes as a file — the OS resolves the link at launch.
    await controller.openEntry(
      controller.entries.firstWhere((e) => e.name == 'link'),
    );
    expect(channel.listCalls, ['/home/tester']);
    expect(channel.openCalls, ['/parent/file.txt', '/parent/link']);

    await controller.openEntry(controller.entries[0]);
    await Future<void>.delayed(Duration.zero);
    expect(channel.listCalls, ['/home/tester', '/parent/folder']);
    // The folder never consulted the preference — no launch, no notice.
    expect(channel.openCalls, ['/parent/file.txt', '/parent/link']);
    expect(controller.notice, isNull);
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

  test('the transient lenses reset when the binding is replaced', () async {
    final lanes = FakePaneLanes();
    lanes.nextLocalChannel = FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = const [];
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await settle();

    controller.showHidden = true;
    controller.viewMode = PaneViewMode.list;

    // A new binding is a new browsing session: the hidden override and
    // view mode die with the old one, like the listing and filter do.
    lanes.nextLocalChannel = FakePaneChannel('/srv/other')
      ..listings['/srv/other'] = const [];
    await controller.openLocalAt('/srv/other');
    await settle();

    expect(controller.location, const LocalPaneLocation('/srv/other'));
    expect(controller.showHidden, isFalse);
    expect(controller.viewMode, PaneViewMode.details);
    controller.dispose();
  });

  test('the transient lenses reset on unbind', () async {
    final lanes = FakePaneLanes();
    lanes.nextRemoteChannel = FakePaneChannel('/srv/home')
      ..listings['/srv/home'] = const [];
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.connectRemote(_remoteBookmark());
    await settle();

    controller.showHidden = true;
    controller.viewMode = PaneViewMode.list;

    await controller.detachRemote();

    expect(controller.phase, PanePhase.unbound);
    expect(controller.showHidden, isFalse);
    expect(controller.viewMode, PaneViewMode.details);
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

    test('Enter in Remove mode commits the removals', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
        _entry('gamma.md'),
      ]);
      controller.selectAll();
      controller.openQuickSelect();
      controller.changeQuickSelectMode(QuickSelectMode.remove);
      controller.changeQuickSelectQuery('alpha');

      controller.confirmQuickSelect();

      expect(controller.quickSelectActive, isFalse);
      expect(controller.isRowSelected(0), isFalse);
      expect(controller.isRowSelected(1), isTrue);
      expect(controller.isRowSelected(2), isTrue);
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

  group('inline rename (02 §2.6)', () {
    /// A controller browsing a scripted local listing; the channel is
    /// returned alongside so rename calls and failures are scriptable.
    Future<(PaneController, FakePaneChannel)> renaming(
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
      return (controller, channel);
    }

    test('opens on the cursor row and Esc cancels without a request',
        () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
      ]);
      expect(controller.inlineRenameActive, isFalse);
      expect(controller.renameTarget, isNull);

      // No cursor → nothing to edit.
      controller.startRename();
      expect(controller.renameTarget, isNull);

      controller.setCursorIndex(1);
      controller.startRename();
      expect(controller.inlineRenameActive, isTrue);
      expect(controller.renameTarget!.name, 'beta.txt');
      expect(controller.renameIndex, 1);

      controller.cancelRename();
      expect(controller.inlineRenameActive, isFalse);
      expect(controller.renameTarget, isNull);
      expect(channel.renameCalls, isEmpty);
      controller.dispose();
    });

    test('is inert off the verb surface and while a commit is in flight',
        () async {
      // Unbound: no verbs, no session.
      final unbound = PaneController(paneTabId: 'pane.left');
      unbound.startRename();
      expect(unbound.inlineRenameActive, isFalse);
      unbound.dispose();

      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        _entry('alpha.txt'),
      ]);
      controller.setCursorIndex(0);
      controller.startRename();
      // A second start while a session is open is a no-op.
      controller.startRename();
      expect(controller.renameTarget!.name, 'alpha.txt');

      // During the in-flight commit, another start is rejected.
      channel.heldRename = Completer<void>();
      unawaited(controller.submitRename('gamma.txt'));
      expect(controller.renameTarget, isNull);
      expect(controller.inlineRenameActive, isTrue,
          reason: 'the in-flight commit still holds the close guard');
      controller.startRename();
      expect(controller.renameTarget, isNull);
      channel.heldRename = null;
      controller.dispose();
    });

    test('the unchanged name closes silently — no request, no refresh',
        () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        _entry('alpha.txt'),
      ]);
      controller.setCursorIndex(0);
      controller.startRename();
      await controller.submitRename('alpha.txt');

      expect(controller.inlineRenameActive, isFalse);
      expect(channel.renameCalls, isEmpty);
      expect(
        channel.listCalls,
        ['/home/tester'],
        reason: 'a no-op rename must not refresh the listing',
      );
      controller.dispose();
    });

    test('blank, separator, and Windows-invalid names stay client-side',
        () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        _entry('alpha.txt'),
      ]);
      controller.setCursorIndex(0);

      controller.startRename();
      await controller.submitRename('   ');
      expect(
        (controller.renameError! as PaneFaultException).fault,
        PaneFault.renameNameEmpty,
      );
      expect(controller.inlineRenameActive, isTrue,
          reason: 'a failed validation keeps the field open');

      await controller.submitRename('a/b');
      expect(
        (controller.renameError! as PaneFaultException).fault,
        PaneFault.renameNameSeparator,
      );

      expect(channel.renameCalls, isEmpty);
      controller.cancelRename();
      controller.dispose();
    });

    test('a local pane on Windows rejects the NTFS set but POSIX does '
        'not', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final lanes = FakePaneLanes();
        final (controller, channel) = await renaming(lanes, [
          _entry('alpha.txt'),
        ]);
        controller.setCursorIndex(0);
        controller.startRename();
        await controller.submitRename('a:b');
        expect(
          (controller.renameError! as PaneFaultException).fault,
          PaneFault.renameNameInvalid,
        );
        expect(channel.renameCalls, isEmpty);
        controller.dispose();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('a valid commit renames, refreshes, and reselects the row',
        () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
      ]);
      controller.setCursorIndex(1);
      controller.startRename();

      // The refresh answers with the renamed listing (the engine has
      // applied the rename by then).
      channel.listings['/home/tester'] = [
        _entry('alpha.txt'),
        _entry('renamed.txt'),
      ];
      await controller.submitRename('renamed.txt');
      await settle();

      expect(channel.renameCalls, [
        ('/parent/beta.txt', '/parent/renamed.txt'),
      ]);
      expect(
        channel.listCalls,
        ['/home/tester', '/home/tester'],
        reason: 'a committed rename re-lists its directory',
      );
      expect(controller.inlineRenameActive, isFalse);
      // The cursor re-anchors on the renamed row, not a pruned index.
      expect(controller.cursorIndex, 1);
      expect(controller.entries[1].name, 'renamed.txt');
      controller.dispose();
    });

    test('a typed refusal re-opens the field with the error inside',
        () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        _entry('alpha.txt'),
      ]);
      controller.setCursorIndex(0);
      controller.startRename();
      channel.renameFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'rename',
        path: '/parent/alpha.txt',
        message: 'Permission denied',
      );
      await controller.submitRename('beta.txt');

      expect(controller.renameTarget, isNotNull,
          reason: 'the field re-opens on the failed session');
      expect(
        controller.renameError!.kind,
        RemoteFileErrorKind.permissionDenied,
      );
      expect(controller.inlineRenameActive, isTrue);
      // A retry submits against the same session.
      channel.renameFailure = null;
      channel.listings['/home/tester'] = [_entry('beta.txt')];
      await controller.submitRename('beta.txt');
      await settle();
      expect(controller.inlineRenameActive, isFalse);
      expect(channel.renameCalls.last, ('/parent/alpha.txt', '/parent/beta.txt'));
      controller.dispose();
    });

    test('an untyped failure reports through onError and closes the '
        'field', () async {
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [_entry('alpha.txt')];
      lanes.nextLocalChannel = channel;
      final reported = <Object>[];
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
        onError: (error, stackTrace) => reported.add(error),
      );
      await controller.openLocalHome();
      await settle();

      controller.setCursorIndex(0);
      controller.startRename();
      channel.renameFailure = StateError('engine exploded');
      await controller.submitRename('beta.txt');

      expect(controller.renameTarget, isNull);
      expect(controller.inlineRenameActive, isFalse);
      expect(
        reported.single,
        isA<StateError>(),
        reason: 'a non-VFS failure is not a name refusal — it reports '
            'through the pane\'s onError sink like every other untyped '
            'failure',
      );
      controller.dispose();
    });

    test('a location change ends the session; the in-flight commit '
        'settles without re-opening', () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        _entry('alpha.txt'),
        _entry('docs', type: RemoteFileType.directory),
      ]);
      channel.listings['/parent/docs'] = [_entry('inner.txt')];
      controller.setCursorIndex(0);
      controller.startRename();
      final held = Completer<void>();
      channel.heldRename = held;
      unawaited(controller.submitRename('beta.txt'));
      expect(controller.inlineRenameActive, isTrue);

      controller.navigate('/parent/docs');
      await settle();
      expect(controller.location, const LocalPaneLocation('/parent/docs'));
      channel.renameFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'rename',
        message: 'denied',
      );
      held.complete();
      await settle();
      expect(controller.renameTarget, isNull,
          reason: 'a rename settling after its pane navigated away '
              'never re-opens a field');
      expect(controller.inlineRenameActive, isFalse);
      controller.dispose();
    });

    test('a same-location refresh that keeps the row ends the session '
        'silently; losing it reports renameTargetGone', () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
      ]);
      controller.setCursorIndex(0);
      controller.startRename();

      // Row survives the refresh → the session just ends (the listing
      // the field edited against was replaced).
      channel.listings['/home/tester'] = [
        _entry('alpha.txt'),
        _entry('beta.txt'),
        _entry('gamma.txt'),
      ];
      controller.refresh();
      await settle();
      expect(controller.renameTarget, isNull);
      expect(controller.renameError, isNull);

      // Row vanishes mid-session → the session re-attaches with the
      // gone fault so the field can say why its target disappeared.
      controller.setCursorIndex(0);
      controller.startRename();
      channel.listings['/home/tester'] = [_entry('beta.txt')];
      controller.refresh();
      await settle();
      expect(controller.renameTarget, isNotNull);
      expect(
        (controller.renameError! as PaneFaultException).fault,
        PaneFault.renameTargetGone,
      );
      controller.dispose();
    });

    test('the new path keeps the entry path\'s own separator', () async {
      // A Windows-style entry path renames with '\' — never a
      // synthesized '/' join that would mismatch the refreshed
      // listing's normalized path and break the cursor re-anchor.
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        const RemoteFileEntry(
          path: r'C:\dir\beta.txt',
          name: 'beta.txt',
          type: RemoteFileType.file,
        ),
      ]);
      controller.setCursorIndex(0);
      controller.startRename();
      channel.listings['/home/tester'] = [
        const RemoteFileEntry(
          path: r'C:\dir\renamed.txt',
          name: 'renamed.txt',
          type: RemoteFileType.file,
        ),
      ];
      await controller.submitRename('renamed.txt');
      await settle();

      expect(channel.renameCalls, [
        (r'C:\dir\beta.txt', r'C:\dir\renamed.txt'),
      ]);
      controller.dispose();
    });

    test('a POSIX name containing a backslash stays inside its parent',
        () async {
      // '\' is a legal POSIX filename character — the parent split must
      // not land on a backslash inside the name itself.
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        const RemoteFileEntry(
          path: r'/parent/weird\name',
          name: r'weird\name',
          type: RemoteFileType.file,
        ),
      ]);
      controller.setCursorIndex(0);
      controller.startRename();
      channel.listings['/home/tester'] = [_entry('plain.txt')];
      await controller.submitRename('plain.txt');
      await settle();

      expect(channel.renameCalls, [
        (r'/parent/weird\name', '/parent/plain.txt'),
      ]);
      controller.dispose();
    });

    test('a separator-less path equal to its name joins the location',
        () async {
      // A path that is exactly its name carries no parent prefix —
      // the backslash inside it must not split, and the destination
      // joins the browsed location instead.
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        const RemoteFileEntry(
          path: r'weird\name',
          name: r'weird\name',
          type: RemoteFileType.file,
        ),
      ]);
      controller.setCursorIndex(0);
      controller.startRename();
      channel.listings['/home/tester'] = [_entry('plain.txt')];
      await controller.submitRename('plain.txt');
      await settle();

      expect(channel.renameCalls, [
        (r'weird\name', '/home/tester/plain.txt'),
      ]);
      controller.dispose();
    });

    test('a POSIX basename ending in a backslash keeps its parent',
        () async {
      // Both an internal AND a terminal '\': the terminal byte is part
      // of the legal POSIX name, not a separator — trimming it first
      // would leave a path that no longer ends with its name, and the
      // fallback split would then land inside the basename.
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        const RemoteFileEntry(
          path: '/parent/weird\\name\\',
          name: 'weird\\name\\',
          type: RemoteFileType.file,
        ),
      ]);
      controller.setCursorIndex(0);
      controller.startRename();
      channel.listings['/home/tester'] = [_entry('plain.txt')];
      await controller.submitRename('plain.txt');
      await settle();

      expect(channel.renameCalls, [
        ('/parent/weird\\name\\', '/parent/plain.txt'),
      ]);
      expect(
        controller.entries[controller.cursorIndex!].name,
        'plain.txt',
        reason: 'the refresh re-anchors on the real destination',
      );
      controller.dispose();
    });

    test('a remote pane keeps POSIX grammar for backslash names',
        () async {
      // A Windows client browsing a remote POSIX listing: the entry
      // path's grammar is '/', so a trailing '\' in the name is a
      // filename byte there too.
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/srv/home');
      channel.listings['/srv/home'] = [
        const RemoteFileEntry(
          path: '/parent/weird\\name\\',
          name: 'weird\\name\\',
          type: RemoteFileType.file,
        ),
      ];
      lanes.nextRemoteChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
      );
      await controller.connectRemote(_remoteBookmark());
      await settle();

      controller.setCursorIndex(0);
      controller.startRename();
      channel.listings['/srv/home'] = [_entry('plain.txt')];
      await controller.submitRename('plain.txt');
      await settle();

      expect(channel.renameCalls, [
        ('/parent/weird\\name\\', '/parent/plain.txt'),
      ]);
      controller.dispose();
    });

    test('a commit settling after a rebind to another server neither '
        'refreshes nor reselects the new binding', () async {
      final lanes = FakePaneLanes();
      final channelA = FakePaneChannel('/srv/a');
      channelA.listings['/srv/a'] = [_entry('alpha.txt')];
      lanes.nextRemoteChannel = channelA;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
      );
      await controller.connectRemote(_remoteBookmark());
      await settle();

      controller.setCursorIndex(0);
      controller.startRename();
      final held = Completer<void>();
      channelA.heldRename = held;
      unawaited(controller.submitRename('beta.txt'));
      expect(controller.inlineRenameActive, isTrue);

      // The tab rebinds to server B and its landing listing commits
      // BEFORE server A's rename settles. B's listing even contains a
      // row at A's destination path spelling.
      final channelB = FakePaneChannel('/srv/b');
      channelB.listings['/srv/b'] = [
        _entry('beta.txt'),
        _entry('other.txt'),
      ];
      lanes.nextRemoteChannel = channelB;
      await controller.connectRemote(_remoteBookmark(id: 'srv-2'));
      await settle();
      expect(
        controller.location,
        const RemotePaneLocation('srv-2', '/srv/b'),
      );

      held.complete();
      await settle();

      expect(controller.inlineRenameActive, isFalse,
          reason: 'the in-flight guard settles regardless of ownership');
      expect(
        channelB.listCalls,
        ['/srv/b'],
        reason: "server A's retired rename must not re-list server B",
      );
      expect(
        controller.cursorIndex,
        isNull,
        reason: "server A's destination must not install a pending "
            'selection on the new binding',
      );
      controller.dispose();
    });

    test('a refusal after a same-path rebind does not reopen the stale '
        'editor and reports operation-scoped', () async {
      final lanes = FakePaneLanes();
      final channelA = FakePaneChannel('/home/tester');
      channelA.listings['/home/tester'] = [_entry('alpha.txt')];
      lanes.nextLocalChannel = channelA;
      final reported = <Object>[];
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
        onError: (error, _) => reported.add(error),
      );
      await controller.openLocalHome();
      await settle();

      controller.setCursorIndex(0);
      controller.startRename();
      final held = Completer<void>();
      channelA.heldRename = held;
      unawaited(controller.submitRename('beta.txt'));

      // Rebind lands on the SAME path spelling — a value-equal
      // location must not make the old operation's session own the
      // new binding's presentation.
      final channelB = FakePaneChannel('/home/tester');
      channelB.listings['/home/tester'] = [_entry('alpha.txt')];
      lanes.nextLocalChannel = channelB;
      await controller.openLocalAt('/home/tester');
      await settle();

      channelA.renameFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'rename',
        path: '/parent/alpha.txt',
        message: 'denied',
      );
      held.complete();
      await settle();

      expect(controller.renameTarget, isNull,
          reason: 'a stale operation never reopens its editor on the '
              'replacement binding');
      expect(controller.inlineRenameActive, isFalse);
      expect(
        reported.single,
        isA<RemoteFileException>(),
        reason: 'a retired operation\'s refusal reports through the '
            'error sink instead of dropping silently',
      );
      controller.dispose();
    });

    test('a refusal after away-and-back navigation does not reopen the '
        'old session', () async {
      final lanes = FakePaneLanes();
      final reported = <Object>[];
      final channel = FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('alpha.txt'),
        _entry('docs', type: RemoteFileType.directory),
      ];
      channel.listings['/parent/docs'] = [_entry('inner.txt')];
      lanes.nextLocalChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
        onError: (error, _) => reported.add(error),
      );
      await controller.openLocalHome();
      await settle();

      controller.setCursorIndex(0);
      controller.startRename();
      final held = Completer<void>();
      channel.heldRename = held;
      unawaited(controller.submitRename('beta.txt'));

      // Away and back to the same path VALUE on the same channel: the
      // location compares equal but the browsing session moved on.
      controller.navigate('/parent/docs');
      await settle();
      controller.navigate('/home/tester');
      await settle();
      expect(controller.location, const LocalPaneLocation('/home/tester'));

      channel.renameFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'rename',
        path: '/parent/alpha.txt',
        message: 'denied',
      );
      held.complete();
      await settle();

      expect(controller.renameTarget, isNull,
          reason: 'an away-and-back round trip retires the operation\'s '
              'presentation ownership');
      expect(controller.inlineRenameActive, isFalse);
      expect(reported.single, isA<RemoteFileException>());
      controller.dispose();
    });

    test('submitting a renameTargetGone session sends no request',
        () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
      ]);
      controller.setCursorIndex(0);
      controller.startRename();

      // The edited row leaves the listing: the session re-attaches as
      // a renameTargetGone diagnostic — it must no longer be a live
      // mutation capability (the old path may name a hidden or
      // REPLACED file by now).
      channel.listings['/home/tester'] = [_entry('beta.txt')];
      controller.refresh();
      await settle();
      expect(
        (controller.renameError! as PaneFaultException).fault,
        PaneFault.renameTargetGone,
      );

      await controller.submitRename('gamma.txt');
      expect(channel.renameCalls, isEmpty,
          reason: 'an invalidated session must never reach the channel');
      expect(controller.inlineRenameActive, isFalse,
          reason: 'submitting the diagnostic dismisses it — a new edit '
              'needs a fresh row session');
      controller.dispose();
    });

    test('a same-path replacement fixture still cannot be renamed from '
        'the invalidated session', () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
      ]);
      controller.setCursorIndex(0);
      controller.startRename();

      // A filter hides the edited row — the file itself may still sit
      // at the old path (the gone fault's hidden-file case).
      controller.openFilter();
      controller.changeFilterQuery('beta');
      expect(
        (controller.renameError! as PaneFaultException).fault,
        PaneFault.renameTargetGone,
      );

      // A refresh now reports a REPLACEMENT entry at the old path —
      // still filtered out, so the diagnostic session stays mounted.
      channel.listings['/home/tester'] = [
        _entry('alpha.txt', size: 9999),
        _entry('beta.txt'),
      ];
      controller.refresh();
      await settle();
      expect(controller.renameTarget, isNotNull);

      await controller.submitRename('gamma.txt');
      expect(channel.renameCalls, isEmpty,
          reason: 'the stale session must not act on the replacement '
              'file now occupying the old path');
      controller.dispose();
    });

    test('a last-resort parent join on a root location does not double '
        'the separator', () async {
      // An entry whose path IS its name (an inconsistent listing)
      // forces the last-resort location join; a POSIX root already ends
      // with its separator, so the join must not produce '//'.
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/');
      channel.listings['/'] = [
        const RemoteFileEntry(
          path: 'plain.txt',
          name: 'plain.txt',
          type: RemoteFileType.file,
        ),
      ];
      lanes.nextLocalChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
      );
      await controller.openLocalHome();
      await settle();
      expect(controller.location, const LocalPaneLocation('/'));

      controller.setCursorIndex(0);
      controller.startRename();
      await controller.submitRename('renamed.txt');
      await settle();

      expect(channel.renameCalls, [
        ('plain.txt', '/renamed.txt'),
      ]);
      controller.dispose();
    });

    test('a last-resort parent join on a remote root does not double '
        'the separator', () async {
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/');
      channel.listings['/'] = [
        const RemoteFileEntry(
          path: 'plain.txt',
          name: 'plain.txt',
          type: RemoteFileType.file,
        ),
      ];
      lanes.nextRemoteChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
      );
      await controller.connectRemote(_remoteBookmark(remotePath: '/'));
      await settle();
      expect(
        controller.location,
        const RemotePaneLocation('srv-1', '/'),
      );

      controller.setCursorIndex(0);
      controller.startRename();
      await controller.submitRename('renamed.txt');
      await settle();

      expect(channel.renameCalls, [
        ('plain.txt', '/renamed.txt'),
      ]);
      controller.dispose();
    });

    test('a stalled commit releases the in-flight guard when a rebind '
        'retires its ownership token', () async {
      final lanes = FakePaneLanes();
      final channelA = FakePaneChannel('/srv/a');
      channelA.listings['/srv/a'] = [_entry('alpha.txt')];
      lanes.nextRemoteChannel = channelA;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
      );
      await controller.connectRemote(_remoteBookmark());
      await settle();

      controller.setCursorIndex(0);
      controller.startRename();
      final held = Completer<void>();
      channelA.heldRename = held; // a wedged request — never completes
      unawaited(controller.submitRename('beta.txt'));
      expect(controller.inlineRenameActive, isTrue);

      // Rebinding retires the stalled operation's token: its request
      // may still be black-holed, but it no longer owns this pane, so
      // the new binding's rename verb must not stay closed on it.
      final channelB = FakePaneChannel('/srv/b');
      channelB.listings['/srv/b'] = [_entry('beta.txt')];
      lanes.nextRemoteChannel = channelB;
      await controller.connectRemote(_remoteBookmark(id: 'srv-2'));
      await settle();

      expect(
        controller.inlineRenameActive,
        isFalse,
        reason: 'a retired operation must not keep the new binding\'s '
            'rename verb closed while its request stalls',
      );
      controller.setCursorIndex(0);
      controller.startRename();
      expect(controller.renameTarget?.name, 'beta.txt');

      // A newer commit's guard must survive the retired operation's
      // late settle — the settling frame may only clear a flag it owns.
      final heldB = Completer<void>();
      channelB.heldRename = heldB;
      unawaited(controller.submitRename('gamma.txt'));
      expect(controller.inlineRenameActive, isTrue);
      held.complete();
      await settle();
      expect(
        controller.inlineRenameActive,
        isTrue,
        reason: 'a retired operation settling late must not release a '
            'newer commit\'s guard',
      );
      heldB.complete();
      await settle();
      expect(controller.inlineRenameActive, isFalse);
      controller.dispose();
    });

    test('a stalled commit releases the in-flight guard when a location '
        'change retires its ownership token', () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await renaming(lanes, [
        _entry('alpha.txt'),
        _entry('docs', type: RemoteFileType.directory),
      ]);
      channel.listings['/parent/docs'] = [_entry('inner.txt')];
      controller.setCursorIndex(0);
      controller.startRename();
      final held = Completer<void>();
      channel.heldRename = held;
      unawaited(controller.submitRename('beta.txt'));
      expect(controller.inlineRenameActive, isTrue);

      controller.navigate('/parent/docs');
      await settle();
      expect(
        controller.inlineRenameActive,
        isFalse,
        reason: 'a retired operation must not keep the browsed '
            'location\'s rename verb closed while its request stalls',
      );
      controller.setCursorIndex(0);
      controller.startRename();
      expect(controller.renameTarget?.name, 'inner.txt');
      controller.dispose();
    });
  });

  group('file open (02 §2.6)', () {
    /// A local pane browsing one file row; the fake channel's
    /// [FakePaneChannel.openCalls] and [FakePaneChannel.openFailure]
    /// script the engine's default-app seam.
    Future<(PaneController, FakePaneChannel)> localFilePane(
      FakePaneLanes lanes, {
      List<RemoteFileEntry>? entries,
    }) async {
      final channel = FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] =
          entries ?? [_entry('file.txt')];
      lanes.nextLocalChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
      );
      await controller.openLocalHome();
      await settle();
      return (controller, channel);
    }

    test('the default Open launches a local file through the channel '
        'seam', () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await localFilePane(lanes);

      await controller.openEntry(controller.entries.single);

      expect(channel.openCalls, ['/parent/file.txt']);
      expect(channel.listCalls, ['/home/tester']);
      expect(controller.error, isNull);
      expect(controller.notice, isNull);
      controller.dispose();
    });

    test('Open on a remote file posts the unavailable notice and never '
        'reaches the channel', () async {
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/srv/home')
        ..listings['/srv/home'] = [_entry('remote.txt')];
      lanes.nextRemoteChannel = channel;
      final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);
      await controller.connectRemote(_remoteBookmark());
      await settle();

      await controller.openEntry(controller.entries.single);

      // The honest not-yet: managed checkout is the editor milestone's —
      // no launcher call, no error (02 §2.6).
      expect(controller.notice, PaneNotice.openRemoteUnavailable);
      expect(channel.openCalls, isEmpty);
      expect(controller.error, isNull);
      controller.dispose();
    });

    test('Edit posts its deferred-milestone notice without launching',
        () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await localFilePane(lanes);
      controller.doubleClickAction = DoubleClickAction.edit;

      await controller.openEntry(controller.entries.single);

      expect(controller.notice, PaneNotice.editLater);
      expect(channel.openCalls, isEmpty);
      expect(controller.error, isNull);
      controller.dispose();
    });

    test('Transfer posts its deferred-milestone notice without launching',
        () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await localFilePane(lanes);
      controller.doubleClickAction = DoubleClickAction.transfer;

      await controller.openEntry(controller.entries.single);

      expect(controller.notice, PaneNotice.transferLater);
      expect(channel.openCalls, isEmpty);
      expect(controller.error, isNull);
      controller.dispose();
    });

    test('Do nothing is exactly inert', () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await localFilePane(lanes);
      controller.doubleClickAction = DoubleClickAction.nothing;

      await controller.openEntry(controller.entries.single);

      expect(channel.openCalls, isEmpty);
      expect(channel.listCalls, ['/home/tester']);
      expect(controller.notice, isNull);
      expect(controller.error, isNull);
      controller.dispose();
    });

    test('folders navigate under every preference value', () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await localFilePane(
        lanes,
        entries: [_entry('folder', type: RemoteFileType.directory)],
      );
      channel.listings['/parent/folder'] = [_entry('inside.txt')];

      // The entry object stays valid after the first navigation carries
      // the listing away — each activation re-lists the folder.
      final folder = controller.entries.single;
      for (final action in DoubleClickAction.values) {
        controller.doubleClickAction = action;
        await controller.openEntry(folder);
        await settle();
      }

      expect(channel.listCalls, [
        '/home/tester',
        '/parent/folder',
        '/parent/folder',
        '/parent/folder',
        '/parent/folder',
      ]);
      expect(channel.openCalls, isEmpty);
      expect(controller.notice, isNull);
      controller.dispose();
    });

    test('a fresh activation clears the lingering notice', () async {
      final lanes = FakePaneLanes();
      final (controller, _) = await localFilePane(lanes);
      controller.doubleClickAction = DoubleClickAction.edit;
      await controller.openEntry(controller.entries.single);
      expect(controller.notice, isNotNull);

      controller.doubleClickAction = DoubleClickAction.nothing;
      await controller.openEntry(controller.entries.single);

      expect(controller.notice, isNull);
      controller.dispose();
    });

    test('dismissNotice clears the strip early', () async {
      final lanes = FakePaneLanes();
      final (controller, _) = await localFilePane(lanes);
      controller.doubleClickAction = DoubleClickAction.edit;
      await controller.openEntry(controller.entries.single);

      controller.dismissNotice();

      expect(controller.notice, isNull);
      controller.dispose();
    });

    test('the notice auto-dismisses after its lifetime', () async {
      final lanes = FakePaneLanes();
      final (controller, _) = await localFilePane(lanes);
      controller.noticeLifetime = const Duration(milliseconds: 20);
      controller.doubleClickAction = DoubleClickAction.edit;
      await controller.openEntry(controller.entries.single);
      expect(controller.notice, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(controller.notice, isNull);
      controller.dispose();
    });

    test('a typed launcher failure surfaces inline and Retry re-opens '
        'the same entry', () async {
      final lanes = FakePaneLanes();
      final (controller, channel) = await localFilePane(
        lanes,
        entries: [_entry('a.txt'), _entry('b.txt')],
      );
      channel.openFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'open',
        message: 'The launcher refused the file.',
      );

      await controller.openEntry(controller.entries.first);

      expect(controller.error, isA<RemoteFileException>());
      expect(controller.error!.kind, RemoteFileErrorKind.permissionDenied);
      expect(controller.error!.message, 'The launcher refused the file.');

      // Retry re-runs THE OPEN for the recorded entry — never a re-list
      // (02 §2.6): the listing call log stays put while the launcher
      // sees the same path again.
      channel.openFailure = null;
      await controller.retry();

      expect(channel.openCalls, ['/parent/a.txt', '/parent/a.txt']);
      expect(channel.listCalls, ['/home/tester']);
      expect(controller.error, isNull);
      controller.dispose();
    });

    test('an untyped launcher failure surfaces the authored fault and '
        'reports the opaque error', () async {
      final lanes = FakePaneLanes();
      final reported = <Object>[];
      final channel = FakePaneChannel('/home/tester')
        ..listings['/home/tester'] = [_entry('file.txt')]
        ..openFailure = StateError('spawn failed');
      lanes.nextLocalChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
        onError: (error, _) => reported.add(error),
      );
      await controller.openLocalHome();
      await settle();

      await controller.openEntry(controller.entries.single);

      final error = controller.error;
      expect(error, isA<PaneFaultException>());
      expect(
        (error! as PaneFaultException).fault,
        PaneFault.openFile,
      );
      expect(reported.single, isA<StateError>());
      controller.dispose();
    });
  });
}
