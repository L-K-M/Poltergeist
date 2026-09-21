@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

/// A LocalFileSystem whose setTimes is silently ignored — the
/// setstat-ignoring server shape (05 §4: clamp, never error).
final class _SetTimesIgnoringFs extends LocalFileSystem {
  @override
  Future<void> setTimes(
    String path, {
    DateTime? accessedAt,
    DateTime? modifiedAt,
  }) async {}
}

/// A LocalFileSystem whose renames into the trash root throw
/// EXDEV — the cross-filesystem trash move shape (05 §8 rail 5's
/// local fallback trigger).
final class _ExdevTrashFs extends LocalFileSystem {
  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) {
    if (newPath.contains(RemoteTrash.rootDirectoryName)) {
      throw LocalCrossDeviceRenameException(
        path: oldPath,
        newPath: newPath,
      );
    }
    return super.rename(oldPath, newPath, overwrite: overwrite);
  }
}

/// Basename that works on listed local entities — `remoteBasename`
/// only splits POSIX separators, so it returns the whole path for a
/// Windows `entity.path`.
String entityName(FileSystemEntity entity) =>
    entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);

void main() {
  const deviceId = 'test-device';
  const pairId = 'pair-under-test';

  late LocalFileSystem leftFs;
  late LocalFileSystem rightFs;
  late Directory leftRoot;
  late Directory rightRoot;
  late Directory runsDir;
  late SyncExecutor executor;

  setUp(() async {
    leftFs = LocalFileSystem();
    rightFs = LocalFileSystem();
    leftRoot = await Directory.systemTemp.createTemp('poltergeist-exec-l-');
    rightRoot = await Directory.systemTemp.createTemp('poltergeist-exec-r-');
    runsDir = await Directory.systemTemp.createTemp('poltergeist-runs-');
    executor = SyncExecutor(
      leftFileSystem: leftFs,
      rightFileSystem: rightFs,
      leftRoot: leftRoot.path,
      rightRoot: rightRoot.path,
      syncRunsDirectory: runsDir.path,
      deviceId: deviceId,
    );
  });

  tearDown(() async {
    for (final dir in [leftRoot, rightRoot, runsDir]) {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  // ── Fixtures ─────────────────────────────────────────────────────────

  Future<File> writeFile(
    Directory root,
    String rel,
    String content, {
    int? mtimeSecs,
  }) async {
    final file = File(remoteJoin(root.path, rel));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    if (mtimeSecs != null) {
      await file.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(mtimeSecs * 1000),
      );
    }
    return file;
  }

  Future<EntrySnapshot> snapOf(Directory root, String rel) async {
    final stat = await FileStat.stat(remoteJoin(root.path, rel));
    return EntrySnapshot(
      kind: switch (stat.type) {
        FileSystemEntityType.file => EntryKind.file,
        FileSystemEntityType.directory => EntryKind.directory,
        FileSystemEntityType.link => EntryKind.symlink,
        _ => EntryKind.other,
      },
      size: stat.size,
      mtimeSecs: stat.modified.millisecondsSinceEpoch ~/ 1000,
    );
  }

  Future<Map<String, EntrySnapshot>> subtreeOf(
    Directory root,
    String rel,
  ) async {
    final entries = <String, EntrySnapshot>{};
    Future<void> walk(String abs, String relBase) async {
      for (final entity in Directory(abs).listSync()) {
        final name = entityName(entity);
        final relative = '$relBase/$name';
        entries[relative] = await snapOf(root, relative);
        if (entity is Directory) await walk(entity.path, relative);
      }
    }

    await walk(remoteJoin(root.path, rel), rel);
    return entries;
  }

  SyncItem item(
    String rel, {
    EntrySnapshot? left,
    EntrySnapshot? right,
    SyncActionType? suggested,
    SyncActionType? effective,
    SyncReason reason = SyncReason.onlyOnLeft,
    Map<String, EntrySnapshot>? destinationSubtree,
  }) => SyncItem(
    relativePath: rel,
    left: left,
    right: right,
    suggested: suggested ?? SyncActionType.copyLeftToRight,
    effective: effective ?? suggested ?? SyncActionType.copyLeftToRight,
    reason: reason,
    destinationSubtree: destinationSubtree,
  );

  SyncPlan makePlan(
    List<SyncItem> items,
    SyncRuleSet rules, {
    int? leftFileCount,
    int? rightFileCount,
  }) => SyncPlan(
    pair: SyncPair(
      id: 'pair-1',
      name: 'test pair',
      left: LocalEndpoint(leftRoot.path),
      right: LocalEndpoint(rightRoot.path),
      rules: rules,
    ),
    scannedAt: DateTime.now(),
    items: items,
    warnings: const [],
    totals: const PlanTotals(
      counts: {},
      bytes: {},
      replacedFiles: 0,
      replacedBytes: 0,
    ),
    leftFileCount: leftFileCount,
    rightFileCount: rightFileCount,
  );

  const updateRules = SyncRuleSet(
    direction: SyncDirection.leftToRight,
    deletions: DeletionPolicy.none,
    backups: BackupPolicy.trash,
  );

  SyncRuleSet mirrorRules({
    DeletionPolicy deletions = DeletionPolicy.trash,
    int maxDelete = 500,
    double deleteFractionWarn = 0.5,
  }) => SyncRuleSet(
    direction: SyncDirection.leftToRight,
    deletions: deletions,
    backups: BackupPolicy.trash,
    maxDelete: maxDelete,
    deleteFractionWarn: deleteFractionWarn,
  );

  const additiveRules = SyncRuleSet(
    direction: SyncDirection.bidirectional,
    deletions: DeletionPolicy.none,
    backups: BackupPolicy.trash,
  );

  SyncItem? find(SyncPlan plan, String rel) {
    for (final i in plan.items) {
      if (i.relativePath == rel) return i;
    }
    return null;
  }

  /// The D15 name (seq-basename) of [rel]'s trashed copy under [root]'s
  /// default in-root trash for [runId], if present.
  File? trashedFile(Directory root, String runId, String name) {
    final dir = Directory(
      remoteJoin(
        remoteJoin(root.path, RemoteTrash.rootDirectoryName),
        runId,
      ),
    );
    if (!dir.existsSync()) return null;
    for (final entity in dir.listSync()) {
      if (entity is File && entityName(entity).endsWith('-$name')) {
        return entity;
      }
    }
    return null;
  }

  // ── Three modes ──────────────────────────────────────────────────────

  group('modes', () {
    test('Update copies new files and backs up overwrites to trash',
        () async {
      await writeFile(leftRoot, 'new.txt', 'new-content', mtimeSecs: 1600000000);
      await writeFile(leftRoot, 'changed.txt', 'new-version', mtimeSecs: 1600000000);
      await writeFile(rightRoot, 'changed.txt', 'old-version');

      final plan = makePlan([
        item(
          'new.txt',
          left: await snapOf(leftRoot, 'new.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
        item(
          'changed.txt',
          left: await snapOf(leftRoot, 'changed.txt'),
          right: await snapOf(rightRoot, 'changed.txt'),
          suggested: SyncActionType.updateLeftToRight,
          reason: SyncReason.sizeDiffers,
        ),
      ], updateRules);

      final run = await executor.run(plan, pairId: pairId);

      expect(await File('${rightRoot.path}/new.txt').readAsString(),
          'new-content');
      expect(await File('${rightRoot.path}/changed.txt').readAsString(),
          'new-version');
      // The overwritten version went to trash (D15 flat name), not
      // deleted.
      final backup = trashedFile(rightRoot, run.runId, 'changed.txt');
      expect(backup, isNotNull);
      expect(await backup!.readAsString(), 'old-version');
      expect(find(plan, 'new.txt')!.status, SyncItemStatus.done);
      expect(find(plan, 'changed.txt')!.status, SyncItemStatus.done);
      // The journal item line carries the backup's origin map.
      final line = run.journal.items.singleWhere(
        (l) => l.relativePath == 'changed.txt',
      );
      // trashLocation is a VFS path — built with remoteJoin, so its
      // separators match however the executor joined it.
      expect(
        line.trashLocation,
        remoteJoin(
          remoteJoin(
            remoteJoin(rightRoot.path, RemoteTrash.rootDirectoryName),
            run.runId,
          ),
          '000001-changed.txt',
        ),
      );
      expect(line.trashBytes, 'old-version'.length);
    });

    test('Mirror deletes destination extras into trash', () async {
      await writeFile(rightRoot, 'orphan.txt', 'orphan');

      final plan = makePlan([
        item(
          'orphan.txt',
          right: await snapOf(rightRoot, 'orphan.txt'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
      ], mirrorRules());

      final run = await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      expect(File('${rightRoot.path}/orphan.txt').existsSync(), isFalse);
      final trashed = trashedFile(rightRoot, run.runId, 'orphan.txt');
      expect(trashed, isNotNull);
      expect(await trashed!.readAsString(), 'orphan');
      expect(find(plan, 'orphan.txt')!.status, SyncItemStatus.done);
    });

    test('Mirror with permanent deletion removes without trash',
        () async {
      await writeFile(rightRoot, 'orphan.txt', 'orphan');

      final plan = makePlan([
        item(
          'orphan.txt',
          right: await snapOf(rightRoot, 'orphan.txt'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
      ], mirrorRules(deletions: DeletionPolicy.permanent));

      await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      expect(File('${rightRoot.path}/orphan.txt').existsSync(), isFalse);
      expect(
        Directory('${rightRoot.path}/${RemoteTrash.rootDirectoryName}')
            .existsSync(),
        isFalse,
      );
    });

    test('Additive two-way copies both directions, deletes nothing',
        () async {
      await writeFile(leftRoot, 'a.txt', 'on-left', mtimeSecs: 1600000000);
      await writeFile(rightRoot, 'b.txt', 'on-right', mtimeSecs: 1600000000);

      final plan = makePlan([
        item(
          'a.txt',
          left: await snapOf(leftRoot, 'a.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
        item(
          'b.txt',
          right: await snapOf(rightRoot, 'b.txt'),
          suggested: SyncActionType.copyRightToLeft,
          reason: SyncReason.onlyOnRight,
        ),
      ], additiveRules);

      await executor.run(plan, pairId: pairId);

      expect(await File('${rightRoot.path}/a.txt').readAsString(), 'on-left');
      expect(await File('${leftRoot.path}/b.txt').readAsString(), 'on-right');
    });

    test('a delete item inside a no-delete plan fails loudly', () async {
      await writeFile(rightRoot, 'orphan.txt', 'orphan');

      final plan = makePlan([
        item(
          'orphan.txt',
          right: await snapOf(rightRoot, 'orphan.txt'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
      ], updateRules);

      await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      final failed = find(plan, 'orphan.txt')!;
      expect(failed.status, SyncItemStatus.failed);
      expect(File('${rightRoot.path}/orphan.txt').existsSync(), isTrue);
    });
  });

  // ── Safety rails ─────────────────────────────────────────────────────

  group('safety rails', () {
    test('maxDelete refuses the whole run before any item executes',
        () async {
      for (var i = 0; i < 3; i++) {
        await writeFile(rightRoot, 'f$i.txt', 'x$i');
      }
      final plan = makePlan([
        for (var i = 0; i < 3; i++)
          item(
            'f$i.txt',
            right: await snapOf(rightRoot, 'f$i.txt'),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
      ], mirrorRules(maxDelete: 2));

      await expectLater(
        executor.run(plan, pairId: pairId),
        throwsA(isA<SyncRunRefusedException>()),
      );
      // Nothing executed — and nothing was journaled.
      expect(await File('${rightRoot.path}/f0.txt').exists(), isTrue);
      expect(await File('${rightRoot.path}/f2.txt').exists(), isTrue);
      expect(runsDir.listSync(), isEmpty);
    });

    test('rail 3 fraction clause demands typed confirmation with data',
        () async {
      // 11 of 20 deletions: > 50 % and >= 10 — the fraction clause.
      for (var i = 0; i < 20; i++) {
        await writeFile(rightRoot, 'f$i.txt', 'x$i');
      }
      final plan = makePlan([
        for (var i = 0; i < 11; i++)
          item(
            'f$i.txt',
            right: await snapOf(rightRoot, 'f$i.txt'),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
      ], mirrorRules(), rightFileCount: 20);

      final gate = assessDeletions(plan).gate;
      expect(gate, isA<SyncRunNeedsConfirmation>());
      final confirm = gate as SyncRunNeedsConfirmation;
      expect(confirm.clause, DeleteRailClause.fraction);
      expect(confirm.deleteCount, 11);
      expect(confirm.sideFileCount, 20);
      expect(confirm.side, SyncSide.right);

      await expectLater(
        executor.run(plan, pairId: pairId),
        throwsA(isA<SyncConfirmationRequiredException>()),
      );
      // Refused until the typed DELETE arrives — files untouched.
      expect(await File('${rightRoot.path}/f0.txt').exists(), isTrue);

      final run = await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );
      expect(await File('${rightRoot.path}/f0.txt').exists(), isFalse);
      expect(run.journal.items, hasLength(11));
    });

    test('rail 3 floor clause wins at any count (>=90% of the side)',
        () async {
      for (var i = 0; i < 3; i++) {
        await writeFile(rightRoot, 'f$i.txt', 'x$i');
      }
      final plan = makePlan([
        for (var i = 0; i < 3; i++)
          item(
            'f$i.txt',
            right: await snapOf(rightRoot, 'f$i.txt'),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
      ], mirrorRules());

      final gate = assessDeletions(plan).gate;
      expect(gate, isA<SyncRunNeedsConfirmation>());
      expect((gate as SyncRunNeedsConfirmation).clause,
          DeleteRailClause.floor90);
    });

    test('near-misses stay clear: exactly 50% and <90%/<10', () async {
      for (var i = 0; i < 20; i++) {
        await writeFile(rightRoot, 'f$i.txt', 'x$i');
      }
      final exactHalf = makePlan([
        for (var i = 0; i < 10; i++)
          item(
            'f$i.txt',
            right: await snapOf(rightRoot, 'f$i.txt'),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
      ], mirrorRules(), rightFileCount: 20);
      // 10 of 20 is exactly 50 % — not *more than* 50 %.
      expect(assessDeletions(exactHalf).gate, isA<SyncRunClear>());

      final smallShare = makePlan([
        for (var i = 0; i < 5; i++)
          item(
            'f$i.txt',
            right: await snapOf(rightRoot, 'f$i.txt'),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
      ], mirrorRules(), rightFileCount: 20);
      // 5 of 20 is 25 % — under both clauses.
      expect(assessDeletions(smallShare).gate, isA<SyncRunClear>());
    });
  });

  // ── Rail-7 preconditions ─────────────────────────────────────────────

  group('preconditions', () {
    test('destination changed since preview flips to conflicted',
        () async {
      await writeFile(leftRoot, 'f.txt', 'new', mtimeSecs: 1600000000);
      await writeFile(rightRoot, 'f.txt', 'old');
      final plan = makePlan([
        item(
          'f.txt',
          left: await snapOf(leftRoot, 'f.txt'),
          right: await snapOf(rightRoot, 'f.txt'),
          suggested: SyncActionType.updateLeftToRight,
          reason: SyncReason.sizeDiffers,
        ),
      ], updateRules);
      // Foreign change after the preview.
      await writeFile(rightRoot, 'f.txt', 'foreign-write');

      await executor.run(plan, pairId: pairId);

      final i = find(plan, 'f.txt')!;
      expect(i.status, SyncItemStatus.conflicted);
      expect(await File('${rightRoot.path}/f.txt').readAsString(),
          'foreign-write');
      // Nothing was backed up — the item never executed.
      expect(
        Directory('${rightRoot.path}/${RemoteTrash.rootDirectoryName}')
            .existsSync(),
        isFalse,
      );
    });

    test('copy-new target that appeared since preview conflicts',
        () async {
      await writeFile(leftRoot, 'n.txt', 'new', mtimeSecs: 1600000000);
      final plan = makePlan([
        item(
          'n.txt',
          left: await snapOf(leftRoot, 'n.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
      ], updateRules);
      await writeFile(rightRoot, 'n.txt', 'foreign');

      await executor.run(plan, pairId: pairId);

      expect(find(plan, 'n.txt')!.status, SyncItemStatus.conflicted);
      expect(
        await File('${rightRoot.path}/n.txt').readAsString(),
        'foreign',
      );
    });

    test('source vanished mid-run fails only that item', () async {
      await writeFile(leftRoot, 'ok.txt', 'fine', mtimeSecs: 1600000000);
      await writeFile(leftRoot, 'gone.txt', 'temp', mtimeSecs: 1600000000);
      final plan = makePlan([
        item(
          'ok.txt',
          left: await snapOf(leftRoot, 'ok.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
        item(
          'gone.txt',
          left: await snapOf(leftRoot, 'gone.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
      ], updateRules);
      await File('${leftRoot.path}/gone.txt').delete();

      await executor.run(plan, pairId: pairId);

      expect(find(plan, 'ok.txt')!.status, SyncItemStatus.done);
      expect(find(plan, 'gone.txt')!.status, SyncItemStatus.failed);
      expect(await File('${rightRoot.path}/ok.txt').readAsString(), 'fine');
    });

    test('a conflicted copy item gates the delete phase', () async {
      await writeFile(leftRoot, 'f.txt', 'new', mtimeSecs: 1600000000);
      await writeFile(rightRoot, 'f.txt', 'old');
      await writeFile(rightRoot, 'orphan.txt', 'orphan');
      final plan = makePlan([
        item(
          'f.txt',
          left: await snapOf(leftRoot, 'f.txt'),
          right: await snapOf(rightRoot, 'f.txt'),
          suggested: SyncActionType.updateLeftToRight,
          reason: SyncReason.sizeDiffers,
        ),
        item(
          'orphan.txt',
          right: await snapOf(rightRoot, 'orphan.txt'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
      ], mirrorRules());
      await writeFile(rightRoot, 'f.txt', 'foreign');

      await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      expect(find(plan, 'f.txt')!.status, SyncItemStatus.conflicted);
      final orphan = find(plan, 'orphan.txt')!;
      expect(orphan.status, SyncItemStatus.skipped);
      expect(orphan.error, contains('earlier errors'));
      // Rail 7/§6: the delete phase never ran — the file survives.
      expect(await File('${rightRoot.path}/orphan.txt').readAsString(),
          'orphan');
    });
  });

  // ── Execution semantics ──────────────────────────────────────────────

  group('execution', () {
    test('mkdir phase creates parents shallowest-first', () async {
      await writeFile(leftRoot, 'a/b/f.txt', 'deep', mtimeSecs: 1600000000);
      final plan = makePlan([
        item('a', suggested: SyncActionType.makeDirRight),
        item('a/b', suggested: SyncActionType.makeDirRight),
        item(
          'a/b/f.txt',
          left: await snapOf(leftRoot, 'a/b/f.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
      ], updateRules);

      await executor.run(plan, pairId: pairId);

      expect(Directory('${rightRoot.path}/a/b').existsSync(), isTrue);
      expect(await File('${rightRoot.path}/a/b/f.txt').readAsString(),
          'deep');
    });

    test('delete phase empties children then rmdirs the parent',
        () async {
      await writeFile(rightRoot, 'dir/a.txt', 'inside');
      final plan = makePlan([
        item(
          'dir/a.txt',
          right: await snapOf(rightRoot, 'dir/a.txt'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
        item(
          'dir',
          right: await snapOf(rightRoot, 'dir'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
      ], mirrorRules());

      await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      expect(Directory('${rightRoot.path}/dir').existsSync(), isFalse);
      expect(find(plan, 'dir/a.txt')!.status, SyncItemStatus.done);
      expect(find(plan, 'dir')!.status, SyncItemStatus.done);
    });

    test('copies preserve mtime through setTimes', () async {
      const sourceSecs = 1577936400; // 2020-01-02T01:00:00Z
      await writeFile(leftRoot, 'f.txt', 'payload', mtimeSecs: sourceSecs);
      final plan = makePlan([
        item(
          'f.txt',
          left: await snapOf(leftRoot, 'f.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
      ], updateRules);

      final run = await executor.run(plan, pairId: pairId);

      final dest = await FileStat.stat('${rightRoot.path}/f.txt');
      expect(dest.modified.millisecondsSinceEpoch ~/ 1000, sourceSecs);
      expect(
        run.journal.items.single.observedMtimeAfterWrite,
        sourceSecs,
      );
      expect(run.journal.items.single.setstatIgnored, isFalse);
    });

    test('a setstat-ignoring destination flags the side unreliable',
        () async {
      final ignoring = SyncExecutor(
        leftFileSystem: leftFs,
        rightFileSystem: _SetTimesIgnoringFs(),
        leftRoot: leftRoot.path,
        rightRoot: rightRoot.path,
        syncRunsDirectory: runsDir.path,
        deviceId: deviceId,
      );
      await writeFile(leftRoot, 'f.txt', 'payload', mtimeSecs: 1577936400);
      final plan = makePlan([
        item(
          'f.txt',
          left: await snapOf(leftRoot, 'f.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
      ], updateRules);

      final run = await ignoring.run(plan, pairId: pairId);

      expect(ignoring.mtimeUnreliableRight, isTrue);
      expect(ignoring.mtimeUnreliableLeft, isFalse);
      expect(run.journal.items.single.setstatIgnored, isTrue);
      expect(run.journal.summary!.mtimeUnreliableRight, isTrue);
      expect(find(plan, 'f.txt')!.status, SyncItemStatus.done);
    });

    test('EXDEV on a trash rename falls back to copy-then-delete',
        () async {
      final exdev = SyncExecutor(
        leftFileSystem: leftFs,
        rightFileSystem: _ExdevTrashFs(),
        leftRoot: leftRoot.path,
        rightRoot: rightRoot.path,
        syncRunsDirectory: runsDir.path,
        deviceId: deviceId,
      );
      await writeFile(rightRoot, 'orphan.txt', 'orphan-content');
      final plan = makePlan([
        item(
          'orphan.txt',
          right: await snapOf(rightRoot, 'orphan.txt'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
      ], mirrorRules());

      final run = await exdev.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      expect(find(plan, 'orphan.txt')!.status, SyncItemStatus.done);
      expect(File('${rightRoot.path}/orphan.txt').existsSync(), isFalse);
      final trashed = trashedFile(rightRoot, run.runId, 'orphan.txt');
      expect(trashed, isNotNull);
      expect(await trashed!.readAsString(), 'orphan-content');
      // Copy-fallback entries journal their digest for rail-9 verify.
      final line = run.journal.items.single;
      expect(
        line.trashLocation,
        remoteJoin(
          remoteJoin(
            remoteJoin(rightRoot.path, RemoteTrash.rootDirectoryName),
            run.runId,
          ),
          '000002-orphan.txt',
        ),
      );
      expect(line.trashContentSha256, isNotNull);
      expect(
        line.trashContentSha256,
        sha256.convert(utf8.encode('orphan-content')).toString(),
      );
    });

    test('trash uses D15 flat names inside <runId>', () async {
      await writeFile(rightRoot, 'one.txt', '1');
      await writeFile(rightRoot, 'sub/two.txt', '2');
      final plan = makePlan([
        item(
          'one.txt',
          right: await snapOf(rightRoot, 'one.txt'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
        item(
          'sub/two.txt',
          right: await snapOf(rightRoot, 'sub/two.txt'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
      ], mirrorRules());

      final run = await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );
      final prefix = sha256
          .convert(utf8.encode(deviceId))
          .toString()
          .substring(0, 8);
      expect(run.runId.startsWith('$prefix-'), isTrue);

      final trashDir = Directory(
        remoteJoin(
          remoteJoin(rightRoot.path, RemoteTrash.rootDirectoryName),
          run.runId,
        ),
      );
      final names = trashDir
          .listSync()
          .map((e) => entityName(e))
          .toList();
      // Flat entries, seq-prefixed in delete order (deepest-first —
      // the child moves before its parent dir is touched), with no
      // nested original structure.
      expect(names, containsAll(<String>['000001-two.txt', '000002-one.txt']));
      expect(Directory('${trashDir.path}/sub').existsSync(), isFalse);
    });

    test('out-of-root trashPath lands under <configured>/<runId>',
        () async {
      final outTrash = await Directory.systemTemp.createTemp('poltergeist-out-');
      addTearDown(() => outTrash.delete(recursive: true));
      await writeFile(rightRoot, 'orphan.txt', 'orphan');
      final rules = SyncRuleSet(
        direction: SyncDirection.leftToRight,
        deletions: DeletionPolicy.trash,
        trashPathRight: remoteJoin(outTrash.path, 'trash-root'),
      );
      final plan = makePlan([
        item(
          'orphan.txt',
          right: await snapOf(rightRoot, 'orphan.txt'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
      ], rules);

      final run = await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      expect(
        File(
          remoteJoin(
            remoteJoin(outTrash.path, 'trash-root'),
            '${run.runId}/000001-orphan.txt',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(
        Directory('${rightRoot.path}/${RemoteTrash.rootDirectoryName}')
            .existsSync(),
        isFalse,
      );
    });

    test('progress events bracket every item and the run', () async {
      await writeFile(leftRoot, 'f.txt', 'payload', mtimeSecs: 1600000000);
      final plan = makePlan([
        item(
          'f.txt',
          left: await snapOf(leftRoot, 'f.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
      ], updateRules);
      final events = <SyncRunEvent>[];

      await executor.run(
        plan,
        pairId: pairId,
        onEvent: events.add,
      );

      expect(
        events.map((e) => e.kind),
        containsAllInOrder([
          SyncRunEvent.itemStarted,
          SyncRunEvent.itemFinished,
          SyncRunEvent.runFinished,
        ]),
      );
      expect(
        events
            .firstWhere((e) => e.kind == SyncRunEvent.itemStarted)
            .item!
            .relativePath,
        'f.txt',
      );
    });

    test('typeDiffers dir->file replace trashes the subtree and journals'
        ' every removed file', () async {
      await writeFile(leftRoot, 'dir', 'now-a-file', mtimeSecs: 1600000000);
      await writeFile(rightRoot, 'dir/a.txt', 'old-a');
      await writeFile(rightRoot, 'dir/sub/b.txt', 'old-b');
      final subtree = await subtreeOf(rightRoot, 'dir');
      final plan = makePlan([
        item(
          'dir',
          left: await snapOf(leftRoot, 'dir'),
          right: await snapOf(rightRoot, 'dir'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.typeDiffers,
          destinationSubtree: subtree,
        ),
      ], updateRules);

      final run = await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      expect(find(plan, 'dir')!.status, SyncItemStatus.done);
      expect(await File('${rightRoot.path}/dir').readAsString(), 'now-a-file');
      // Every removed file got its own trash line under the parent.
      expect(
        run.journal.trashLines.map((l) => l.relativePath),
        containsAll(<String>['dir/a.txt', 'dir/sub/b.txt']),
      );
      expect(
        run.journal.trashLines.every((l) => l.parentPath == 'dir'),
        isTrue,
      );
      // And rmdir lines for the emptied tree.
      expect(
        run.journal.rmdirLines.map((l) => l.relativePath),
        containsAll(<String>['dir/sub', 'dir']),
      );
      expect(trashedFile(rightRoot, run.runId, 'a.txt'), isNotNull);
      expect(trashedFile(rightRoot, run.runId, 'b.txt'), isNotNull);
    });

    test('a changed subtree aborts the whole replace', () async {
      await writeFile(leftRoot, 'dir', 'now-a-file', mtimeSecs: 1600000000);
      await writeFile(rightRoot, 'dir/a.txt', 'old-a');
      final subtree = await subtreeOf(rightRoot, 'dir');
      final plan = makePlan([
        item(
          'dir',
          left: await snapOf(leftRoot, 'dir'),
          right: await snapOf(rightRoot, 'dir'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.typeDiffers,
          destinationSubtree: subtree,
        ),
      ], updateRules);
      // Foreign change under the doomed directory.
      await writeFile(rightRoot, 'dir/new-foreign.txt', 'foreign');

      await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      expect(find(plan, 'dir')!.status, SyncItemStatus.conflicted);
      expect(Directory('${rightRoot.path}/dir').existsSync(), isTrue);
      expect(await File('${rightRoot.path}/dir/a.txt').readAsString(), 'old-a');
    });
  });

  // ── Retry Failed ─────────────────────────────────────────────────────

  group('retry failed', () {
    test('re-runs only failed items, journaling attempt n+1', () async {
      await writeFile(leftRoot, 'ok.txt', 'fine', mtimeSecs: 1600000000);
      await writeFile(leftRoot, 'late.txt', 'temp', mtimeSecs: 1600000000);
      final plan = makePlan([
        item(
          'ok.txt',
          left: await snapOf(leftRoot, 'ok.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
        item(
          'late.txt',
          left: await snapOf(leftRoot, 'late.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
      ], updateRules);
      await File('${leftRoot.path}/late.txt').delete();

      final first = await executor.run(plan, pairId: pairId);
      expect(find(plan, 'late.txt')!.status, SyncItemStatus.failed);
      final linesAfterFirst = first.journal.items.length;

      // The source returns — Retry Failed re-runs just the failed item.
      await writeFile(leftRoot, 'late.txt', 'temp', mtimeSecs: 1600000000);
      final second = await executor.retryFailed(first);

      expect(find(plan, 'late.txt')!.status, SyncItemStatus.done);
      expect(
        await File('${rightRoot.path}/late.txt').readAsString(),
        'temp',
      );
      // One new line — the retry at attempt 2; the already-done item
      // was not re-executed or re-journaled.
      expect(second.journal.items.length, linesAfterFirst + 1);
      final retryLine = second.journal.items.last;
      expect(retryLine.relativePath, 'late.txt');
      expect(retryLine.attempt, 2);
      // Same runId — retry never forks the run's history.
      expect(second.runId, first.runId);
    });

    test('a retry whose source changed flips to conflicted', () async {
      await writeFile(leftRoot, 'f.txt', 'first', mtimeSecs: 1600000000);
      final plan = makePlan([
        item(
          'f.txt',
          left: await snapOf(leftRoot, 'f.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
      ], updateRules);
      await File('${leftRoot.path}/f.txt').delete();
      final first = await executor.run(plan, pairId: pairId);
      expect(find(plan, 'f.txt')!.status, SyncItemStatus.failed);

      // A different file under the same name — never pushed
      // un-previewed.
      await writeFile(leftRoot, 'f.txt', 'different-size-content');
      await executor.retryFailed(first);

      expect(find(plan, 'f.txt')!.status, SyncItemStatus.conflicted);
    });
  });

  // ── Restore Trashed Files ────────────────────────────────────────────

  group('restore trashed files', () {
    test('a trashed delete restores to its origin', () async {
      await writeFile(rightRoot, 'd.txt', 'deleted-content');
      final plan = makePlan([
        item(
          'd.txt',
          right: await snapOf(rightRoot, 'd.txt'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
      ], mirrorRules());
      final run = await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );
      expect(File('${rightRoot.path}/d.txt').existsSync(), isFalse);

      final report = await restoreTrashedFiles(
        run.journal,
        fsFor: (side) => side == SyncSide.left ? leftFs : rightFs,
        rootFor: (side) =>
            side == SyncSide.left ? leftRoot.path : rightRoot.path,
      );

      expect(report.skipped, isEmpty);
      expect(report.restored, ['d.txt']);
      expect(
        await File('${rightRoot.path}/d.txt').readAsString(),
        'deleted-content',
      );
      // The trash entry moved back — no lingering copy.
      expect(
        trashedFile(rightRoot, run.runId, 'd.txt'),
        isNull,
      );
    });

    test('an update backup restores the pre-run version', () async {
      await writeFile(leftRoot, 'f.txt', 'new-version', mtimeSecs: 1600000000);
      await writeFile(rightRoot, 'f.txt', 'old-version');
      final plan = makePlan([
        item(
          'f.txt',
          left: await snapOf(leftRoot, 'f.txt'),
          right: await snapOf(rightRoot, 'f.txt'),
          suggested: SyncActionType.updateLeftToRight,
          reason: SyncReason.sizeDiffers,
        ),
      ], updateRules);
      final run = await executor.run(plan, pairId: pairId);
      expect(
        await File('${rightRoot.path}/f.txt').readAsString(),
        'new-version',
      );

      final report = await restoreTrashedFiles(
        run.journal,
        fsFor: (side) => side == SyncSide.left ? leftFs : rightFs,
        rootFor: (side) =>
            side == SyncSide.left ? leftRoot.path : rightRoot.path,
      );

      expect(report.skipped, isEmpty);
      expect(
        await File('${rightRoot.path}/f.txt').readAsString(),
        'old-version',
      );
    });

    test('a post-state change skips the entry instead of overwriting',
        () async {
      await writeFile(leftRoot, 'f.txt', 'new-version', mtimeSecs: 1600000000);
      await writeFile(rightRoot, 'f.txt', 'old-version');
      final plan = makePlan([
        item(
          'f.txt',
          left: await snapOf(leftRoot, 'f.txt'),
          right: await snapOf(rightRoot, 'f.txt'),
          suggested: SyncActionType.updateLeftToRight,
          reason: SyncReason.sizeDiffers,
        ),
      ], updateRules);
      final run = await executor.run(plan, pairId: pairId);
      // User edited the synced file after the run — post-state diverged.
      await writeFile(rightRoot, 'f.txt', 'user-edit-after');

      final report = await restoreTrashedFiles(
        run.journal,
        fsFor: (side) => side == SyncSide.left ? leftFs : rightFs,
        rootFor: (side) =>
            side == SyncSide.left ? leftRoot.path : rightRoot.path,
      );

      expect(report.restored, isEmpty);
      expect(report.skipped, hasLength(1));
      expect(
        await File('${rightRoot.path}/f.txt').readAsString(),
        'user-edit-after',
      );
    });

    test('a recreated origin is never overwritten by restore', () async {
      await writeFile(rightRoot, 'd.txt', 'deleted');
      final plan = makePlan([
        item(
          'd.txt',
          right: await snapOf(rightRoot, 'd.txt'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
      ], mirrorRules());
      final run = await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );
      // New work arrived where the deletion used to be.
      await writeFile(rightRoot, 'd.txt', 'recreated');

      final report = await restoreTrashedFiles(
        run.journal,
        fsFor: (side) => side == SyncSide.left ? leftFs : rightFs,
        rootFor: (side) =>
            side == SyncSide.left ? leftRoot.path : rightRoot.path,
      );

      expect(report.restored, isEmpty);
      expect(report.skipped, hasLength(1));
      expect(
        await File('${rightRoot.path}/d.txt').readAsString(),
        'recreated',
      );
    });

    test('a dir->file replace reverts the whole recorded set', () async {
      await writeFile(leftRoot, 'dir', 'now-a-file', mtimeSecs: 1600000000);
      await writeFile(rightRoot, 'dir/a.txt', 'old-a');
      await writeFile(rightRoot, 'dir/sub/b.txt', 'old-b');
      final subtree = await subtreeOf(rightRoot, 'dir');
      final plan = makePlan([
        item(
          'dir',
          left: await snapOf(leftRoot, 'dir'),
          right: await snapOf(rightRoot, 'dir'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.typeDiffers,
          destinationSubtree: subtree,
        ),
      ], updateRules);
      final run = await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );
      expect(
        await File('${rightRoot.path}/dir').readAsString(),
        'now-a-file',
      );

      final report = await restoreTrashedFiles(
        run.journal,
        fsFor: (side) => side == SyncSide.left ? leftFs : rightFs,
        rootFor: (side) =>
            side == SyncSide.left ? leftRoot.path : rightRoot.path,
      );

      expect(report.skipped, isEmpty);
      expect(
        report.restored,
        containsAll(<String>['dir/a.txt', 'dir/sub/b.txt']),
      );
      // The run's created file is gone, the original tree is back.
      expect(Directory('${rightRoot.path}/dir').existsSync(), isTrue);
      expect(
        await File('${rightRoot.path}/dir/a.txt').readAsString(),
        'old-a',
      );
      expect(
        await File('${rightRoot.path}/dir/sub/b.txt').readAsString(),
        'old-b',
      );
    });
  });
}
