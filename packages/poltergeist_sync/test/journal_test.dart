@TestOn('vm')
library;

import 'dart:io';

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
        kind: ScanWarningKind.listingFailure,
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

  test('an unknown or absent warning kind falls back on replay only',
      () async {
    final written = await writeRun('run-kinds');
    // Forward tolerance: a journal from a newer build whose warning
    // vocabulary has grown must still replay — the informational
    // bucket keeps the line without mistaking it for a listing failure.
    var text = await File(written.path).readAsString();
    text = text.replaceFirst(
      '"kind":"listingFailure"',
      '"kind":"fromAFutureBuild"',
    );
    await File(written.path).writeAsString(text);

    var replayed = await SyncRunJournal.open(written.path);
    expect(
      replayed.record.warnings.single.kind,
      ScanWarningKind.malformedName,
    );

    // Older journals carry no kind at all — same fallback.
    text = await File(written.path).readAsString();
    text = text.replaceFirst(',"kind":"fromAFutureBuild"', '');
    await File(written.path).writeAsString(text);
    replayed = await SyncRunJournal.open(written.path);
    expect(
      replayed.record.warnings.single.kind,
      ScanWarningKind.malformedName,
    );
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
    // 24 journals for one pair: the oldest two with unpurged trash
    // must survive, the rest prune to the retention count — so two
    // unprotected oldest must actually be deleted.
    for (var i = 0; i < 24; i++) {
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
    expect(runsDir.listSync(), hasLength(24));

    await SyncRunJournal.prune(runsDir.path, 'pair-1', keep: 20);

    final remaining = runsDir
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .toList();
    // The prune must actually delete: the two unprotected oldest
    // journals are gone, the newest 20 stay, and the 2 live-trash
    // journals are retained no matter their age.
    expect(remaining, isNot(contains('run-2.jsonl')));
    expect(remaining, isNot(contains('run-3.jsonl')));
    expect(remaining, hasLength(22));
    expect(remaining, containsAll(<String>['run-0.jsonl', 'run-1.jsonl']));
    expect(remaining, contains('run-23.jsonl'));
  });

  test('a journal without a header is refused', () async {
    final bogus = File('${runsDir.path}/bogus.jsonl');
    await bogus.writeAsString('{"v":1,"type":"item","path":"x"}\n');

    await expectLater(
      SyncRunJournal.open(bogus.path),
      throwsA(isA<FormatException>()),
    );
  });

  test('a torn line mid-file is skipped, not truncated at', () async {
    // A kill leaves a torn write; a resumed run then appends *after*
    // it. Replay must keep every later line — lastAttempt, restore
    // lists, and the retention check all depend on them.
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-torn', DateTime.fromMillisecondsSinceEpoch(1700000000000)),
    );
    await journal.appendItem(
      SyncJournalItemLine(
        relativePath: 'before.txt',
        side: SyncSide.right,
        action: SyncActionType.deleteRight,
        outcome: SyncItemStatus.done,
        attempt: 1,
        bytes: 1,
      ),
    );
    // The torn line: a partial write appended mid-file.
    await File(journal.path).writeAsString(
      '{"v":1,"type":"item","path":"to',
      mode: FileMode.append,
    );
    await journal.appendItem(
      SyncJournalItemLine(
        relativePath: 'after.txt',
        side: SyncSide.right,
        action: SyncActionType.deleteRight,
        outcome: SyncItemStatus.failed,
        attempt: 2,
        bytes: 1,
      ),
    );

    final replayed = await SyncRunJournal.open(journal.path);
    expect(replayed.items, hasLength(2));
    expect(
      replayed.lastAttempt(
        'after.txt',
        SyncSide.right,
        SyncActionType.deleteRight,
      ),
      2,
    );
  });

  test('invalid UTF-8 in a torn line does not fail replay', () async {
    // A kill can sever a multi-byte character mid-write; strict
    // decoding would throw before the skip-undecodable logic runs.
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-utf8', DateTime.fromMillisecondsSinceEpoch(1700000000000)),
    );
    await journal.appendItem(
      SyncJournalItemLine(
        relativePath: 'kept.txt',
        side: SyncSide.right,
        action: SyncActionType.deleteRight,
        outcome: SyncItemStatus.done,
        attempt: 1,
        bytes: 1,
      ),
    );
    // Raw invalid bytes mid-file, then a valid record after them —
    // replay must continue past the damage, not just tolerate EOF.
    final file = File(journal.path);
    await file.writeAsBytes([0xFF, 0xFE], mode: FileMode.append);
    await journal.appendItem(
      SyncJournalItemLine(
        relativePath: 'after.txt',
        side: SyncSide.right,
        action: SyncActionType.deleteRight,
        outcome: SyncItemStatus.done,
        attempt: 1,
        bytes: 1,
      ),
    );

    final replayed = await SyncRunJournal.open(journal.path);
    expect(
      replayed.items.map((i) => i.relativePath),
      equals(<String>['kept.txt', 'after.txt']),
    );
  });

  test('a duplicate header line is refused', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-dup', DateTime.fromMillisecondsSinceEpoch(1700000000000)),
    );
    // A second header must not silently discard what replay already
    // gathered. (Blank lines pad the file — find the real header.)
    final lines = await File(journal.path).readAsLines();
    final header = lines.firstWhere((l) => l.trim().isNotEmpty);
    await File(journal.path).writeAsString(
      '$header\n',
      mode: FileMode.append,
    );

    await expectLater(
      SyncRunJournal.open(journal.path),
      throwsA(isA<FormatException>()),
    );
  });

  test('a path-unsafe runId is refused at create', () async {
    await expectLater(
      SyncRunJournal.create(
        runsDir.path,
        record(
          '../escape',
          DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
