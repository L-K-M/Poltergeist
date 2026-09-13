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

    await _waitFor(
      () => events.length >= 4,
      deadline,
      'four events; seen: $events',
    );

    expect(events[0], isA<FileSystemCreateEvent>());
    expect(events.any((event) => event is FileSystemModifyEvent), isTrue);
    expect(
      events.whereType<FileSystemMoveEvent>().map((event) => event.path),
      contains(p.join(root.path, 'entry.txt')),
    );
    expect(
      events.whereType<FileSystemDeleteEvent>().map((event) => event.path),
      contains(p.join(root.path, 'moved.txt')),
    );
    expect(marker.isCompleted, isFalse, reason: 'the watch stays live');
  });

  test('watched-directory removal reports the root then closes', () async {
    final root = await tempFixture('pg-inotify-vanish');
    final watchedPath = root.resolveSymbolicLinksSync();
    final rootLoss = Completer<FileSystemEvent>();
    final done = Completer<void>();

    final subscription = LocalWatchBackend.platform().watch(root.path).listen(
      (event) {
        if (!rootLoss.isCompleted && p.equals(event.path, watchedPath)) {
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
    final watchedPath = root.resolveSymbolicLinksSync();
    final rootLoss = Completer<FileSystemEvent>();
    final done = Completer<void>();

    final subscription = LocalWatchBackend.platform().watch(root.path).listen(
      (event) {
        if (!rootLoss.isCompleted && p.equals(event.path, watchedPath)) {
          rootLoss.complete(event);
        }
      },
      onDone: done.complete,
    );
    addTearDown(subscription.cancel);

    root.renameSync(p.join(parent.path, 'renamed'));

    final loss = await rootLoss.future.timeout(deadline);
    expect(loss, isA<FileSystemDeleteEvent>());
    await done.future.timeout(deadline);
  });

  test('cancellation releases every descriptor it created', () async {
    final root = await tempFixture('pg-inotify-fd');
    final baseline = _descriptorCount();

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
    // ambient descriptors from concurrently running suites. A real
    // per-cycle leak would add fifty descriptors, far past the tolerance.
    expect(
      _descriptorCount(),
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

  test('repeated retarget and stop cycles on one adapter release cleanly',
      () async {
    final parent = await tempFixture('pg-inotify-retarget');
    final first = Directory(p.join(parent.path, 'first'))..createSync();
    final second = Directory(p.join(parent.path, 'second'))..createSync();

    final baseline = _descriptorCount();
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
      _descriptorCount(),
      lessThanOrEqualTo(baseline + _ambientDescriptorSlack),
      reason: 'retarget cycles leaked',
    );
    expect(losses, isEmpty, reason: 'no cycle may report loss');
  });
}

/// Ambient descriptor churn from suites sharing this process. A per-cycle
/// descriptor leak accumulates far past this bound.
const int _ambientDescriptorSlack = 8;

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
