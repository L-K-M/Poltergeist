import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/transfer_limits_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';

/// D37's owner of the per-server caps: what reaches the queue, when, and
/// what a failed write leaves behind.
void main() {
  late FakeAppTransferQueue queue;

  setUp(() => queue = FakeAppTransferQueue());
  tearDown(() => queue.close());

  test('the choices stop one short of the app-wide total', () {
    expect(transferConcurrencyChoices, [
      for (var files = 1; files < maxGlobalInFlightTransfers; files++) files,
    ]);
  });

  test('a queue bound late starts under the caps already chosen', () {
    final limits = TransferLimitsController(
      initial: const ServerTransferLimits(
        perServer: TransferConcurrency.fixed(2),
        overrides: {'fast': TransferConcurrency.automatic()},
      ),
    );
    addTearDown(limits.dispose);
    expect(queue.serverTransferLimits.filesFor('any'), isNull);

    limits.queue = queue;
    expect(queue.serverTransferLimits.filesFor('any'), 2);
    expect(queue.serverTransferLimits.filesFor('fast'), isNull);
  });

  test('the default applies at once and is written after', () async {
    final written = <TransferConcurrency>[];
    final landed = Completer<void>();
    final limits = TransferLimitsController(
      persistDefault: (value) {
        written.add(value);
        return landed.future;
      },
    )..queue = queue;
    addTearDown(limits.dispose);
    var notified = 0;
    limits.addListener(() => notified++);

    limits.setPerServer(const TransferConcurrency.fixed(3));
    // In force before the write lands, like the bandwidth limits.
    expect(queue.serverTransferLimits.filesFor('any'), 3);
    expect(limits.perServer, const TransferConcurrency.fixed(3));
    expect(written, [const TransferConcurrency.fixed(3)]);
    expect(notified, 1);

    // Choosing what is already in force writes nothing.
    limits.setPerServer(const TransferConcurrency.fixed(3));
    expect(written, hasLength(1));
    landed.complete();
  });

  test('a default that fails to write is reported and stays in force', () async {
    final errors = <Object>[];
    final limits = TransferLimitsController(
      persistDefault: (_) async => throw StateError('read-only'),
      onError: (error, _) => errors.add(error),
    )..queue = queue;
    addTearDown(limits.dispose);

    limits.setPerServer(const TransferConcurrency.fixed(1));
    await pumpEventQueue();
    expect(errors, [isA<StateError>()]);
    expect(queue.serverTransferLimits.filesFor('any'), 1);
  });

  test('an override applies the overrides the store answers with', () async {
    final landed = Completer<Map<String, TransferConcurrency>>();
    final limits = TransferLimitsController(
      initial: const ServerTransferLimits(
        perServer: TransferConcurrency.fixed(2),
      ),
      persistOverride: (_, _) => landed.future,
    )..queue = queue;
    addTearDown(limits.dispose);

    final saving = limits.setOverride(
      'fussy',
      const TransferConcurrency.fixed(1),
    );
    // Nothing changes until the store has it.
    await pumpEventQueue();
    expect(queue.serverTransferLimits.filesFor('fussy'), 2);

    // The store's answer wins: it carries an override another write
    // landed meanwhile.
    landed.complete({
      'fussy': const TransferConcurrency.fixed(1),
      'fast': const TransferConcurrency.automatic(),
    });
    await saving;
    expect(queue.serverTransferLimits.filesFor('fussy'), 1);
    expect(queue.serverTransferLimits.filesFor('fast'), isNull);
    expect(queue.serverTransferLimits.filesFor('other'), 2);
    expect(limits.overrideFor('fussy'), const TransferConcurrency.fixed(1));
  });

  test('an override that fails to write throws and changes nothing', () async {
    final limits = TransferLimitsController(
      persistOverride: (_, _) async => throw StateError('read-only'),
    )..queue = queue;
    addTearDown(limits.dispose);

    await expectLater(
      limits.setOverride('fussy', const TransferConcurrency.fixed(1)),
      throwsStateError,
    );
    expect(limits.overrideFor('fussy'), isNull);
    expect(queue.serverTransferLimits.filesFor('fussy'), isNull);
  });

  test('clearing an override puts the server back on the default', () async {
    final limits = TransferLimitsController(
      initial: const ServerTransferLimits(
        perServer: TransferConcurrency.fixed(2),
        overrides: {'fussy': TransferConcurrency.fixed(1)},
      ),
    )..queue = queue;
    addTearDown(limits.dispose);

    await limits.setOverride('fussy', null);
    expect(limits.overrideFor('fussy'), isNull);
    expect(queue.serverTransferLimits.filesFor('fussy'), 2);
  });
}
