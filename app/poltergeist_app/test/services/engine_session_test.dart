import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/file_stores.dart';
import 'package:poltergeist_app/services/prompt_coordinator.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_bookmark_store.dart';

final _now = DateTime.utc(2026, 9, 11, 9);

const _pin = HostKey(
  host: 'web.example.com',
  port: 2222,
  type: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:pinned',
  pinnedAt: 1700000000000,
);

final _incident = IncidentRecord(
  serverId: 'b1',
  host: 'web.example.com',
  port: 2222,
  username: 'deploy',
  presentedFingerprintSha256: 'SHA256:presented',
  pinnedFingerprintSha256: 'SHA256:pinned',
);

Bookmark _blockedBookmark() {
  return Bookmark(
    id: 'b1',
    kind: BookmarkKind.remotePath,
    label: 'web',
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 2222,
        username: 'deploy',
        authMethod: AuthMethod.password,
        secretRef: 'secret-b1',
      ),
    ),
    remotePath: '/',
    sortKey: 'b1',
    createdAt: _now,
    updatedAt: _now,
  );
}

/// The engine surface, socket-free: scripted prompts/trust events over
/// broadcast lanes, recorded calls (the FakeSftpDemoEngine pattern, over
/// the production [AppEngine] facet).
class FakeAppEngine implements AppEngine {
  final promptsController = StreamController<EnginePromptEvent>.broadcast();
  final dismissalsController =
      StreamController<PromptDismissedEvent>.broadcast();
  final pinsController = StreamController<HostKeyPinnedEvent>.broadcast();
  final incidentsController = StreamController<IncidentStoreEvent>.broadcast();
  final statesControllers = <String, StreamController<ServerStatus>>{};
  final recoveryController =
      StreamController<RecoveryFailedEvent>.broadcast();
  final logController = StreamController<ConnectionLogEvent>.broadcast();
  final probeStatusesController =
      StreamController<ProbeStatusesEvent>.broadcast();
  final _pendingReplies = <String, Completer<PromptReply>>{};

  final replies = <(String, EnginePromptKind, PromptReply)>[];
  final openCalls =
      <({String serverId, String paneTabId, ServerConfig config})>[];

  /// Emitted (and awaited) in order inside [openBrowseChannel].
  List<EnginePromptEvent> promptScript = const [];

  Object? openFailure;
  FakeAppBrowseChannel? channel;
  final disconnectIds = <String>[];
  int shutdownCalls = 0;

  @override
  Stream<EnginePromptEvent> get prompts => promptsController.stream;

  @override
  Stream<PromptDismissedEvent> get promptDismissals =>
      dismissalsController.stream;

  @override
  void replyPrompt(String promptId, EnginePromptKind kind, PromptReply reply) {
    replies.add((promptId, kind, reply));
    final completer = _pendingReplies.remove(promptId);
    if (completer != null && !completer.isCompleted) completer.complete(reply);
  }

  @override
  Stream<HostKeyPinnedEvent> get hostKeyPins => pinsController.stream;

  @override
  Stream<IncidentStoreEvent> get incidentChanges =>
      incidentsController.stream;

  @override
  Stream<ServerStatus> watchServer(String serverId) => statesControllers
      .putIfAbsent(
        serverId,
        () => StreamController<ServerStatus>.broadcast(sync: true),
      )
      .stream;

  @override
  Stream<RecoveryFailedEvent> get recoveryFailures =>
      recoveryController.stream;

  @override
  Stream<ConnectionLogEvent> get connectionLog => logController.stream;

  @override
  Stream<ProbeStatusesEvent> get probeStatuses =>
      probeStatusesController.stream;

  @override
  Future<void> setProbeTargets(List<ServerConfig> targets) async {}

  @override
  Future<void> setProbeActivity(ProbeActivity activity) async {}

  @override
  Future<AppBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  }) async {
    openCalls.add((serverId: serverId, paneTabId: paneTabId, config: config));
    final repliesAtOpenStart = replies.length;
    _stateOf(serverId).add(
      const ServerStatus(ServerConnectionState.connecting),
    );
    for (final prompt in promptScript) {
      promptsController.add(prompt);
      await _waitForReply(prompt.promptId);
    }
    final failure = openFailure;
    if (failure != null) {
      // The engine's teardown fan-out: a declined changed key ends
      // blocked; every other failure ends disconnected with the detail.
      final declinedChangedKey = promptScript.any(
        (prompt) =>
            prompt.kind == EnginePromptKind.hostKeyChanged &&
            replies
                .skip(repliesAtOpenStart)
                .any(
                  (reply) =>
                      reply.$1 == prompt.promptId &&
                      reply.$3 is HostKeyPromptReply &&
                      !(reply.$3 as HostKeyPromptReply).accepted,
                ),
      );
      _stateOf(serverId).add(
        ServerStatus(
          declinedChangedKey
              ? ServerConnectionState.blocked
              : ServerConnectionState.disconnected,
          detail: failure is RemoteFileException ? failure.message : null,
        ),
      );
      throw failure;
    }
    final channel = this.channel;
    if (channel == null) throw StateError('no browse channel scripted');
    _stateOf(serverId).add(
      const ServerStatus(ServerConnectionState.connected),
    );
    return channel;
  }

  /// The per-server state lane, created on watch like the client's.
  StreamController<ServerStatus> _stateOf(String serverId) =>
      statesControllers.putIfAbsent(
        serverId,
        () => StreamController<ServerStatus>.broadcast(sync: true),
      );

  Future<PromptReply> _waitForReply(String promptId) {
    final completer = Completer<PromptReply>();
    _pendingReplies[promptId] = completer;
    return completer.future;
  }

  @override
  Future<void> disconnectServer(String serverId) async {
    disconnectIds.add(serverId);
  }

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
  }

  /// Closes every controller without awaiting: a controller whose
  /// subscription was cancelled completes its close future only in real
  /// async, which never arrives inside a widget test's fake-async zone.
  void close() {
    unawaited(promptsController.close());
    unawaited(dismissalsController.close());
    unawaited(pinsController.close());
    unawaited(incidentsController.close());
    for (final controller in statesControllers.values) {
      unawaited(controller.close());
    }
    unawaited(recoveryController.close());
    unawaited(logController.close());
    unawaited(probeStatusesController.close());
  }
}

class FakeAppBrowseChannel implements AppBrowseChannel {
  FakeAppBrowseChannel({this.homePath = '/home/deploy', this.entries = const []});

  @override
  final String homePath;

  final List<RemoteFileEntry> entries;

  int closeCalls = 0;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async => entries;

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

/// A pin store whose read violates the fail-safe contract with an
/// unexpected error type (not a corrupt file): the composition must
/// still boot engine-less rather than dying in main.
class _ThrowingPinStore implements HostKeyStore {
  @override
  Future<List<HostKey>> all() async => throw StateError('pin read failed');

  @override
  Future<HostKey?> get(String host, int port) async => null;

  @override
  Future<void> put(HostKey key) async {}
}

EnginePromptEvent _changedKeyPrompt(String promptId) {
  return EnginePromptEvent(
    promptId: promptId,
    kind: EnginePromptKind.hostKeyChanged,
    data: HostKeyPromptData(
      host: 'web.example.com',
      port: 2222,
      keyType: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:presented',
      pinnedFingerprintSha256: 'SHA256:pinned',
    ),
  );
}

/// Mirror writes are fire-and-forget into the stores' serialized chains
/// (like the engine's own writes), so assertions poll until the file
/// lands and only then read it back — a store instance caches its first
/// load, and one created before the atomic rename would read empty
/// forever. Real IO, not microtasks.
Future<List<T>> _eventually<T>(
  String path,
  Future<List<T>> Function() read,
) async {
  final file = File(path);
  // Real file IO (temp write + rename) on a possibly loaded runner: a
  // generous budget beats a flake, and the normal case lands on attempt 1.
  for (var attempt = 0; attempt < 500; attempt++) {
    if (await file.exists()) return await read();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('mirror write did not land in time');
}

void main() {
  late Directory support;
  late FakeBookmarkStore bookmarks;
  late List<Object> reported;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('engine-session-test');
    bookmarks = FakeBookmarkStore([_blockedBookmark()]);
    reported = [];
  });

  tearDown(() async {
    if (support.existsSync()) {
      await support.delete(recursive: true);
    }
  });

  /// Builds the production composition over a fake spawn seam, mirroring
  /// main.dart's wiring (the real factory differs only in the spawn and
  /// the store paths).
  Future<(EngineSession?, FakeAppEngine?)> startSession({
    FakeAppEngine? engine,
    List<EngineConfig>? spawnedConfigs,
    Object? spawnFailure,
    GlobalKey<NavigatorState>? navigatorKey,
  }) async {
    final scripted = engine ?? FakeAppEngine();
    addTearDown(scripted.close);
    final session = await startEngineSession(
      supportDirectoryPath: support.path,
      bookmarks: bookmarks,
      navigatorKey: navigatorKey ?? GlobalKey<NavigatorState>(),
      spawn: (config) async {
        if (spawnFailure != null) throw spawnFailure;
        spawnedConfigs?.add(config);
        return scripted;
      },
      onError: (error, stackTrace) => reported.add(error),
    );
    return (session, session == null ? null : scripted);
  }

  group('startup spawn and seeding', () {
    test('spawns the engine with pins and incidents seeded together', () async {
      // The persisted stores hold one pin and the incident that names it.
      await FileHostKeyStore(
        File('${support.path}${Platform.pathSeparator}host_keys.json'),
      ).put(_pin);
      await FileIncidentStore(
        File('${support.path}${Platform.pathSeparator}incidents.json'),
      ).put(_incident);

      final configs = <EngineConfig>[];
      final (session, _) = await startSession(spawnedConfigs: configs);
      addTearDown(session!.shutdown);

      expect(configs, hasLength(1));
      // Audit finding A: the incident and the pin it names cross together,
      // or the engine refuses to restore the record. The pinned HostKey
      // type carries no ==, so the seed is compared by its JSON form.
      expect(
        configs.single.hostKeyPins.map((pin) => pin.toJson()).toList(),
        [_pin.toJson()],
      );
      expect(configs.single.incidents, [_incident]);
    });

    test('subscribes the prompt and trust mirrors before returning', () async {
      final (session, engine) = await startSession();
      addTearDown(session!.shutdown);

      // 03 §5's ordering rule: listeners exist before any caller can send.
      expect(engine!.promptsController.hasListener, isTrue);
      expect(engine.pinsController.hasListener, isTrue);
      expect(engine.incidentsController.hasListener, isTrue);
    });

    test('reports a failed spawn and continues without an engine', () async {
      final (session, _) = await startSession(
        spawnFailure: StateError('isolate boot failed'),
      );

      expect(session, isNull);
      expect(reported, isNotEmpty);
    });

    test('an unexpected store fault boots engine-less, not dead', () async {
      // A store contract violation (an error type its fail-safe read does
      // not catch) must not escape into main and kill the boot.
      final session = await startEngineSession(
        supportDirectoryPath: support.path,
        bookmarks: bookmarks,
        navigatorKey: GlobalKey<NavigatorState>(),
        pinStore: _ThrowingPinStore(),
        spawn: (config) async => FakeAppEngine(),
        onError: (error, stackTrace) => reported.add(error),
      );

      expect(session, isNull);
      expect(reported, isNotEmpty);
    });
  });

  group('trust mirrors', () {
    test('persists engine pin writes to the app-owned pin store', () async {
      final (session, engine) = await startSession();
      addTearDown(session!.shutdown);

      engine!.pinsController.add(const HostKeyPinnedEvent(key: _pin));
      final store = FileHostKeyStore(
        File('${support.path}${Platform.pathSeparator}host_keys.json'),
      );
      final pins = await _eventually(
        '${support.path}${Platform.pathSeparator}host_keys.json',
        store.all,
      );

      expect(pins.map((pin) => pin.toJson()).toList(), [_pin.toJson()]);
    });

    test('persists stored incident records', () async {
      final (session, engine) = await startSession();
      addTearDown(session!.shutdown);

      engine!.incidentsController.add(
        IncidentRecordStoredEvent(record: _incident),
      );
      final store = FileIncidentStore(
        File('${support.path}${Platform.pathSeparator}incidents.json'),
      );
      final records = await _eventually(
        '${support.path}${Platform.pathSeparator}incidents.json',
        store.load,
      );

      expect(records, [_incident]);
    });

    test('applies scoped and bulk removals idempotently', () async {
      final store = FileIncidentStore(
        File('${support.path}${Platform.pathSeparator}incidents.json'),
      );
      await store.put(_incident);
      final (session, engine) = await startSession();
      addTearDown(session!.shutdown);

      // A removal for a record it just seeded (the engine drops a record
      // whose pin is gone) must apply without error and never re-seed.
      engine!.incidentsController.add(
        IncidentRecordRemovedEvent(serverId: 'b1', endpoint: _incident.poolKey),
      );
      // The removal deletes the file's only record; wait for the file to
      // vanish (a write of `[]` may land first — poll until empty).
      var removed = false;
      for (var attempt = 0; attempt < 500; attempt++) {
        final probe = FileIncidentStore(
          File('${support.path}${Platform.pathSeparator}incidents.json'),
        );
        if ((await probe.load()).isEmpty) {
          removed = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(removed, isTrue);

      // The no-op phase needs something observable. The engine mirror is
      // the file's single writer (the store's documented
      // one-instance-per-file contract), so the `other` record enters
      // through a stored event, and the bulk removal must delete exactly
      // it — while the repeated scoped removal re-deletes nothing and no
      // event ever re-seeds `b1`.
      final otherIncident = IncidentRecord(
        serverId: 'other',
        host: 'web.example.com',
        port: 2222,
        username: 'deploy',
        presentedFingerprintSha256: 'SHA256:presented',
        pinnedFingerprintSha256: 'SHA256:pinned',
      );
      engine.incidentsController.add(
        IncidentRecordStoredEvent(record: otherIncident),
      );
      engine.incidentsController.add(
        IncidentRecordRemovedEvent(serverId: 'b1', endpoint: _incident.poolKey),
      );
      engine.incidentsController.add(
        const IncidentRecordRemovedEvent(serverId: 'other', endpoint: null),
      );
      var storedSeen = false;
      var bulkApplied = false;
      for (var attempt = 0; attempt < 500; attempt++) {
        final probe = FileIncidentStore(
          File('${support.path}${Platform.pathSeparator}incidents.json'),
        );
        final records = await probe.load();
        // The stored event must land first — polling for empty alone would
        // succeed before any event processed (the file starts this phase
        // empty).
        if (records.any((record) => record.serverId == 'other')) {
          storedSeen = true;
        }
        if (storedSeen && records.isEmpty) {
          bulkApplied = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(storedSeen, isTrue);
      expect(bulkApplied, isTrue);
      // `b1` stayed deleted through the second scoped removal and was
      // never re-seeded by the mirror, and the review connect never ran.
      expect(
        await FileIncidentStore(
          File('${support.path}${Platform.pathSeparator}incidents.json'),
        ).load(),
        isEmpty,
      );
      expect(engine.openCalls, isEmpty);
    });
  });

  group('lifecycle', () {
    test('shuts the engine down when the app detaches', () async {
      final (session, engine) = await startSession();
      addTearDown(session!.shutdown);

      session.forwardLifecycle(AppLifecycleState.detached);
      await pumpEventQueue();

      expect(engine!.shutdownCalls, 1);
    });

    test('shutdown is idempotent and ignores later detach events', () async {
      final (session, engine) = await startSession();

      await session!.shutdown();
      await session.shutdown();
      session.forwardLifecycle(AppLifecycleState.detached);
      await pumpEventQueue();

      expect(engine!.shutdownCalls, 1);
    });
  });

  group('blocked-key review', () {
    test('opens a review connect through the bookmark identity', () async {
      final (session, engine) = await startSession();
      addTearDown(session!.shutdown);
      final channel = FakeAppBrowseChannel();
      engine!.channel = channel;

      await session.reviewBlockedHostKey('b1');

      expect(engine.openCalls, hasLength(1));
      final call = engine.openCalls.single;
      expect(call.serverId, 'b1');
      expect(call.config.host, 'web.example.com');
      expect(call.config.port, 2222);
      expect(call.config.username, 'deploy');
      expect(call.config.authMethod, AuthMethod.password);
      expect(call.config.secretRef, 'secret-b1');
      // The review connect ends with the reference dropped: a review is
      // not a session.
      expect(channel.closeCalls, 1);
      expect(engine.disconnectIds, ['b1']);
    });

    test('a declined review drops the reference without a fault', () async {
      final (session, engine) = await startSession();
      addTearDown(session!.shutdown);
      engine!.openFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'connect',
        message: 'The server is blocked until the new key is reviewed.',
      );

      await session.reviewBlockedHostKey('b1');

      expect(engine.disconnectIds, ['b1']);
      // A decline is the user's answer, not a fault: nothing was reported.
      expect(reported, isEmpty);
    });

    test('an unknown id opens nothing', () async {
      final (session, engine) = await startSession();
      addTearDown(session!.shutdown);

      await session.reviewBlockedHostKey('missing');

      expect(engine!.openCalls, isEmpty);
      expect(engine.disconnectIds, isEmpty);
    });

    test('routes the raised prompt through the session coordinator', () async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final engine = FakeAppEngine();
      final session = await startEngineSession(
        supportDirectoryPath: support.path,
        bookmarks: bookmarks,
        navigatorKey: navigatorKey,
        spawn: (config) async => engine,
        onError: (error, stackTrace) => reported.add(error),
      );
      addTearDown(session!.shutdown);
      engine.promptScript = [_changedKeyPrompt('p1')];
      engine.channel = FakeAppBrowseChannel();

      // The coordinator's reply answer arrives asynchronously; the review
      // await covers the whole connect.
      final review = session.reviewBlockedHostKey('b1');
      await pumpEventQueue();
      // No surface is mounted, so the coordinator declines rather than
      // blocking the engine (its no-context contract).
      await review;

      expect(
        engine.replies
            .where((reply) => reply.$1 == 'p1')
            .map((reply) => reply.$3),
        [isA<HostKeyPromptReply>().having((r) => r.accepted, 'accepted', false)],
      );
    });

    test('shares the coordinator, engine, and lanes with app surfaces', () async {
      final (session, engine) = await startSession();
      addTearDown(session!.shutdown);
      engine!.channel = FakeAppBrowseChannel();

      expect(session.prompts, isA<PromptCoordinator>());
      expect(session.connectionLanes.watchServer('b1'), isNotNull);

      // The demo facet must route to the same production engine — one
      // engine per process, never a second spawn behind the demo entry.
      await (await session.demoEngineFactory()).openBrowseChannel(
        serverId: 'demo',
        paneTabId: 'demo',
        config: ServerConfig(
          id: 'demo',
          label: 'demo',
          host: 'demo.example.com',
          port: 22,
          username: 'deploy',
          authMethod: AuthMethod.agent,
          createdAt: _now.millisecondsSinceEpoch,
          updatedAt: _now.millisecondsSinceEpoch,
        ),
      );
      expect(engine.openCalls, hasLength(1));
    });
  });
}
