import 'dart:async';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

const _probePort = 2222;
const _probeTimeout = Duration(seconds: 5);
const _eventTimeout = Duration(seconds: 5);
const _probeLogServerId = 'test-prober';
const _hostStatuses = {
  'online.example': ProbeStatus.online,
  'offline.example': ProbeStatus.offline,
  'unknown.example': ProbeStatus.unknown,
};

ServerConfig _target({
  String id = 'online',
  String host = 'online.example',
  int port = _probePort,
}) => ServerConfig(
  id: id,
  label: id,
  host: host,
  port: port,
  username: 'user',
  authMethod: AuthMethod.password,
  createdAt: 0,
  updatedAt: 0,
);

Future<EngineClient> _spawn() async {
  final client = await EngineClient.spawnForTesting(
    const EngineConfig(),
    entrypoint: _probeEngine,
  );
  addTearDown(client.shutdown);
  return client;
}

void main() {
  test(
    'probe status snapshots broadcast tri-state results across isolates',
    () async {
      final client = await _spawn();
      final first = <ProbeStatusesEvent>[];
      final second = <ProbeStatusesEvent>[];
      final prompts = <EnginePromptEvent>[];
      final firstSubscription = client.probeStatuses.listen(first.add);
      final secondSubscription = client.probeStatuses.listen(second.add);
      final promptSubscription = client.prompts.listen(prompts.add);
      addTearDown(firstSubscription.cancel);
      addTearDown(secondSubscription.cancel);
      addTearDown(promptSubscription.cancel);

      await client.setProbeTargets([
        for (final status in ProbeStatus.values)
          _target(id: status.name, host: '${status.name}.example'),
      ]);
      final settled = client.probeStatuses.firstWhere(
        (event) => event.statuses['online'] == ProbeStatus.online,
      );
      await client.setProbeActivity(ProbeActivity.running);
      final event = await settled.timeout(_eventTimeout);

      expect(event.statuses, {
        for (final status in ProbeStatus.values) status.name: status,
      });
      expect(second.last, same(first.last));
      expect(first.last, same(event));
      expect(() => event.statuses.clear(), throwsUnsupportedError);
      expect(prompts, isEmpty);
      expect(await client.connectedServerIds(), isEmpty);
    },
  );

  test(
    'targets stay idle until enabled and an empty target list stays idle',
    () async {
      final client = await _spawn();
      final attempts = <ConnectionLogEvent>[];
      final subscription = client.connectionLog.listen(attempts.add);
      addTearDown(subscription.cancel);

      await client.setProbeTargets([_target()]);
      await client.connectedServerIds();
      expect(attempts, isEmpty);

      await client.setProbeTargets([]);
      await client.setProbeActivity(ProbeActivity.running);
      await client.connectedServerIds();
      expect(attempts, isEmpty);

      await client.setProbeActivity(ProbeActivity.paused);
      await client.setProbeTargets([_target()]);
      final settled = client.probeStatuses.firstWhere(
        (event) => event.statuses['online'] == ProbeStatus.online,
      );
      await client.setProbeActivity(ProbeActivity.running);
      await settled.timeout(_eventTimeout);
      expect(attempts.single.serverId, _probeLogServerId);
      expect(attempts.single.lines, ['online.example']);
    },
  );

  test(
    'pause, target replacement, resume, and clear cross the client boundary',
    () async {
      final client = await _spawn();
      final attempts = <ConnectionLogEvent>[];
      final snapshots = <ProbeStatusesEvent>[];
      final attemptSubscription = client.connectionLog.listen(attempts.add);
      final statusSubscription = client.probeStatuses.listen(snapshots.add);
      addTearDown(attemptSubscription.cancel);
      addTearDown(statusSubscription.cancel);

      await client.setProbeTargets([_target()]);
      final firstSweep = client.probeStatuses.firstWhere(
        (event) => event.statuses['online'] == ProbeStatus.online,
      );
      await client.setProbeActivity(ProbeActivity.running);
      await firstSweep.timeout(_eventTimeout);

      await client.setProbeActivity(ProbeActivity.paused);
      await client.setProbeTargets([
        _target(id: 'offline', host: 'offline.example'),
      ]);
      await client.connectedServerIds();
      expect(attempts, hasLength(1));
      expect(snapshots.last.statuses, {'offline': ProbeStatus.unknown});

      final secondSweep = client.probeStatuses.firstWhere(
        (event) => event.statuses['offline'] == ProbeStatus.offline,
      );
      await client.setProbeActivity(ProbeActivity.running);
      await secondSweep.timeout(_eventTimeout);
      expect(attempts, hasLength(2));
      expect(snapshots.last.statuses, {'offline': ProbeStatus.offline});

      await client.setProbeTargets([]);
      await client.connectedServerIds();
      expect(snapshots.last.statuses, isEmpty);
      expect(attempts, hasLength(2));
    },
  );

  test(
    'invalid probe targets fail typed without replacing the accepted set',
    () async {
      final client = await _spawn();
      await client.setProbeTargets([_target()]);

      for (final targets in [
        [_target(id: '')],
        [_target(host: '')],
        [_target(port: 0)],
        [_target(), _target(host: 'offline.example')],
      ]) {
        await expectLater(
          client.setProbeTargets(targets),
          throwsA(
            isA<RemoteFileException>().having(
              (error) => error.kind,
              'kind',
              RemoteFileErrorKind.other,
            ),
          ),
        );
      }

      final settled = client.probeStatuses.firstWhere(
        (event) => event.statuses['online'] == ProbeStatus.online,
      );
      await client.setProbeActivity(ProbeActivity.running);
      expect((await settled.timeout(_eventTimeout)).statuses, {
        'online': ProbeStatus.online,
      });
      expect(await client.connectedServerIds(), isEmpty);
    },
  );

  test(
    'shutdown closes probe statuses and rejects later probe controls',
    () async {
      final client = await _spawn();
      final snapshots = client.probeStatuses.toList();

      await client.shutdown();
      expect(await snapshots.timeout(_eventTimeout), isEmpty);

      final disconnected = throwsA(
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.disconnected,
        ),
      );
      await expectLater(client.setProbeTargets([_target()]), disconnected);
      await expectLater(
        client.setProbeActivity(ProbeActivity.running),
        disconnected,
      );
    },
  );

  test('unexpected engine termination closes probe statuses', () async {
    final client = await EngineClient.spawn(
      const EngineConfig(
        policy: PoolPolicy(reconnectBackoffCap: Duration.zero),
      ),
    );
    addTearDown(client.shutdown);
    final snapshots = client.probeStatuses.toList();

    await expectLater(
      client.setProbeActivity(ProbeActivity.running),
      throwsA(isA<RemoteFileException>()),
    );
    await client.terminated.timeout(_eventTimeout);
    expect(await snapshots.timeout(_eventTimeout), isEmpty);
  });
}

/// The production host owns all probe controls and status publication.
void _probeEngine(SendPort events) {
  final commands = ReceivePort();
  events.send(commands.sendPort);
  EngineHost? host;
  commands.listen((message) {
    if (host == null) {
      host = EngineHost(
        config: message as EngineConfig,
        events: events,
        prober: _StatusProber(events),
      );
      return;
    }

    // Let already-scheduled immediate sweeps settle before the query ack.
    // Negative probe assertions then need no wall-clock sleeps.
    if (message is ConnectedServerIdsRequest) {
      Timer.run(() => host!.handle(message));
      return;
    }
    host!.handle(message);
  });
}

final class _StatusProber implements Prober {
  final SendPort _events;

  _StatusProber(this._events);

  @override
  Future<ProbeStatus> probe(
    String host,
    int port, {
    Duration timeout = _probeTimeout,
  }) async {
    // Report each attempted socket operation on the same ordered event port.
    _events.send(
      ConnectionLogEvent(serverId: _probeLogServerId, lines: [host]),
    );
    return _hostStatuses[host] ?? ProbeStatus.unknown;
  }
}
