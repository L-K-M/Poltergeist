// Unit tests for the bounded pipe the transfer queue relays every file
// hop through (03 §4.5's small-buffer contract): backpressure, abort
// unwinding, and the close/error attribution edges the engine depends
// on.

@Timeout(Duration(minutes: 1))
library;

import 'dart:async';

import 'package:poltergeist_core/src/transfer/bounded_transfer_sink.dart';
import 'package:test/test.dart';

BoundedTransferSink newSink({int maxBufferedBytes = 8}) =>
    BoundedTransferSink(
      StreamController<List<int>>(),
      maxBufferedBytes: maxBufferedBytes,
    );

void main() {
  group('BoundedTransferSink', () {
    test('stream is a single cached view of the controller', () {
      // A fresh .map wrapper per access would split the single-
      // subscription controller stream into competing listeners.
      final sink = newSink();
      expect(identical(sink.stream, sink.stream), isTrue);
    });

    test('close fails a pending addStream rather than completing it',
        () async {
      final sink = newSink(maxBufferedBytes: 4);
      // The upload side is always attached in real use — close() waits
      // for buffered events to be delivered, so a consumer must exist.
      final consumer = sink.stream.listen((_) {});
      final source = StreamController<List<int>>();
      // Overfill the buffer: the source subscription parks on the drain
      // waiter and the addStream future stays pending.
      source.add(List.filled(8, 0));
      final relay = sink.addStream(source.stream);
      final assertion = expectLater(relay, throwsStateError);
      // A couple of turns so the listener sees the chunk and parks.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      await sink.close();
      await assertion;
      await consumer.cancel();
      unawaited(source.close());
    });

    test('a source error fails the relay and reaches the consumer',
        () async {
      final sink = newSink();
      final source = StreamController<List<int>>();
      final failure = StateError('boom');
      final relay = sink.addStream(source.stream);
      final relayAssertion = expectLater(relay, throwsA(failure));
      final consumerAssertion = expectLater(
        sink.stream.first,
        throwsA(failure),
      );
      source.addError(failure);
      await relayAssertion;
      await consumerAssertion;
      unawaited(source.close());
    });
  });
}
