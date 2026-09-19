// The D15 trash-channel relay (00 D15, 03 §7.1): the platform
// MethodChannel answers only on the app's UI isolate, so the engine's
// LocalTrashService reaches it through the EngineConfig.trashRequests
// port — TrashInvokeRequest out, TrashInvokeReply back, wrapped by
// trashChannelInvokerFor into the TrashChannelInvoker the channel
// backends consume. These tests run the whole chain over real
// ReceivePort/SendPort pairs (ports behave identically in-isolate) and
// pin the per-platform feature-detection the binding depends on.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io' show ProcessException;
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

/// A fake app-side server: answers each [TrashInvokeRequest] on its
/// reply port with the scripted reply.
final class _FakeChannelApp {
  _FakeChannelApp(this._reply) {
    _subscription = port.listen((message) {
      received.add(message);
      final request = message as TrashInvokeRequest;
      final reply = _reply;
      if (reply != null) request.replyTo.send(reply);
    });
  }

  final port = ReceivePort();
  final received = <Object?>[];
  TrashInvokeReply? _reply;
  late final StreamSubscription<Object?> _subscription;

  set reply(TrashInvokeReply? value) => _reply = value;

  Future<void> close() async {
    await _subscription.cancel();
    port.close();
  }
}

void main() {
  group('LocalTrashService channelInvoker feature-detection', () {
    test('macOS/Windows default backends pick up the invoker', () async {
      final calls = <(String, Map<String, Object?>)>[];
      Future<Object?> invoker(String method, Map<String, Object?> args) async {
        calls.add((method, args));
        return {'trashedPath': '/Trash/x.txt'};
      }

      for (final os in ['macos', 'windows']) {
        calls.clear();
        final service = LocalTrashService(
          operatingSystem: os,
          channelInvoker: invoker,
        );
        expect(await service.isAvailable(), isTrue);
        expect(await service.trash('/data/x.txt'), '/Trash/x.txt');
        expect(calls.map((c) => c.$1), [trashChannelMethod]);
      }
    });

    test('no invoker keeps the channel backends unavailable', () async {
      for (final os in ['macos', 'windows']) {
        final service = LocalTrashService(operatingSystem: os);
        expect(await service.isAvailable(), isFalse);
        await expectLater(
          service.trash('/data/x.txt'),
          throwsA(
            isA<TrashException>().having(
              (e) => e.kind,
              'kind',
              TrashErrorKind.unavailable,
            ),
          ),
        );
      }
    });

    test('an explicit backend overrides the invoker', () async {
      var invocations = 0;
      Future<Object?> invoker(String m, Map<String, Object?> a) async {
        invocations++;
        return null;
      }

      final backend = _RecordingBackend();
      final service = LocalTrashService(
        operatingSystem: 'macos',
        macOS: backend,
        channelInvoker: invoker,
      );
      await service.trash('/data/x.txt');
      expect(backend.trashed, ['/data/x.txt']);
      expect(invocations, 0);
    });

    test('the invoker is ignored where the channel does not exist', () async {
      // Linux dispatches to gio; an invoker must not re-route it.
      var probes = 0;
      final service = LocalTrashService(
        operatingSystem: 'linux',
        channelInvoker: (m, a) async => throw StateError('must not run'),
        processRunner: (executable, args) async {
          probes++;
          throw ProcessException('gio', args);
        },
      );
      expect(await service.isAvailable(), isFalse);
      expect(probes, 1);
    });
  });

  group('trashChannelInvokerFor relay', () {
    late _FakeChannelApp app;

    setUp(() => app = _FakeChannelApp(null));
    tearDown(() => app.close());

    test('a result reply resolves the invocation', () async {
      app.reply = const TrashInvokeReply.result({'trashedPath': '/T/f'});
      final invoker = trashChannelInvokerFor(app.port.sendPort);
      final result = await invoker(trashChannelMethod, {'path': '/data/f'});
      expect(result, {'trashedPath': '/T/f'});
      final request = app.received.single as TrashInvokeRequest;
      expect(request.method, trashChannelMethod);
      expect(request.arguments, {'path': '/data/f'});
    });

    test('a null result reply resolves to null', () async {
      app.reply = const TrashInvokeReply.result(null);
      final invoker = trashChannelInvokerFor(app.port.sendPort);
      expect(await invoker(trashChannelMethod, {'path': '/data/f'}), isNull);
    });

    test('a failure reply throws — the backend maps it to failed', () async {
      app.reply = const TrashInvokeReply.failure('platform said no');
      final invoker = trashChannelInvokerFor(app.port.sendPort);
      await expectLater(
        invoker(trashChannelMethod, {'path': '/data/f'}),
        throwsA(isA<StateError>()),
      );
      // End-to-end through the backend: typed TrashErrorKind.failed.
      final backend = ChannelTrashBackend(invoker: invoker);
      await expectLater(
        backend.trash('/data/f'),
        throwsA(
          isA<TrashException>()
              .having((e) => e.kind, 'kind', TrashErrorKind.failed)
              .having(
                (e) => e.message,
                'message',
                contains('platform said no'),
              ),
        ),
      );
    });

    test('a malformed reply throws instead of decoding garbage', () async {
      // Simulate a foreign sender answering with an unexpected shape.
      await app.close();
      final port = ReceivePort();
      addTearDown(port.close);
      port.listen((message) {
        (message as TrashInvokeRequest).replyTo.send('not a reply');
      });
      final invoker = trashChannelInvokerFor(port.sendPort);
      await expectLater(
        invoker(trashChannelMethod, {'path': '/data/f'}),
        throwsA(isA<StateError>()),
      );
    });

    test('a wedged server fails the call within the bound', () async {
      // The fake never replies — the invocation must not hang forever.
      final invoker = trashChannelInvokerFor(
        app.port.sendPort,
        timeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        invoker(trashChannelMethod, {'path': '/data/f'}),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('concurrent invocations answer on their own reply ports', () async {
      app.reply = const TrashInvokeReply.result(null);
      final invoker = trashChannelInvokerFor(app.port.sendPort);
      await Future.wait([
        invoker(trashChannelMethod, {'path': '/data/a'}),
        invoker(trashChannelMethod, {'path': '/data/b'}),
      ]);
      expect(app.received, hasLength(2));
    });

    test('the EngineHost composition — port to invoker to service', () async {
      // Exactly the chain EngineHost's factory builds: the port out of
      // EngineConfig, through trashChannelInvokerFor, into the channel
      // backend LocalTrashService dispatches on macOS/Windows.
      app.reply = const TrashInvokeReply.result({'trashedPath': '/T/f'});
      final service = LocalTrashService(
        operatingSystem: 'macos',
        channelInvoker: trashChannelInvokerFor(app.port.sendPort),
      );
      expect(await service.isAvailable(), isTrue);
      expect(await service.trash('/data/f'), '/T/f');
    });
  });

  group('EngineConfig.trashRequests', () {
    test('a SendPort crosses the spawn into the real engine isolate', () async {
      // The port itself must survive Isolate.spawn for the relay to work
      // at all; the engine's normal request path proves it booted.
      final requests = ReceivePort();
      addTearDown(requests.close);
      final client = await EngineClient.spawn(
        EngineConfig(trashRequests: requests.sendPort),
      );
      addTearDown(client.shutdown);
      expect(await client.connectedServerIds(), isEmpty);
    });
  });
}

final class _RecordingBackend implements LocalTrashBackend {
  final trashed = <String>[];

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<String?> trash(String path) async {
    trashed.add(path);
    return null;
  }
}
