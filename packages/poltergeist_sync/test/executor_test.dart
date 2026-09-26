@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

/// A LocalFileSystem whose clock is scriptable: [reportedMtime] wins
/// over the real file's stat, and setTimes records its request into
/// [requestedMtime] (feeding reportedMtime so a verifying re-stat sees
/// the stamp). Lets tests exercise mtimes the host filesystem cannot
/// store — e.g. pre-epoch stamps dart:io's setLastModified rejects.
final class _FakeClockFs extends LocalFileSystem {
  final Map<String, DateTime> reportedMtime = {};
  final Map<String, DateTime?> requestedMtime = {};

  @override
  Future<RemoteFileEntry> stat(
    String path, {
    bool followLinks = true,
  }) async {
    final entry = await super.stat(path, followLinks: followLinks);
    final fake = reportedMtime[path];
    if (fake == null) return entry;
    return RemoteFileEntry(
      path: entry.path,
      name: entry.name,
      type: entry.type,
      size: entry.size,
      uid: entry.uid,
      gid: entry.gid,
      accessedAt: entry.accessedAt,
      modifiedAt: fake,
      contentSha256: entry.contentSha256,
      mode: entry.mode,
    );
  }

  @override
  Future<void> setTimes(
    String path, {
    DateTime? accessedAt,
    DateTime? modifiedAt,
  }) async {
    requestedMtime[path] = modifiedAt;
    if (modifiedAt != null) reportedMtime[path] = modifiedAt;
  }
}

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

/// A LocalFileSystem that answers attribute writes the way
/// `sftp-server -P setstat,fsetstat` does: an upload carrying
/// preserveMode fails with permissionDenied (the mode stamp happens
/// inside the upload), and setTimes fails the same. The denied-request
/// shape §4's fallback exists for — as opposed to
/// _SetTimesIgnoringFs's silent clamp.
final class _SetstatDenyingFs extends LocalFileSystem {
  var uploads = 0;
  var uploadsWithMode = 0;

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) {
    uploads++;
    if (preserveMode != null) {
      uploadsWithMode++;
      // The real server accepts the bytes, then refuses the trailing
      // fsetstat — drain the content first, then fail the mode stamp.
      // (Failing via super.upload() would commit the rename and the
      // retry would hit an exists-conflict.)
      return content.drain<void>().then(
        (_) => throw RemoteFileException(
          kind: RemoteFileErrorKind.permissionDenied,
          operation: 'upload',
          path: path,
          message: 'The server refused the setstat request.',
        ),
      );
    }
    return super.upload(
      path,
      content,
      length: length,
      overwrite: overwrite,
      expectedTarget: expectedTarget,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    );
  }

  @override
  Future<void> setTimes(
    String path, {
    DateTime? accessedAt,
    DateTime? modifiedAt,
  }) => Future.error(
    RemoteFileException(
      kind: RemoteFileErrorKind.permissionDenied,
      operation: 'setTimes',
      path: path,
      message: 'The server refused the setstat request.',
    ),
  );
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

/// Fails after consuming the replacement, when its old destination has
/// already moved to trash. The callback inspects the persisted recovery
/// boundary without depending on the executor's in-memory journal.
final class _FailingUpdateFs extends LocalFileSystem {
  _FailingUpdateFs(this.beforeFailure);

  final Future<void> Function() beforeFailure;

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    await content.drain<void>();
    await beforeFailure();
    throw RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: 'upload',
      path: path,
      message: 'Connection lost before the replacement committed.',
    );
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
    final path = remoteJoin(root.path, rel);
    final stat = await FileStat.stat(path);
    // lstat-style kind detection — FileStat.stat follows links and
    // would misclassify a symlink-to-file as a plain file.
    final type = await FileSystemEntity.type(path, followLinks: false);
    return EntrySnapshot(
      kind: switch (type) {
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
    // Exact D15 match — a suffix match would also accept a foreign
    // 'x-name' occupant.
    final exact = RegExp('^[0-9]{6}-${RegExp.escape(name)}\$');
    for (final entity in dir.listSync()) {
      if (entity is File && exact.hasMatch(entityName(entity))) {
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
      // The backup's origin map precedes the replacement, independently
      // of whether the update succeeds. Its item carries no duplicate.
      final line = run.journal.trashLines.single;
      final outcome = run.journal.items.singleWhere(
        (l) => l.relativePath == 'changed.txt',
      );
      expect(outcome.trashLocation, isNull);
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
      expect(line.bytes, 'old-version'.length);
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

    test('a pre-epoch mtime floors instead of truncating', () async {
      // A source stat at -1500 ms must request -2 s (floor), never
      // -1 s (trunc). dart:io's setLastModified cannot write a
      // pre-epoch stamp on this host's filesystem, so both sides fake
      // their clock: the source reports -1500 ms, the destination
      // records what setTimes was asked for.
      final fakeLeft = _FakeClockFs();
      final fakeRight = _FakeClockFs();
      final exec = SyncExecutor(
        leftFileSystem: fakeLeft,
        rightFileSystem: fakeRight,
        leftRoot: leftRoot.path,
        rightRoot: rightRoot.path,
        syncRunsDirectory: runsDir.path,
        deviceId: deviceId,
      );
      await writeFile(leftRoot, 'f.txt', 'payload', mtimeSecs: 1600000000);
      fakeLeft.reportedMtime[remoteJoin(leftRoot.path, 'f.txt')] =
          DateTime.fromMillisecondsSinceEpoch(-1500, isUtc: true);
      final plan = makePlan([
        item(
          'f.txt',
          left: await snapOf(leftRoot, 'f.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
      ], updateRules);

      final run = await exec.run(plan, pairId: pairId);

      expect(find(plan, 'f.txt')!.status, SyncItemStatus.done);
      expect(exec.mtimeUnreliableRight, isFalse);
      // The DateTime passes through to setTimes verbatim; the journal's
      // observed seconds must floor to -2 — restore compares live
      // stats with the same floor, and trunc's -1 would read as a
      // post-run change and skip the entry.
      expect(
        fakeRight.requestedMtime[remoteJoin(rightRoot.path, 'f.txt')],
        DateTime.fromMillisecondsSinceEpoch(-1500, isUtc: true),
      );
      expect(run.journal.items.single.observedMtimeAfterWrite, -2);
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

    test('a setstat-denying destination retries without the mode stamp',
        () async {
      final denyingFs = _SetstatDenyingFs();
      final denying = SyncExecutor(
        leftFileSystem: leftFs,
        rightFileSystem: denyingFs,
        leftRoot: leftRoot.path,
        rightRoot: rightRoot.path,
        syncRunsDirectory: runsDir.path,
        deviceId: deviceId,
      );
      await writeFile(leftRoot, 'a.txt', 'payload-a', mtimeSecs: 1577936400);
      await writeFile(leftRoot, 'b.txt', 'payload-b', mtimeSecs: 1577936400);
      final plan = makePlan([
        item(
          'a.txt',
          left: await snapOf(leftRoot, 'a.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
        item(
          'b.txt',
          left: await snapOf(leftRoot, 'b.txt'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
        // Serial transfers — under concurrency the first refusal can
        // race sibling uploads and the count below stops being exact.
      ], const SyncRuleSet(
        direction: SyncDirection.leftToRight,
        deletions: DeletionPolicy.none,
        backups: BackupPolicy.trash,
        transferConcurrency: 1,
      ));

      final run = await denying.run(plan, pairId: pairId);

      expect(find(plan, 'a.txt')!.status, SyncItemStatus.done);
      expect(find(plan, 'b.txt')!.status, SyncItemStatus.done);
      expect(
        await File('${rightRoot.path}/a.txt').readAsString(),
        'payload-a',
      );
      expect(
        await File('${rightRoot.path}/b.txt').readAsString(),
        'payload-b',
      );
      expect(denying.mtimeUnreliableRight, isTrue);
      expect(run.journal.items.every((i) => i.setstatIgnored), isTrue);
      // Only the first item pays the doomed mode-stamped attempt —
      // the run remembers the refusal and uploads the rest plainly.
      expect(denyingFs.uploads, 3);
      expect(denyingFs.uploadsWithMode, 1);
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

    test('a symlink in the destination parent chain conflicts', () async {
      // §6 rule 5: the parent chain is re-stat'd nofollow — a link
      // component would let the write escape the sync root.
      if (Platform.isWindows) return; // Link.create needs privileges
      await writeFile(leftRoot, 'real/f.txt', 'payload', mtimeSecs: 1600000000);
      await writeFile(rightRoot, 'target/.keep', '', mtimeSecs: 1600000000);
      await Link('${rightRoot.path}/linkdir').create('${rightRoot.path}/target');
      final plan = makePlan([
        item(
          'linkdir/f.txt',
          left: await snapOf(leftRoot, 'real/f.txt'),
          right: null,
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
      ], updateRules);

      await executor.run(plan, pairId: pairId);

      expect(find(plan, 'linkdir/f.txt')!.status, SyncItemStatus.conflicted);
      expect(
        File('${rightRoot.path}/target/f.txt').existsSync(),
        isFalse,
      );
    });

    test('a permanent replace without a subtree snapshot conflicts '
        'instead of deleting', () async {
      // A stale plan missing destinationSubtree must never trigger a
      // live-list permanent wipe — conflicted, destination untouched.
      await writeFile(leftRoot, 'dir', 'now-a-file', mtimeSecs: 1600000000);
      await writeFile(rightRoot, 'dir/a.txt', 'old-a');
      final plan = makePlan([
        item(
          'dir',
          left: await snapOf(leftRoot, 'dir'),
          right: await snapOf(rightRoot, 'dir'),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.typeDiffers,
          destinationSubtree: null,
        ),
      ], mirrorRules(deletions: DeletionPolicy.permanent));

      await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      expect(find(plan, 'dir')!.status, SyncItemStatus.conflicted);
      expect(await File('${rightRoot.path}/dir/a.txt').readAsString(), 'old-a');
    });
  });

  // ── Scanned plans end to end ─────────────────────────────────────────

  group('scanned plans', () {
    Future<SyncPlan> scanAndDiff(SyncRuleSet rules) async {
      final left = await TreeScanner(
        leftFs,
      ).scan(leftRoot.path, side: SyncSide.left, rules: rules);
      final right = await TreeScanner(
        rightFs,
      ).scan(rightRoot.path, side: SyncSide.right, rules: rules);
      return diffScans(
        left: left,
        right: right,
        pair: SyncPair(
          id: 'pair-1',
          name: 'test pair',
          left: LocalEndpoint(leftRoot.path),
          right: LocalEndpoint(rightRoot.path),
          rules: rules,
        ),
      );
    }

    /// A directory outside both roots for links to point at.
    Future<Directory> linkTarget() async {
      final target = await Directory.systemTemp.createTemp(
        'poltergeist-link-target-',
      );
      addTearDown(() => target.delete(recursive: true));
      return target;
    }

    test('a resolved kind change replaces the directory without a '
        'conflict', () async {
      await writeFile(leftRoot, 'p', 'file-now');
      await writeFile(rightRoot, 'p/inner.txt', 'old');
      final plan = await scanAndDiff(
        const SyncRuleSet(
          direction: SyncDirection.leftToRight,
          deletions: DeletionPolicy.trash,
          conflictDefault: ConflictDefault.keepLeft,
        ),
      );
      // One file removed, counted once (05 §6 rule 4).
      expect(assessDeletions(plan).removals[SyncSide.right], 1);

      final run = await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      for (final item in plan.items) {
        expect(item.status, SyncItemStatus.done, reason: item.relativePath);
      }
      expect(await File('${rightRoot.path}/p').readAsString(), 'file-now');
      expect(trashedFile(rightRoot, run.runId, 'inner.txt'), isNotNull);
    });

    test('an unresolved kind change keeps the directory whole', () async {
      await writeFile(leftRoot, 'p', 'file-now');
      await writeFile(rightRoot, 'p/precious.txt', 'keep me');
      final plan = await scanAndDiff(
        mirrorRules(deletions: DeletionPolicy.permanent),
      );

      await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      expect(
        await File('${rightRoot.path}/p/precious.txt').readAsString(),
        'keep me',
      );
    });

    test('a Mirror keeps the real directory under a source-side link',
        () async {
      if (Platform.isWindows) return; // Link.create needs privileges
      final target = await linkTarget();
      await Link('${leftRoot.path}/data').create(target.path);
      await writeFile(rightRoot, 'data/photo1.jpg', 'one');
      await writeFile(rightRoot, 'data/sub/photo2.jpg', 'two');
      final plan = await scanAndDiff(mirrorRules());

      await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      expect(File('${rightRoot.path}/data/photo1.jpg').existsSync(), isTrue);
      expect(
        File('${rightRoot.path}/data/sub/photo2.jpg').existsSync(),
        isTrue,
      );
    });

    test('a destination-side link takes no copies and gates nothing',
        () async {
      if (Platform.isWindows) return; // Link.create needs privileges
      final target = await linkTarget();
      await Link('${rightRoot.path}/data').create(target.path);
      await writeFile(leftRoot, 'data/a.txt', 'payload');
      await writeFile(rightRoot, 'old.txt', 'orphan');
      final plan = await scanAndDiff(mirrorRules());

      await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );

      expect(find(plan, 'data/a.txt')!.status, SyncItemStatus.skipped);
      expect(File('${target.path}/a.txt').existsSync(), isFalse);
      // Nothing conflicted, so the delete phase ran.
      expect(find(plan, 'old.txt')!.status, SyncItemStatus.done);
      expect(File('${rightRoot.path}/old.txt').existsSync(), isFalse);
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
    test('legacy item-line update backup restores after reopening', () async {
      await writeFile(leftRoot, 'f.txt', 'new-version');
      await writeFile(rightRoot, 'f.txt', 'old-version');
      final plan = makePlan([
        item(
          'f.txt',
          left: await snapOf(leftRoot, 'f.txt'),
          right: await snapOf(rightRoot, 'f.txt'),
          suggested: SyncActionType.updateLeftToRight,
          reason: SyncReason.contentDiffers,
        ),
      ], updateRules);
      final run = await executor.run(plan, pairId: pairId);
      final backup = run.journal.trashLines.single;
      final journalFile = File(run.journal.path);
      final records = [
        for (final line in await journalFile.readAsLines())
          if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
      ];
      // Recreate the old on-disk format: only the completed item line
      // carries the backup; there is no standalone trash record.
      records.removeWhere((record) => record['type'] == 'trash');
      final legacyItem = records.singleWhere(
        (record) => record['type'] == 'item',
      );
      legacyItem['trashLocation'] = backup.trashLocation;
      legacyItem['trashBytes'] = backup.bytes;
      await journalFile.writeAsString(
        '${records.map(jsonEncode).join('\n')}\n',
      );
      final reopened = await SyncRunJournal.open(journalFile.path);
      expect(reopened.trashLines, isEmpty);
      expect(reopened.items.single.trashLocation, backup.trashLocation);

      final report = await restoreTrashedFiles(
        reopened,
        fsFor: (side) => side == SyncSide.left ? leftFs : rightFs,
        rootFor: (side) =>
            side == SyncSide.left ? leftRoot.path : rightRoot.path,
      );

      expect(report.restored, ['f.txt']);
      expect(report.skipped, isEmpty);
      expect(await File('${rightRoot.path}/f.txt').readAsString(), 'old-version');
    });

    for (final cancelDuringUpload in [false, true]) {
      test(
        '${cancelDuringUpload ? 'cancelled' : 'failed'} update keeps a '
        'persisted backup that restores after reopening',
        () async {
          await writeFile(leftRoot, 'f.txt', 'new-version');
          await writeFile(rightRoot, 'f.txt', 'old-version');
          final plan = makePlan([
            item(
              'f.txt',
              left: await snapOf(leftRoot, 'f.txt'),
              right: await snapOf(rightRoot, 'f.txt'),
              suggested: SyncActionType.updateLeftToRight,
              reason: SyncReason.contentDiffers,
            ),
          ], updateRules);
          final cancellation = RemoteTransferCancellation();
          late SyncRunJournal beforeFailure;
          rightFs = _FailingUpdateFs(() async {
            final journalFile = await runsDir.list().single;
            beforeFailure = await SyncRunJournal.open(journalFile.path);
            if (cancelDuringUpload) cancellation.cancel();
          });
          final failing = SyncExecutor(
            leftFileSystem: leftFs,
            rightFileSystem: rightFs,
            leftRoot: leftRoot.path,
            rightRoot: rightRoot.path,
            syncRunsDirectory: runsDir.path,
            deviceId: deviceId,
          );

          final run = await failing.run(
            plan,
            pairId: pairId,
            cancellation: cancellation,
          );

          expect(plan.items.single.status, SyncItemStatus.failed);
          expect(run.cancelled, cancelDuringUpload);
          expect(File('${rightRoot.path}/f.txt').existsSync(), isFalse);
          expect(beforeFailure.hasUnpurgedTrash, isTrue);
          final reopened = await SyncRunJournal.open(run.journal.path);
          final report = await restoreTrashedFiles(
            reopened,
            fsFor: (side) => side == SyncSide.left ? leftFs : rightFs,
            rootFor: (side) =>
                side == SyncSide.left ? leftRoot.path : rightRoot.path,
          );

          expect(report.restored, ['f.txt']);
          expect(report.skipped, isEmpty);
          expect(
            await File('${rightRoot.path}/f.txt').readAsString(),
            'old-version',
          );
        },
      );
    }

    test('failed update restore preserves a recreated origin', () async {
      await writeFile(leftRoot, 'f.txt', 'new-version');
      await writeFile(rightRoot, 'f.txt', 'old-version');
      final plan = makePlan([
        item(
          'f.txt',
          left: await snapOf(leftRoot, 'f.txt'),
          right: await snapOf(rightRoot, 'f.txt'),
          suggested: SyncActionType.updateLeftToRight,
          reason: SyncReason.contentDiffers,
        ),
      ], updateRules);
      rightFs = _FailingUpdateFs(() async {});
      final failing = SyncExecutor(
        leftFileSystem: leftFs,
        rightFileSystem: rightFs,
        leftRoot: leftRoot.path,
        rightRoot: rightRoot.path,
        syncRunsDirectory: runsDir.path,
        deviceId: deviceId,
      );
      final run = await failing.run(plan, pairId: pairId);
      await writeFile(rightRoot, 'f.txt', 'later-user-edit');

      final report = await restoreTrashedFiles(
        await SyncRunJournal.open(run.journal.path),
        fsFor: (side) => side == SyncSide.left ? leftFs : rightFs,
        rootFor: (side) =>
            side == SyncSide.left ? leftRoot.path : rightRoot.path,
      );

      expect(report.restored, isEmpty);
      expect(report.skipped.single.relativePath, 'f.txt');
      expect(
        await File('${rightRoot.path}/f.txt').readAsString(),
        'later-user-edit',
      );
      expect(
        await trashedFile(rightRoot, run.runId, 'f.txt')!.readAsString(),
        'old-version',
      );
    });

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

    test('a blocked restore chain leaves the live destination alone',
        () async {
      await writeFile(rightRoot, 'sub/f.txt', 'deleted');
      final plan = makePlan([
        item(
          'sub/f.txt',
          right: await snapOf(rightRoot, 'sub/f.txt'),
          suggested: SyncActionType.deleteRight,
          reason: SyncReason.onlyOnRight,
        ),
      ], mirrorRules());
      final run = await executor.run(
        plan,
        pairId: pairId,
        deleteConfirmationAcknowledged: true,
      );
      // A file now occupies the origin's parent — the chain cannot be
      // recreated, so restore must skip *before* touching anything.
      await Directory('${rightRoot.path}/sub').delete(recursive: true);
      await writeFile(rightRoot, 'sub', 'a-file-now', mtimeSecs: 1600000001);

      final report = await restoreTrashedFiles(
        run.journal,
        fsFor: (side) => side == SyncSide.left ? leftFs : rightFs,
        rootFor: (side) =>
            side == SyncSide.left ? leftRoot.path : rightRoot.path,
      );

      expect(report.restored, isEmpty);
      expect(report.skipped, hasLength(1));
      expect(
        await File('${rightRoot.path}/sub').readAsString(),
        'a-file-now',
      );
      // The trashed original stays in trash — nothing was half-moved.
      expect(
        trashedFile(rightRoot, run.runId, 'f.txt'),
        isNotNull,
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
