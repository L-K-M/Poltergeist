import 'dart:async';
import 'dart:isolate';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'engine_host_test.dart' show HostHarness;

const _firstDelay = Duration(seconds: 1);

void main() {
  test(
    'background failure crosses the host port without a state watch',
    () async {
      final time = FakeAsync();
      final h = time.run((_) => HostHarness());
      final unsendable = ReceivePort();
      addTearDown(() {
        time.run((_) => h.dispose());
        time.flushMicrotasks();
        unsendable.close();
      });
      await _open(time, h);

      h.opener.connectFailure = RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'connect',
        path: '/home/test',
        message: 'Access denied.',
        cause: unsendable,
      );
      await _step(time, h.opener.transports.single.die);
      await _step(time, () => time.elapse(_firstDelay));

      final event = h.events.whereType<RecoveryFailedEvent>().single;
      expect(event.serverId, 'srv-1');
      expect(event.paneTabId, isNull);
      expect(event.error.kind, RemoteFileErrorKind.permissionDenied);
      expect(event.error.operation, 'connect');
      expect(event.error.path, '/home/test');
      expect(event.error.message, 'Access denied.');
      expect(event.error.toException().cause, isNull);
      expect(h.events.whereType<ServerStateEvent>(), isEmpty);
      expect(time.pendingTimers, isEmpty);
    },
  );

  test('arbitrary background errors cross as a generic diagnostic', () async {
    final time = FakeAsync();
    final h = time.run((_) => HostHarness());
    addTearDown(() {
      time.run((_) => h.dispose());
      time.flushMicrotasks();
    });
    await _open(time, h);
    h.opener.connectFailure = StateError('private resolver details');
    await _step(time, h.opener.transports.single.die);
    await _step(time, () => time.elapse(_firstDelay));

    final error = h.events.whereType<RecoveryFailedEvent>().single.error;
    expect(error.kind, RemoteFileErrorKind.other);
    expect(error.operation, 'reconnect');
    expect(error.path, isNull);
    expect(error.message, 'Connection recovery failed.');
    expect(time.pendingTimers, isEmpty);
  });
}

/// Port delivery uses the real event loop; only pool timers advance by hand.
Future<void> _step(FakeAsync time, void Function() action) async {
  time.run((_) => action());
  time.flushMicrotasks();
  await pumpEventQueue();
  time.flushMicrotasks();
}

Future<void> _open(FakeAsync time, HostHarness h) async {
  EngineResult? opened;
  await _step(time, () => h.openBrowse().then((result) => opened = result));
  await _step(
    time,
    () => h.reply(
      h.takePrompt(),
      const CredentialPromptReply(
        password: 'test',
        origin: CredentialOrigin.stored,
      ),
    ),
  );
  await _step(
    time,
    () => h.reply(h.takePrompt(), const HostKeyPromptReply(accepted: true)),
  );
  expect(opened, isA<BrowseChannelOpened>());
}
