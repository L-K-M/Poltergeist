// Contract tests for the transfer persistence layer (03 §4.6, D16):
// the write-ahead journal, crash/torn-tail/quarantine recovery,
// compaction, the capped history store, and the queue's restore path.
//
// Store tests run FileTransferPersistence directly over a real temp dir.
// Queue tests reuse the deterministic fake-VFS harness — the local side
// is the production LocalFileSystem over real files, the remote side a
// FakeTreeFileSystem.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'transfer_fakes.dart';

TransferTaskSpec localToRemoteSpec({
  required List<String> rootPaths,
  String destinationDir = '/dest',
  String serverId = 's1',
}) => TransferTaskSpec(
  source: const LocalFsLocation(),
  destination: ServerFsLocation(serverId),
  rootPaths: rootPaths,
  destinationDir: destinationDir,
  policy: ResolvedConflictPolicy(files: ConflictResolution.skip),
);

/// A `TransferJournalIo` that counts calls and can gate/fsync-fail on
/// demand — the fault-injection seam the ordering and exclusivity tests
/// drive.
class ScriptedIo extends TransferJournalIo {
  int appendCalls = 0;
  int fsyncCalls = 0;
  int rewriteCalls = 0;
  int dirFsyncCalls = 0;

  /// Ordered operation log ('append:journal', 'fsync:history', …) — the
  /// ordering tests assert interleavings, not just counts.
  final List<String> ops = [];

  /// Completes while a rewrite is in flight (for exclusivity tests).
  final Completer<void> rewriteStarted = Completer();
  Completer<void>? rewriteGate;

  /// Throw on the Nth appendLine (1-based) to script write failures.
  int? failOnAppend;

  static String _tag(File file) =>
      file.path.endsWith(transferJournalFileName) ? 'journal' : 'history';

  @override
  Future<void> appendLine(File file, String line) async {
    appendCalls++;
    ops.add('append:${_tag(file)}');
    if (appendCalls == failOnAppend) {
      throw const FileSystemException('scripted append failure');
    }
    return super.appendLine(file, line);
  }

  @override
  Future<void> fsyncFile(File file) async {
    fsyncCalls++;
    ops.add('fsync:${_tag(file)}');
    return super.fsyncFile(file);
  }

  @override
  Future<void> fsyncDirectory(Directory directory) async {
    dirFsyncCalls++;
    ops.add('dirfsync');
    return super.fsyncDirectory(directory);
  }

  @override
  Future<void> atomicRewrite(File file, String contents) async {
    rewriteCalls++;
    ops.add('rewrite:${_tag(file)}');
    if (!rewriteStarted.isCompleted) rewriteStarted.complete();
    await rewriteGate?.future;
    return super.atomicRewrite(file, contents);
  }
}

/// A persistence seam that records every call — the ordering tests read
/// what the queue's in-memory state looked like *at append time*.
class RecordingPersistence implements TransferPersistence {
  final List<TransferJournalRecord> journal = [];
  final List<TransferHistoryEntry> historyEntries = [];
  TransferJournalReplay replayValue = TransferJournalReplay(tasks: []);
  bool shutdownCalled = false;

  /// Runs inside `appendJournal` — captures state before the caller's
  /// mutation lands.
  void Function(TransferJournalRecord record)? onAppend;

  @override
  TransferJournalReplay get replay => replayValue;

  @override
  void appendJournal(TransferJournalRecord record) {
    onAppend?.call(record);
    journal.add(record);
  }

  @override
  void appendHistory(TransferHistoryEntry entry) => historyEntries.add(entry);

  @override
  Future<void> shutdown() async {
    shutdownCalled = true;
  }
}

/// A persistence seam whose shutdown fails — the dispose-path test
/// asserts the queue still closes its event stream.
class ThrowingShutdownPersistence implements TransferPersistence {
  @override
  TransferJournalReplay get replay => TransferJournalReplay(tasks: []);

  @override
  void appendJournal(TransferJournalRecord record) {}

  @override
  void appendHistory(TransferHistoryEntry entry) {}

  @override
  Future<void> shutdown() => Future.error(StateError('disk gone'));
}

TransferJournalRecord enqueued(String taskId, TransferTaskSpec spec) =>
    TaskEnqueuedRecord(
      taskId: taskId,
      spec: spec,
      enqueuedAt: DateTime.utc(2026, 1, 1),
    );

PlanEntryRecord fileEntry(
  String taskId,
  String itemId,
  String sourcePath,
  String destinationPath, {
  int size = 5,
}) => PlanEntryRecord(
  taskId: taskId,
  itemId: itemId,
  isDirectory: false,
  sourcePath: sourcePath,
  destinationPath: destinationPath,
  sourceType: RemoteFileType.file,
  sourceSize: size,
);

TransferHistoryEntry historyEntry(String taskId) => TransferHistoryEntry(
  taskId: taskId,
  source: const LocalFsLocation(),
  destination: const ServerFsLocation('s1'),
  rootPaths: const ['/r'],
  destinationDir: '/dest',
  operation: TransferOperation.copy,
  outcome: TransferTaskState.completed,
  startedAt: DateTime.utc(2026, 1, 1),
  finishedAt: DateTime.utc(2026, 1, 1, 0, 1),
  completedFiles: 1,
  failedItems: 0,
  skippedItems: 0,
  transferredBytes: 5,
  totalBytes: 5,
);

void main() {
  late Directory tempDir;
  late Directory storeDir;
  late List<String> notices;
  // Every store this test opened — including ones deliberately
  // abandoned mid-test to simulate a crash. TearDown shuts them all
  // down so no writer-chain op or fsync timer can still hold a file
  // handle when the fixture directory is deleted (errno 32 on Windows).
  final openedStores = <FileTransferPersistence>[];

  Future<FileTransferPersistence> openStore({
    ScriptedIo? io,
    int historyLimit = transferHistoryLimit,
    int compactFinishedTasks = journalCompactFinishedTasks,
    int compactBytes = journalCompactBytes,
    int fsyncEveryRecords = journalFsyncEveryRecords,
  }) async {
    final store = await FileTransferPersistence.open(
      storeDir,
      io: io ?? const TransferJournalIo(),
      onNotice: notices.add,
      historyLimit: historyLimit,
      compactFinishedTasks: compactFinishedTasks,
      compactBytes: compactBytes,
      fsyncEveryRecords: fsyncEveryRecords,
    );
    openedStores.add(store);
    return store;
  }

  List<String> journalLines(File file) => file
      .readAsStringSync()
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      .toList();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('poltergeist-tp-');
    tempDir = Directory(tempDir.resolveSymbolicLinksSync());
    storeDir = Directory('${tempDir.path}/store');
    notices = [];
  });

  tearDown(() async {
    for (final store in openedStores) {
      await store.shutdown();
    }
    openedStores.clear();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('store recovery', () {
    test('empty directory opens clean with no replay', () async {
      final store = await openStore();
      expect(store.replay.tasks, isEmpty);
      expect(store.replay.tornJournalBytes, 0);
      expect(store.replay.quarantinedJournalPath, isNull);
      await store.shutdown();
    });

    test('replays a pending task with its spec and item set', () async {
      final store = await openStore();
      final spec = localToRemoteSpec(rootPaths: ['/src/a.txt']);
      store.appendJournal(enqueued('t1', spec));
      store.appendJournal(
        fileEntry('t1', 'i1', '/src/a.txt', '/dest/a.txt'),
      );
      store.appendJournal(
        ScanCompleteRecord(taskId: 't1', totalBytes: 5, skippedSymlinks: 0),
      );
      await store.flush();

      final reopened = await openStore();
      expect(reopened.replay.tasks, hasLength(1));
      final restored = reopened.replay.tasks.single;
      expect(restored.taskId, 't1');
      expect(restored.scanComplete, isTrue);
      expect(restored.totalBytes, 5);
      expect(restored.items, hasLength(1));
      expect(restored.items.single.itemId, 'i1');
      expect(restored.items.single.outcome, isNull);
      expect(restored.spec.destinationDir, '/dest');
      await reopened.shutdown();
    });

    test('a paused task replays as wasPaused', () async {
      final store = await openStore();
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      store.appendJournal(
        TaskStateRecord(taskId: 't1', state: TransferTaskState.paused),
      );
      await store.flush();

      final reopened = await openStore();
      expect(reopened.replay.tasks.single.wasPaused, isTrue);
      await reopened.shutdown();
    });

    test('terminal and removed tasks do not replay', () async {
      final store = await openStore();
      store.appendJournal(enqueued('done', localToRemoteSpec(rootPaths: ['/a'])));
      store.appendJournal(
        TaskStateRecord(taskId: 'done', state: TransferTaskState.completed),
      );
      store.appendJournal(enqueued('gone', localToRemoteSpec(rootPaths: ['/b'])));
      store.appendJournal(TaskRemovedRecord(taskId: 'gone'));
      await store.flush();

      final reopened = await openStore();
      expect(reopened.replay.tasks, isEmpty);
      await reopened.shutdown();
    });

    test('item outcomes survive: completed and removed never resurrect',
        () async {
      final store = await openStore();
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/s'])));
      store.appendJournal(fileEntry('t1', 'done', '/s/a', '/dest/a'));
      store.appendJournal(fileEntry('t1', 'cut', '/s/b', '/dest/b'));
      store.appendJournal(fileEntry('t1', 'live', '/s/c', '/dest/c'));
      store.appendJournal(
        FileCompletedRecord(taskId: 't1', itemId: 'done'),
      );
      store.appendJournal(ItemRemovedRecord(taskId: 't1', itemId: 'cut'));
      await store.flush();

      final reopened = await openStore();
      final items = {
        for (final item in reopened.replay.tasks.single.items)
          item.itemId: item.outcome,
      };
      expect(items['done'], RestoredItemOutcome.completed);
      expect(items['cut'], RestoredItemOutcome.removed);
      expect(items['live'], isNull);
      await reopened.shutdown();
    });

    test('a torn trailing line truncates and reports the dropped bytes',
        () async {
      final store = await openStore();
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await store.flush();
      // A crash mid-append leaves bytes without the newline terminator.
      // No shutdown — the crash simulation abandons the store (a clean
      // shutdown's compaction rewrite would consume the tail).
      await store.journalFile.writeAsString(
        '{"v":1,"type":"taskState","taskId":"t1","state":"paus',
        mode: FileMode.append,
        flush: true,
      );

      final reopened = await openStore();
      expect(reopened.replay.tornJournalBytes, greaterThan(0));
      expect(reopened.replay.tasks, hasLength(1));
      // The file was truncated before reopen — no malformed tail remains.
      expect(
        store.journalFile.readAsStringSync().endsWith('\n'),
        isTrue,
      );
      await reopened.shutdown();
    });

    test('a torn tail after non-ASCII records truncates at the byte '
        'offset — String.length is UTF-16 units, not bytes', () async {
      final store = await openStore();
      // Multi-byte paths desynchronize the two measures.
      store.appendJournal(
        enqueued('t1', localToRemoteSpec(rootPaths: ['/étage/файл.txt'])),
      );
      await store.flush();
      final intactBytes = store.journalFile.lengthSync();
      await store.journalFile.writeAsString(
        '{"v":1,"type":"taskState","taskId":"t1","state":"paus',
        mode: FileMode.append,
        flush: true,
      );

      final reopened = await openStore();
      expect(reopened.replay.tornJournalBytes, greaterThan(0));
      expect(reopened.replay.tasks.single.taskId, 't1');
      // A UTF-16-length truncate would have cut inside the live record.
      expect(store.journalFile.lengthSync(), intactBytes);
      expect(journalLines(store.journalFile), hasLength(1));
      await reopened.shutdown();
    });

    test('a tail torn mid-UTF-8-sequence truncates instead of '
        'quarantining the file', () async {
      final store = await openStore();
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await store.flush();
      // 'é' is two UTF-8 bytes — drop the last so the tail is
      // undecodable. The intact prefix must still survive.
      final tail = utf8.encode(
        '{"v":1,"type":"taskState","taskId":"t1","state":"paused",'
        '"at":"2026-01-01T00:00:00Z","note":"é',
      );
      final raf = await store.journalFile.open(mode: FileMode.append);
      await raf.writeFrom(tail.sublist(0, tail.length - 1));
      await raf.close();

      final reopened = await openStore();
      expect(reopened.replay.tornJournalBytes, greaterThan(0));
      expect(reopened.replay.quarantinedJournalPath, isNull);
      expect(reopened.replay.tasks.single.taskId, 't1');
      await reopened.shutdown();
    });

    test('a record missing its at timestamp quarantines', () async {
      final store = await openStore();
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await store.flush();
      await store.journalFile.writeAsString(
        '{"v":1,"type":"taskState","taskId":"t1","state":"paused"}\n',
        mode: FileMode.append,
        flush: true,
      );

      final reopened = await openStore();
      // The intact prefix replays; the timestamp-less line quarantines.
      expect(reopened.replay.quarantinedJournalPath, isNotNull);
      expect(reopened.replay.quarantinedJournalRecords, 1);
      expect(reopened.replay.tasks.single.taskId, 't1');
      await reopened.shutdown();
    });

    test('a complete-but-unparseable line quarantines and replays the '
        'prefix', () async {
      final store = await openStore();
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await store.flush();
      await store.shutdown();

      await store.journalFile.writeAsString(
        '{"v":1,"type":"bogus"}\n{"v":1,"type":"taskState","taskId":"t2","state":"paused","at":"2026-01-01T00:00:00Z"}\n',
        mode: FileMode.append,
        flush: true,
      );

      final reopened = await openStore();
      expect(reopened.replay.tasks, hasLength(1));
      expect(reopened.replay.quarantinedJournalPath, isNotNull);
      expect(reopened.replay.quarantinedJournalRecords, 2);
      expect(
        File(reopened.replay.quarantinedJournalPath!).existsSync(),
        isTrue,
      );
      // The live file was rewritten to the intact prefix — later appends
      // never land behind the malformed line.
      expect(journalLines(store.journalFile), hasLength(1));
      await reopened.shutdown();
    });

    test('an unknown schema version quarantines the journal', () async {
      await openStore().then((s) => s.shutdown());
      await storeDir.create(recursive: true);
      File('${storeDir.path}/$transferJournalFileName').writeAsStringSync(
        '{"v":99,"type":"taskEnqueued","taskId":"t1","at":"2026-01-01T00:00:00Z","enqueuedAt":"2026-01-01T00:00:00Z","spec":{}}\n',
      );
      final reopened = await openStore();
      expect(reopened.replay.tasks, isEmpty);
      expect(reopened.replay.quarantinedJournalPath, isNotNull);
      await reopened.shutdown();
    });

    test('a torn history tail truncates and reports', () async {
      final store = await openStore();
      store.appendHistory(historyEntry('h1'));
      await store.flush();
      // A crash mid-append — no shutdown (a clean shutdown's compaction
      // would append behind the torn tail, burying it mid-file).
      await store.historyFile.writeAsString(
        '{"v":1,"type":"transferHis',
        mode: FileMode.append,
        flush: true,
      );

      final reopened = await openStore();
      expect(reopened.replay.tornHistoryBytes, greaterThan(0));
      expect(reopened.history, hasLength(1));
      await reopened.shutdown();
    });

    test('abandoned rewrite temps are swept at open', () async {
      await openStore().then((s) => s.shutdown());
      final temp = File(
        '${storeDir.path}/$transferJournalFileName.tmp-deadbeef',
      );
      await temp.writeAsString('partial');
      await temp.setLastModified(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      await openStore().then((s) => s.shutdown());
      expect(temp.existsSync(), isFalse);
    });
  });

  group('compaction', () {
    test('finished tasks migrate to history; the journal keeps only '
        'pending record sets', () async {
      final store = await openStore();
      store.appendJournal(enqueued('done', localToRemoteSpec(rootPaths: ['/a'])));
      store.appendJournal(fileEntry('done', 'i1', '/a/f', '/dest/f'));
      store.appendJournal(
        ScanCompleteRecord(taskId: 'done', totalBytes: 5, skippedSymlinks: 0),
      );
      store.appendJournal(
        FileCompletedRecord(taskId: 'done', itemId: 'i1'),
      );
      store.appendJournal(
        TaskStateRecord(taskId: 'done', state: TransferTaskState.completed),
      );
      store.appendJournal(enqueued('live', localToRemoteSpec(rootPaths: ['/b'])));
      store.appendJournal(fileEntry('live', 'i2', '/b/g', '/dest/g'));
      await store.flush();

      // Startup compaction migrates the finished task.
      final reopened = await openStore();
      expect(reopened.replay.tasks.single.taskId, 'live');
      expect(reopened.history, hasLength(1));
      expect(reopened.history.single.taskId, 'done');

      final lines = journalLines(store.journalFile);
      final records = lines.map(TransferJournalRecord.parse).toList();
      expect(records.every((r) => r.taskId == 'live'), isTrue);
      // The pending task's full record set survived — taskEnqueued plus
      // the planEntry.
      expect(
        records.whereType<TaskEnqueuedRecord>(),
        hasLength(1),
      );
      expect(records.whereType<PlanEntryRecord>(), hasLength(1));
      await reopened.shutdown();
    });

    test('history ids are idempotent — a pre-recorded task is not '
        'appended twice', () async {
      final store = await openStore();
      store.appendHistory(historyEntry('done'));
      store.appendJournal(enqueued('done', localToRemoteSpec(rootPaths: ['/a'])));
      store.appendJournal(
        TaskStateRecord(taskId: 'done', state: TransferTaskState.completed),
      );
      await store.flush();

      final reopened = await openStore();
      expect(reopened.history, hasLength(1));
      await reopened.shutdown();
    });

    test('an append issued during a gated rewrite lands on the new '
        'journal — the single-writer chain makes stale-handle loss '
        'impossible', () async {
      final io = ScriptedIo();
      // Compact on every finished task.
      final store = await openStore(io: io, compactFinishedTasks: 1);
      final openRewrites = io.rewriteCalls;
      // Arm the gate AFTER open — the startup compaction rewrites too.
      io.rewriteGate = Completer();
      store.appendJournal(enqueued('done', localToRemoteSpec(rootPaths: ['/a'])));
      store.appendJournal(
        TaskStateRecord(taskId: 'done', state: TransferTaskState.completed),
      );
      // The compaction rewrite is now gated in flight.
      await pumpUntil(
        () => io.rewriteCalls > openRewrites,
        reason: 'no mid-session rewrite',
      );
      // Queue an append behind it — it must land on the rewritten file.
      store.appendJournal(enqueued('late', localToRemoteSpec(rootPaths: ['/z'])));
      io.rewriteGate!.complete();
      await store.flush();

      final records = journalLines(store.journalFile)
          .map(TransferJournalRecord.parse)
          .toList();
      expect(records.single.taskId, 'late');
      await store.shutdown();
    });
  });

  group('history', () {
    test('records survive a restart', () async {
      final store = await openStore();
      store.appendHistory(historyEntry('h1'));
      store.appendHistory(historyEntry('h2'));
      await store.flush();
      await store.shutdown();

      final reopened = await openStore();
      expect(
        reopened.history.map((e) => e.taskId),
        ['h1', 'h2'],
      );
      await reopened.shutdown();
    });

    test('the cap trims only after the 10% slack and keeps the newest',
        () async {
      final store = await openStore(historyLimit: 10);
      for (var i = 0; i < 11; i++) {
        store.appendHistory(historyEntry('h$i'));
      }
      await store.flush();
      // 11 records = cap + slack: not yet trimmed.
      expect(journalLines(store.historyFile), hasLength(11));

      store.appendHistory(historyEntry('h11'));
      await store.flush();
      final lines = journalLines(store.historyFile);
      expect(lines, hasLength(10));
      final kept = lines
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .map((j) => j['taskId'])
          .toList();
      expect(kept.first, 'h2');
      expect(kept.last, 'h11');
      await store.shutdown();
    });
  });

  group('fsync policy', () {
    test('journal fsyncs at the record boundary and before history',
        () async {
      final io = ScriptedIo();
      final store = await openStore(io: io, fsyncEveryRecords: 2);
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await store.flush();
      io.ops.clear();

      // The second record's boundary fsync fires inside the writer
      // chain — no explicit flush needed.
      store.appendJournal(
        TaskStateRecord(taskId: 't1', state: TransferTaskState.paused),
      );
      await pumpUntil(
        () => io.ops.contains('fsync:journal'),
        reason: 'record-boundary fsync never fired',
      );

      // 03 §4.6 ordering: a task's history row is never durable before
      // the journal describing it — the journal fsync precedes the
      // history append inside the serialized chain.
      io.ops.clear();
      store.appendHistory(historyEntry('t1'));
      await store.flush();
      final historyAppend = io.ops.indexOf('append:history');
      expect(historyAppend, greaterThan(0));
      expect(io.ops[historyAppend - 1], 'fsync:journal');
      await store.shutdown();
    });

    test('flush after shutdown performs no I/O', () async {
      final io = ScriptedIo();
      final store = await openStore(io: io);
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await store.flush();
      await store.shutdown();
      final opsAfterShutdown = io.ops.length;
      await store.flush();
      // Post-shutdown a flush must not resurrect the write chain —
      // Windows temp-dir teardown is where a stray handle bites.
      expect(io.ops, hasLength(opsAfterShutdown));
    });
  });

  group('queue integration', () {
    late FakeTreeFileSystem s1;
    late FakeQueueConnectionManager connections;
    late Directory localSrc;
    final createdQueues = <TransferQueue>[];

    TransferQueue newQueue({TransferPersistence? persistence}) {
      final created = TransferQueue(
        connections: connections,
        persistence: persistence,
      );
      createdQueues.add(created);
      return created;
    }

    setUp(() async {
      s1 = FakeTreeFileSystem();
      s1.addDirectory('/dest');
      connections = FakeQueueConnectionManager({'s1': s1});
      localSrc = Directory('${tempDir.path}/src')..createSync();
    });

    tearDown(() async {
      for (final queue in createdQueues) {
        await queue.dispose();
      }
      createdQueues.clear();
    });

    test('journal calls precede the state transitions they describe',
        () async {
      final recording = RecordingPersistence();
      final queue = newQueue(persistence: recording);
      final seenAtAppend = <String>[];
      queue.events.listen((_) {});

      File('${localSrc.path}/a.txt').writeAsStringSync('hello');
      recording.onAppend = (record) {
        final task = queue.tasks
            .where((t) => t.id == record.taskId)
            .firstOrNull;
        seenAtAppend.add(
          task == null ? 'absent' : task.state.name,
        );
      };
      // Gate the upload so the task is provably mid-flight at pause.
      final uploadGate = Completer<void>();
      s1.uploadGate = (_) => uploadGate;
      final task = queue.enqueue(
        localToRemoteSpec(rootPaths: ['${localSrc.path}/a.txt']),
      );
      // taskEnqueued was journaled before the task became visible.
      expect(recording.journal.first, isA<TaskEnqueuedRecord>());
      expect(seenAtAppend.first, 'absent');

      await pumpUntil(() => s1.uploadCalls > 0, reason: 'upload not armed');
      recording.onAppend = (record) {
        if (record is TaskStateRecord) {
          seenAtAppend.add('saw:${task.state.name}');
        }
      };
      queue.pauseTask(task.id);
      final paused = recording.journal.whereType<TaskStateRecord>().last;
      expect(paused.state, TransferTaskState.paused);
      // The record reached the seam before task.state mutated.
      expect(seenAtAppend.last, isNot('saw:paused'));
      uploadGate.complete();
      queue.resumeTask(task.id);
      await awaitTaskDone(task);
    });

    test('a completed transfer journals lifecycle + writes history',
        () async {
      final store = await openStore();
      final queue = newQueue(persistence: store);
      File('${localSrc.path}/a.txt').writeAsStringSync('hello');
      final task = queue.enqueue(
        localToRemoteSpec(rootPaths: ['${localSrc.path}/a.txt']),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      await store.flush();

      final types = journalLines(store.journalFile)
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .map((j) => j['type'])
          .toList();
      expect(types.first, 'taskEnqueued');
      expect(types, contains('planEntry'));
      expect(types, contains('scanComplete'));
      expect(types, contains('fileCompleted'));
      expect(types.last, 'taskState');
      expect(store.history.single.taskId, task.id);
      expect(store.history.single.outcome, TransferTaskState.completed);
    });

    test('restore maps a crashed running task to queued under the '
        'forced queue pause; resume finishes it without re-transferring '
        'completed items', () async {
      // Craft a crashed session's journal: one file done, one pending.
      final crashed = await openStore();
      final f1 = File('${localSrc.path}/done.txt')..writeAsStringSync('done!');
      final f2 = File('${localSrc.path}/todo.txt')
        ..writeAsStringSync('todo?');
      final spec = localToRemoteSpec(
        rootPaths: [f1.path, f2.path],
      );
      crashed.appendJournal(enqueued('task-1', spec));
      crashed.appendJournal(
        fileEntry('task-1', 'item-done', f1.path, '/dest/done.txt', size: 5),
      );
      crashed.appendJournal(
        fileEntry(
          'task-1',
          'item-todo',
          f2.path,
          '/dest/todo.txt',
          size: 5,
        ),
      );
      crashed.appendJournal(
        ScanCompleteRecord(
          taskId: 'task-1',
          totalBytes: 10,
          skippedSymlinks: 0,
        ),
      );
      crashed.appendJournal(
        FileCompletedRecord(taskId: 'task-1', itemId: 'item-done'),
      );
      await crashed.flush();
      // Simulate the crash: no shutdown — abandon the store with its
      // writes already flushed.
      final uploadsBefore = s1.uploadCalls;

      final store = await openStore();
      expect(store.replay.tasks, hasLength(1));

      final queue = newQueue(persistence: store);
      await queue.restore();
      final restored = queue.tasks.single;
      expect(restored.id, 'task-1');
      // §4.6: running/scanning map to queued; the runtime queue-level
      // pause flag (never journaled) holds admission until Resume.
      expect(restored.state, TransferTaskState.queued);
      expect(queue.isPaused, isTrue);
      expect(restored.scanComplete, isTrue);
      expect(
        restored.items.where((i) => i.id == 'item-done').single.state,
        TransferItemState.completed,
      );

      queue.resumeQueue();
      await awaitTaskDone(restored);
      expect(restored.state, TransferTaskState.completed);
      // Only the pending item transferred — the completed one did not
      // resurrect.
      expect(s1.uploadCalls - uploadsBefore, 1);
      expect(s1.entryAt('/dest/todo.txt'), isNotNull);
      await store.flush();
      expect(store.history.single.taskId, 'task-1');
    });

    test('a mid-scan crash re-scans on resume and merges journaled '
        'outcomes by destination path', () async {
      final crashed = await openStore();
      final f1 = File('${localSrc.path}/done.txt')..writeAsStringSync('done!');
      File('${localSrc.path}/todo.txt').writeAsStringSync('todo?');
      // The root is a directory, so children land under its leaf name:
      // the journaled destinationPath must match the re-scan's join.
      final spec = localToRemoteSpec(rootPaths: [localSrc.path]);
      crashed.appendJournal(enqueued('task-1', spec));
      crashed.appendJournal(
        PlanEntryRecord(
          taskId: 'task-1',
          itemId: 'item-done',
          isDirectory: false,
          sourcePath: f1.path,
          destinationPath: '/dest/src/done.txt',
          sourceType: RemoteFileType.file,
          sourceSize: 5,
          containerKey: null,
        ),
      );
      crashed.appendJournal(
        FileCompletedRecord(taskId: 'task-1', itemId: 'item-done'),
      );
      // No scanComplete — the crash hit mid-scan.
      await crashed.flush();
      final uploadsBefore = s1.uploadCalls;

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      final restored = queue.tasks.single;
      // §4.6: not journaled-paused → queued under the forced queue-level
      // pause; the re-scan waits for Resume too, so the task visibly
      // stays queued and acquires no leases while restored-parked.
      expect(queue.isPaused, isTrue);
      expect(restored.state, TransferTaskState.queued);
      expect(restored.scanComplete, isFalse);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(restored.state, TransferTaskState.queued);
      expect(restored.scanComplete, isFalse);
      expect(s1.uploadCalls - uploadsBefore, 0);

      queue.resumeQueue();
      await pumpUntil(
        () => restored.scanComplete,
        reason: 're-scan never completed after resumeQueue',
      );
      await awaitTaskDone(restored);
      expect(restored.state, TransferTaskState.completed);
      // The re-scan rediscovered both files; only the journaled-pending
      // one transferred (the done item merged and stayed completed).
      expect(s1.uploadCalls - uploadsBefore, 1);
      expect(s1.entryAt('/dest/src/todo.txt'), isNotNull);
      expect(s1.entryAt('/dest/src/done.txt'), isNull);
      expect(
        restored.items
            .where((i) => i.destinationPath == '/dest/src/done.txt')
            .single
            .state,
        TransferItemState.completed,
      );
    });

    test('a task journaled paused stays paused through resumeQueue '
        'until its own resumeTask', () async {
      final crashed = await openStore();
      final f1 = File('${localSrc.path}/a.txt')..writeAsStringSync('hi!');
      crashed.appendJournal(
        enqueued('task-1', localToRemoteSpec(rootPaths: [f1.path])),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'item-a', f1.path, '/dest/a.txt', size: 3),
      );
      crashed.appendJournal(
        ScanCompleteRecord(
          taskId: 'task-1',
          totalBytes: 3,
          skippedSymlinks: 0,
        ),
      );
      crashed.appendJournal(
        TaskStateRecord(
          taskId: 'task-1',
          state: TransferTaskState.paused,
        ),
      );
      await crashed.flush();
      final uploadsBefore = s1.uploadCalls;

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      final restored = queue.tasks.single;
      // §4.6: a per-task journaled pause survives restart on top of the
      // forced queue-level pause.
      expect(restored.state, TransferTaskState.paused);
      expect(queue.isPaused, isTrue);

      queue.resumeQueue();
      for (var i = 0; i < 50 && s1.uploadCalls == uploadsBefore; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(restored.state, TransferTaskState.paused);
      expect(s1.uploadCalls - uploadsBefore, 0);

      queue.resumeTask(restored.id);
      await awaitTaskDone(restored);
      expect(restored.state, TransferTaskState.completed);
      expect(s1.uploadCalls - uploadsBefore, 1);
      expect(s1.entryAt('/dest/a.txt'), isNotNull);
    });

    test('a cancelled task does not restore', () async {
      final crashed = await openStore();
      crashed.appendJournal(
        enqueued('task-1', localToRemoteSpec(rootPaths: ['/r'])),
      );
      crashed.appendJournal(
        TaskStateRecord(
          taskId: 'task-1',
          state: TransferTaskState.cancelled,
        ),
      );
      await crashed.flush();

      final store = await openStore();
      expect(store.replay.tasks, isEmpty);
      final queue = newQueue(persistence: store);
      await queue.restore();
      expect(queue.tasks, isEmpty);
      await queue.dispose();
    });

    test('removeTask journals the removal and the task does not restore',
        () async {
      // Drive the production API: a completed task removed from the
      // listing, not a hand-appended record.
      final store = await openStore();
      final queue = newQueue(persistence: store);
      File('${localSrc.path}/a.txt').writeAsStringSync('bye!');
      final task = queue.enqueue(
        localToRemoteSpec(rootPaths: ['${localSrc.path}/a.txt']),
      );
      await awaitTaskDone(task);
      queue.removeTask(task.id);
      await store.flush();
      expect(
        journalLines(store.journalFile)
            .map(TransferJournalRecord.parse)
            .whereType<TaskRemovedRecord>(),
        hasLength(1),
      );
      // Clean-shutdown compaction writes the history row.
      await store.shutdown();

      final reopened = await openStore();
      expect(reopened.replay.tasks, isEmpty);
      expect(reopened.history.single.taskId, task.id);
      expect(reopened.history.single.outcome, TransferTaskState.completed);
    });

    test('restore sweeps orphaned upload temps in journaled directories '
        'only', () async {
      // Plant a dead temp plus a look-alike that is NOT ours.
      s1.addFile('/dest/.seance-upload-deadbeef.tmp', [1]);
      s1.addFile('/dest/.poltergeist-12345678.tmp', [2]);
      s1.addFile('/dest/keep.txt', [3]);
      s1.addFile('/elsewhere/.seance-upload-99999999.tmp', [4]);

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued('task-1', localToRemoteSpec(rootPaths: ['/r'])),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'i1', '/r/f', '/dest/f'),
      );
      crashed.appendJournal(
        ScanCompleteRecord(taskId: 'task-1', totalBytes: 5, skippedSymlinks: 0),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();

      // Sweeps are fire-and-forget — they land shortly after restore,
      // not inside it.
      await pumpUntil(
        () => s1.entryAt('/dest/.seance-upload-deadbeef.tmp') == null,
        reason: 'orphaned temp never swept',
      );
      expect(s1.entryAt('/dest/.poltergeist-12345678.tmp'), isNull);
      expect(s1.entryAt('/dest/keep.txt'), isNotNull);
      expect(
        s1.entryAt('/elsewhere/.seance-upload-99999999.tmp'),
        isNotNull,
      );
    });

    test('a queued restore whose items all ended terminal drains to '
        'completed without a resume', () async {
      // The task's terminal record was the torn tail — every journaled
      // item already finished, so restore drains the task to its honest
      // terminal state instead of stranding it queued forever.
      final crashed = await openStore();
      final f1 = File('${localSrc.path}/a.txt')..writeAsStringSync('done');
      crashed.appendJournal(
        enqueued('task-1', localToRemoteSpec(rootPaths: [f1.path])),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'item-a', f1.path, '/dest/a.txt', size: 4),
      );
      crashed.appendJournal(
        ScanCompleteRecord(taskId: 'task-1', totalBytes: 4, skippedSymlinks: 0),
      );
      crashed.appendJournal(
        FileCompletedRecord(taskId: 'task-1', itemId: 'item-a'),
      );
      // No taskState:completed — that record died with the crash.
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);
      expect(restored.state, TransferTaskState.completed);
      await pumpUntil(
        () => store.history.isNotEmpty,
        reason: 'history row never written',
      );
      expect(store.history.single.taskId, 'task-1');
      // Set before the rebuild — the row carries the real totals.
      expect(store.history.single.totalBytes, 4);
      // Nothing re-transferred — every journaled item was already done.
      expect(s1.uploadCalls, 0);
    });

    test('a mid-scan merge keys on source path too — same-destination '
        'items do not cross-wire', () async {
      // Two roots with the same leaf name both plan to /dest/f.txt.
      final dirA = Directory('${tempDir.path}/dirA')..createSync();
      final dirB = Directory('${tempDir.path}/dirB')..createSync();
      File('${dirA.path}/f.txt').writeAsStringSync('AAA');
      File('${dirB.path}/f.txt').writeAsStringSync('BBBB');
      final spec = localToRemoteSpec(
        rootPaths: ['${dirA.path}/f.txt', '${dirB.path}/f.txt'],
      );
      final crashed = await openStore();
      crashed.appendJournal(enqueued('task-1', spec));
      // Journal order opposes scan order: pending i2 first, completed
      // i1 second — a destination-only merge would pop i2 for A's file.
      crashed.appendJournal(
        fileEntry(
          'task-1',
          'i2',
          '${dirB.path}/f.txt',
          '/dest/f.txt',
          size: 4,
        ),
      );
      crashed.appendJournal(
        fileEntry(
          'task-1',
          'i1',
          '${dirA.path}/f.txt',
          '/dest/f.txt',
          size: 3,
        ),
      );
      crashed.appendJournal(
        FileCompletedRecord(taskId: 'task-1', itemId: 'i1'),
      );
      // Mid-scan: no scanComplete.
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);
      expect(restored.state, TransferTaskState.completed);
      // i1 kept its completed outcome under ITS source — only i2's
      // source actually uploaded.
      expect(s1.uploadCalls, 1);
      expect(s1.entryAt('/dest/f.txt')!.size, 4);
      expect(
        restored.items.where((i) => i.id == 'i1').single.state,
        TransferItemState.completed,
      );
      expect(
        restored.items.where((i) => i.id == 'i2').single.state,
        TransferItemState.completed,
      );
    });

    test('dispose still closes the event stream when persistence '
        'shutdown throws', () async {
      final queue = newQueue(persistence: ThrowingShutdownPersistence());
      var streamClosed = false;
      queue.events.listen((_) {}, onDone: () => streamClosed = true);
      await expectLater(queue.dispose(), throwsStateError);
      await pumpUntil(() => streamClosed, reason: 'events never closed');
    });

    test('with no persistence the queue runs exactly the in-memory '
        'behavior and writes nothing', () async {
      final queue = newQueue();
      File('${localSrc.path}/a.txt').writeAsStringSync('hello');
      final task = queue.enqueue(
        localToRemoteSpec(rootPaths: ['${localSrc.path}/a.txt']),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s1.entryAt('/dest/a.txt'), isNotNull);
      expect(storeDir.existsSync(), isFalse);
    });
  });
}
