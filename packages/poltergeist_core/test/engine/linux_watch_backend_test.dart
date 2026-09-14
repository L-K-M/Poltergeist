@TestOn('linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:poltergeist_core/src/engine/local_directory_watcher.dart';
import 'package:poltergeist_core/src/engine/protocol.dart'
    show DirectoryWatchSignal;
import 'package:test/test.dart';

/// The production Linux backend behind the watch seam: real kernel events,
/// real root-loss shapes, and real descriptor lifetime. The overflow
/// reproduction lives in `linux_inotify_overflow_test.dart`.
void main() {
  const deadline = Duration(seconds: 10);
  const cleanupDeadline = Duration(seconds: 30);

  Future<Directory> tempFixture(String name) async {
    final directory = await Directory.systemTemp.createTemp(name);
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    return directory;
  }

  test('create, modify, move, and delete surface as backend events',
      () async {
    final root = await tempFixture('pg-inotify-');
    final marker = Completer<void>();
    final events = <FileSystemEvent>[];

    final subscription = LocalWatchBackend.platform()
        .watch(root.path)
        .listen(events.add, onDone: marker.complete, onError: marker.completeError);
    addTearDown(subscription.cancel);

    final file = File(p.join(root.path, 'entry.txt'));
    file.writeAsStringSync('alpha');
    final moved = File(p.join(root.path, 'moved.txt'));
    file.renameSync(moved.path);
    moved.deleteSync();

    // Await the terminal delete rather than an event count: the write
    // path's modify multiplicity varies across filesystems.
    await _waitFor(
      () => events.whereType<FileSystemDeleteEvent>().any(
        (event) => p.equals(event.path, p.join(root.path, 'moved.txt')),
      ),
      deadline,
      'terminal delete; seen: $events',
    );

    expect(events[0], isA<FileSystemCreateEvent>());
    expect(events.any((event) => event is FileSystemModifyEvent), isTrue);
    // dart:io's Linux shape: the rename halves merge into one move event
    // naming the source with its destination.
    expect(
      events.whereType<FileSystemMoveEvent>().toList(),
      [
        isA<FileSystemMoveEvent>()
            .having(
              (event) => event.path,
              'path',
              p.join(root.path, 'entry.txt'),
            )
            .having(
              (event) => event.destination,
              'destination',
              p.join(root.path, 'moved.txt'),
            ),
      ],
    );
    expect(
      events.whereType<FileSystemDeleteEvent>().map((event) => event.path),
      contains(p.join(root.path, 'moved.txt')),
    );
    expect(marker.isCompleted, isFalse, reason: 'the watch stays live');
  });

  test('watched-directory removal reports the root then closes', () async {
    final root = await tempFixture('pg-inotify-vanish');
    final rootLoss = Completer<FileSystemEvent>();
    final done = Completer<void>();

    // The backend reports the exact string passed to watch();
    // canonicalization is the engine channel's job, tested there.
    final subscription = LocalWatchBackend.platform().watch(root.path).listen(
      (event) {
        if (!rootLoss.isCompleted && p.equals(event.path, root.path)) {
          rootLoss.complete(event);
        }
      },
      onDone: done.complete,
      onError: done.completeError,
    );
    addTearDown(subscription.cancel);

    root.deleteSync();

    final loss = await rootLoss.future.timeout(deadline);
    expect(loss, isA<FileSystemDeleteEvent>());
    await done.future.timeout(deadline);
  });

  test('renaming the watched directory reports the root then closes',
      () async {
    final parent = await tempFixture('pg-inotify-move');
    final root = Directory(p.join(parent.path, 'watched'))..createSync();
    final rootLoss = Completer<FileSystemEvent>();
    final done = Completer<void>();

    final subscription = LocalWatchBackend.platform().watch(root.path).listen(
      (event) {
        if (!rootLoss.isCompleted && p.equals(event.path, root.path)) {
          rootLoss.complete(event);
        }
      },
      onDone: done.complete,
      onError: done.completeError,
    );
    addTearDown(subscription.cancel);

    root.renameSync(p.join(parent.path, 'renamed'));

    final loss = await rootLoss.future.timeout(deadline);
    expect(loss, isA<FileSystemDeleteEvent>());
    await done.future.timeout(deadline);
  });

  test('cancellation releases every descriptor it created', () async {
    final root = await tempFixture('pg-inotify-fd');
    final baseline = await _descriptorFloor();

    for (var cycle = 0; cycle < 25; cycle++) {
      final delivered = Completer<void>();
      final subscription = LocalWatchBackend.platform()
          .watch(root.path)
          .listen((event) {
            if (!delivered.isCompleted) delivered.complete();
          });
      File(p.join(root.path, 'cycle-$cycle')).writeAsStringSync('x');
      await delivered.future.timeout(deadline);

      // A cancel must settle only after the full release; the count is
      // sampled right after, so this awaits real teardown.
      await subscription.cancel();
    }

    // Helper-isolate exit and port teardown finish on the event loop.
    await _pumpEventQueue();
    // Suites run as isolates of one process, so /proc/self/fd carries
    // ambient descriptors from concurrently running suites; sampling the
    // minimum over a short window settles that churn. A real per-cycle
    // leak would add fifty descriptors, far past the tolerance.
    expect(
      await _descriptorFloor(),
      lessThanOrEqualTo(baseline + _ambientDescriptorSlack),
      reason: '25 watch lifetimes leaked',
    );
  });

  test('a cancelled watch delivers no events afterwards', () async {
    final root = await tempFixture('pg-inotify-quiet');
    final events = <FileSystemEvent>[];
    final subscription = LocalWatchBackend.platform()
        .watch(root.path)
        .listen(events.add, cancelOnError: true);
    await subscription.cancel();

    File(p.join(root.path, 'after-cancel')).writeAsStringSync('x');
    await _pumpEventQueue();

    expect(events, isEmpty);
  });

  test('sibling watchers isolate their loss', () async {
    final parent = await tempFixture('pg-inotify-siblings');
    final left = Directory(p.join(parent.path, 'left'))..createSync();
    final right = Directory(p.join(parent.path, 'right'))..createSync();

    final backend = LocalWatchBackend.platform();
    final leftLoss = Completer<FileSystemEvent>();
    final rightEvents = <FileSystemEvent>[];

    final leftSubscription = backend.watch(left.path).listen((event) {
      if (!leftLoss.isCompleted && p.equals(event.path, left.path)) {
        leftLoss.complete(event);
      }
    });
    addTearDown(leftSubscription.cancel);
    final rightSubscription = backend.watch(right.path).listen(rightEvents.add);
    addTearDown(rightSubscription.cancel);

    left.deleteSync();
    await leftLoss.future.timeout(deadline);

    File(p.join(right.path, 'untouched')).writeAsStringSync('still watched');
    await _waitFor(
      () => rightEvents.isNotEmpty,
      deadline,
      'right-side events; seen: $rightEvents',
    );
  });

  test('cancellation completes while the kernel queue stays busy', () async {
    // markTestSkipped does not throw (test_api requires an explicit
    // return), so both unavailable-probe paths return before any
    // resource is created.
    try {
      final probe = await Process.run('python3', ['--version']);
      if (probe.exitCode != 0) {
        markTestSkipped('python3 is not available on this host');
        return;
      }
    } on ProcessException {
      markTestSkipped('python3 is not available on this host');
      return;
    }

    // Raw rename loops in owned processes reproduce the starvation shape:
    // production outpaces the helper's drain, so the kernel queue never
    // reports empty and a drain-until-EAGAIN loop never revisits the stop
    // pipe. In-process Dart producers lose that race and cannot pin it.
    final root = await (Directory('/dev/shm').existsSync()
            ? Directory('/dev/shm').createTemp('pg-busy-cancel-')
            : Directory.systemTemp.createTemp('pg-busy-cancel-'));
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final delivered = Completer<void>();
    final errors = <Object>[];
    final subscription = LocalWatchBackend.platform()
        .watch(root.path)
        .listen((event) {
          if (!delivered.isCompleted) delivered.complete();
        }, onError: errors.add);

    const producerCount = 4;
    final producers = <Process>[];
    final terminated = <int>{};
    final producerDiagnostics = <String>[];
    // Null until the body assigns its own cancellation; on an early
    // failure the finally cancels itself so the await below always
    // covers an actual release.
    Future<void>? cancellation;
    var cancellationFailed = false;
    try {
      for (var index = 0; index < producerCount; index++) {
        final producer = await Process.start('python3', [
          '-c',
          _renameProducerScript,
          root.path,
          '$index',
        ]);
        producers.add(producer);
        unawaited(
          producer.exitCode.then((_) => terminated.add(producer.pid)),
        );
        unawaited(producer.stdout.drain<void>());
        producer.stderr.transform(systemEncoding.decoder).listen(
          producerDiagnostics.add,
        );
      }
      // Any producer death invalidates the sustained-pressure premise, so
      // require all four, not merely one survivor.
      bool allRunning() => terminated.isEmpty;

      await delivered.future.timeout(deadline);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(allRunning(), isTrue, reason: 'producers must still be running');

      // The property: cancellation is bounded by the helper's own poll
      // cycle, never by filesystem quiescence.
      cancellation = subscription.cancel();
      await cancellation.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail(
          'cancellation starved while producers still run: '
          '${producerDiagnostics.join()} $errors',
        ),
      );
      expect(
        allRunning(),
        isTrue,
        reason: 'released while producers still run',
      );
      // Deliberate saturation legitimately overruns the kernel queue, so
      // an overflow error may surface here — that is #94's loss signal
      // working, not a cancellation failure. The boundedness property
      // above is what this test pins.
    } finally {
      // Always await the real cancellation: the body assigns it on its
      // own path; on an early failure (or a mid-loop spawn throw) cancel
      // here so the await below covers an actual release. A second
      // cancel returns the first future.
      Future<void>? pending;
      try {
        pending = cancellation ?? subscription.cancel();
      } catch (error, stackTrace) {
        cancellationFailed = true;
        printOnFailure(
          'cancellation threw before returning its cleanup future: '
          '$error\n$stackTrace',
        );
      }
      for (final producer in producers) {
        producer.kill(ProcessSignal.sigterm);
      }
      // Preserve a primary body failure while retaining enough detail to
      // distinguish a stalled release from an errored one.
      if (pending != null) {
        try {
          await pending.timeout(
            cleanupDeadline,
            onTimeout: () {
              cancellationFailed = true;
              printOnFailure(
                'cancellation outlived the '
                '${cleanupDeadline.inSeconds}s cleanup bound',
              );
            },
          );
        } catch (error, stackTrace) {
          cancellationFailed = true;
          printOnFailure(
            'cancellation errored during cleanup: $error\n$stackTrace',
          );
        }
      }
      for (final producer in producers) {
        producer.kill(ProcessSignal.sigkill);
      }
      await Future.wait(producers.map((producer) => producer.exitCode));
    }

    // After the try/finally: a cleanup failure fails a green body, while an
    // original body failure propagates untouched instead of being
    // displaced by this assertion.
    expect(
      cancellationFailed,
      isFalse,
      reason: 'cancellation cleanup failed',
    );
  });

  test('repeated retarget and stop cycles on one adapter release cleanly',
      () async {
    final parent = await tempFixture('pg-inotify-retarget');
    final first = Directory(p.join(parent.path, 'first'))..createSync();
    final second = Directory(p.join(parent.path, 'second'))..createSync();

    final baseline = await _descriptorFloor();
    final watcher = LocalDirectoryWatcher();
    addTearDown(watcher.dispose);
    final losses = <LocalWatchSignal>[];
    watcher.signals.listen(
      (signal) {
        if (signal.kind == DirectoryWatchSignal.lost) losses.add(signal);
      },
    );

    for (var cycle = 0; cycle < 20; cycle++) {
      final target = cycle.isEven ? first : second;
      await watcher.retarget(target.path);
      File(p.join(target.path, 'cycle-$cycle')).writeAsStringSync('x');
    }
    await watcher.stop();

    await _pumpEventQueue();
    // Same ambient-tolerance reasoning as the cancellation test: a leak
    // here would add forty descriptors across the twenty cycles.
    expect(
      await _descriptorFloor(),
      lessThanOrEqualTo(baseline + _ambientDescriptorSlack),
      reason: 'retarget cycles leaked',
    );
    expect(losses, isEmpty, reason: 'no cycle may report loss');
  });
}

/// Ambient descriptor churn from suites sharing this process. A per-cycle
/// descriptor leak accumulates far past this bound.
const int _ambientDescriptorSlack = 8;

/// The minimum count over a short window: transient holds from sibling
/// suites settle, a genuine leak's floor stays elevated.
Future<int> _descriptorFloor() async {
  var floor = _descriptorCount();
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    floor = _min(floor, _descriptorCount());
  }
  return floor;
}

int _min(int a, int b) => a < b ? a : b;

/// Owned rename pressure: the probe-proven shape. Two 249-byte names per
/// pair (legal filesystem bytes, malformed UTF-8), tight os.rename turns,
/// self-terminating after 60 s as a runaway backstop — the test's
/// finally SIGTERM/SIGKILLs and reaps long before that on every path.
const String _renameProducerScript = r'''
import os, sys, time
root = os.fsencode(sys.argv[1]) + b'/' + sys.argv[2].encode()
a = root + b'\xff' * 249
b = root + b'\xfe' * 249
open(a, 'w').close()
end = time.monotonic() + 60
while time.monotonic() < end:
    for _ in range(1000):
        os.rename(a, b)
        os.rename(b, a)
''';

Future<void> _waitFor(
  bool Function() condition,
  Duration limit,
  String reason,
) async {
  final end = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _pumpEventQueue() {
  var pumped = Future<void>.value();
  for (var i = 0; i < 5; i++) {
    pumped = pumped.then((_) => Future<void>.delayed(Duration.zero));
  }
  return pumped;
}

/// /proc/self/fd is process-wide and shared with concurrently running
/// suites: an entry can vanish between the listing and the read. Re-list
/// instead of treating another suite's close as a counting failure.
int _descriptorCount() {
  for (var attempt = 0;; attempt++) {
    try {
      return Directory('/proc/self/fd').listSync().length;
    } on PathNotFoundException {
      if (attempt >= 5) rethrow;
    }
  }
}
