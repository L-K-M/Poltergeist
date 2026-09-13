import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_engine_lanes.dart';

// Red-first regressions for the round-14 review's two confirmed defects.
void main() {
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
    return nextLocalChannel ?? FakePaneChannel('/home/tester');
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
      final failure = remoteOpenFailure;
      if (failure != null) throw failure;
    }
    final failure = remoteOpenFailure;
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

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    listCalls.add(path);
    return listings[path] ?? const [];
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}
