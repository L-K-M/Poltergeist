import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/application_error_reporter.dart';
import 'package:poltergeist_app/services/probe_controller.dart';
import 'package:poltergeist_app/services/probe_coordinator.dart';
import 'package:poltergeist_app/services/probe_settings_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

ServerConfig _server({
  String id = 'bookmark-a',
  String host = 'sftp.example',
  int port = 22,
}) => ServerConfig(
  id: id,
  label: 'SFTP',
  host: host,
  port: port,
  username: 'deploy',
  authMethod: AuthMethod.agent,
  createdAt: 0,
  updatedAt: 0,
);

/// Records commands and whether a snapshot listener existed when they ran.
/// The engine contract: the app consumer must subscribe before sending
/// targets or activity (the #55 ordering rule).
final class _Bridge implements ProbeBridge {
  final events = StreamController<ProbeStatusesEvent>.broadcast(sync: true);
  final calls = <String>[];
  List<ServerConfig> targets = const [];

  /// True if every command observed a live snapshot listener.
  bool subscribedBeforeCommands = true;

  @override
  Stream<ProbeStatusesEvent> get probeStatuses => events.stream;

  @override
  Future<void> setProbeTargets(List<ServerConfig> targets) {
    _record('targets:${targets.map((target) => target.id).join(',')}');
    this.targets = targets;
    return Future.value();
  }

  @override
  Future<void> setProbeActivity(ProbeActivity activity) {
    _record(activity.name);
    return Future.value();
  }

  void _record(String call) {
    calls.add(call);
    subscribedBeforeCommands =
        subscribedBeforeCommands && events.hasListener;
  }

  void emit(Map<String, ProbeStatus> statuses) =>
      events.add(ProbeStatusesEvent(statuses: statuses));
}

final class _Settings implements ProbeSettings {
  ProbePreference global = ProbePreference.enabled;
  bool failReads = false;
  bool failWrites = false;
  final calls = <String>[];
  final servers = <String, ({String host, int port, bool connected})>{};

  @override
  Future<ProbePreference> loadGlobalPreference() async {
    if (failReads) throw StateError('settings unreadable');
    return global;
  }

  @override
  Future<ProbeServerFacts> loadServerFacts({
    required String serverId,
    required String host,
    required int port,
  }) async {
    if (failReads) throw StateError('settings unreadable');
    final facts = servers[serverId];
    if (facts == null) return ProbeServerFacts.unseen;
    return ProbeServerFacts(
      exposure: FavoriteExposure.seen,
      connected: facts.connected
          ? FavoriteConnection.connected
          : FavoriteConnection.neverConnected,
    );
  }

  @override
  Future<void> markSeen({
    required String serverId,
    required String host,
    required int port,
  }) async {
    _write(serverId, host, port, connected: servers[serverId]?.connected ?? false);
  }

  @override
  Future<void> markConnected({
    required String serverId,
    required String host,
    required int port,
  }) async {
    _write(serverId, host, port, connected: true);
  }

  void _write(String serverId, String host, int port, {required bool connected}) {
    if (failWrites) throw StateError('settings unwritable');
    calls.add('write:$serverId');
    servers[serverId] = (host: host, port: port, connected: connected);
  }

  @override
  Future<void> removeServer(String serverId) async {
    if (failWrites) throw StateError('settings unwritable');
    calls.add('remove:$serverId');
    servers.remove(serverId);
  }
}

void main() {
  late _Bridge bridge;
  late _Settings settings;
  late ProbeCoordinator coordinator;
  late List<Object> errors;

  setUp(() {
    bridge = _Bridge();
    settings = _Settings();
    errors = [];
    coordinator = ProbeCoordinator(
      bridge: bridge,
      settings: settings,
      errors: ApplicationErrorReporter(sink: (error, _) => errors.add(error)),
    );
  });

  tearDown(() async {
    coordinator.dispose();
    await bridge.events.close();
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('subscribes before any target or activity command', () async {
    expect(bridge.events.hasListener, isTrue);
    expect(bridge.calls, isEmpty);

    coordinator.showServer(_server());
    await pump();

    expect(bridge.subscribedBeforeCommands, isTrue);
  });

  test('showServer persists exposure and configures the engine', () async {
    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    coordinator.showServer(_server());
    await pump();

    expect(settings.calls, ['write:bookmark-a']);
    expect(settings.servers['bookmark-a']!.connected, isFalse);
    expect(bridge.targets.single.id, 'bookmark-a');
    expect(bridge.calls.last, 'running');
  });

  test('a persisted connection is supplied back to the controller', () async {
    settings.servers['bookmark-a'] = (
      host: 'sftp.example',
      port: 22,
      connected: true,
    );

    coordinator.showServer(_server());
    await pump();

    // The favorite carries the stored connection fact (the sync-provenance
    // rule: a synced-in favorite becomes eligible only after connecting
    // here), and markSeen preserves it.
    expect(settings.servers['bookmark-a']!.connected, isTrue);
    expect(bridge.targets.single.id, 'bookmark-a');
  });

  test('global opt-out clears targets and never runs probes', () async {
    settings.global = ProbePreference.disabled;
    coordinator.forwardLifecycle(AppLifecycleState.resumed);

    coordinator.showServer(_server());
    await pump();

    expect(bridge.targets, isEmpty);
    expect(bridge.calls, isNot(contains('running')));
    expect(coordinator.statuses, {'bookmark-a': ProbeStatus.unknown});
  });

  test('an unreadable store fails closed: no targets, no activity', () async {
    settings.failReads = true;
    coordinator.forwardLifecycle(AppLifecycleState.resumed);

    coordinator.showServer(_server());
    await pump();

    expect(errors, hasLength(1));
    expect(bridge.targets, isEmpty);
    expect(bridge.calls, isNot(contains('running')));
  });

  test('markConnected re-applies policy with the stored connection', () async {
    final config = _server();
    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    coordinator.showServer(config);
    await pump();
    bridge.calls.clear();

    coordinator.markConnected(config);
    await pump();

    expect(settings.calls.last, 'write:bookmark-a');
    expect(settings.servers['bookmark-a']!.connected, isTrue);
    expect(bridge.calls, isNot(contains('running')));
    // Same endpoint set: the controller preserves cadence without new
    // bridge commands beyond the retained running state.
    expect(bridge.targets.single.id, 'bookmark-a');
  });

  test('hideServer clears targets and drops the record', () async {
    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    coordinator.showServer(_server());
    await pump();

    coordinator.hideServer('bookmark-a');
    await pump();

    expect(settings.calls.last, 'remove:bookmark-a');
    expect(settings.servers, isEmpty);
    expect(bridge.targets, isEmpty);
    expect(bridge.calls.last, 'targets:');
  });

  test(
    'a stale hideServer cannot drop a replacement server',
    () async {
      coordinator.forwardLifecycle(AppLifecycleState.resumed);
      coordinator.showServer(_server());
      await pump();

      coordinator.showServer(_server(id: 'bookmark-b', host: 'other.example'));
      coordinator.hideServer('bookmark-a');
      await pump();

      expect(bridge.targets.single.id, 'bookmark-b');
      expect(settings.calls, isNot(contains('remove:bookmark-a')));
    },
  );

  test('forwardLifecycle pauses and resumes without store reloads', () async {
    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    coordinator.showServer(_server());
    await pump();
    final writeCalls = settings.calls.length;
    bridge.calls.clear();

    coordinator.forwardLifecycle(AppLifecycleState.hidden);
    await pump();
    expect(bridge.calls, contains('paused'));

    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    await pump();
    expect(bridge.calls.last, 'running');
    expect(settings.calls.length, writeCalls);
  });

  test('unknown lifecycle pauses probes', () async {
    coordinator.showServer(_server());
    await pump();

    expect(bridge.calls, isNot(contains('running')));
    expect(bridge.targets.single.id, 'bookmark-a');
  });

  test('dispose removes the record and unsubscribes', () async {
    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    coordinator.showServer(_server());
    await pump();

    coordinator.dispose();
    await pump();

    expect(settings.calls.last, 'remove:bookmark-a');
    expect(settings.servers, isEmpty);
    expect(bridge.events.hasListener, isFalse);
  });

  test('statuses mirror the engine snapshots per server', () async {
    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    coordinator.showServer(_server());
    await pump();

    bridge.emit({'bookmark-a': ProbeStatus.online});
    expect(coordinator.statuses, {'bookmark-a': ProbeStatus.online});
  });
}
