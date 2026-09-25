import 'dart:async';
import 'dart:ui' show Color, Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/drag_out_controller.dart';
import 'package:poltergeist_app/services/drag_out_producer.dart';
import 'package:poltergeist_app/services/os_drag_out.dart';
import 'package:poltergeist_app/services/pane_drop.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';
import '../support/fake_drag_out.dart';

const _style = DragOutImageStyle(
  palette: DragOutImagePalette(
    background: Color(0xFFEEEEEE),
    foreground: Color(0xFF111111),
    badge: Color(0xFF3355FF),
    onBadge: Color(0xFFFFFFFF),
  ),
  devicePixelRatio: 2,
  itemCountLabel: _count,
);

String _count(int count) => '$count items';

RemoteFileEntry _entry(
  String path, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
}) => RemoteFileEntry(
  path: path,
  name: path.split('/').last,
  type: type,
  size: size,
);

PaneEntryDrag _remoteDrag(List<RemoteFileEntry> entries) => PaneEntryDrag(
  source: const ServerFsLocation('srv-1'),
  rootPaths: [for (final entry in entries) entry.path],
  entries: entries,
);

PaneEntryDrag _localDrag(List<RemoteFileEntry> entries) => PaneEntryDrag(
  source: const LocalFsLocation(),
  rootPaths: [for (final entry in entries) entry.path],
  entries: entries,
);

void main() {
  late FakeDragOutBackend backend;
  late FakeDragOutProducer files;
  late FakeAppTransferQueue queue;
  late DateTime now;
  late DragOutController controller;

  DragOutController build({
    DragOutSupport support = DragOutSupport.localFilesAndPromises,
    bool withFiles = true,
    bool withQueue = true,
    DragOutImageRenderer? renderImage,
  }) {
    backend.support = support;
    return controller = DragOutController(
      backend: backend,
      files: withFiles ? files : null,
      queue: withQueue ? queue : null,
      renderImage: renderImage,
      dropStagingDirectory: '/var/folders/xy/T/Drops',
      clock: () => now,
      pausePollInterval: const Duration(milliseconds: 1),
      progressInterval: const Duration(milliseconds: 100),
    );
  }

  setUp(() {
    backend = FakeDragOutBackend();
    files = FakeDragOutProducer();
    queue = FakeAppTransferQueue();
    now = DateTime.utc(2026, 9, 25, 12);
  });

  tearDown(() => controller.dispose());

  Future<DragOutHandOffResult> handOffResult(PaneEntryDrag drag) =>
      controller.handOff(drag, position: const Offset(1500, 40), style: _style);

  Future<DragOutHandOff> handOff(PaneEntryDrag drag) async =>
      (await handOffResult(drag)).outcome;

  /// Starts a remote session over [entries] and returns its id.
  Future<String> startRemote(List<RemoteFileEntry> entries) async {
    expect(await handOff(_remoteDrag(entries)), DragOutHandOff.started);
    return backend.requests.last.sessionId;
  }

  Future<void> fulfil(String sessionId, String promiseId, String path) =>
      controller.fulfilPromise(
        DragOutPromiseRequest(
          sessionId: sessionId,
          promiseId: promiseId,
          destinationPath: path,
        ),
      );

  Matcher failsWith(DragOutPromiseFailure failure) => throwsA(
    isA<DragOutPromiseException>().having(
      (error) => error.failure,
      'failure',
      failure,
    ),
  );

  group('hand-off', () {
    test('a local drag offers file URLs the destination may copy or link, '
        'never move', () async {
      build(support: DragOutSupport.localFiles);
      final drag = _localDrag([
        _entry('/home/tester/report.txt', size: 12),
        _entry('/home/tester/docs', type: RemoteFileType.directory),
      ]);
      expect(await handOff(drag), DragOutHandOff.started);
      final request = backend.requests.single;
      expect(request.position, const Offset(1500, 40));
      // The owner's rule (00 D14's drag-out amendment): no trash may
      // take the source, so no destination may move it.
      expect(request.allowedOperations, {DragOutOffer.copy, DragOutOffer.link});
      expect(request.items.map((item) => item.toChannel()), [
        {
          'kind': 'file',
          'path': '/home/tester/report.txt',
          'name': 'report.txt',
          'isDirectory': false,
        },
        {
          'kind': 'file',
          'path': '/home/tester/docs',
          'name': 'docs',
          'isDirectory': true,
        },
      ]);
      expect(controller.activeEchoPayload, same(drag));
    });

    test('remote rows where only local files travel do not start a '
        'native drag', () async {
      build(support: DragOutSupport.localFiles);
      final result = await handOff(_remoteDrag([_entry('/srv/a.txt')]));
      expect(result, DragOutHandOff.remoteUnsupported);
      expect(backend.requests, isEmpty);
    });

    test('promises need the produce seam and the queue', () async {
      build(withQueue: false);
      expect(controller.support, DragOutSupport.localFiles);
      expect(
        await handOff(_remoteDrag([_entry('/srv/a.txt')])),
        DragOutHandOff.remoteUnsupported,
      );
    });

    test('remote rows become copy-only promises; flagged names and links '
        'are left out, and counted', () async {
      build();
      final result = await handOffResult(
        _remoteDrag([
          _entry('/srv/a.txt', size: 5),
          _entry('/srv/bad�.txt'),
          _entry('/srv/link', type: RemoteFileType.symbolicLink),
          _entry('/srv/site', type: RemoteFileType.directory, size: 4096),
        ]),
      );
      expect(result.outcome, DragOutHandOff.started);
      expect(result.leftOut.links, 1);
      expect(result.leftOut.flaggedNames, 1);
      expect(result.leftOut.unlisted, 0);
      final request = backend.requests.single;
      expect(request.allowedOperations, {DragOutOffer.copy});
      expect(request.items.map((item) => item.toChannel()), [
        {
          'kind': 'promise',
          'promiseId': 'p1',
          'name': 'a.txt',
          'isDirectory': false,
          'size': 5,
        },
        {
          'kind': 'promise',
          'promiseId': 'p2',
          'name': 'site',
          'isDirectory': true,
          'size': null,
        },
      ]);
    });

    test('a drag with nothing to offer does not reach the backend, and '
        'says why', () async {
      build();
      final result = await handOffResult(_remoteDrag([_entry('/srv/bad�')]));
      expect(result.outcome, DragOutHandOff.unavailable);
      expect(result.leftOut.flaggedNames, 1);
      expect(result.leftOut.count, 1);
      expect(backend.requests, isEmpty);
    });

    test('a root without a listing entry is left out and counted', () async {
      build();
      final result = await handOffResult(
        PaneEntryDrag(
          source: const ServerFsLocation('srv-1'),
          rootPaths: const ['/srv/a.txt', '/srv/gone.txt'],
          entries: [_entry('/srv/a.txt', size: 1)],
        ),
      );
      expect(result.outcome, DragOutHandOff.started);
      expect(backend.requests.single.items.map((item) => item.name), ['a.txt']);
      expect(result.leftOut.unlisted, 1);
      expect(result.leftOut.count, 1);
    });

    test('a refused start leaves nothing out: the in-app drag still '
        'carries every row', () async {
      build();
      backend.nextResult = const DragOutNotStarted(DragOutRefusal.busy);
      final result = await handOffResult(
        _remoteDrag([
          _entry('/srv/a.txt'),
          _entry('/srv/link', type: RemoteFileType.symbolicLink),
        ]),
      );
      expect(result.outcome, DragOutHandOff.notStarted);
      expect(result.leftOut.isEmpty, isTrue);
    });

    test('a refused start forgets the session', () async {
      build();
      backend.nextResult = const DragOutNotStarted(
        DragOutRefusal.buttonReleased,
      );
      expect(
        await handOff(_remoteDrag([_entry('/srv/a.txt')])),
        DragOutHandOff.notStarted,
      );
      final sessionId = backend.requests.single.sessionId;
      expect(controller.activeEchoPayload, isNull);
      await expectLater(
        fulfil(sessionId, 'p1', '/Users/me/Desktop/a.txt'),
        failsWith(DragOutPromiseFailure.unknown),
      );
    });

    test(
      'the image renderer gets the name, or the count for several',
      () async {
        final specs = <DragOutImageSpec>[];
        build(
          support: DragOutSupport.localFiles,
          renderImage: (spec) async {
            specs.add(spec);
            return null;
          },
        );
        await handOff(_localDrag([_entry('/home/tester/report.txt')]));
        await handOff(
          _localDrag([_entry('/home/tester/a'), _entry('/home/tester/b')]),
        );
        expect(specs.map((spec) => (spec.label, spec.count)), [
          ('report.txt', 1),
          ('2 items', 2),
        ]);
        expect(specs.first.devicePixelRatio, 2);
      },
    );

    test(
      'a failing renderer still starts the session without an image',
      () async {
        build(
          support: DragOutSupport.localFiles,
          renderImage: (_) => Future.error(StateError('no GPU')),
        );
        expect(
          await handOff(_localDrag([_entry('/home/tester/report.txt')])),
          DragOutHandOff.started,
        );
        expect(backend.requests.single.image, isNull);
      },
    );

    test('a new session ends one whose end never arrived', () async {
      build(support: DragOutSupport.localFiles);
      final first = _localDrag([_entry('/home/tester/a.txt')]);
      final second = _localDrag([_entry('/home/tester/b.txt')]);
      await handOff(first);
      // No sessionEnded for the first: the OS runs one drag at a time,
      // so the next start retires it.
      await handOff(second);
      expect(controller.activeEchoPayload, same(second));
      now = now.add(const Duration(seconds: 10));
      expect(controller.claimEcho(const ['/home/tester/a.txt']), isNull);
    });

    test('a session end that reports a move is only an end: nothing is '
        'transferred or deleted', () async {
      build(support: DragOutSupport.localFiles);
      final drag = _localDrag([_entry('/home/tester/report.txt')]);
      await handOff(drag);
      // Never offered, but a target may claim one anyway.
      controller.sessionEnded(
        backend.requests.single.sessionId,
        DragOutOperation.move,
      );
      expect(controller.activeEchoPayload, isNull);
      expect(queue.enqueuedSpecs, isEmpty);
      expect(queue.prepareDeleteCalls, isEmpty);
      expect(queue.enqueuedDeletes, isEmpty);
      expect(files.produces, isEmpty);
      // The echo still counts: a drop back into the window moments later
      // lands with the in-app verb.
      expect(
        controller.claimEcho(const ['/home/tester/report.txt']),
        same(drag),
      );
    });

    test('sessionEnded ends the echo window for hover labels', () async {
      build(support: DragOutSupport.localFiles);
      await handOff(_localDrag([_entry('/home/tester/report.txt')]));
      var notified = 0;
      controller.addListener(() => notified++);
      controller.sessionEnded(
        backend.requests.single.sessionId,
        DragOutOperation.copy,
      );
      expect(controller.activeEchoPayload, isNull);
      expect(notified, 1);
    });
  });

  group('file promises', () {
    test(
      'produce straight into the destination, with throttled progress',
      () async {
        build();
        final session = await startRemote([_entry('/srv/a.txt', size: 300)]);
        final done = fulfil(session, 'p1', '/Users/me/Desktop/a.txt');
        await pumpEventQueue();
        final produce = files.produces.single;
        expect(produce.serverId, 'srv-1');
        expect(produce.remotePath, '/srv/a.txt');
        expect(produce.destinationPath, '/Users/me/Desktop/a.txt');
        expect(produce.expectedSize, 300);
        produce.onProgress!(100, 300);
        produce.onProgress!(150, 300); // inside the throttle window
        now = now.add(const Duration(milliseconds: 150));
        produce.onProgress!(200, 300);
        produce.complete();
        await done;
        expect(backend.progress.map((report) => report.completedBytes), [
          100,
          200,
          300,
        ]);
        expect(backend.progress.last.totalBytes, 300);
      },
    );

    test('an existing file fails the promise and is never replaced', () async {
      build();
      final session = await startRemote([_entry('/srv/a.txt')]);
      final done = fulfil(session, 'p1', '/Users/me/Desktop/a.txt');
      await pumpEventQueue();
      files.produces.single.fail(
        RemoteFileErrorKind.conflict,
        'A local item named "a.txt" already exists.',
      );
      await expectLater(done, failsWith(DragOutPromiseFailure.exists));
    });

    test('a failed produce fails the promise with its reason', () async {
      build();
      final session = await startRemote([_entry('/srv/a.txt')]);
      final done = fulfil(session, 'p1', '/Users/me/Desktop/a.txt');
      await pumpEventQueue();
      files.produces.single.fail(
        RemoteFileErrorKind.disconnected,
        'The connection closed.',
      );
      await expectLater(
        done,
        throwsA(
          isA<DragOutPromiseException>()
              .having((e) => e.failure, 'failure', DragOutPromiseFailure.failed)
              .having((e) => e.message, 'message', 'The connection closed.'),
        ),
      );
    });

    test('cancelling in the OS cancels the produce task', () async {
      build();
      final session = await startRemote([_entry('/srv/a.txt')]);
      final done = fulfil(session, 'p1', '/Users/me/Desktop/a.txt');
      await pumpEventQueue();
      controller.cancelPromise(session, 'p1');
      expect(files.cancelled, ['produce-1']);
      await expectLater(done, failsWith(DragOutPromiseFailure.cancelled));
    });

    test('a Pause on its Transfers row cancels the produce and fails the '
        'promise, with an Alert', () async {
      build();
      final session = await startRemote([_entry('/srv/a.txt', size: 300)]);
      final done = fulfil(session, 'p1', '/Users/me/Desktop/a.txt');
      await pumpEventQueue();
      final produce = files.produces.single;
      // The produce hop is a row on the same queue: its per-task pause
      // would park it until a resume that may never come, while the OS
      // waits on the promise.
      queue.pauseTask(produce.taskId);
      await expectLater(
        done.timeout(const Duration(seconds: 2)),
        failsWith(DragOutPromiseFailure.paused),
      );
      expect(files.cancelled, [produce.taskId]);
      final notice = controller.notices.single;
      expect(notice.kind, DragOutNoticeKind.pausedMidway);
      expect(notice.itemName, 'a.txt');
      expect(notice.destinationDir, '/Users/me/Desktop');
    });

    test('a pause of another row leaves the produce running', () async {
      build();
      final session = await startRemote([_entry('/srv/a.txt', size: 3)]);
      final done = fulfil(session, 'p1', '/Users/me/Desktop/a.txt');
      await pumpEventQueue();
      queue.pauseTask('task-elsewhere');
      await pumpEventQueue();
      expect(files.cancelled, isEmpty);
      files.produces.single.complete();
      await done;
      expect(controller.notices, isEmpty);
    });

    test('promises stay answerable after the session ended', () async {
      build();
      final session = await startRemote([_entry('/srv/a.txt')]);
      controller.sessionEnded(session, DragOutOperation.copy);
      now = now.add(const Duration(minutes: 1));
      final done = fulfil(session, 'p1', '/Users/me/Desktop/a.txt');
      await pumpEventQueue();
      files.produces.single.complete();
      await done;
    });

    test('an unknown promise fails fast', () async {
      build();
      final session = await startRemote([_entry('/srv/a.txt')]);
      await expectLater(
        fulfil(session, 'p9', '/Users/me/Desktop/a.txt'),
        failsWith(DragOutPromiseFailure.unknown),
      );
    });
  });

  group('folder promises', () {
    test(
      'ride a normal recursive download into the destination folder',
      () async {
        build();
        final session = await startRemote([
          _entry('/srv/site', type: RemoteFileType.directory),
        ]);
        final done = fulfil(session, 'p1', '/Users/me/Desktop/site');
        await pumpEventQueue();
        final spec = queue.enqueuedSpecs.single;
        expect(spec.source, const ServerFsLocation('srv-1'));
        expect(spec.destination, const LocalFsLocation());
        expect(spec.rootPaths, ['/srv/site']);
        expect(spec.destinationDir, '/Users/me/Desktop');
        expect(spec.operation, TransferOperation.copy);
        expect(spec.produce, isNull);
        // The settings matrix's download bucket, like any drop.
        expect(spec.policy.folders, ConflictResolution.ask);
        final task = queue.tasks.single
          ..transferredBytes = 10
          ..totalBytes = 10
          ..state = TransferTaskState.completed;
        queue.emit(TransferQueueTaskEvent(task.id, task.state));
        await done;
        expect(backend.progress.last.completedBytes, 10);
      },
    );

    test('a paused queue fails the promise at once, with an Alert', () async {
      build();
      queue.pauseQueue();
      final session = await startRemote([
        _entry('/srv/site', type: RemoteFileType.directory),
      ]);
      await expectLater(
        fulfil(session, 'p1', '/Users/me/Desktop/site'),
        failsWith(DragOutPromiseFailure.paused),
      );
      expect(queue.enqueuedSpecs, isEmpty);
      expect(controller.notices.single.kind, DragOutNoticeKind.paused);
      expect(controller.notices.single.itemName, 'site');
      expect(controller.notices.single.destinationDir, '/Users/me/Desktop');
    });

    test(
      'a pause mid-download cancels the task and fails the promise',
      () async {
        build();
        final session = await startRemote([
          _entry('/srv/site', type: RemoteFileType.directory),
        ]);
        final done = fulfil(session, 'p1', '/Users/me/Desktop/site');
        await pumpEventQueue();
        final task = queue.tasks.single..state = TransferTaskState.running;
        queue.pauseQueue();
        await expectLater(done, failsWith(DragOutPromiseFailure.paused));
        expect(queue.cancelTaskCalls, [task.id]);
        expect(controller.notices.single.kind, DragOutNoticeKind.pausedMidway);
      },
    );

    test('a Pause on its Transfers row cancels the download and fails the '
        'promise, with an Alert', () async {
      build();
      final session = await startRemote([
        _entry('/srv/site', type: RemoteFileType.directory),
      ]);
      final done = fulfil(session, 'p1', '/Users/me/Desktop/site');
      await pumpEventQueue();
      final task = queue.tasks.single..state = TransferTaskState.running;
      // Unlike the queue pause, nothing polls for this one: the row's
      // pause event is the signal.
      queue.pauseTask(task.id);
      await expectLater(
        done.timeout(const Duration(seconds: 2)),
        failsWith(DragOutPromiseFailure.paused),
      );
      expect(queue.cancelTaskCalls, [task.id]);
      expect(task.state, TransferTaskState.cancelled);
      final notice = controller.notices.single;
      expect(notice.kind, DragOutNoticeKind.pausedMidway);
      expect(notice.itemName, 'site');
      expect(notice.destinationDir, '/Users/me/Desktop');
    });

    test('a renamed destination fails instead of landing elsewhere', () async {
      build();
      final session = await startRemote([
        _entry('/srv/site', type: RemoteFileType.directory),
      ]);
      await expectLater(
        fulfil(session, 'p1', '/Users/me/Desktop/site 2'),
        failsWith(DragOutPromiseFailure.renamed),
      );
      expect(queue.enqueuedSpecs, isEmpty);
      expect(controller.notices.single.kind, DragOutNoticeKind.renamed);
    });

    test('cancelling in the OS cancels the download task', () async {
      build();
      final session = await startRemote([
        _entry('/srv/site', type: RemoteFileType.directory),
      ]);
      final done = fulfil(session, 'p1', '/Users/me/Desktop/site');
      await pumpEventQueue();
      controller.cancelPromise(session, 'p1');
      await expectLater(done, failsWith(DragOutPromiseFailure.cancelled));
      expect(queue.cancelTaskCalls, [queue.tasks.single.id]);
      expect(controller.notices, isEmpty);
    });

    test('a failed download fails the promise with the task error', () async {
      build();
      final session = await startRemote([
        _entry('/srv/site', type: RemoteFileType.directory),
      ]);
      final done = fulfil(session, 'p1', '/Users/me/Desktop/site');
      await pumpEventQueue();
      final task = queue.tasks.single
        ..state = TransferTaskState.failed
        ..error = 'Permission denied.';
      queue.emit(TransferQueueTaskEvent(task.id, task.state));
      await expectLater(
        done,
        throwsA(
          isA<DragOutPromiseException>().having(
            (e) => e.message,
            'message',
            'Permission denied.',
          ),
        ),
      );
    });
  });

  group('own-drag echo', () {
    test('a promise called into desktop_drop staging fails fast and the '
        'drop is claimed once', () async {
      build();
      final drag = _remoteDrag([_entry('/srv/a.txt')]);
      expect(await handOff(drag), DragOutHandOff.started);
      final session = backend.requests.single.sessionId;
      await expectLater(
        fulfil(
          session,
          'p1',
          '/private/var/folders/xy/T/Drops/20260925_120000_000Z/a.txt',
        ),
        failsWith(DragOutPromiseFailure.ownDrop),
      );
      expect(files.produces, isEmpty);
      controller.sessionEnded(session, DragOutOperation.copy);
      now = now.add(const Duration(seconds: 1));
      expect(controller.claimEcho(const []), same(drag));
      expect(controller.claimEcho(const []), isNull);
    });

    test('a remote session without a staged promise claims no drop', () async {
      build();
      await handOff(_remoteDrag([_entry('/srv/a.txt')]));
      expect(controller.claimEcho(const []), isNull);
      expect(controller.claimEcho(const ['/Users/me/Desktop/a.txt']), isNull);
    });

    test('a local echo matches the dragged paths only', () async {
      build(support: DragOutSupport.localFiles);
      final drag = _localDrag([
        _entry('/home/tester/a.txt'),
        _entry('/home/tester/b.txt'),
      ]);
      await handOff(drag);
      expect(controller.claimEcho(const ['/home/tester/a.txt']), isNull);
      expect(controller.claimEcho(const ['/elsewhere/a.txt']), isNull);
      expect(
        controller.claimEcho(const [
          '/home/tester/b.txt',
          '/home/tester/a.txt',
        ]),
        same(drag),
      );
    });

    test('the echo window closes after the grace period', () async {
      build(support: DragOutSupport.localFiles);
      final drag = _localDrag([_entry('/home/tester/a.txt')]);
      await handOff(drag);
      controller.sessionEnded(
        backend.requests.single.sessionId,
        DragOutOperation.copy,
      );
      now = now.add(const Duration(seconds: 10));
      expect(controller.claimEcho(const ['/home/tester/a.txt']), isNull);
    });

    test('staging paths compare through the /private spelling', () {
      build();
      expect(
        controller.isDropStagingPath('/var/folders/xy/T/Drops/1/a.txt'),
        isTrue,
      );
      expect(
        controller.isDropStagingPath('/private/var/folders/xy/T/Drops/1/a'),
        isTrue,
      );
      expect(controller.isDropStagingPath('/Users/me/Desktop/a'), isFalse);
      expect(controller.isDropStagingPath('/var/folders/xy/T/Drops'), isFalse);
    });
  });

  test('the queue producer asks for exclusive, drag-out-pool hops', () {
    controller = DragOutController(backend: const NoDragOutBackend());
    final recording = _RecordingPreviewProducer();
    final producer = QueueDragOutProducer(recording);
    final ticket = producer.produceFile(
      serverId: 'srv-1',
      remotePath: '/srv/a.txt',
      destinationPath: '/Users/me/Desktop/a.txt',
      expectedSize: 3,
    );
    final spec = recording.specs.single;
    expect(spec.serverId, 'srv-1');
    expect(spec.remotePath, '/srv/a.txt');
    expect(spec.destinationPath, '/Users/me/Desktop/a.txt');
    expect(spec.expectedSize, 3);
    expect(spec.writeMode, ProduceWriteMode.exclusive);
    expect(spec.slotPool, ProduceSlotPool.dragOut);
    producer.cancel(ticket.taskId);
    expect(recording.cancelled, [ticket.taskId]);
  });
}

class _RecordingPreviewProducer implements PreviewProducer {
  final specs = <PreviewProduceSpec>[];
  final cancelled = <String>[];

  @override
  PreviewProduceTicket start(PreviewProduceSpec spec) {
    specs.add(spec);
    return PreviewProduceTicket(
      taskId: 'task-${specs.length}',
      result: Completer<RemoteFileEntry>().future,
    );
  }

  @override
  void cancel(String taskId) => cancelled.add(taskId);
}
