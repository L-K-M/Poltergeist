import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/application_error_reporter.dart';
import 'package:poltergeist_app/services/bookmark_store.dart';
import 'package:poltergeist_app/services/connection_state_bridge.dart';
import 'package:poltergeist_app/services/connection_status_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_bookmark_store.dart';
import '../support/fake_connection_state_bridge.dart';

final _now = DateTime.utc(2026, 9, 10, 12);

/// Waits for [condition] on a real clock, reporting [describe] on timeout.
/// The engine lanes cross an isolate port, so a current-state-first watch
/// arrives on a later turn, not in the frame that subscribed.
Future<void> _pollUntil(
  bool Function() condition, {
  required String describe,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after $timeout waiting for $describe');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Bookmark _server(
  String id, {
  String label = 'web',
  String host = 'web.example.com',
  int port = 2222,
  String username = 'deploy',
}) {
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: label,
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: host,
        port: port,
        username: username,
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/',
    sortKey: id,
    createdAt: _now,
    updatedAt: _now,
  );
}

Bookmark _localFolder(String id) {
  return Bookmark(
    id: id,
    kind: BookmarkKind.localFolder,
    label: 'home',
    localPath: '/home/tester',
    sortKey: id,
    createdAt: _now,
    updatedAt: _now,
  );
}

/// A reference-style server: no endpoint in Poltergeist (04 §2.2), so it is
/// not a serverId the pool can hold.
Bookmark _referenceStyle(String id) {
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: 'ref',
    server: const BookmarkServerRef(serverConfigId: 'config-1'),
    remotePath: '/',
    sortKey: id,
    createdAt: _now,
    updatedAt: _now,
  );
}

void main() {
  late FakeBookmarkStore store;
  late FakeConnectionStateBridge bridge;
  late List<Object> reported;

  setUp(() {
    store = FakeBookmarkStore();
    bridge = FakeConnectionStateBridge();
    reported = [];
  });

  tearDown(() async {
    await bridge.close();
  });

  ConnectionStatusController controller({
    BookmarkRepository? bookmarks,
    ConnectionStateBridge? engine,
    bool withBridge = true,
  }) {
    final created = ConnectionStatusController(
      bookmarks: bookmarks ?? store,
      bridge: withBridge ? (engine ?? bridge) : null,
      errors: ApplicationErrorReporter(sink: (error, _) => reported.add(error)),
    );
    addTearDown(created.dispose);
    return created;
  }

  group('the server list', () {
    test('lists endpoint-bearing bookmarks in store order', () async {
      store.bookmarks = [
        _server('a', label: 'alpha'),
        _localFolder('local'),
        _server('b', label: 'beta', host: 'beta.example.com', port: 22),
        _referenceStyle('ref'),
      ];
      final connections = controller();

      await connections.loadServers();

      // The store's own order, minus the rows that name no endpoint: a
      // local folder has no server, and a serverConfigId reference carries
      // no endpoint in Poltergeist (04 §2.2).
      expect(connections.load, ConnectionListLoad.ready);
      expect(connections.servers.map((server) => server.serverId), ['a', 'b']);
      expect(connections.servers.first.label, 'alpha');
      expect(connections.servers.first.host, 'web.example.com');
      expect(connections.servers.first.port, 2222);
      expect(connections.servers.first.username, 'deploy');
      expect(connections.servers.first.status, isNull);
      expect(bridge.watched, ['a', 'b']);
    });

    test('an empty store yields an empty ready list', () async {
      final connections = controller();

      await connections.loadServers();

      expect(connections.load, ConnectionListLoad.ready);
      expect(connections.servers, isEmpty);
      expect(bridge.watched, isEmpty);
    });

    test('a failed read reports and lands on failed', () async {
      store.bookmarks = [_server('a')];
      final connections = controller();
      await connections.loadServers();
      expect(connections.servers, hasLength(1));

      // A later reload fails: the rows stay for the retry, and the failure
      // is reported rather than rendered as an empty list.
      store.failure = const FileSystemException('unreadable');
      await connections.loadServers();

      expect(connections.load, ConnectionListLoad.failed);
      expect(connections.servers, hasLength(1));
      expect(reported, [isA<FileSystemException>()]);
    });

    test('a superseded load drops itself', () async {
      store.bookmarks = [_server('stale')];
      store.gate = Completer<void>();
      final connections = controller();

      final first = connections.loadServers();
      // The second load starts while the first is parked and reads the
      // newer store: the stale completion must not overwrite it.
      final gate = store.gate!;
      store.gate = null;
      store.bookmarks = [_server('fresh')];
      final second = connections.loadServers();
      await second;
      gate.complete();
      await first;

      expect(connections.servers.map((server) => server.serverId), ['fresh']);
      expect(bridge.watched.last, 'fresh');
      expect(bridge.hasListener('stale'), isFalse);
    });

    test('reloading re-watches the current rows only', () async {
      store.bookmarks = [_server('a')];
      final connections = controller();
      await connections.loadServers();
      expect(bridge.hasListener('a'), isTrue);

      store.bookmarks = [_server('b')];
      await connections.loadServers();

      expect(bridge.watched, ['a', 'b']);
      expect(bridge.hasListener('a'), isFalse);
      expect(bridge.hasListener('b'), isTrue);
      expect(connections.servers.map((server) => server.serverId), ['b']);
    });

    test('without a bridge no row claims live truth', () async {
      store.bookmarks = [_server('a')];
      final connections = controller(withBridge: false);

      await connections.loadServers();

      expect(connections.load, ConnectionListLoad.ready);
      expect(connections.servers.single.status, isNull);
      expect(bridge.watched, isEmpty);
    });
  });

  group('live connection truth', () {
    test('a status lands on its row with its detail', () async {
      store.bookmarks = [_server('a'), _server('b')];
      final connections = controller();
      await connections.loadServers();

      bridge.emitStatus(
        'a',
        const ServerStatus(ServerConnectionState.connecting),
      );
      expect(
        connections.servers[0].status?.state,
        ServerConnectionState.connecting,
      );
      expect(connections.servers[1].status, isNull);

      bridge.emitStatus(
        'a',
        const ServerStatus(
          ServerConnectionState.blocked,
          detail: 'Host key changed for web.example.com:2222.',
        ),
      );

      final row = connections.servers[0];
      expect(row.status?.state, ServerConnectionState.blocked);
      expect(row.status?.detail, 'Host key changed for web.example.com:2222.');
    });

    test('a pane-scoped recovery failure attributes its pane', () async {
      store.bookmarks = [_server('a')];
      final connections = controller();
      await connections.loadServers();
      bridge.emitStatus(
        'a',
        const ServerStatus(ServerConnectionState.connected),
      );

      bridge.emitRecovery('a', paneTabId: 'left');

      final row = connections.servers.single;
      expect(row.paneFailure?.paneTabId, 'left');
      expect(row.paneFailure?.message, 'Could not resolve the home directory.');
      // The pool itself stayed up: the pane failure does not fake a state.
      expect(row.status?.state, ServerConnectionState.connected);
    });

    test('a reload keeps unresolved pane attribution and live truth', () async {
      // The recovery lane is replay-free (03 §3.5): a reload that drops
      // rows to fresh values erases the only record of an unresolved pane
      // failure, and blanks live status until each watch replays.
      store.bookmarks = [_server('a')];
      final connections = controller();
      await connections.loadServers();
      bridge.emitStatus(
        'a',
        const ServerStatus(ServerConnectionState.connected),
      );
      bridge.emitRecovery('a', paneTabId: 'left');

      await connections.loadServers();

      final row = connections.servers.single;
      expect(row.status?.state, ServerConnectionState.connected);
      expect(row.paneFailure?.paneTabId, 'left');
    });

    test('a bookmark removed from the store loses its truth', () async {
      store.bookmarks = [_server('a'), _server('b')];
      final connections = controller();
      await connections.loadServers();
      bridge.emitStatus(
        'a',
        const ServerStatus(ServerConnectionState.connected),
      );

      store.bookmarks = [_server('b')];
      await connections.loadServers();

      expect(connections.servers, hasLength(1));
      expect(connections.servers.single.serverId, 'b');
      expect(connections.servers.single.status, isNull);
    });

    test('a reload with a stopped engine keeps truth cleared', () async {
      store.bookmarks = [_server('a')];
      final connections = controller();
      await connections.loadServers();
      bridge.emitStatus(
        'a',
        const ServerStatus(ServerConnectionState.connected),
      );
      await bridge.stopEngine();

      await connections.loadServers();

      expect(connections.servers.single.status, isNull);
      expect(connections.servers.single.paneFailure, isNull);
    });

    test('an identical status does not re-notify', () async {
      store.bookmarks = [_server('a')];
      final connections = controller();
      await connections.loadServers();

      var notifications = 0;
      connections.addListener(() => notifications++);

      bridge.emitStatus(
        'a',
        const ServerStatus(ServerConnectionState.connected),
      );
      final first = notifications;

      // The watch lane replays current state on every re-subscribe; a
      // byte-identical replay must not rebuild the list.
      bridge.emitStatus(
        'a',
        const ServerStatus(ServerConnectionState.connected),
      );

      expect(first, 1);
      expect(notifications, 1);
    });

    test(
      'a pool-level recovery failure rides the status detail alone',
      () async {
        store.bookmarks = [_server('a')];
        final connections = controller();
        await connections.loadServers();

        // The pool-level terminal failure reaches the status lane with the
        // same summary (03 §3.2's teardown fan-out), so the recovery lane
        // must not add a second, pane-less copy of it.
        bridge.emitRecovery('a');

        expect(connections.servers.single.paneFailure, isNull);
      },
    );

    test('an event for an unlisted server is ignored', () async {
      store.bookmarks = [_server('a')];
      final connections = controller();
      await connections.loadServers();

      // Through the shared recovery lane, which delivers to any id: the
      // controller must drop events for ids the store does not list (a
      // per-server status lane for an unwatched id cannot even exist).
      bridge.emitRecovery('adhoc', paneTabId: 'left');

      expect(connections.servers, hasLength(1));
      expect(connections.servers.single.status, isNull);
      expect(connections.servers.single.paneFailure, isNull);
    });

    test('engine loss clears live truth and keeps the rows', () async {
      store.bookmarks = [_server('a')];
      final connections = controller();
      await connections.loadServers();
      bridge.emitStatus(
        'a',
        const ServerStatus(ServerConnectionState.connected),
      );
      bridge.emitRecovery('a', paneTabId: 'left');
      expect(connections.servers.single.status, isNotNull);

      await bridge.stopEngine();

      // A stale "connected" would be a lie; the reference itself is the
      // store's and survives.
      final row = connections.servers.single;
      expect(row.serverId, 'a');
      expect(row.status, isNull);
      expect(row.paneFailure, isNull);
      expect(connections.load, ConnectionListLoad.ready);
    });

    test('a bridge that refuses watches reports and clears truth', () async {
      store.bookmarks = [_server('a')];
      bridge.watchFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.other,
        operation: 'watch',
        message: 'The engine is not running.',
      );
      final connections = controller();

      await connections.loadServers();

      // The list is still the store's truth; only the live lane is gone.
      expect(connections.load, ConnectionListLoad.ready);
      expect(connections.servers.single.status, isNull);
      expect(reported, [isA<RemoteFileException>()]);
    });

    test(
      'a faulting status lane is reported without blanking the list',
      () async {
        store.bookmarks = [_server('a')];
        final connections = controller();
        await connections.loadServers();
        bridge.emitStatus(
          'a',
          const ServerStatus(ServerConnectionState.connected),
        );

        bridge.failStatusLane('a', StateError('lane fault'));

        expect(reported, [isA<StateError>()]);
        expect(connections.load, ConnectionListLoad.ready);
        expect(
          connections.servers.single.status?.state,
          ServerConnectionState.connected,
        );
      },
    );

    test('dispose stops both lanes', () async {
      store.bookmarks = [_server('a')];
      final connections = controller();
      await connections.loadServers();
      expect(bridge.hasListener('a'), isTrue);

      connections.dispose();

      expect(bridge.hasListener('a'), isFalse);
      expect(bridge.recoveryHasListener, isFalse);
      // A late emission must not reach a disposed notifier.
      bridge.emitStatus(
        'a',
        const ServerStatus(ServerConnectionState.connected),
      );
      bridge.emitRecovery('a', paneTabId: 'left');
      expect(reported, isEmpty);
    });
  });

  test(
    'the production bridge consumes the real engine lanes',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
    // The seam against the real EngineClient, not a fake: watchServer must
    // deliver the engine's current state first (03 §3.2) through the
    // adapter, and shutdown must close the lane.
    final client = await EngineClient.spawn(const EngineConfig());
    addTearDown(() => client.terminated.timeout(const Duration(seconds: 30)));
    addTearDown(client.shutdown);

    store.bookmarks = [_server('a')];
    final connections = controller(engine: connectionStateBridgeOf(client));
    await connections.loadServers();
    expect(connections.servers.single.status, isNull);

    await _pollUntil(
      () => connections.servers.single.status != null,
      describe: 'the engine\'s current-state-first watch delivery',
    );

    final row = connections.servers.single;
    expect(row.status?.state, ServerConnectionState.disconnected);
    expect(row.status?.detail, isNull);

    // The lane-close half of the comment, asserted rather than promised:
    // a direct subscription observes done when the engine shuts down.
    final laneDone = Completer<void>();
    final lane = client.watchServer('a');
    final subscription = lane.listen(null, onDone: laneDone.complete);

    connections.dispose();
    await client.shutdown();
    try {
      await laneDone.future.timeout(const Duration(seconds: 30));
    } finally {
      await subscription.cancel();
    }
  });
}
