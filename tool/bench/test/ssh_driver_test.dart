import 'dart:async';

import 'package:poltergeist_m0_bench/ssh_driver.dart';
import 'package:test/test.dart';

void main() {
  test('forces and awaits transport close after an SFTP timeout', () async {
    final transportRelease = Completer<void>();
    var transportStarted = false;

    final close = closeSshResources(
      sftpCloses: [() => Completer<void>().future],
      closeTransport: () {
        transportStarted = true;
        return transportRelease.future;
      },
      sftpCloseTimeout: Duration.zero,
    );
    var closeCompleted = false;
    final observedClose = close.whenComplete(() => closeCompleted = true);
    final expectation = expectLater(
      observedClose,
      throwsA(isA<TimeoutException>()),
    );

    await Future<void>.delayed(Duration.zero);
    expect(transportStarted, isTrue);
    expect(closeCompleted, isFalse);

    transportRelease.complete();
    await expectation;
  });

  test('attempts every close and preserves the first error', () async {
    final firstError = StateError('SFTP close failed');
    final calls = <String>[];

    await expectLater(
      closeSshResources(
        sftpCloses: [
          () {
            calls.add('first SFTP');
            throw firstError;
          },
          () => calls.add('second SFTP'),
        ],
        closeTransport: () {
          calls.add('transport');
          throw StateError('transport close failed');
        },
        sftpCloseTimeout: const Duration(seconds: 1),
      ),
      throwsA(same(firstError)),
    );

    expect(calls, ['first SFTP', 'second SFTP', 'transport']);
  });
}
