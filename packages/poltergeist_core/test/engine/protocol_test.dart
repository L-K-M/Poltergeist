import 'dart:async';
import 'dart:isolate';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

const _sample = TransferProgressEvent(
  taskId: 'task',
  itemId: 'item',
  transferred: 7,
  total: 10,
  taskTransferredBytes: 1007,
  taskTotalBytes: 1010,
);
const _unknownTotals = TransferProgressEvent(
  taskId: 'other',
  itemId: 'item',
  transferred: 2,
  total: null,
  taskTransferredBytes: 12,
  taskTotalBytes: null,
);

void main() {
  test('batch snapshots its input and exposes an immutable item list', () {
    final source = [_sample];
    final batch = TransferProgressBatchEvent(source);
    source.add(_unknownTotals);

    expect(batch.items, [_sample]);
    expect(() => batch.items.add(_unknownTotals), throwsUnsupportedError);
    expect(() => batch.items[0] = _unknownTotals, throwsUnsupportedError);
  });

  test(
    'every progress payload round-trips through a spawned isolate',
    () async {
      final messages = ReceivePort();
      final incoming = StreamIterator<dynamic>(messages);
      final isolate = await Isolate.spawn(_echo, messages.sendPort);
      addTearDown(() async {
        isolate.kill(priority: Isolate.immediate);
        messages.close();
        await incoming.cancel();
      });

      expect(await incoming.moveNext(), isTrue);
      final engine = incoming.current as SendPort;
      for (final event in <EngineEvent>[
        _sample,
        _unknownTotals,
        TransferProgressBatchEvent([_sample, _unknownTotals]),
      ]) {
        engine.send(event);
        expect(await incoming.moveNext(), isTrue);
        final returned = incoming.current as EngineEvent;
        expect(returned.protocolVersion, 1);
        expect(returned.protocolVersion, engineProtocolVersion);
        switch ((event, returned)) {
          case (
            final TransferProgressEvent sent,
            final TransferProgressEvent received,
          ):
            _expectProgress(received, sent);
          case (
            final TransferProgressBatchEvent sent,
            final TransferProgressBatchEvent received,
          ):
            expect(received.items, hasLength(sent.items.length));
            for (var index = 0; index < sent.items.length; index++) {
              _expectProgress(received.items[index], sent.items[index]);
            }
            expect(() => received.items.clear(), throwsUnsupportedError);
          default:
            fail('Progress event type changed across the port.');
        }
      }
    },
  );
}

void _expectProgress(
  TransferProgressEvent actual,
  TransferProgressEvent expected,
) {
  expect(actual.taskId, expected.taskId);
  expect(actual.itemId, expected.itemId);
  expect(actual.transferred, expected.transferred);
  expect(actual.total, expected.total);
  expect(actual.taskTransferredBytes, expected.taskTransferredBytes);
  expect(actual.taskTotalBytes, expected.taskTotalBytes);
}

void _echo(SendPort parent) {
  final requests = ReceivePort();
  parent.send(requests.sendPort);
  requests.listen((event) => parent.send(event as EngineEvent));
}
