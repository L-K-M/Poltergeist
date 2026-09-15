import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart' show FakePaneLanes, FakePaneChannel;

class _ClosingChannel extends FakePaneChannel {
  _ClosingChannel() : super('/srv/home');
  Completer<void>? closeGate;

  @override
  Future<void> close() async {
    final gate = closeGate;
    closeGate = null;
    await super.close();
    await gate?.future;
  }
}

void main() {
  Bookmark bookmark() {
    final now = DateTime.utc(2026, 9, 13);
    return Bookmark(
      id: 'reconnect-proof',
      kind: BookmarkKind.remotePath,
      label: 'Reconnect proof',
      server: BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: 'proof.example.com',
          port: 22,
          username: 'tester',
          authMethod: AuthMethod.password,
        ),
      ),
      remotePath: '/',
      sortKey: 'proof',
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  late FakePaneLanes lanes;
  late FakePaneChannel channel;
  late PaneController pane;
  setUp(() async {
    lanes = FakePaneLanes();
    channel = FakePaneChannel('/srv/home');
    channel.listings[channel.homePath] = const [
      RemoteFileEntry(
        path: '/srv/home/cached.txt',
        name: 'cached.txt',
        type: RemoteFileType.file,
        size: 1,
      ),
    ];
    lanes.nextRemoteChannel = channel;
    pane = PaneController(paneTabId: 'proof', lanes: lanes);
    await pane.connectRemote(bookmark());
    await settle();
    expect(pane.entries.single.name, 'cached.txt');
    expect(pane.verbsEnabled, isTrue);
  });
  tearDown(() async {
    pane.dispose();
    await settle();
    for (final stream in lanes.statesControllers.values) {
      await stream.close();
    }
  });

  test(
    'transport loss disables commands without a failed navigation',
    () async {
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      expect(pane.connectionLost, isTrue);
      expect(pane.entries.single.name, 'cached.txt');
      expect(
        pane.verbsEnabled,
        isFalse,
        reason:
            '02 UX section 2.7 disables actions on cached disconnected data',
      );
    },
  );

  test(
    'status-only recovery relists the retained channel before enabling verbs',
    () async {
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      channel.listings[channel.homePath] = const [
        RemoteFileEntry(
          path: '/srv/home/fresh.txt',
          name: 'fresh.txt',
          type: RemoteFileType.file,
        ),
      ];
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();
      expect(channel.listCalls, ['/srv/home', '/srv/home']);
      expect(pane.entries.single.name, 'fresh.txt');
      expect(pane.connectionLost, isFalse);
      expect(pane.verbsEnabled, isTrue);
      expect(
        channel.closeCalls,
        0,
        reason: 'the engine heals healthy bindings in place',
      );
    },
  );

  test('a pre-loss listing cannot repaint or clear recovery', () async {
    final old = Completer<void>();
    channel.holdNext = old;
    pane.navigate('/old');
    lanes.emitState(
      bookmark().id,
      const ServerStatus(ServerConnectionState.reconnecting),
    );
    await settle();
    channel.listings['/old'] = const [
      RemoteFileEntry(
        path: '/old/stale.txt',
        name: 'stale.txt',
        type: RemoteFileType.file,
      ),
    ];
    old.complete();
    await settle();
    expect(pane.entries.single.name, 'cached.txt');
    expect(pane.connectionLost, isTrue);
    expect(pane.verbsEnabled, isFalse);
  });

  test(
    'failed healing retains cache and explicit retry reopens only this pane',
    () async {
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      channel.listingFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'home',
        message: 'Home unavailable',
      );
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();
      expect(pane.connectionLost, isTrue);
      expect(pane.error?.kind, RemoteFileErrorKind.permissionDenied);
      expect(pane.entries.single.name, 'cached.txt');
      final healed = FakePaneChannel('/srv/home')..listings['/srv/home'] = [];
      final held = Completer<void>();
      lanes.nextRemoteChannel = healed;
      lanes.holdRemoteOpen = held;
      final retrying = pane.retry();
      await settle();
      expect(pane.entries.single.name, 'cached.txt');
      expect(pane.connectionLost, isTrue);
      expect(channel.closeCalls, 1);
      held.complete();
      await retrying;
      await settle();
      expect(healed.listCalls, ['/srv/home']);
      expect(pane.entries, isEmpty);
      expect(pane.connectionLost, isFalse);
      expect(pane.verbsEnabled, isTrue);
      expect(lanes.disconnects, isEmpty);
    },
  );

  test(
    'failed reopen keeps cache and can retry without disconnecting siblings',
    () async {
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      channel.listingFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'home',
        message: 'Denied',
      );
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();
      lanes.remoteOpenFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'open',
        message: 'Offline',
      );
      await pane.retry();
      expect(pane.entries.single.name, 'cached.txt');
      expect(pane.canRetryRecovery, isTrue);
      expect(channel.closeCalls, 1);
      lanes.remoteOpenFailure = null;
      final healed = FakePaneChannel('/srv/home')..listings['/srv/home'] = [];
      lanes.nextRemoteChannel = healed;
      await pane.retry();
      await settle();
      expect(pane.connectionLost, isFalse);
      expect(healed.listCalls, ['/srv/home']);
      expect(lanes.disconnects, isEmpty);
    },
  );

  test(
    'cancel invalidates a held healing listing and releases its channel',
    () async {
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      final held = Completer<void>();
      channel.holdNext = held;
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();
      await pane.cancelRecovery();
      held.complete();
      await settle();
      expect(channel.closeCalls, 1);
      expect(lanes.disconnects, [bookmark().id]);
      expect(pane.phase, PanePhase.unbound);
      expect(pane.entries, isEmpty);
      expect(pane.connectionLost, isFalse);
    },
  );

  test(
    'late retry open cannot replace or close a newer same-id bind',
    () async {
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      channel.listingFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'home',
        message: 'Denied',
      );
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();
      final held = Completer<void>();
      lanes.holdRemoteOpen = held;
      final retrying = pane.retry();
      await settle();
      final replacement = FakePaneChannel('/replacement')
        ..listings['/replacement'] = [];
      lanes.nextRemoteChannel = replacement;
      await pane.connectRemote(bookmark(), initialPath: '/replacement');
      await settle();
      final old = FakePaneChannel('/old');
      lanes.nextRemoteChannel = old;
      held.complete();
      await retrying;
      await settle();
      expect(old.closeCalls, 1);
      expect(old.listCalls, isEmpty);
      expect(replacement.closeCalls, 0);
      expect(pane.location?.path, '/replacement');
      expect(pane.connectionLost, isFalse);
      expect(lanes.disconnects, isEmpty);
    },
  );

  test(
    'one failed healed binding cannot disable or detach its healthy sibling',
    () async {
      final siblingChannel = FakePaneChannel('/sibling')
        ..listings['/sibling'] = [];
      lanes.nextRemoteChannel = siblingChannel;
      final sibling = PaneController(paneTabId: 'sibling', lanes: lanes);
      addTearDown(sibling.dispose);
      await sibling.connectRemote(bookmark());
      await settle();
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      channel.listingFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'home',
        message: 'Denied',
      );
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();
      expect(pane.connectionLost, isTrue);
      expect(sibling.connectionLost, isFalse);
      expect(sibling.verbsEnabled, isTrue);
      await pane.detachRemote();
      sibling.refresh();
      await settle();
      expect(siblingChannel.listCalls, ['/sibling', '/sibling', '/sibling']);
      expect(siblingChannel.closeCalls, 0);
      expect(channel.closeCalls, 1);
      expect(lanes.disconnects, isEmpty);
    },
  );

  test(
    'a second loss invalidates the first healing answer and repeated status is inert',
    () async {
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      final held = Completer<void>();
      channel.holdNext = held;
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();
      expect(channel.listCalls, hasLength(2));
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();
      expect(pane.connectionLost, isFalse);
      channel.listingFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'list',
        message: 'Old failure',
      );
      held.complete();
      await settle();
      expect(pane.error, isNull);
      expect(pane.entries.single.name, 'cached.txt');
      expect(pane.verbsEnabled, isTrue);
    },
  );

  test(
    'reopening waits for old-channel release before requesting a replacement',
    () async {
      final closing = _ClosingChannel()..listings['/srv/home'] = [];
      lanes.nextRemoteChannel = closing;
      await pane.connectRemote(bookmark());
      await settle();
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      closing.listingFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'home',
        message: 'Denied',
      );
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();
      final gate = Completer<void>();
      closing.closeGate = gate;
      final healed = FakePaneChannel('/srv/home')..listings['/srv/home'] = [];
      lanes.nextRemoteChannel = healed;
      final retrying = pane.retry();
      await settle();
      expect(closing.closeCalls, 1);
      expect(
        lanes.calls.where((call) => call.startsWith('openBrowse:')),
        hasLength(2),
      );
      expect(healed.listCalls, isEmpty);
      gate.complete();
      await retrying;
      await settle();
      expect(healed.listCalls, ['/srv/home']);
      expect(closing.closeCalls, 1);
      expect(pane.connectionLost, isFalse);
    },
  );

  test(
    'cancel during healing cannot disconnect a newer same-id binding',
    () async {
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      final held = Completer<void>();
      channel.holdNext = held;
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();
      final cancelling = pane.cancelRecovery();
      final replacement = FakePaneChannel('/replacement')
        ..listings['/replacement'] = [];
      lanes.nextRemoteChannel = replacement;
      await Future.wait([cancelling, pane.connectRemote(bookmark())]);
      held.complete();
      await settle();
      expect(lanes.disconnects, isEmpty);
      expect(channel.closeCalls, 1);
      expect(replacement.closeCalls, 0);
      expect(pane.location?.path, '/replacement');
      expect(pane.verbsEnabled, isTrue);
    },
  );

  test(
    'loss after cancelling the first listing still heals to the channel home',
    () async {
      // A pane with NO prior binding keeps its live channel when Esc
      // cancels the first listing — the state this test exercises. A
      // bound pane's Esc now rolls back to the prior binding instead
      // (transactional replacement, 02 §2.8).
      final freshPane = PaneController(paneTabId: 'fresh', lanes: lanes);
      addTearDown(freshPane.dispose);
      final held = Completer<void>();
      final first = FakePaneChannel('/new/home')
        ..listings['/new/home'] = []
        ..holdNext = held;
      lanes.nextRemoteChannel = first;
      await freshPane.connectRemote(bookmark());
      freshPane.cancelNavigation();
      expect(freshPane.location, isNull);
      held.complete();
      await settle();
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();
      expect(first.listCalls, ['/new/home', '/new/home']);
      expect(freshPane.location?.path, '/new/home');
      expect(freshPane.connectionLost, isFalse);
      expect(freshPane.verbsEnabled, isTrue);
    },
  );

  test('status EOF cannot heal loss or accept its pending listing', () async {
    lanes.emitState(
      bookmark().id,
      const ServerStatus(ServerConnectionState.reconnecting),
    );
    await settle();
    final held = Completer<void>();
    channel.holdNext = held;
    lanes.emitState(
      bookmark().id,
      const ServerStatus(ServerConnectionState.connected),
    );
    await settle();
    await lanes.statesControllers[bookmark().id]!.close();
    held.complete();
    await settle();
    expect(pane.connectionStatus, isNull);
    expect(pane.connectionLost, isTrue);
    expect(pane.canRetryRecovery, isTrue);
    expect(pane.verbsEnabled, isFalse);
    expect(pane.entries.single.name, 'cached.txt');

    // An explicit replacement's accepted listing is usable proof after EOF.
    final healed = FakePaneChannel('/srv/home')..listings['/srv/home'] = [];
    lanes.statesControllers.remove(bookmark().id);
    lanes.nextRemoteChannel = healed;
    await pane.retry();
    await settle();
    expect(channel.closeCalls, 1);
    expect(pane.connectionLost, isFalse);
    expect(pane.verbsEnabled, isTrue);
    expect(pane.entries, isEmpty);
  });

  test(
    'connected status alone cannot dismiss the cached-loss banner',
    () async {
      lanes.emitState(
        bookmark().id,
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      expect(pane.connectionLost, isTrue);
      // Gate both possible recovery paths; neither can deliver a fresh listing.
      final heldOpen = Completer<void>();
      final heldListing = Completer<void>();
      lanes.holdRemoteOpen = heldOpen;
      channel.holdNext = heldListing;
      lanes.nextRemoteChannel = FakePaneChannel('/srv/home')
        ..listings['/srv/home'] = [];
      try {
        lanes.emitState(
          bookmark().id,
          const ServerStatus(ServerConnectionState.connected),
        );
        await settle();
        expect(
          pane.connectionLost,
          isTrue,
          reason:
              '02 UX section 2.7 clears only after a healed listing arrives',
        );
      } finally {
        heldOpen.complete();
        heldListing.complete();
        await settle();
      }
    },
  );
}
