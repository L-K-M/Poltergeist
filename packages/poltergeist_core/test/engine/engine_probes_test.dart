import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_core/src/engine/engine_probes.dart';
import 'package:test/test.dart';

const _sshPort = 22;
const _beforeEarliestSweep = Duration(seconds: 41);
const _throughLatestSweep = Duration(seconds: 37);

ServerConfig _server(String id, {String? host, int port = _sshPort}) =>
    ServerConfig(
      id: id,
      label: id,
      host: host ?? '$id.example',
      port: port,
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );

class _ProbeCall {
  final String host;
  final int port;
  final Duration timeout;
  final result = Completer<ProbeStatus>();

  _ProbeCall(this.host, this.port, this.timeout);
}

class _ControlledProber implements Prober {
  final calls = <_ProbeCall>[];

  @override
  Future<ProbeStatus> probe(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    final call = _ProbeCall(host, port, timeout);
    calls.add(call);
    return call.result.future;
  }
}

class _Harness {
  final prober = _ControlledProber();
  final emitted = <Map<String, ProbeStatus>>[];
  final connected = <String>{};
  final connectedEndpoints = <String, (String, int)>{};
  late final EngineProbes owner = EngineProbes(
    emit: emitted.add,
    connectedServerIds: (targets) => {
      for (final target in targets)
        if (connected.contains(target.id) &&
            (connectedEndpoints[target.id] == null ||
                connectedEndpoints[target.id] == (target.host, target.port)))
          target.id,
    },
    prober: prober,
  );

  void close(FakeAsync time) {
    unawaited(owner.dispose());
    time.flushMicrotasks();
    expect(time.pendingTimers, isEmpty);
  }
}

void main() {
  test('starts paused; explicit running starts only configured targets', () {
    fakeAsync((time) {
      final h = _Harness();
      h.owner.updateTargets([_server('a')]);
      time.elapse(const Duration(minutes: 5));
      expect(h.prober.calls, isEmpty);
      expect(h.emitted.single, {'a': ProbeStatus.unknown});

      h.owner.setActivity(ProbeActivity.running);
      time.elapse(Duration.zero);
      expect(h.prober.calls.single.host, 'a.example');
      expect(h.prober.calls.single.timeout, const Duration(seconds: 3));
      h.close(time);
    });
  });

  test(
    'one endpoint probe fans out across bookmarks but ports stay distinct',
    () {
      fakeAsync((time) {
        final h = _Harness();
        h.owner.updateTargets([
          _server('a', host: 'shared.example'),
          _server('b', host: 'shared.example'),
          _server('c', host: 'shared.example', port: 2222),
        ]);
        h.owner.setActivity(ProbeActivity.running);
        time.elapse(Duration.zero);
        expect(h.prober.calls.map((call) => call.port), [_sshPort, 2222]);
        h.prober.calls[0].result.complete(ProbeStatus.online);
        h.prober.calls[1].result.complete(ProbeStatus.offline);
        time.flushMicrotasks();
        expect(h.emitted.last, {
          'a': ProbeStatus.online,
          'b': ProbeStatus.online,
          'c': ProbeStatus.offline,
        });
        expect(() => h.emitted.last.clear(), throwsUnsupportedError);
        h.close(time);
      });
    },
  );

  test('a live bookmark skips probes for every alias of its endpoint', () {
    fakeAsync((time) {
      final h = _Harness()..connected.add('b');
      h.owner.updateTargets([
        _server('a', host: 'shared.example'),
        _server('b', host: 'shared.example'),
      ]);
      h.owner.setActivity(ProbeActivity.running);
      time.elapse(Duration.zero);
      expect(h.prober.calls, isEmpty);
      expect(h.emitted.last, {
        'a': ProbeStatus.online,
        'b': ProbeStatus.online,
      });
      h.close(time);
    });
  });

  test('host casing shares one probe and case-only edits preserve cadence', () {
    fakeAsync((time) {
      final h = _Harness();
      h.owner.updateTargets([
        _server('a', host: 'Shared.EXAMPLE'),
        _server('b', host: 'shared.example'),
      ]);
      h.owner.setActivity(ProbeActivity.running);
      time.elapse(Duration.zero);
      expect(h.prober.calls.single.host, 'shared.example');
      h.prober.calls.single.result.complete(ProbeStatus.online);
      time.flushMicrotasks();
      expect(h.emitted.last, {
        'a': ProbeStatus.online,
        'b': ProbeStatus.online,
      });

      final count = h.emitted.length;
      h.owner.updateTargets([
        _server('a', host: 'shared.example'),
        _server('b', host: 'SHARED.EXAMPLE'),
      ]);
      expect(h.emitted, hasLength(count));
      time.elapse(_beforeEarliestSweep);
      expect(h.prober.calls, hasLength(1));
      time.elapse(_throughLatestSweep);
      expect(h.prober.calls, hasLength(2));
      expect(h.prober.calls.last.host, 'shared.example');
      h.close(time);
    });
  });

  test('live pool truth outranks a probe completed after connecting', () {
    fakeAsync((time) {
      final h = _Harness();
      h.owner.updateTargets([_server('a')]);
      h.owner.setActivity(ProbeActivity.running);
      time.elapse(Duration.zero);
      h.connected.add('a');
      h.prober.calls.single.result.complete(ProbeStatus.offline);
      time.flushMicrotasks();
      expect(h.emitted.last, {'a': ProbeStatus.online});
      h.close(time);
    });
  });

  test(
    'a live id at the old endpoint does not suppress a retargeted probe',
    () {
      fakeAsync((time) {
        final h = _Harness()..connected.add('a');
        h.connectedEndpoints['a'] = ('old.example', _sshPort);
        h.owner.updateTargets([_server('a', host: 'old.example')]);
        h.owner.setActivity(ProbeActivity.running);
        time.elapse(Duration.zero);
        expect(h.prober.calls, isEmpty);
        expect(h.emitted.last, {'a': ProbeStatus.online});

        h.owner.updateTargets([_server('a', host: 'new.example')]);
        expect(h.emitted.last, {'a': ProbeStatus.unknown});
        time.elapse(_beforeEarliestSweep + _throughLatestSweep);
        expect(h.prober.calls.single.host, 'new.example');
        h.prober.calls.single.result.complete(ProbeStatus.offline);
        time.flushMicrotasks();
        expect(h.emitted.last, {'a': ProbeStatus.offline});
        h.close(time);
      });
    },
  );

  test('same targets and repeated running preserve the jittered cadence', () {
    fakeAsync((time) {
      final h = _Harness();
      h.owner.updateTargets([_server('a')]);
      h.owner.setActivity(ProbeActivity.running);
      time.elapse(Duration.zero);
      h.prober.calls.single.result.complete(ProbeStatus.online);
      time.flushMicrotasks();

      h.owner.updateTargets([_server('a').copyWith(label: 'Renamed')]);
      h.owner.setActivity(ProbeActivity.running);
      time.elapse(_beforeEarliestSweep);
      expect(h.prober.calls, hasLength(1));
      time.elapse(_throughLatestSweep);
      expect(h.prober.calls, hasLength(2));
      h.close(time);
    });
  });

  test('same endpoints preserve pending results across alias replacement', () {
    fakeAsync((time) {
      final h = _Harness();
      h.owner.updateTargets([_server('a', host: 'shared.example')]);
      h.owner.setActivity(ProbeActivity.running);
      time.elapse(Duration.zero);
      h.owner.updateTargets([_server('b', host: 'shared.example')]);
      h.prober.calls.single.result.complete(ProbeStatus.online);
      time.flushMicrotasks();
      expect(h.prober.calls, hasLength(1));
      expect(h.emitted.last, {'b': ProbeStatus.online});
      h.close(time);
    });
  });

  test('retarget and removal reset the snapshot and discard old results', () {
    fakeAsync((time) {
      final h = _Harness();
      h.owner.updateTargets([_server('a'), _server('b')]);
      h.owner.setActivity(ProbeActivity.running);
      time.elapse(Duration.zero);
      h.owner.updateTargets([_server('a', host: 'replacement.example')]);
      expect(h.emitted.last, {'a': ProbeStatus.unknown});
      final count = h.emitted.length;
      for (final call in h.prober.calls) {
        call.result.complete(ProbeStatus.online);
      }
      time.flushMicrotasks();
      expect(h.emitted, hasLength(count));

      time.elapse(_beforeEarliestSweep + _throughLatestSweep);
      expect(h.prober.calls.last.host, 'replacement.example');
      h.prober.calls.last.result.complete(ProbeStatus.offline);
      time.flushMicrotasks();
      expect(h.emitted.last, {'a': ProbeStatus.offline});
      h.owner.updateTargets([]);
      expect(h.emitted.last, isEmpty);
      expect(time.pendingTimers, isEmpty);
      h.close(time);
    });
  });

  test(
    'pause/resume waits for six old probes and never starts stale queued work',
    () {
      fakeAsync((time) {
        final h = _Harness();
        h.owner.updateTargets([for (var i = 0; i < 9; i++) _server('$i')]);
        h.owner.setActivity(ProbeActivity.running);
        time.elapse(Duration.zero);
        expect(h.prober.calls, hasLength(6));
        h.owner.setActivity(ProbeActivity.paused);
        h.owner.setActivity(ProbeActivity.running);
        time.elapse(Duration.zero);
        expect(h.prober.calls, hasLength(6));

        for (final call in h.prober.calls.take(6)) {
          call.result.complete(ProbeStatus.online);
        }
        time.flushMicrotasks();
        time.elapse(Duration.zero);
        expect(h.prober.calls, hasLength(12));
        expect(h.emitted, hasLength(1));
        expect(h.prober.calls.skip(6).map((call) => call.host), [
          for (var i = 0; i < 6; i++) '$i.example',
        ]);
        h.close(time);
      });
    },
  );

  test('paused and disposed owners reject late results and controls', () {
    fakeAsync((time) {
      final h = _Harness();
      h.owner.updateTargets([_server('a')]);
      h.owner.setActivity(ProbeActivity.running);
      time.elapse(Duration.zero);
      h.owner.setActivity(ProbeActivity.paused);
      h.prober.calls.single.result.complete(ProbeStatus.online);
      time.flushMicrotasks();
      expect(h.emitted, hasLength(1));
      h.close(time);

      expect(() => h.owner.updateTargets([_server('b')]), throwsStateError);
      expect(
        () => h.owner.setActivity(ProbeActivity.running),
        throwsStateError,
      );
      time.elapse(const Duration(minutes: 5));
      expect(h.emitted, hasLength(1));
      expect(h.prober.calls, hasLength(1));
      h.close(time);
    });
  });

  test('dispose invalidates in-flight results and all queued probes', () {
    fakeAsync((time) {
      final h = _Harness();
      h.owner.updateTargets([for (var i = 0; i < 9; i++) _server('$i')]);
      h.owner.setActivity(ProbeActivity.running);
      time.elapse(Duration.zero);
      expect(h.prober.calls, hasLength(6));
      h.close(time);

      for (final call in h.prober.calls) {
        call.result.complete(ProbeStatus.online);
      }
      time.elapse(const Duration(minutes: 5));
      expect(h.prober.calls, hasLength(6));
      expect(h.emitted, hasLength(1));
      expect(time.pendingTimers, isEmpty);
    });
  });

  test(
    'unexpected probe failure stays unknown and does not discard siblings',
    () {
      fakeAsync((time) {
        final h = _Harness();
        h.owner.updateTargets([_server('a'), _server('b')]);
        h.owner.setActivity(ProbeActivity.running);
        time.elapse(Duration.zero);
        h.prober.calls[0].result.completeError(StateError('unexpected'));
        h.prober.calls[1].result.complete(ProbeStatus.online);
        time.flushMicrotasks();
        expect(h.emitted.last, {
          'a': ProbeStatus.unknown,
          'b': ProbeStatus.online,
        });
        h.close(time);
      });
    },
  );

  test('a caller cannot mutate the configured target snapshot', () {
    fakeAsync((time) {
      final h = _Harness();
      final targets = [_server('a')];
      h.owner.updateTargets(targets);
      targets
        ..clear()
        ..add(_server('b'));
      h.owner.setActivity(ProbeActivity.running);
      time.elapse(Duration.zero);
      expect(h.prober.calls.single.host, 'a.example');
      h.prober.calls.single.result.complete(ProbeStatus.online);
      time.flushMicrotasks();
      expect(h.emitted.last, {'a': ProbeStatus.online});
      h.close(time);
    });
  });

  test(
    'bad target replacement fails before changing the previous snapshot',
    () {
      fakeAsync((time) {
        final h = _Harness();
        h.owner.updateTargets([_server('valid')]);
        final invalid = <List<ServerConfig>>[
          [_server('')],
          [_server('duplicate'), _server('duplicate')],
          [_server('a', host: '')],
          [_server('a', host: ' host.example')],
          [_server('a', host: 'host\n.example')],
          [_server('a', port: 0)],
          [_server('a', port: 65536)],
        ];
        for (final targets in invalid) {
          expect(() => h.owner.updateTargets(targets), throwsArgumentError);
        }
        expect(h.emitted, hasLength(1));
        h.owner.setActivity(ProbeActivity.running);
        time.elapse(Duration.zero);
        expect(h.prober.calls.single.host, 'valid.example');
        h.close(time);
      });
    },
  );
}
