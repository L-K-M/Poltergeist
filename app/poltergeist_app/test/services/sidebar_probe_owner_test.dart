import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/application_error_reporter.dart';
import 'package:poltergeist_app/services/probe_controller.dart';
import 'package:poltergeist_app/services/probe_settings_store.dart';
import 'package:poltergeist_app/services/sidebar_probe_owner.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final _now = DateTime.utc(2026, 10, 1);

Bookmark _remoteFavorite(
  String id, {
  String host = 'sftp.example',
  int port = 22,
}) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: 'label-$id',
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: host,
      port: port,
      username: 'deploy',
      authMethod: AuthMethod.agent,
    ),
  ),
  remotePath: '/srv/$id',
  sortKey: 'k-$id',
  createdAt: _now,
  updatedAt: _now,
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
    // Mirrors the real store: case-insensitive host, exact port.
    if (facts == null ||
        facts.host.toLowerCase() != host.toLowerCase() ||
        facts.port != port) {
      return ProbeServerFacts.unseen;
    }
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
    final existing = servers[serverId];
    final sameEndpoint =
        existing != null &&
        existing.host.toLowerCase() == host.toLowerCase() &&
        existing.port == port;
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
  late SidebarProbeOwner owner;
  late List<Object> errors;

  setUp(() {
    bridge = _Bridge();
    settings = _Settings();
    errors = [];
    owner = SidebarProbeOwner(
      bridge: bridge,
      settings: settings,
      errors: ApplicationErrorReporter(sink: (error, _) => errors.add(error)),
    );
  });

  tearDown(() async {
    owner.dispose();
    await bridge.events.close();
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('subscribes before any target or activity command', () async {
    expect(bridge.events.hasListener, isTrue);
    expect(bridge.calls, isEmpty);

    owner.syncFavorites([_remoteFavorite('b1')]);
    await pump();

    expect(bridge.subscribedBeforeCommands, isTrue);
    expect(bridge.calls, isNotEmpty);
  });

  test('an unseen favorite stays unprobed until its row mounts', () async {
    owner.forwardLifecycle(AppLifecycleState.resumed);
    owner.syncFavorites([_remoteFavorite('b1')]);
    await pump();

    // No exposure fact yet: syncing alone must not start a probe.
    expect(bridge.targets, isEmpty);

    owner.noteVisible('b1');
    await pump();

    expect(settings.calls, ['write:b1']);
    expect(bridge.targets.single.id, 'b1');
    expect(bridge.calls.last, 'running');
  });

  test('favorites without an embedded identity never probe', () async {
    owner.forwardLifecycle(AppLifecycleState.resumed);
    owner.syncFavorites([
      _remoteFavorite('b1'),
      Bookmark(
        id: 'local-1',
        kind: BookmarkKind.localFolder,
        label: 'Docs',
        localPath: '/home/deploy/docs',
        sortKey: 'k2',
        createdAt: _now,
        updatedAt: _now,
      ),
      Bookmark(
        id: 'sync-1',
        kind: BookmarkKind.savedSync,
        label: 'Mirror',
        sortKey: 'k3',
        createdAt: _now,
        updatedAt: _now,
      ),
    ]);
    await pump();
    // The local folder and the saved-sync rows carry no endpoint to
    // mark seen — noteVisible no-ops on them by contract.
    owner.noteVisible('local-1');
    owner.noteVisible('sync-1');
    owner.noteVisible('b1');
    await pump();

    expect(settings.calls, ['write:b1']);
    expect(bridge.targets.map((target) => target.id), ['b1']);
  });

  test('a store reload dropping a favorite stops its probe', () async {
    owner.forwardLifecycle(AppLifecycleState.resumed);
    owner.syncFavorites([_remoteFavorite('b1'), _remoteFavorite('b2')]);
    owner.noteVisible('b1');
    owner.noteVisible('b2');
    await pump();
    expect(bridge.targets, hasLength(2));

    // The favorite left the list: out of probing, but its device-local
    // record survives (a collapsed group must not erase history).
    owner.syncFavorites([_remoteFavorite('b1')]);
    await pump();

    expect(bridge.targets.map((target) => target.id), ['b1']);
    expect(settings.calls, isNot(contains('remove:b2')));
  });

  test('noteRemoved purges the record and drops the target', () async {
    owner.forwardLifecycle(AppLifecycleState.resumed);
    owner.syncFavorites([_remoteFavorite('b1')]);
    owner.noteVisible('b1');
    await pump();
    expect(bridge.targets, hasLength(1));

    owner.noteRemoved('b1');
    await pump();

    expect(settings.calls, contains('remove:b1'));
    expect(settings.servers, isNot(contains('b1')));
    expect(bridge.targets, isEmpty);
  });

  test('noteConnected persists the fact once per endpoint', () async {
    owner.forwardLifecycle(AppLifecycleState.resumed);
    owner.syncFavorites([_remoteFavorite('b1')]);
    await pump();

    owner.noteConnected('b1', host: 'sftp.example', port: 22);
    owner.noteConnected('b1', host: 'sftp.example', port: 22);
    await pump();

    expect(settings.calls.where((call) => call == 'write:b1'), hasLength(1));
    expect(settings.servers['b1']!.connected, isTrue);
  });

  test('global opt-out clears targets and never runs probes', () async {
    settings.global = ProbePreference.disabled;
    owner.forwardLifecycle(AppLifecycleState.resumed);
    owner.syncFavorites([_remoteFavorite('b1')]);
    owner.noteVisible('b1');
    await pump();

    expect(bridge.targets, isEmpty);
    expect(bridge.calls, isNot(contains('running')));
    expect(owner.statuses['b1'], ProbeStatus.unknown);
  });

  test('an unreadable store fails closed: no targets, no activity',
      () async {
    settings.failReads = true;
    owner.forwardLifecycle(AppLifecycleState.resumed);
    owner.syncFavorites([_remoteFavorite('b1')]);
    owner.noteVisible('b1');
    await pump();

    expect(errors, isNotEmpty);
    expect(bridge.targets, isEmpty);
    expect(bridge.calls, isNot(contains('running')));
  });

  test('a paused lifecycle holds probes until resumed', () async {
    owner.forwardLifecycle(AppLifecycleState.paused);
    owner.syncFavorites([_remoteFavorite('b1')]);
    owner.noteVisible('b1');
    await pump();

    expect(bridge.calls, isNot(contains('running')));

    owner.forwardLifecycle(AppLifecycleState.resumed);
    await pump();

    expect(bridge.calls.last, 'running');
  });

  test('engine snapshots reach the owner statuses', () async {
    owner.forwardLifecycle(AppLifecycleState.resumed);
    owner.syncFavorites([_remoteFavorite('b1')]);
    owner.noteVisible('b1');
    await pump();

    bridge.events.add(
      ProbeStatusesEvent(statuses: {'b1': ProbeStatus.online}),
    );
    await pump();

    expect(owner.statuses['b1'], ProbeStatus.online);
  });
}
