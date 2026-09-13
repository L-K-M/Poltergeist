import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_engine_lanes.dart';
import 'package:poltergeist_app/services/pane_location.dart';

// Red-first regressions for the round-14 review's two confirmed defects.
void main() {
  registerRound15Tests();
  test('cancelRecovery during an in-flight connect invalidates the bind',
      () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('late.txt')];
    lanes.nextRemoteChannel = channel;
    final heldOpen = Completer<void>();
    lanes.holdRemoteOpen = heldOpen;
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);

    // The connect parks on the held open; the engine reports reconnecting
    // so the banner is visible while the bind is still in flight.
    final connecting = controller.connectRemote(_remoteBookmark());
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, PanePhase.connectingRemote);
    lanes.emitState(
      'srv-1',
      const ServerStatus(ServerConnectionState.reconnecting),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.connectionLost, isTrue);

    // The banner's cancel: the user is done with this server.
    await controller.cancelRecovery();
    expect(lanes.disconnects, ['srv-1']);

    // The held open completing now must NOT bind the cancelled server:
    // the pane stays unbound and the stale channel is closed.
    heldOpen.complete();
    await connecting;
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, PanePhase.unbound);
    expect(controller.location, isNull);
    expect(channel.closeCalls, 1);
    expect(channel.listCalls, isEmpty,
        reason: 'the cancelled bind must never list');
    controller.dispose();
  });

  test('a failed bind clears the stale connection-lost banner', () async {
    final lanes = FakePaneLanes();
    lanes.remoteOpenFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: 'connect',
      message: 'Authentication failed for tester@web.example.com:22',
    );
    final heldOpen = Completer<void>();
    lanes.holdRemoteOpen = heldOpen;
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);

    // The connect parks after subscribing its status watch; the engine
    // reports reconnecting, then the open fails terminally.
    final connecting = controller.connectRemote(_remoteBookmark());
    await Future<void>.delayed(Duration.zero);
    lanes.emitState(
      'srv-1',
      const ServerStatus(ServerConnectionState.reconnecting),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.connectionLost, isTrue);

    heldOpen.complete();
    await connecting;
    await Future<void>.delayed(Duration.zero);

    // The bind failed terminally: no recovery is running, so the banner
    // must not linger over the error surface.
    expect(controller.error, isNotNull);
    expect(controller.connectionLost, isFalse);
    controller.dispose();
  });
}

RemoteFileEntry _entry(String name) => RemoteFileEntry(
  path: '/srv/home/$name',
  name: name,
  type: RemoteFileType.file,
);

Bookmark _remoteBookmark() {
  final now = DateTime.utc(2026, 9, 12);
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
    remotePath: '/',
    sortKey: 'k',
    createdAt: now,
    updatedAt: now,
  );
}

class FakePaneLanes implements PaneEngineLanes {
  final calls = <String>[];
  final statesControllers = <String, StreamController<ServerStatus>>{};

  FakePaneChannel? nextLocalChannel;
  FakePaneChannel? nextRemoteChannel;
  Object? remoteOpenFailure;

  Completer<void>? holdRemoteOpen;

  @override
  Future<AppBrowseChannel> openLocalChannel({required String rootPath}) async {
    calls.add('openLocal:$rootPath');
    // Consume-once, mirroring openBrowseChannel: a scripted local
    // channel serves exactly one open so later panes don't bleed their
    // recorded calls into the first pane's assertions.
    final channel = nextLocalChannel;
    nextLocalChannel = null;
    return channel ?? FakePaneChannel('/home/tester');
  }

  @override
  Future<AppBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  }) async {
    calls.add('openBrowse:$serverId:$paneTabId');
    final hold = holdRemoteOpen;
    if (hold != null) {
      holdRemoteOpen = null;
      await hold.future;
    }
    // One-shot, like every other knob: a scripted failure throws once
    // so a retry can script success without re-cleaning the flag.
    final failure = remoteOpenFailure;
    remoteOpenFailure = null;
    if (failure != null) throw failure;
    final channel = nextRemoteChannel ?? FakePaneChannel('/srv/home');
    nextRemoteChannel = null;
    return channel;
  }

  StreamController<ServerStatus> _statesOf(String serverId) =>
      statesControllers.putIfAbsent(
        serverId,
        () => StreamController<ServerStatus>.broadcast(),
      );

  void emitState(String serverId, ServerStatus status) {
    _statesOf(serverId).add(status);
  }

  @override
  Stream<ServerStatus> watchServer(String serverId) {
    calls.add('watch:$serverId');
    return _statesOf(serverId).stream;
  }

  final disconnects = <String>[];

  @override
  Future<void> disconnectServer(String serverId) async {
    disconnects.add(serverId);
  }
}

class FakePaneChannel implements AppBrowseChannel {
  FakePaneChannel(this.homePath);

  @override
  final String homePath;

  final listings = <String, List<RemoteFileEntry>>{};
  final listCalls = <String>[];
  int closeCalls = 0;

  /// When set, every listing answers this typed failure (a severed
  /// transport) instead of table data.
  RemoteFileException? failure;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    listCalls.add(path);
    final failure = this.failure;
    if (failure != null) throw failure;
    return listings[path] ?? const [];
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

// ── round-15 regressions ────────────────────────────────────────────────

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void registerRound15Tests() {
  test('retry on a severed remote channel reopens instead of looping', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('root.txt')];
    lanes.nextRemoteChannel = channel;
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);
    await controller.connectRemote(_remoteBookmark());
    await _settle();
    expect(controller.phase, PanePhase.browsing);

    // The transport severs mid-session: the next navigation fails with
    // the typed disconnected error over the cached listing.
    channel.failure = const RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: 'list',
      message: 'Connection closed.',
    );
    controller.navigate('/srv/www');
    await _settle();
    expect(controller.error?.kind, RemoteFileErrorKind.disconnected);
    expect(
      controller.location,
      const RemotePaneLocation('srv-1', '/srv/www'),
    );

    // Retry must REOPEN the channel (a fresh bind), not re-list the
    // dead one — and it must return to the directory the user was in.
    channel.failure = null;
    final reopened = FakePaneChannel('/srv/home');
    reopened.listings['/srv/www'] = [_entry('index.html')];
    lanes.nextRemoteChannel = reopened;
    await controller.retry();
    await _settle();

    expect(
      lanes.calls.where((c) => c.startsWith('openBrowse:')).length,
      2,
      reason: 'retry re-opens the browse channel',
    );
    expect(controller.error, isNull);
    expect(reopened.listCalls, ['/srv/www'],
        reason: 'the re-opened bind lands on the preserved directory');
    expect(
      controller.location,
      const RemotePaneLocation('srv-1', '/srv/www'),
    );
    expect(channel.closeCalls, 1, reason: 'the dead channel is released');
    controller.dispose();
  });

  test('a failed reconnect still preserves the user directory on the next retry', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('root.txt')];
    lanes.nextRemoteChannel = channel;
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);
    await controller.connectRemote(_remoteBookmark());
    await _settle();

    // Transport severs; the first retry reconnects but the server is
    // STILL unreachable — the reconnect bind itself fails.
    channel.failure = const RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: 'list',
      message: 'Connection closed.',
    );
    controller.navigate('/srv/www');
    await _settle();
    expect(controller.error?.kind, RemoteFileErrorKind.disconnected);

    lanes.remoteOpenFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: 'connect',
      message: 'unreachable',
    );
    await controller.retry(); // reconnect attempt fails
    await _settle();
    expect(controller.phase, PanePhase.connectingRemote);
    expect(controller.error, isNotNull);

    // The server comes back; the NEXT retry must land the user where
    // they were (/srv/www), not on the bookmark root.
    lanes.remoteOpenFailure = null;
    final healed = FakePaneChannel('/srv/home');
    healed.listings['/srv/www'] = [_entry('index.html')];
    lanes.nextRemoteChannel = healed;
    await controller.retry();
    await _settle();

    expect(healed.listCalls, ['/srv/www'],
        reason: 'the preserved directory survives a failed reconnect');
    expect(
      controller.location,
      const RemotePaneLocation('srv-1', '/srv/www'),
    );
    controller.dispose();
  });

  test('a dead status lane cannot latch the connection-lost banner', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = const [];
    lanes.nextRemoteChannel = channel;
    final controller = PaneController(
      paneTabId: 'pane.right',
      lanes: lanes,
      onError: (_, _) {},
    );
    await controller.connectRemote(_remoteBookmark());
    await _settle();

    // The lane reports reconnecting, then dies with an error.
    lanes.emitState(
      'srv-1',
      const ServerStatus(ServerConnectionState.reconnecting),
    );
    await _settle();
    expect(controller.connectionLost, isTrue);
    lanes.statesControllers['srv-1']!.addError('lane died');
    await _settle();

    // A dead lane must not leave the banner pinned on its last state.
    expect(controller.connectionLost, isFalse);
    controller.dispose();
  });

  test('a cleanly closed status lane cannot latch the connection-lost banner', () async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = const [];
    lanes.nextRemoteChannel = channel;
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);
    await controller.connectRemote(_remoteBookmark());
    await _settle();

    // The lane reports reconnecting, then closes cleanly (no error).
    lanes.emitState(
      'srv-1',
      const ServerStatus(ServerConnectionState.reconnecting),
    );
    await _settle();
    expect(controller.connectionLost, isTrue);
    await lanes.statesControllers['srv-1']!.close();
    await _settle();

    // A cleanly-ended lane must not leave the banner pinned either
    // (same rule as an errored lane).
    expect(controller.connectionLost, isFalse);
    controller.dispose();
  });
}
