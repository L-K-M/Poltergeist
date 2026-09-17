// Contract tests for the conflict seam (02 §5.2's five-verb model over
// 03 §4.1's ask-park): an unresolved collision parks the item — no
// dispatch slot, no lease, no journal record — and surfaces a
// PendingConflict until resolveConflict answers it. Answers are
// re-evaluated against fresh destination state, apply-to-all is
// task-scoped, the surfaced set is bounded, and cancel/reconnect
// invalidation plus restart all drop the session-scoped prompt.
//
// Harness notes: identical to transfer_queue_test.dart — remote ends are
// FakeTreeFileSystems behind FakeQueueConnectionManager, every gate is a
// Completer, and pumpUntil drives the event loop deterministically.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'transfer_fakes.dart';

TransferTaskSpec copySpec({
  required List<String> rootPaths,
  String destinationDir = '/dst',
  ConflictResolution files = ConflictResolution.ask,
  ConflictResolution folders = ConflictResolution.ask,
}) => TransferTaskSpec(
  source: const ServerFsLocation('s1'),
  destination: const ServerFsLocation('s2'),
  rootPaths: rootPaths,
  destinationDir: destinationDir,
  policy: ResolvedConflictPolicy(files: files, folders: folders),
);

List<TransferQueueConflictEvent> conflictEvents(List<TransferQueueEvent> all) =>
    all.whereType<TransferQueueConflictEvent>().toList();

void main() {
  late FakeTreeFileSystem s1;
  late FakeTreeFileSystem s2;
  late FakeQueueConnectionManager connections;
  late TransferQueue queue;
  late List<TransferQueueEvent> events;
  final createdQueues = <TransferQueue>[];

  TransferQueue newQueue({
    int? maxInFlightFiles,
    int? maxPendingConflicts,
    int taskRetryLimit = 5,
  }) {
    final created = TransferQueue(
      connections: connections,
      poolPolicy: PoolPolicy(taskRetryLimit: taskRetryLimit),
      maxInFlightFiles: maxInFlightFiles ?? maxGlobalInFlightTransfers,
      maxPendingConflicts:
          maxPendingConflicts ?? maxSurfacedPendingConflicts,
    );
    createdQueues.add(created);
    return created;
  }

  setUp(() {
    s1 = FakeTreeFileSystem()..addDirectory('/dst');
    s2 = FakeTreeFileSystem()..addDirectory('/dst');
    connections = FakeQueueConnectionManager({'s1': s1, 's2': s2});
    queue = newQueue();
    events = [];
    queue.events.listen(events.add);
  });

  tearDown(() async {
    for (final created in createdQueues) {
      try {
        await created.dispose();
      } catch (_) {}
    }
    createdQueues.clear();
  });

  /// Parks the colliding file item and returns it.
  Future<TransferItem> parkFile(
    TransferTask task, {
    String destinationPath = '/dst/f.txt',
  }) async {
    await pumpUntil(
      () => queue.pendingConflicts.isNotEmpty,
      reason: 'the collision never surfaced',
    );
    return task.items
        .where((i) => i.destinationPath == destinationPath)
        .single;
  }

  group('park and resolve (02 §5.2, 03 §4.1)', () {
    test('an ask collision parks slot-free and lease-free with the fresh '
        'destination stat surfaced', () async {
      s1.addFile('/src/f.txt', 'new-bytes'.codeUnits);
      s1.addFile('/src/ok.txt', 'ok'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits, modifiedAt: DateTime.utc(2020));
      final task = queue.enqueue(
        copySpec(rootPaths: ['/src/f.txt', '/src/ok.txt']),
      );
      final item = await parkFile(task);

      expect(item.state, TransferItemState.conflictPending);
      expect(task.hasPendingConflicts, isTrue);
      expect(task.isTerminal, isFalse);
      final conflict = queue.pendingConflicts.single;
      expect(conflict.taskId, task.id);
      expect(conflict.itemId, item.id);
      expect(conflict.isDirectory, isFalse);
      expect(conflict.destinationPath, '/dst/f.txt');
      expect(conflict.existing.size, 3);
      expect(conflict.availableVerbs, isNot(contains(ConflictResolution.merge)));
      // A parked item holds nothing: no leases, no upload in flight.
      expect(connections.activeLeases('s1'), 0);
      expect(connections.activeLeases('s2'), 0);
      expect(s2.activeUploads, 0);
      expect(s2.fileBytes['/dst/f.txt'], 'old'.codeUnits);
      expect(
        conflictEvents(events).single.pending,
        isTrue,
      );
      // The sibling file is unaffected — the item pauses, not the task.
      await pumpUntil(
        () => s2.entryAt('/dst/ok.txt') != null ||
            task.items.any(
              (i) =>
                  i.sourcePath == '/src/ok.txt' &&
                  i.state == TransferItemState.completed,
            ),
        reason: 'the sibling item never completed',
      );
      expect(s2.fileBytes['/dst/ok.txt'], 'ok'.codeUnits);
    });

    test('a replace answer commits through expectedTarget', () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = queue.enqueue(copySpec(rootPaths: ['/src/f.txt']));
      final item = await parkFile(task);

      expect(
        queue.resolveConflict(task.id, item.id, ConflictResolution.replace),
        isTrue,
      );
      await awaitTaskDone(task);
      expect(item.state, TransferItemState.completed);
      expect(s2.fileBytes['/dst/f.txt'], 'new'.codeUnits);
      expect(conflictEvents(events).map((e) => e.pending), [true, false]);
      expect(queue.pendingConflicts, isEmpty);
    });

    test('a skip answer preserves the occupant and ends the item skipped',
        () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = queue.enqueue(copySpec(rootPaths: ['/src/f.txt']));
      final item = await parkFile(task);

      expect(
        queue.resolveConflict(task.id, item.id, ConflictResolution.skip),
        isTrue,
      );
      await awaitTaskDone(task);
      expect(item.state, TransferItemState.skipped);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/f.txt'], 'old'.codeUnits);
    });

    test('a keepBoth answer lands the numbered target', () async {
      s1.addFile('/src/report.pdf', 'new'.codeUnits);
      s2.addFile('/dst/report.pdf', 'old'.codeUnits);
      final task = queue.enqueue(copySpec(rootPaths: ['/src/report.pdf']));
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'the collision never surfaced',
      );
      final item = task.items.single;

      expect(
        queue.resolveConflict(task.id, item.id, ConflictResolution.keepBoth),
        isTrue,
      );
      await awaitTaskDone(task);
      expect(s2.fileBytes['/dst/report.pdf'], 'old'.codeUnits);
      expect(s2.fileBytes['/dst/report (2).pdf'], 'new'.codeUnits);
      expect(item.destinationPath, '/dst/report (2).pdf');
    });

    test('the answer is re-evaluated against fresh destination state — a '
        'replaceIfNewer decided on a stale stat still skips when the '
        'occupant freshened while parked', () async {
      final older = DateTime.fromMillisecondsSinceEpoch(1000000);
      final newer = DateTime.fromMillisecondsSinceEpoch(2000000);
      s1.addFile('/src/f.txt', 'new'.codeUnits, modifiedAt: older);
      s2.addFile('/dst/f.txt', 'old'.codeUnits, modifiedAt: older);
      final task = queue.enqueue(copySpec(rootPaths: ['/src/f.txt']));
      final item = await parkFile(task);

      // The occupant's mtime jumps past the source while the prompt sits.
      await s2.setTimes('/dst/f.txt', modifiedAt: newer);
      expect(
        queue.resolveConflict(
          task.id,
          item.id,
          ConflictResolution.replaceIfNewer,
        ),
        isTrue,
      );
      await awaitTaskDone(task);
      // Fresh stat said "not newer" — the item skips instead of
      // overwriting on the stale parked stat (02 §5.2's re-check rule).
      expect(item.state, TransferItemState.skipped);
      expect(s2.fileBytes['/dst/f.txt'], 'old'.codeUnits);
    });

    test('a vanished occupant lets an answered item proceed', () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = queue.enqueue(copySpec(rootPaths: ['/src/f.txt']));
      final item = await parkFile(task);

      await s2.delete(s2.entryAt('/dst/f.txt')!);
      expect(
        queue.resolveConflict(task.id, item.id, ConflictResolution.replace),
        isTrue,
      );
      await awaitTaskDone(task);
      expect(item.state, TransferItemState.completed);
      expect(s2.fileBytes['/dst/f.txt'], 'new'.codeUnits);
    });

    test('resolveConflict validates: ask is never an answer, merge is '
        'folders-only, unknown and already-answered ids return false',
        () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = queue.enqueue(copySpec(rootPaths: ['/src/f.txt']));
      final item = await parkFile(task);

      expect(
        () => queue.resolveConflict(
          task.id,
          item.id,
          ConflictResolution.ask,
        ),
        throwsArgumentError,
      );
      expect(
        () => queue.resolveConflict(
          task.id,
          item.id,
          ConflictResolution.merge,
        ),
        throwsArgumentError,
      );
      // A rejected answer leaves the conflict parked.
      expect(queue.pendingConflicts, hasLength(1));

      expect(
        queue.resolveConflict(task.id, item.id, ConflictResolution.skip),
        isTrue,
      );
      // Late/duplicate answers are ignored (03 §4.1).
      expect(
        queue.resolveConflict(task.id, item.id, ConflictResolution.replace),
        isFalse,
      );
      expect(
        queue.resolveConflict(task.id, 'no-such-item', ConflictResolution.skip),
        isFalse,
      );
      expect(
        queue.resolveConflict('no-such-task', item.id, ConflictResolution.skip),
        isFalse,
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
    });
  });

  group('apply-to-all scope (02 §5.2)', () {
    test('a task-scoped answer resolves later collisions without prompting',
        () async {
      // The stat gate holds the second file's destination check (scan or
      // decision) until the task-scoped answer is already installed, so
      // it can never reach the prompt.
      final bStat = Completer<void>();
      s2.statGate = (path) => path == '/dst/b.txt' ? bStat : null;
      s1.addFile('/src/a.txt', 'A'.codeUnits);
      s1.addFile('/src/b.txt', 'B'.codeUnits);
      s2.addFile('/dst/a.txt', 'old-a'.codeUnits);
      s2.addFile('/dst/b.txt', 'old-b'.codeUnits);
      final task = queue.enqueue(
        copySpec(rootPaths: ['/src/a.txt', '/src/b.txt']),
      );
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'the first collision never surfaced',
      );
      final first = queue.pendingConflicts.single;

      expect(
        queue.resolveConflict(
          task.id,
          first.itemId,
          ConflictResolution.replace,
          scope: ConflictResolutionScope.task,
        ),
        isTrue,
      );
      bStat.complete();
      s2.statGate = null;

      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/a.txt'], 'A'.codeUnits);
      expect(s2.fileBytes['/dst/b.txt'], 'B'.codeUnits);
      // Exactly one conflict ever surfaced: the second colliding item
      // took the installed scope answer without prompting.
      expect(
        conflictEvents(events).where((e) => e.pending),
        hasLength(1),
      );
    });

    test('task-scoped merge keeps folders merging while colliding files '
        'take the replace analog', () async {
      s1.addDirectory('/src/dir');
      s1.addFile('/src/dir/inside.txt', 'new'.codeUnits);
      s2.addDirectory('/dst/dir');
      s2.addFile('/dst/dir/inside.txt', 'old'.codeUnits);
      s2.addFile('/dst/dir/kept.txt', 'kept'.codeUnits);
      final task = queue.enqueue(
        copySpec(rootPaths: ['/src/dir']),
      );
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'the directory collision never surfaced',
      );
      final dir = queue.pendingConflicts.single;
      expect(dir.isDirectory, isTrue);
      expect(dir.availableVerbs, contains(ConflictResolution.merge));

      expect(
        queue.resolveConflict(
          task.id,
          dir.itemId,
          ConflictResolution.merge,
          scope: ConflictResolutionScope.task,
        ),
        isTrue,
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      // Merge recursed into the existing directory; the file inside hit
      // the apply-to-all file analog (replace).
      expect(s2.fileBytes['/dst/dir/inside.txt'], 'new'.codeUnits);
      expect(s2.fileBytes['/dst/dir/kept.txt'], 'kept'.codeUnits);
      expect(
        conflictEvents(events).where((e) => e.pending),
        hasLength(1),
      );
    });
  });

  group('bounded surface and invalidation (03 §4.1)', () {
    test('collisions past the surfaced cap wait unsurfaced and promote in '
        'order as answers free slots', () async {
      queue = newQueue(maxPendingConflicts: 1);
      events = [];
      queue.events.listen(events.add);
      s1.addFile('/src/a.txt', 'A'.codeUnits);
      s1.addFile('/src/b.txt', 'B'.codeUnits);
      s2.addFile('/dst/a.txt', 'old-a'.codeUnits);
      s2.addFile('/dst/b.txt', 'old-b'.codeUnits);
      final task = queue.enqueue(
        copySpec(rootPaths: ['/src/a.txt', '/src/b.txt']),
      );
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'the first collision never surfaced',
      );
      // Give the second collision time to reach the cap branch — its
      // item waits unsurfaced instead of growing the prompt list.
      await pump(30);
      expect(queue.pendingConflicts, hasLength(1));
      // The unsurfaced item parked without holding a lease or slot.
      expect(connections.activeLeases('s1'), 0);
      expect(connections.activeLeases('s2'), 0);

      final first = queue.pendingConflicts.single;
      expect(
        queue.resolveConflict(task.id, first.itemId, ConflictResolution.skip),
        isTrue,
      );
      // The freed slot promotes the waiter — it re-stats and surfaces
      // its own fresh conflict rather than reusing a stale entry.
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty &&
            queue.pendingConflicts.single.itemId != first.itemId,
        reason: 'the waiting collision never promoted',
      );
      final second = queue.pendingConflicts.single;
      expect(
        queue.resolveConflict(task.id, second.itemId, ConflictResolution.skip),
        isTrue,
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/a.txt'], 'old-a'.codeUnits);
      expect(s2.fileBytes['/dst/b.txt'], 'old-b'.codeUnits);
    });

    test('cancel dismisses the surface and a late answer is ignored',
        () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = queue.enqueue(copySpec(rootPaths: ['/src/f.txt']));
      final item = await parkFile(task);

      queue.cancelTask(task.id);
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.cancelled);
      expect(item.state, TransferItemState.cancelled);
      expect(queue.pendingConflicts, isEmpty);
      // The dismissal event rides the broadcast stream — pump it through
      // (the task is already terminal, so awaitTaskDone never pumped).
      await pumpUntil(
        () => conflictEvents(events).length == 2,
        reason: 'the cancel dismissal never surfaced',
      );
      expect(
        conflictEvents(events).map((e) => e.pending),
        [true, false],
      );
      // The reply arrived after dismissal — §4.1's ignored-late-reply.
      expect(
        queue.resolveConflict(task.id, item.id, ConflictResolution.skip),
        isFalse,
      );
      expect(s2.fileBytes['/dst/f.txt'], 'old'.codeUnits);
    });

    test('a §3.3 disconnect invalidates the parked conflict and the item '
        're-prompts fresh', () async {
      // One in-flight slot serializes the siblings: f.txt parks first,
      // then b.txt dispatches and drops its link — deterministically
      // after the conflict surfaced.
      queue = newQueue(maxInFlightFiles: 1);
      events = [];
      queue.events.listen(events.add);
      var dropped = false;
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s1.addFile('/src/b.txt', 'B'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      s1.downloadFailure = (path) {
        if (path != '/src/b.txt' || dropped) return null;
        dropped = true;
        return const RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: 'download',
          message: 'link dropped',
        );
      };
      final task = queue.enqueue(
        copySpec(rootPaths: ['/src/f.txt', '/src/b.txt']),
      );
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'the collision never surfaced',
      );
      final item = task.items
          .where((i) => i.sourcePath == '/src/f.txt')
          .single;

      // The disconnect flips the task to queued → the parked prompt is
      // stale and dismisses; the item re-dispatches and re-surfaces.
      await pumpUntil(
        () => conflictEvents(events)
            .any((e) => e.itemId == item.id && !e.pending),
        reason: 'the disconnect never invalidated the parked conflict',
      );
      await pumpUntil(
        () =>
            conflictEvents(events)
                .where((e) => e.itemId == item.id && e.pending)
                .length ==
            2,
        reason: 'the conflict never re-surfaced fresh',
      );
      expect(
        queue.resolveConflict(task.id, item.id, ConflictResolution.skip),
        isTrue,
      );
      await awaitTaskDone(task);
      // The retried sibling transferred; the re-prompted item skipped.
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/b.txt'], 'B'.codeUnits);
      expect(s2.fileBytes['/dst/f.txt'], 'old'.codeUnits);
    });
  });

  group('directory conflicts', () {
    test('a folder ask parks the directory and holds its children; a merge '
        'answer recurses into the occupant', () async {
      s1.addDirectory('/src/dir');
      s1.addFile('/src/dir/new.txt', 'new'.codeUnits);
      s2.addDirectory('/dst/dir');
      s2.addFile('/dst/dir/kept.txt', 'kept'.codeUnits);
      final task = queue.enqueue(
        copySpec(
          rootPaths: ['/src/dir'],
          files: ConflictResolution.replace,
        ),
      );
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'the directory collision never surfaced',
      );
      final dir = queue.pendingConflicts.single;
      expect(dir.isDirectory, isTrue);
      // The subtree waits on the directory's answer — nothing transferred.
      expect(s2.entryAt('/dst/dir/new.txt'), isNull);

      expect(
        queue.resolveConflict(task.id, dir.itemId, ConflictResolution.merge),
        isTrue,
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/dir/new.txt'], 'new'.codeUnits);
      expect(s2.fileBytes['/dst/dir/kept.txt'], 'kept'.codeUnits);
    });

    test('a merge fallback on a non-directory occupant parks instead of '
        'pretending recursion is possible (03 §4.1)', () async {
      s1.addDirectory('/src/dir');
      s1.addFile('/src/dir/inside.txt', 'in'.codeUnits);
      s2.addFile('/dst/dir', 'a-file'.codeUnits);
      final task = queue.enqueue(
        copySpec(
          rootPaths: ['/src/dir'],
          files: ConflictResolution.skip,
          folders: ConflictResolution.merge,
        ),
      );
      // merge cannot recurse into a file — the directory parks.
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'the kind-mismatch collision never surfaced',
      );
      final dir = queue.pendingConflicts.single;
      expect(dir.isDirectory, isTrue);
      expect(
        queue.resolveConflict(task.id, dir.itemId, ConflictResolution.skip),
        isTrue,
      );
      await awaitTaskDone(task);
      final byPath = {for (final i in task.items) i.sourcePath: i};
      expect(byPath['/src/dir']!.state, TransferItemState.skipped);
      expect(byPath['/src/dir/inside.txt']!.state, TransferItemState.skipped);
      expect(s2.fileBytes['/dst/dir'], 'a-file'.codeUnits);
    });
  });
}
