@TestOn('vm')
library;

import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

void main() {
  late Directory runsDir;

  setUp(() async {
    runsDir = await Directory.systemTemp.createTemp('poltergeist-journal-');
  });

  tearDown(() async {
    if (await runsDir.exists()) await runsDir.delete(recursive: true);
  });

  const rules = SyncRuleSet(
    direction: SyncDirection.leftToRight,
    deletions: DeletionPolicy.trash,
    backups: BackupPolicy.trash,
    maxDelete: 250,
  );

  SyncRunRecord record(String runId, [DateTime? startedAt]) => SyncRunRecord(
    runId: runId,
    pairId: 'pair-1',
    startedAt: startedAt ?? DateTime.now(),
    rules: rules,
    totals: const PlanTotals(
      counts: {SyncActionType.deleteRight: 1},
      bytes: {SyncActionType.deleteRight: 5},
      replacedFiles: 0,
      replacedBytes: 0,
    ),
    warnings: const [
      ScanWarning(
        relativePath: 'locked/',
        side: SyncSide.right,
        message: 'Could not list "locked/"',
      ),
    ],
  );

  Future<SyncRunJournal> writeRun(String runId) async {
    final journal = await SyncRunJournal.create(runsDir.path, record(runId));
    await journal.appendItem(
      const SyncJournalItemLine(
        relativePath: 'd.txt',
        side: SyncSide.right,
        action: SyncActionType.deleteRight,
        outcome: SyncItemStatus.done,
        attempt: 1,
        bytes: 5,
        durationMs: 12,
        trashLocation: '/r/.poltergeist-trash/RUN/000001-d.txt',
        trashBytes: 5,
      ),
    );
    await journal.appendTrash(
      const SyncJournalTrashLine(
        parentPath: 'dir',
        relativePath: 'dir/old.txt',
        side: SyncSide.right,
        trashLocation: '/r/.poltergeist-trash/RUN/000002-old.txt',
        bytes: 7,
      ),
    );
    await journal.appendRmdir(
      const SyncJournalRmdirLine(
        relativePath: 'dir',
        side: SyncSide.right,
        parentPath: 'dir',
      ),
    );
    await journal.appendSummary(
      const SyncJournalSummary(
        counts: {SyncItemStatus.done: 1},
        bytesTransferred: 0,
        cancelled: false,
        mtimeUnreliableLeft: false,
        mtimeUnreliableRight: true,
      ),
    );
    return journal;
  }

  test('replay round-trips every line kind', () async {
    final written = await writeRun('run-1');

    final replayed = await SyncRunJournal.open(written.path);

    expect(replayed.record.runId, 'run-1');
    expect(replayed.record.pairId, 'pair-1');
    expect(replayed.record.rules, rules);
    expect(replayed.record.totals.counts[SyncActionType.deleteRight], 1);
    expect(replayed.record.warnings.single.relativePath, 'locked/');
    expect(replayed.items, hasLength(1));
    final line = replayed.items.single;
    expect(line.relativePath, 'd.txt');
    expect(line.action, SyncActionType.deleteRight);
    expect(line.outcome, SyncItemStatus.done);
    expect(line.attempt, 1);
    expect(line.trashLocation, '/r/.poltergeist-trash/RUN/000001-d.txt');
    expect(line.trashBytes, 5);
    expect(replayed.trashLines.single.relativePath, 'dir/old.txt');
    expect(replayed.rmdirLines.single.relativePath, 'dir');
    expect(replayed.summary!.mtimeUnreliableRight, isTrue);
    expect(replayed.purged, isFalse);
    expect(replayed.hasUnpurgedTrash, isTrue);
  });

  test('a torn final line is dropped on replay', () async {
    final written = await writeRun('run-2');
    // The crash-mid-write tail: valid prefix, truncated line.
    await File(written.path).writeAsString(
      '{"v":1,"type":"item","path":"half-writ',
      mode: FileMode.append,
    );

    final replayed = await SyncRunJournal.open(written.path);

    expect(replayed.items, hasLength(1));
    expect(replayed.summary, isNotNull);
  });

  test('markPurged releases the journal for pruning', () async {
    final written = await writeRun('run-3');
    expect(written.hasUnpurgedTrash, isTrue);

    await written.markPurged();

    final replayed = await SyncRunJournal.open(written.path);
    expect(replayed.purged, isTrue);
    expect(replayed.hasUnpurgedTrash, isFalse);
  });

  test('lastAttempt drives attempt numbering', () async {
    final written = await writeRun('run-4');
    expect(
      written.lastAttempt(
        'd.txt',
        SyncSide.right,
        SyncActionType.deleteRight,
      ),
      1,
    );
    expect(
      written.lastAttempt(
        'other.txt',
        SyncSide.right,
        SyncActionType.deleteRight,
      ),
      0,
    );
  });

  test('prune keeps the newest journals but never live trash', () async {
    // 22 journals for one pair: the oldest two with unpurged trash
    // must survive, the rest prune to the retention count.
    for (var i = 0; i < 22; i++) {
      final journal = await SyncRunJournal.create(
        runsDir.path,
        record(
          'run-$i',
          DateTime.fromMillisecondsSinceEpoch(1700000000000 + i * 1000),
        ),
      );
      if (i < 2) {
        await journal.appendItem(
          SyncJournalItemLine(
            relativePath: 'kept-$i.txt',
            side: SyncSide.right,
            action: SyncActionType.deleteRight,
            outcome: SyncItemStatus.done,
            attempt: 1,
            bytes: 1,
            trashLocation: '/r/.poltergeist-trash/run/000001-kept.txt',
          ),
        );
      }
    }
    expect(runsDir.listSync(), hasLength(22));

    await SyncRunJournal.prune(runsDir.path, 'pair-1', keep: 20);

    final remaining = runsDir
        .listSync()
        .map((e) => remoteBasename(e.path))
        .toList();
    // 20 retained + the 2 live-trash journals the prune refuses.
    expect(remaining, hasLength(20 + 2));
    expect(remaining, containsAll(<String>['run-0.jsonl', 'run-1.jsonl']));
    expect(remaining, contains('run-21.jsonl'));
  });

  test('a journal without a header is refused', () async {
    final bogus = File('${runsDir.path}/bogus.jsonl');
    await bogus.writeAsString('{"v":1,"type":"item","path":"x"}\n');

    await expectLater(
      SyncRunJournal.open(bogus.path),
      throwsA(isA<FormatException>()),
    );
  });
}
