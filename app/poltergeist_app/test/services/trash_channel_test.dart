// The app side of the D15 trash channel (03 §7.1): TrashChannelServer
// binds only where a channel backend exists (macOS FileManager.trashItem,
// Windows IFileOperation) and serves TrashInvokeRequests off the port the
// EngineConfig carried into the engine — so these tests run the real
// request/reply wire against a mocked MethodChannel handler.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/trash_channel.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(trashChannelName);

  void mockChannel(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() => mockChannel(null));

  group('per-platform feature-detection', () {
    test('binds only on macOS and Windows', () async {
      for (final os in ['linux', 'android', 'ios', 'fuchsia']) {
        // Linux's gio spawn runs in-isolate; everything else has no
        // backend at all — no port means an honestly-unavailable backend.
        expect(TrashChannelServer.bind(operatingSystem: os), isNull);
      }
      for (final os in ['macos', 'windows']) {
        final server = TrashChannelServer.bind(operatingSystem: os);
        addTearDown(server!.close);
        expect(server, isNotNull);
      }
    });
  });

  group('request serving', () {
    test('a request invokes the channel and replies with the result', () async {
      final seen = <MethodCall>[];
      mockChannel((call) async {
        seen.add(call);
        return {'trashedPath': '/Trash/x.txt'};
      });
      final server = TrashChannelServer.bind(
        operatingSystem: 'macos',
        channel: channel,
      )!;
      addTearDown(server.close);

      final invoker = trashChannelInvokerFor(server.requests);
      expect(await invoker(trashChannelMethod, {'path': '/data/x.txt'}), {
        'trashedPath': '/Trash/x.txt',
      });
      expect(seen.single.method, trashChannelMethod);
      expect(seen.single.arguments, {'path': '/data/x.txt'});
    });

    test('a PlatformException travels back as a failure reply', () async {
      mockChannel(
        (call) async =>
            throw PlatformException(code: 'TRASH_FAILED', message: 'denied'),
      );
      final server = TrashChannelServer.bind(
        operatingSystem: 'windows',
        channel: channel,
      )!;
      addTearDown(server.close);

      final invoker = trashChannelInvokerFor(server.requests);
      await expectLater(
        invoker(trashChannelMethod, {'path': 'C:/x'}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('denied'),
          ),
        ),
      );
    });

    test('a malformed message is reported, never answered', () async {
      final reported = Completer<Object>();
      final server = TrashChannelServer.bind(
        operatingSystem: 'macos',
        channel: channel,
        onError: (error, stackTrace) => reported.complete(error),
      )!;
      addTearDown(server.close);

      server.requests.send('not a TrashInvokeRequest');
      expect(await reported.future, isA<StateError>());
    });
  });
}
