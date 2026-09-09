import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/application_error_reporter.dart';
import 'package:poltergeist_app/services/probe_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

const _defaultSshPort = 22;

void main() {
  late _Bridge bridge;
  late ProbeController controller;
  late List<Object> errors;

  setUp(() {
    bridge = _Bridge();
    errors = [];
    controller = ProbeController(
      bridge,
      errors: ApplicationErrorReporter(sink: (error, _) => errors.add(error)),
    );
  });

  tearDown(() async {
    controller.dispose();
    await bridge.events.close();
  });

  Future<void> update(
    List<ProbeFavorite> favorites, {
    ProbePreference preference = ProbePreference.enabled,
    AppLifecycleState? lifecycle = AppLifecycleState.resumed,
  }) => controller.update(
    favorites: favorites,
    preference: preference,
    lifecycle: lifecycle,
  );

  test(
    'subscribes before configuration and retains the pre-ack snapshot',
    () async {
      expect(bridge.events.hasListener, isTrue);
      expect(bridge.calls, isEmpty);
      bridge.replacement = {'local': ProbeStatus.online};

      await update([_favorite()]);

      expect(bridge.calls, ['targets:local', 'running']);
      expect(controller.statuses, {'local': ProbeStatus.online});
      expect(() => controller.statuses.clear(), throwsUnsupportedError);
    },
  );

  test(
    'eligibility requires local exposure, consent, and sync provenance',
    () async {
      final favorites = <ProbeFavorite>[];
      final expectedTargets = <String>[];
      for (final origin in FavoriteOrigin.values) {
        for (final exposure in FavoriteExposure.values) {
          for (final connection in FavoriteConnection.values) {
            for (final preference in ProbePreference.values) {
              final id =
                  '${origin.name}/${exposure.name}/'
                  '${connection.name}/${preference.name}';
              favorites.add(
                _favorite(
                  id: id,
                  origin: origin,
                  exposure: exposure,
                  connection: connection,
                  preference: preference,
                ),
              );
              // Three allowed combinations, enumerated independently of policy.
              if (id == 'device/seen/neverConnected/enabled' ||
                  id == 'device/seen/connected/enabled' ||
                  id == 'sync/seen/connected/enabled') {
                expectedTargets.add(id);
              }
            }
          }
        }
      }

      await update(favorites);

      expect(bridge.targets.map((server) => server.id), expectedTargets);
      expect(controller.statuses.length, favorites.length);
      expect(controller.statuses.values, everyElement(ProbeStatus.unknown));
    },
  );

  test(
    'a visible synced favorite becomes eligible after connecting here',
    () async {
      await update([_favorite(origin: FavoriteOrigin.sync)]);
      expect(bridge.targets, isEmpty);
      expect(bridge.calls, isNot(contains('running')));

      await update([
        _favorite(
          origin: FavoriteOrigin.sync,
          connection: FavoriteConnection.connected,
        ),
      ]);
      expect(bridge.targets.single.id, 'local');
      expect(bridge.calls.last, 'running');
    },
  );

  test(
    'global opt-out clears targets and truth before pending work settles',
    () async {
      await update([_favorite()]);
      bridge.emit({'local': ProbeStatus.online});
      final ack = bridge.holdTargets();

      final disabled = update([
        _favorite(),
      ], preference: ProbePreference.disabled);

      expect(bridge.calls.sublist(bridge.calls.length - 2), [
        'paused',
        'targets:',
      ]);
      expect(controller.statuses['local'], ProbeStatus.unknown);
      bridge.emit({'local': ProbeStatus.online});
      ack.complete();
      await disabled;
      expect(controller.statuses['local'], ProbeStatus.unknown);
      expect(bridge.targets, isEmpty);
    },
  );

  for (final lifecycle in <AppLifecycleState?>[
    null,
    ...AppLifecycleState.values,
  ]) {
    if (lifecycle == AppLifecycleState.resumed) continue;
    test('$lifecycle pauses without losing the last known status', () async {
      await update([_favorite()]);
      bridge.emit({'local': ProbeStatus.online});
      bridge.calls.clear();

      await update([_favorite()], lifecycle: lifecycle);
      bridge.emit({'local': ProbeStatus.offline});

      expect(bridge.calls.first, 'paused');
      expect(bridge.calls, isNot(contains('running')));
      expect(controller.statuses['local'], ProbeStatus.online);

      await update([_favorite()]);
      expect(bridge.calls.last, 'running');
      bridge.emit({'local': ProbeStatus.offline});
      expect(controller.statuses['local'], ProbeStatus.offline);
    });
  }

  test(
    'equivalent objects, metadata, order and host case preserve cadence',
    () async {
      await update([_favorite(), _favorite(id: 'second')]);
      bridge.emit({'local': ProbeStatus.online, 'second': ProbeStatus.offline});
      bridge.calls.clear();

      await update([
        _favorite(id: 'second'),
        _favorite(host: 'LOCAL.EXAMPLE', label: 'Renamed'),
      ]);

      expect(bridge.calls, isEmpty);
      expect(controller.statuses, {
        'local': ProbeStatus.online,
        'second': ProbeStatus.offline,
      });
    },
  );

  test(
    'removal and per-favorite opt-out cannot retain incoming truth',
    () async {
      await update([_favorite(), _favorite(id: 'removed')]);
      bridge.emit({'local': ProbeStatus.online, 'removed': ProbeStatus.online});

      await update([_favorite(preference: ProbePreference.disabled)]);
      bridge.emit({'local': ProbeStatus.online, 'removed': ProbeStatus.online});

      expect(controller.statuses, {'local': ProbeStatus.unknown});
      expect(bridge.targets, isEmpty);
    },
  );

  test(
    'host and port changes clear old truth while awaiting replacement',
    () async {
      for (final favorite in [
        _favorite(host: 'new.example'),
        _favorite(port: 2222),
      ]) {
        await update([_favorite()]);
        bridge.emit({'local': ProbeStatus.online});
        final ack = bridge.holdTargets();

        final changed = update([favorite]);
        expect(controller.statuses['local'], ProbeStatus.unknown);
        ack.complete();
        await changed;
        expect(controller.statuses['local'], ProbeStatus.unknown);
      }
    },
  );

  test(
    'hide overtakes a pending target ack and cannot be resumed by it',
    () async {
      final ack = bridge.holdTargets();
      final starting = update([_favorite()]);

      await update([_favorite()], lifecycle: AppLifecycleState.hidden);
      expect(bridge.calls, contains('paused'));
      ack.complete();
      await starting;

      expect(bridge.calls, isNot(contains('running')));
    },
  );

  test(
    'rapid A to B to A rejects late acks and publishes the latest snapshot',
    () async {
      final firstAck = bridge.holdTargets();
      final first = update([_favorite()]);
      final secondAck = bridge.holdTargets();
      final second = update([_favorite(host: 'other.example')]);
      bridge.replacement = {'local': ProbeStatus.offline};

      await update([_favorite()]);
      secondAck.complete();
      firstAck.complete();
      await Future.wait([first, second]);

      expect(bridge.calls.where((call) => call == 'running'), hasLength(1));
      expect(controller.statuses['local'], ProbeStatus.offline);
    },
  );

  test(
    'target failure pauses, clears truth, reports, and allows explicit retry',
    () async {
      final ack = bridge.holdTargets();
      final failure = StateError('target request failed');
      final starting = update([_favorite()]);
      ack.completeError(failure);
      await starting;

      expect(errors, [failure]);
      expect(controller.statuses['local'], ProbeStatus.unknown);
      expect(bridge.calls, isNot(contains('running')));
      expect(bridge.calls.sublist(bridge.calls.length - 2), [
        'paused',
        'targets:',
      ]);

      await update([_favorite()]);
      expect(bridge.calls.last, 'running');
    },
  );

  test('stale target failure cannot stop the current configuration', () async {
    final ack = bridge.holdTargets();
    final old = update([_favorite()]);
    await update([_favorite(host: 'new.example')]);
    bridge.calls.clear();
    ack.completeError(StateError('stale request'));
    await old;

    expect(errors, isEmpty);
    expect(bridge.calls, isEmpty);
  });

  test('engine death clears truth and prevents later configuration', () async {
    await update([_favorite()]);
    bridge.emit({'local': ProbeStatus.online});
    await bridge.events.close();
    bridge.calls.clear();

    await update([_favorite()]);

    expect(controller.statuses['local'], ProbeStatus.unknown);
    expect(bridge.calls, isEmpty);
  });

  test(
    'stream errors stop probing and report through the local sink',
    () async {
      await update([_favorite()]);
      bridge.emit({'local': ProbeStatus.online});
      final failure = StateError('engine stream');

      bridge.events.addError(failure);

      expect(errors, [failure]);
      expect(controller.statuses['local'], ProbeStatus.unknown);
      expect(bridge.calls.sublist(bridge.calls.length - 2), [
        'paused',
        'targets:',
      ]);
    },
  );

  test(
    'disposal cancels pending starts and unsubscribes exactly once',
    () async {
      final ack = bridge.holdTargets();
      final starting = update([_favorite()]);
      controller.dispose();
      final calls = List.of(bridge.calls);
      controller.dispose();
      ack.complete();
      await starting;
      await update([_favorite()]);

      expect(bridge.calls, calls);
      expect(bridge.calls, isNot(contains('running')));
      expect(bridge.events.hasListener, isFalse);
    },
  );

  test(
    'listener opt-out during publication cannot be undone by the outer update',
    () async {
      Future<void>? disabled;
      controller.addListener(() {
        disabled ??= update([
          _favorite(),
        ], preference: ProbePreference.disabled);
      });

      await update([_favorite()]);
      await disabled;

      expect(bridge.targets, isEmpty);
      expect(bridge.calls, isNot(contains('running')));
    },
  );

  test(
    'duplicate ids reject the snapshot before changing the engine',
    () async {
      await update([_favorite()]);
      bridge.calls.clear();

      expect(() => update([_favorite(), _favorite()]), throwsArgumentError);
      expect(bridge.calls, isEmpty);
      expect(bridge.targets.single.id, 'local');
    },
  );

  test('a failed running ack clears truth and stops the engine', () async {
    final ack = bridge.holdActivity();
    final starting = update([_favorite()]);
    // Wait until the running command owns the completer before failing it.
    await bridge.activitySent.future;
    final failure = StateError('running request failed');
    ack.completeError(failure);
    await starting;

    expect(errors, [failure]);
    expect(controller.statuses['local'], ProbeStatus.unknown);
    expect(bridge.calls.sublist(bridge.calls.length - 2), [
      'paused',
      'targets:',
    ]);
  });

  test('opt-out overtakes a pending running acknowledgement', () async {
    final ack = bridge.holdActivity();
    final starting = update([_favorite()]);
    await bridge.activitySent.future;

    await update([_favorite()], preference: ProbePreference.disabled);
    final calls = List.of(bridge.calls);
    ack.complete();
    await starting;

    expect(bridge.calls, calls);
    expect(bridge.targets, isEmpty);
    expect(controller.statuses['local'], ProbeStatus.unknown);
  });

  test(
    'real client ports preserve replacement and no-op target ordering',
    () async {
      final client = await EngineClient.spawnForTesting(
        const EngineConfig(),
        entrypoint: _probeEngine,
      );
      addTearDown(client.shutdown);
      final mirror = ProbeController(client);
      addTearDown(mirror.dispose);

      Future<void> configure(String host, AppLifecycleState lifecycle) =>
          mirror.update(
            favorites: [_favorite(host: host)],
            preference: ProbePreference.enabled,
            lifecycle: lifecycle,
          );

      await configure('local.example', AppLifecycleState.resumed);
      expect(mirror.statuses, {'local': ProbeStatus.online});

      await configure('replacement.example', AppLifecycleState.resumed);
      expect(mirror.statuses, {'local': ProbeStatus.offline});

      // Equivalent targets publish nothing, including across pause/resume.
      await configure('replacement.example', AppLifecycleState.hidden);
      await configure('replacement.example', AppLifecycleState.resumed);
      expect(mirror.statuses, {'local': ProbeStatus.offline});
    },
  );
}

ProbeFavorite _favorite({
  String id = 'local',
  String host = 'local.example',
  int port = _defaultSshPort,
  String label = 'Favorite',
  FavoriteOrigin origin = FavoriteOrigin.device,
  FavoriteExposure exposure = FavoriteExposure.seen,
  FavoriteConnection connection = FavoriteConnection.neverConnected,
  ProbePreference preference = ProbePreference.enabled,
}) => ProbeFavorite(
  server: ServerConfig(
    id: id,
    host: host,
    port: port,
    label: label,
    username: 'fixture-user',
    authMethod: AuthMethod.password,
    createdAt: 0,
    updatedAt: 0,
  ),
  origin: origin,
  exposure: exposure,
  connection: connection,
  preference: preference,
);

/// Commands apply in invocation order; acknowledgements can arrive later.
final class _Bridge implements ProbeBridge {
  final events = StreamController<ProbeStatusesEvent>.broadcast(sync: true);
  final calls = <String>[];
  final _acks = Queue<Completer<void>>();
  final _activityAcks = Queue<Completer<void>>();
  final activitySent = Completer<void>();
  List<ServerConfig> targets = const [];
  Map<String, ProbeStatus>? replacement;

  Completer<void> holdTargets() {
    final ack = Completer<void>();
    _acks.add(ack);
    return ack;
  }

  Completer<void> holdActivity() {
    final ack = Completer<void>();
    _activityAcks.add(ack);
    return ack;
  }

  @override
  Stream<ProbeStatusesEvent> get probeStatuses => events.stream;

  void emit(Map<String, ProbeStatus> statuses) =>
      events.add(ProbeStatusesEvent(statuses: statuses));

  @override
  Future<void> setProbeTargets(List<ServerConfig> targets) {
    calls.add('targets:${targets.map((target) => target.id).join(',')}');
    this.targets = targets;
    if (!events.isClosed) {
      final snapshot =
          replacement ??
          {for (final target in targets) target.id: ProbeStatus.unknown};
      // Like the real port, delivery precedes the ack without reentering
      // the synchronous stream while a listener sends another command.
      scheduleMicrotask(() {
        if (!events.isClosed) emit(snapshot);
      });
    }
    return _acks.isEmpty ? Future.value() : _acks.removeFirst().future;
  }

  @override
  Future<void> setProbeActivity(ProbeActivity activity) {
    calls.add(activity.name);
    if (!activitySent.isCompleted) activitySent.complete();
    return _activityAcks.isEmpty
        ? Future.value()
        : _activityAcks.removeFirst().future;
  }
}

/// Exercises the production client's port/broadcast scheduling without sockets.
void _probeEngine(SendPort events) {
  final requests = ReceivePort();
  events.send(requests.sendPort);
  Map<String, (String, int)> targets = const {};
  Map<String, ProbeStatus> previous = const {};
  requests.listen((message) {
    switch (message) {
      case EngineConfig():
        return;
      case final SetProbeTargetsRequest request:
        final next = {
          for (final server in request.targets)
            server.id: (server.host, server.port),
        };
        if (next.length != targets.length ||
            next.entries.any((entry) => targets[entry.key] != entry.value)) {
          // A queued old snapshot precedes the authoritative replacement.
          events.send(ProbeStatusesEvent(statuses: previous));
          targets = next;
          previous = {
            for (final server in request.targets)
              server.id: server.host == 'local.example'
                  ? ProbeStatus.online
                  : ProbeStatus.offline,
          };
          events.send(ProbeStatusesEvent(statuses: previous));
        }
        events.send(
          ResponseEvent(
            requestId: request.requestId,
            result: const EngineAck(),
          ),
        );
      case final SetProbeActivityRequest request:
        events.send(
          ResponseEvent(
            requestId: request.requestId,
            result: const EngineAck(),
          ),
        );
      case final ShutdownRequest request:
        events.send(
          ResponseEvent(
            requestId: request.requestId,
            result: const EngineAck(),
          ),
        );
        requests.close();
      default:
        throw StateError('Unexpected probe fixture request.');
    }
  });
}
