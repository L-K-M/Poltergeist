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
    subscribedBeforeCommands = subscribedBeforeCommands && events.hasListener;
  }

  void emit(Map<String, ProbeStatus> statuses) =>
      events.add(ProbeStatusesEvent(statuses: statuses));
}

final class _Settings implements ProbeSettings {
  ProbePreference global = ProbePreference.enabled;
  bool failReads = false;
  bool failWrites = false;
  final calls = <String>[];
  final reads = <String>[];
  final servers = <String, ({String host, int port, bool connected})>{};

  @override
  Future<ProbePreference> loadGlobalPreference() async {
    reads.add('global');
    if (failReads) throw StateError('settings unreadable');
    return global;
  }

  @override
  Future<ProbeServerFacts> loadServerFacts({
    required String serverId,
    required String host,
    required int port,
  }) async {
    reads.add('facts:$serverId');
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

  /// Replaces markSeen for sequencing tests (a gate or scripted write).
  Future<void> Function({
    required String serverId,
    required String host,
    required int port,
  })?
  markSeenHook;

  @override
  Future<void> markSeen({
    required String serverId,
    required String host,
    required int port,
  }) async {
    final hook = markSeenHook;
    if (hook != null) {
      return hook(serverId: serverId, host: host, port: port);
    }
    final existing = servers[serverId];
    final sameEndpoint =
        existing != null && existing.host == host && existing.port == port;
    _write(
      serverId,
      host,
      port,
      connected: sameEndpoint ? existing.connected : false,
    );
  }

  @override
  Future<void> markConnected({
    required String serverId,
    required String host,
    required int port,
  }) async {
    _write(serverId, host, port, connected: true);
  }

  void _write(
    String serverId,
    String host,
    int port, {
    required bool connected,
  }) {
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
    // here). The write and the read prove showServer actually persisted
    // exposure and consulted the stored facts — the seeded value alone
    // would pass vacuously.
    expect(settings.calls, contains('write:bookmark-a'));
    expect(settings.reads, contains('facts:bookmark-a'));
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

  test('a stale hideServer cannot drop a replacement server', () async {
    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    coordinator.showServer(_server());
    await pump();

    coordinator.showServer(_server(id: 'bookmark-b', host: 'other.example'));
    coordinator.hideServer('bookmark-a');
    await pump();

    expect(bridge.targets.single.id, 'bookmark-b');
    // The stale hide cannot drop the replacement's record; the replaced
    // A record is removed by showServer itself.
    expect(settings.servers.keys, ['bookmark-b']);
    expect(settings.calls, isNot(contains('remove:bookmark-b')));
  });

  test('forwardLifecycle pauses and resumes without store reloads', () async {
    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    coordinator.showServer(_server());
    await pump();
    final writeCalls = settings.calls.length;
    final readCalls = settings.reads.length;
    bridge.calls.clear();

    coordinator.forwardLifecycle(AppLifecycleState.hidden);
    await pump();
    expect(bridge.calls, contains('paused'));

    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    await pump();
    expect(bridge.calls.last, 'running');
    expect(settings.calls.length, writeCalls);
    expect(settings.reads.length, readCalls);
  });

  test(
    'before any lifecycle event, targets are set but probes stay paused',
    () async {
      coordinator.showServer(_server());
      await pump();

      expect(bridge.calls, isNot(contains('running')));
      expect(bridge.targets.single.id, 'bookmark-a');
    },
  );

  test('a non-resumed lifecycle state pauses probes', () async {
    coordinator.forwardLifecycle(AppLifecycleState.inactive);
    coordinator.showServer(_server());
    await pump();

    expect(bridge.calls, isNot(contains('running')));
    expect(bridge.targets.single.id, 'bookmark-a');
  });

  test('a superseded showServer never persists its record', () async {
    coordinator.showServer(_server());
    // The replacement lands before the first operation's queue slot runs.
    coordinator.showServer(_server(id: 'bookmark-b', host: 'other.example'));
    await pump();

    expect(settings.servers, isNot(contains('bookmark-a')));
    expect(settings.servers.keys, ['bookmark-b']);
    expect(bridge.targets.single.id, 'bookmark-b');
  });

  test('a replaced server\'s record is dropped', () async {
    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    coordinator.showServer(_server());
    await pump();

    coordinator.showServer(_server(id: 'bookmark-b', host: 'other.example'));
    await pump();

    expect(settings.servers, isNot(contains('bookmark-a')));
    expect(settings.servers.keys, ['bookmark-b']);
  });

  test(
    'hide then dispose in the same frame updates nothing after dispose',
    () async {
      coordinator.forwardLifecycle(AppLifecycleState.resumed);
      coordinator.showServer(_server());
      await pump();
      final callsBefore = bridge.calls.length;

      coordinator.hideServer('bookmark-a');
      coordinator.dispose();
      await pump();

      expect(settings.calls.last, 'remove:bookmark-a');
      // dispose() emits exactly its own stop (pause + empty targets); the
      // queued hide adds nothing further.
      expect(bridge.calls.sublist(callsBefore), ['paused', 'targets:']);
      expect(bridge.events.hasListener, isFalse);
    },
  );

  test('lifecycle changes serialize behind pending store operations', () async {
    final first = Completer<void>();
    final gate = Completer<void>();
    settings
        .markSeenHook = ({required serverId, required host, required port}) {
      settings.calls.add('write:$serverId');
      settings.servers[serverId] = (host: host, port: port, connected: false);
      if (serverId == 'bookmark-b') {
        first.complete();
        return gate.future;
      }
      return Future.value();
    };

    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    coordinator.showServer(_server(id: 'bookmark-a'));
    await pump();
    bridge.calls.clear();

    // B's markSeen is pending when the lifecycle change arrives; the
    // lifecycle update must not overtake B's configuration and re-send A.
    coordinator.showServer(_server(id: 'bookmark-b', host: 'other.example'));
    await first.future;
    coordinator.forwardLifecycle(AppLifecycleState.hidden);
    gate.complete();
    await pump();

    // A's targets were sent exactly once (its own configuration); the
    // queued lifecycle change describes B, never A, and B's configuration
    // already carries the pause (paused precedes B's targets).
    expect(bridge.calls.where((call) => call == 'targets:bookmark-a'), isEmpty);
    expect(bridge.targets.single.id, 'bookmark-b');
    expect(
      bridge.calls.indexOf('paused'),
      lessThan(bridge.calls.indexOf('targets:bookmark-b')),
    );
  });

  test('unwritable settings report failures and fail closed', () async {
    settings.failWrites = true;
    coordinator.forwardLifecycle(AppLifecycleState.resumed);

    coordinator.showServer(_server());
    await pump();

    expect(errors, isNotEmpty);
    expect(bridge.targets, isEmpty);
    expect(bridge.calls, isNot(contains('running')));
  });

  test('a failed removal still clears targets and reports', () async {
    coordinator.forwardLifecycle(AppLifecycleState.resumed);
    coordinator.showServer(_server());
    await pump();
    settings.failWrites = true;

    coordinator.hideServer('bookmark-a');
    await pump();

    expect(errors, isNotEmpty);
    expect(bridge.targets, isEmpty);
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
