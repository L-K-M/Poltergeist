import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'pool_fakes.dart';

/// A bookmark edit as the engine host applies one: the resolver answers
/// the new config before the manager hears of it.
void _edit(PoolHarness harness, ServerConfig config) {
  harness.servers[config.id] = config;
  harness.manager.updateServerConfig(config.id, config);
}

ServerConfig _moved(PoolHarness harness, String serverId) =>
    harness.servers[serverId]!.copyWith(host: 'new.example');

List<String> _dialedHosts(PoolHarness harness) => [
  for (final call in harness.opener.calls) call.config.host,
];

List<ServerConnectionState> _watch(PoolHarness harness, String serverId) {
  final states = <ServerConnectionState>[];
  final subscription = harness.manager
      .watchServer(serverId)
      .listen((status) => states.add(status.state));
  addTearDown(subscription.cancel);
  return states;
}

final _disconnectedError = isA<RemoteFileException>().having(
  (error) => error.kind,
  'kind',
  RemoteFileErrorKind.disconnected,
);
final _disconnected = throwsA(_disconnectedError);

void main() {
  final endpointEdits = <String, ServerConfig Function(ServerConfig)>{
    'host': (config) => config.copyWith(host: 'new.example'),
    'port': (config) => config.copyWith(port: 2222),
    'username': (config) => config.copyWith(username: 'renamed'),
  };
  for (final MapEntry(key: field, value: edit) in endpointEdits.entries) {
    test('a new open after a $field edit dials the edited endpoint', () {
      fakeAsync((time) {
        final harness = PoolHarness()..addServer('s1', host: 'old.example');
        final pane = browsePane(time, harness, 'tab-1');
        completeWithoutTimers(time, pane.close());

        final edited = edit(harness.servers['s1']!);
        _edit(harness, edited);
        browsePane(time, harness, 'tab-2');

        expect(harness.opener.calls, hasLength(2));
        final dialed = harness.opener.calls.last.config;
        expect(
          (dialed.host, dialed.port, dialed.username),
          (edited.host, edited.port, edited.username),
        );
      });
    });
  }

  test('an endpoint edit drains live channels instead of cutting them', () {
    fakeAsync((time) {
      final harness = PoolHarness()..addServer('s1', host: 'old.example');
      final pane = browsePane(time, harness, 'old-tab');
      final lease = completeWithoutTimers(
        time,
        harness.manager.leaseTransferChannel('s1'),
      );
      final old = harness.opener.transports.single;

      _edit(harness, _moved(harness, 's1'));
      final fresh = browsePane(time, harness, 'new-tab');

      expect(_dialedHosts(harness), ['old.example', 'new.example']);
      final current = harness.opener.transports.last;
      expect(fresh.fs, same(current.channels.single.fs));
      // Work begun before the edit stays on the endpoint it authenticated to.
      expect(pane.fs, same(old.channels[0].fs));
      expect(lease.fs, same(old.channels[1].fs));
      expect(old.closed, isFalse);

      completeWithoutTimers(time, pane.close());
      expect(old.closed, isFalse, reason: 'the lease still holds it');
      completeWithoutTimers(time, lease.release());
      expect(old.closed, isTrue);
      expect(current.closed, isFalse);
      expect(
        completeWithoutTimers(time, harness.manager.connectedServerIds()),
        {'s1'},
      );
    });
  });

  test('a drained endpoint never reconnects for the edited id', () {
    fakeAsync((time) {
      final prober = FakeReconnectProber();
      final harness = PoolHarness(prober: prober)
        ..addServer('s1', host: 'old.example');
      final pane = browsePane(time, harness, 'old-tab');
      final states = _watch(harness, 's1');
      time.flushMicrotasks();

      _edit(harness, _moved(harness, 's1'));
      time.flushMicrotasks();
      // The id's status speaks for its new endpoint, which nothing dialed.
      expect(states, [
        ServerConnectionState.connected,
        ServerConnectionState.disconnected,
      ]);

      harness.opener.transports.single.simulateExternalDeath();
      time.elapse(const Duration(minutes: 5));

      expect(_dialedHosts(harness), ['old.example']);
      expect(prober.calls, 0);
      expect(() => pane.fs, _disconnected);
      expect(states, hasLength(2));
    });
  });

  test('an edit during a first connect never dials the old endpoint', () {
    fakeAsync((time) {
      final harness = PoolHarness()..addServer('s1', host: 'old.example');
      final gate = harness.credentialGate = Completer<void>();
      Object? staleFailure;
      harness.manager
          .openBrowseChannel('s1', paneTabId: 'old-tab')
          .then<void>((_) {}, onError: (Object error) => staleFailure = error);
      time.flushMicrotasks();

      _edit(harness, _moved(harness, 's1'));
      // The old attempt's resolution is dismissed, so its prompt closes.
      expect(harness.resolutionScopes, hasLength(1));
      var dismissed = false;
      harness.resolutionScopes.single.dismissed.then((_) => dismissed = true);
      time.flushMicrotasks();
      expect(dismissed, isTrue);

      final fresh = harness.manager.openBrowseChannel('s1', paneTabId: 'tab');
      gate.complete();
      completeWithoutTimers(time, fresh);

      expect(_dialedHosts(harness), ['new.example']);
      expect(staleFailure, _disconnectedError);
    });
  });

  test('an edit fails queued acquisitions so they retry on the new '
      'endpoint', () {
    fakeAsync((time) {
      final harness = PoolHarness(
        policy: const PoolPolicy(
          maxTransports: 1,
          maxTransferChannelsPerTransport: 1,
          maxChannelsPerTransport: 1,
        ),
      )..addServer('s1', host: 'old.example');
      browsePane(time, harness, 'old-tab');
      final queued = harness.manager.leaseTransferChannel('s1');
      Object? queuedFailure;
      queued.then<void>(
        (_) {},
        onError: (Object error) {
          queuedFailure = error;
        },
      );
      time.flushMicrotasks();
      expect(queuedFailure, isNull, reason: 'waiting for the only channel');

      _edit(harness, _moved(harness, 's1'));
      time.flushMicrotasks();
      expect(queuedFailure, _disconnectedError);

      completeWithoutTimers(time, harness.manager.leaseTransferChannel('s1'));
      expect(_dialedHosts(harness), ['old.example', 'new.example']);
    });
  });

  test('a same-endpoint edit keeps live transports and reaches the next '
      'connect', () {
    fakeAsync((time) {
      final harness = PoolHarness()..addServer('s1');
      final first = browsePane(time, harness, 'tab-1');
      final states = _watch(harness, 's1');
      time.flushMicrotasks();

      _edit(
        harness,
        harness.servers['s1']!.copyWith(
          label: 'Renamed',
          identityFilePath: '/keys/rotated',
        ),
      );
      final second = browsePane(time, harness, 'tab-2');

      // Same endpoint: the live transport serves on, nothing re-dials.
      expect(harness.opener.calls, hasLength(1));
      expect(harness.opener.transports.single.channels, hasLength(2));
      time.flushMicrotasks();
      expect(states, [ServerConnectionState.connected]);

      completeWithoutTimers(time, first.close());
      completeWithoutTimers(time, second.close());
      browsePane(time, harness, 'tab-3');

      final dialed = harness.opener.calls.last.config;
      expect(dialed.identityFilePath, '/keys/rotated');
      expect(dialed.label, 'Renamed');
    });
  });

  for (final reopened in [false, true]) {
    test('disconnect after an endpoint edit closes the draining channels '
        '(${reopened ? 'reopened' : 'not reopened'})', () {
      fakeAsync((time) {
        final harness = PoolHarness()..addServer('s1', host: 'old.example');
        browsePane(time, harness, 'old-tab');
        final lease = completeWithoutTimers(
          time,
          harness.manager.leaseTransferChannel('s1'),
        );
        _edit(harness, _moved(harness, 's1'));
        if (reopened) browsePane(time, harness, 'new-tab');

        completeWithoutTimers(time, harness.manager.disconnectServer('s1'));

        expect(harness.opener.transports, hasLength(reopened ? 2 : 1));
        expect(
          harness.opener.transports.every((transport) => transport.closed),
          isTrue,
        );
        expect(harness.openChannels, isEmpty);
        expect(() => lease.fs, _disconnected);
      });
    });
  }

  test('an edit back rejoins the shared pool and disconnect reaches every '
      'endpoint', () {
    fakeAsync((time) {
      final harness = PoolHarness()
        ..addServer('s1', host: 'old.example')
        ..addServer('s2', host: 'old.example');
      final original = harness.servers['s1']!;
      browsePane(time, harness, 'first');
      final kept = browsePane(time, harness, 'kept', server: 's2');

      _edit(harness, _moved(harness, 's1'));
      browsePane(time, harness, 'moved');
      _edit(harness, original);
      browsePane(time, harness, 'back');

      // s2 kept the old pool alive, so the edit back joins it again.
      expect(_dialedHosts(harness), ['old.example', 'new.example']);
      final [shared, moved] = harness.opener.transports;
      expect(shared.channels, hasLength(3));
      expect(moved.closed, isFalse, reason: 'its pane is still open');

      completeWithoutTimers(time, harness.manager.disconnectServer('s1'));
      expect(moved.closed, isTrue);
      expect(shared.closed, isFalse);
      expect(harness.openChannels.single.fs, same(kept.fs));
    });
  });

  test('a sibling keeps the shared pool when one bookmark moves', () {
    fakeAsync((time) {
      final harness = PoolHarness()
        ..addServer('s1', host: 'old.example')
        ..addServer('s2', host: 'old.example');
      final moved = browsePane(time, harness, 'moved');
      final kept = browsePane(time, harness, 'kept', server: 's2');
      final siblingStates = _watch(harness, 's2');
      time.flushMicrotasks();
      final shared = harness.opener.transports.single;

      _edit(harness, _moved(harness, 's1'));
      browsePane(time, harness, 'fresh');
      expect(_dialedHosts(harness), ['old.example', 'new.example']);

      completeWithoutTimers(time, moved.close());
      expect(shared.closed, isFalse);
      expect(kept.fs, same(shared.channels[1].fs));
      time.flushMicrotasks();
      expect(siblingStates, [ServerConnectionState.connected]);
      expect(
        completeWithoutTimers(time, harness.manager.connectedServerIds()),
        {'s1', 's2'},
      );
    });
  });
}
