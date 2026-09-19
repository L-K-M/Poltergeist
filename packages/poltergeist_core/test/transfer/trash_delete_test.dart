// D15 trash service + delete tasks (00 D15, 02 §2.6, 03 §7.1/§7.3,
// 07 §3.5): one TrashService boundary above the raw VFS delete —
// local OS trash with platform dispatch (macOS/Windows through the
// poltergeist/trash channel seam, Linux through `gio trash` with an
// arg-list spawn and a detect-once probe), remote `.poltergeist-trash/
// <runId>/` moves behind the per-server opt-in, and the
// confirm-then-permanent fallback that never silently unlinks.
//
// The queue half runs the real TransferQueue over the in-memory
// FakeTreeFileSystem (remote side) and the same fake behind the local
// endpoint (the `localFileSystem` seam accepts any RemoteFileSystem),
// so post-order, opt-in, collision, and journal assertions observe real
// behavior without disk or channels.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show ProcessException, ProcessResult;

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'transfer_fakes.dart';

/// A scripted OS-trash backend — records trashed paths and can report a
/// trashed location (the macOS Put Back anchor shape).
class FakeLocalTrashBackend implements LocalTrashBackend {
  bool available = true;
  final List<String> trashed = [];
  Object? failure;
  String? Function(String path)? trashedPath;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<String?> trash(String path) async {
    if (!available) {
      throw TrashException(
        kind: TrashErrorKind.unavailable,
        path: path,
        message: 'backend marked unavailable',
      );
    }
    final scripted = failure;
    if (scripted != null) throw scripted;
    trashed.add(path);
    return trashedPath?.call(path);
  }
}

void main() {
  group('LocalTrashService dispatch', () {
    test(
      'macOS and Windows route through the poltergeist/trash channel',
      () async {
        final calls = <(String, Map<String, Object?>)>[];
        Future<Object?> invoker(
          String method,
          Map<String, Object?> args,
        ) async {
          calls.add((method, args));
          return {'trashedPath': '/Users/u/.Trash/x.txt'};
        }

        for (final os in ['macos', 'windows']) {
          calls.clear();
          final service = LocalTrashService(
            operatingSystem: os,
            // Both platforms' backend is ChannelTrashBackend — the
            // injected invoker stands in for the app's channel binding.
            macOS: ChannelTrashBackend(invoker: invoker),
            windows: ChannelTrashBackend(invoker: invoker),
          );
          expect(await service.isAvailable(), isTrue);
          expect(await service.trash('/data/x.txt'), '/Users/u/.Trash/x.txt');
          expect(calls.map((c) => c.$1), [trashChannelMethod]);
          expect(calls.single.$2, {'path': '/data/x.txt'});
        }
      },
    );

    test('an unwired channel reports unavailable, never silent', () async {
      final service = LocalTrashService(operatingSystem: 'macos');
      expect(await service.isAvailable(), isFalse);
      await expectLater(
        service.trash('/data/x.txt'),
        throwsA(
          isA<TrashException>().having(
            (e) => e.kind,
            'kind',
            TrashErrorKind.unavailable,
          ),
        ),
      );
    });

    test('an unsupported platform is an explicit error kind', () async {
      final service = LocalTrashService(operatingSystem: 'fuchsia');
      expect(await service.isAvailable(), isFalse);
      await expectLater(
        service.trash('/data/x.txt'),
        throwsA(
          isA<TrashException>().having(
            (e) => e.kind,
            'kind',
            TrashErrorKind.unsupportedPlatform,
          ),
        ),
      );
    });
  });

  group('GioTrashBackend (Linux)', () {
    test('spawns `gio trash` with an arg list — never a shell', () async {
      final spawns = <(String, List<String>)>[];
      final backend = GioTrashBackend(
        runner: (executable, args) async {
          spawns.add((executable, args));
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(await backend.isAvailable(), isTrue);
      await backend.trash('/data/x.txt');
      expect(spawns.map((s) => s.$1), ['gio', 'gio']);
      // `--` keeps a dash-prefixed filename out of GOption parsing.
      expect(spawns.map((s) => s.$2).toList(), [
        ['--version'],
        ['trash', '--', '/data/x.txt'],
      ]);
    });

    test('the capability probe is detected once and cached', () async {
      var probes = 0;
      final backend = GioTrashBackend(
        runner: (executable, args) async {
          probes++;
          // ENOENT — the binary is absent.
          throw ProcessException('gio', args);
        },
      );
      expect(await backend.isAvailable(), isFalse);
      expect(await backend.isAvailable(), isFalse);
      expect(probes, 1);
      await expectLater(
        backend.trash('/data/x.txt'),
        throwsA(
          isA<TrashException>().having(
            (e) => e.kind,
            'kind',
            TrashErrorKind.unavailable,
          ),
        ),
      );
      // The unavailable answer never re-ran a spawn.
      expect(probes, 1);
    });

    test('a nonzero gio trash exit is a typed failure', () async {
      final backend = GioTrashBackend(
        runner: (executable, args) async => args.first == '--version'
            ? ProcessResult(0, 0, '', '')
            : ProcessResult(0, 1, '', 'Unable to find or create trash'),
      );
      await expectLater(
        backend.trash('/data/x.txt'),
        throwsA(
          isA<TrashException>()
              .having((e) => e.kind, 'kind', TrashErrorKind.failed)
              .having(
                (e) => e.message,
                'message',
                contains('Unable to find or create trash'),
              ),
        ),
      );
    });
  });

  group('RemoteTrash mover', () {
    late FakeTreeFileSystem fs;
    late RemoteTrash trash;

    setUp(() {
      fs = FakeTreeFileSystem();
      trash = RemoteTrash(runIdMinter: () => 'run-1');
    });

    test('creates both levels at 0700', () async {
      fs.addDirectory('/data');
      final runDir = await trash.ensureRunDirectory(fs, '/data', 'run-1');
      expect(runDir, '/data/.poltergeist-trash/run-1');
      expect(fs.modes['/data/.poltergeist-trash'], 0x1C0);
      expect(fs.modes[runDir], 0x1C0);
    });

    test(
      'repairs a looser pre-existing mode; refuses a non-directory',
      () async {
        fs.addDirectory('/data');
        fs.addDirectory('/data/.poltergeist-trash');
        // The fake's addDirectory carries no mode — _ensure0700 repairs.
        await trash.ensureRunDirectory(fs, '/data', 'run-1');
        expect(fs.modes['/data/.poltergeist-trash'], 0x1C0);

        // A file squatting on the trash name is refused, never replaced.
        fs.addFile('/data/.poltergeist-trash', [1]);
        await expectLater(
          trash.ensureRunDirectory(fs, '/data', 'run-2'),
          throwsA(
            isA<RemoteFileException>().having(
              (e) => e.kind,
              'kind',
              RemoteFileErrorKind.conflict,
            ),
          ),
        );
      },
    );

    test('a server that cannot chmod refuses the trash operation', () async {
      fs.addDirectory('/data');
      fs.setModeFailure = (path) => const RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'setMode',
        message: 'chmod unsupported',
      );
      await expectLater(
        trash.ensureRunDirectory(fs, '/data', 'run-1'),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.unsupported,
          ),
        ),
      );
    });

    test('moves entries under unique sequence-prefixed names', () async {
      fs.addDirectory('/data');
      final runDir = await trash.ensureRunDirectory(fs, '/data', 'run-1');
      fs.addFile('/data/a.txt', [1]);
      fs.addFile('/data/sub/a.txt', [2]);
      var seq = 0;
      final first = await trash.moveToTrash(
        fs,
        fs.entryAt('/data/a.txt')!,
        runDir,
        () => ++seq,
      );
      final second = await trash.moveToTrash(
        fs,
        fs.entryAt('/data/sub/a.txt')!,
        runDir,
        () => ++seq,
      );
      expect(first, '$runDir/000001-a.txt');
      expect(second, '$runDir/000002-a.txt');
      expect(fs.fileBytes[first], [1]);
      expect(fs.fileBytes[second], [2]);
      expect(fs.entryAt('/data/a.txt'), isNull);
    });

    test('a collision bumps the sequence — never clobbers trash', () async {
      fs.addDirectory('/data');
      final runDir = await trash.ensureRunDirectory(fs, '/data', 'run-1');
      fs.addFile('/data/a.txt', [1]);
      // A foreign occupant (a sibling machine's run could share the
      // folder) at the first candidate name.
      fs.addFile('$runDir/000001-a.txt', [9]);
      var seq = 0;
      final target = await trash.moveToTrash(
        fs,
        fs.entryAt('/data/a.txt')!,
        runDir,
        () => ++seq,
      );
      expect(target, '$runDir/000002-a.txt');
      expect(fs.fileBytes[target], [1]);
      // The occupant was never overwritten.
      expect(fs.fileBytes['$runDir/000001-a.txt'], [9]);
    });

    test('a directory cannot rename into its own subtree', () async {
      fs.addFile('/data/dir/x.txt', [1]);
      await expectLater(
        fs.rename('/data/dir', '/data/dir/nested'),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
      // The tables survive intact — no mid-move corruption.
      expect(fs.fileBytes['/data/dir/x.txt'], [1]);
      expect(fs.entryAt('/data/dir'), isNotNull);
    });

    test('a non-conflict rename error propagates, not a bump', () async {
      fs.addDirectory('/data');
      final runDir = await trash.ensureRunDirectory(fs, '/data', 'run-1');
      fs.addFile('/data/a.txt', [1]);
      fs.renameFailure = (oldPath, newPath) => const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'rename',
        message: 'denied',
      );
      var seq = 0;
      await expectLater(
        trash.moveToTrash(fs, fs.entryAt('/data/a.txt')!, runDir, () => ++seq),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.permissionDenied,
          ),
        ),
      );
      // No rename storm — the failure surfaced on the first attempt.
      expect(seq, 1);
    });
  });

  group('journal strict decode of the disposition pair', () {
    Map<String, Object?> enqueuedJson(TransferTaskSpec spec) =>
        TaskEnqueuedRecord(
          taskId: 't1',
          spec: spec,
          enqueuedAt: DateTime.utc(2026, 9, 18),
        ).toJson();

    Map<String, Object?> specJson(Map<String, Object?> record) =>
        (record['spec']! as Map).cast<String, Object?>();

    TransferTaskSpec copySpec() => TransferTaskSpec(
      source: const ServerFsLocation('srv1'),
      destination: const ServerFsLocation('srv1'),
      rootPaths: const ['/a'],
      destinationDir: '/dst',
      policy: ResolvedConflictPolicy(
        files: ConflictResolution.skip,
        folders: ConflictResolution.skip,
      ),
    );

    TransferTaskSpec deleteSpec() => TransferTaskSpec(
      source: const ServerFsLocation('srv1'),
      destination: const ServerFsLocation('srv1'),
      rootPaths: const ['/a'],
      destinationDir: '/',
      policy: ResolvedConflictPolicy(
        files: ConflictResolution.skip,
        folders: ConflictResolution.skip,
      ),
      operation: TransferOperation.delete,
      disposition: DeleteDisposition.trash,
    );

    test('a delete spec round-trips operation and disposition', () {
      final decoded =
          TransferJournalRecord.parse(jsonEncode(enqueuedJson(deleteSpec())))
              as TaskEnqueuedRecord;
      expect(decoded.spec.operation, TransferOperation.delete);
      expect(decoded.spec.disposition, DeleteDisposition.trash);
    });

    test('a delete spec missing its disposition is malformed — never '
        'defaulted to a copy', () {
      final json = enqueuedJson(deleteSpec());
      specJson(json).remove('disposition');
      expect(
        () => TransferJournalRecord.parse(jsonEncode(json)),
        throwsFormatException,
      );
    });

    test('a copy spec carrying a disposition is malformed — the field is '
        'never silently dropped', () {
      final json = enqueuedJson(copySpec());
      specJson(json)['disposition'] = 'trash';
      expect(
        () => TransferJournalRecord.parse(jsonEncode(json)),
        throwsFormatException,
      );
    });
  });

  group('delete tasks through the queue', () {
    late FakeTreeFileSystem remoteFs;
    late FakeTreeFileSystem localSide;
    late FakeQueueConnectionManager connections;
    late FakeLocalTrashBackend localBackend;
    late RecordingPersistence persistence;
    late List<TransferQueueEvent> events;
    final queues = <TransferQueue>[];

    TransferQueue newQueue({
      bool Function(String serverId)? remoteTrashEnabled,
      RemoteTrash? remoteTrash,
      LocalTrashService? localTrash,
      TransferPersistence? store,
    }) {
      final queue = TransferQueue(
        connections: connections,
        localFileSystem: localSide,
        remoteTrashEnabled: remoteTrashEnabled,
        remoteTrash: remoteTrash,
        localTrash: localTrash,
        isFlaggedEntry: (entry) => entry.name.contains('flag'),
        persistence: store ?? persistence,
      );
      queues.add(queue);
      events = [];
      queue.events.listen(events.add);
      return queue;
    }

    setUp(() {
      remoteFs = FakeTreeFileSystem();
      localSide = FakeTreeFileSystem();
      connections = FakeQueueConnectionManager({'srv1': remoteFs});
      localBackend = FakeLocalTrashBackend();
      persistence = RecordingPersistence();
    });

    tearDown(() async {
      for (final queue in queues) {
        await queue.dispose();
      }
      queues.clear();
    });

    test('remote permanent delete requires confirmation', () async {
      final queue = newQueue();
      remoteFs.addFile('/data/a.txt', [1]);
      await expectLater(
        queue.enqueueDelete(
          const DeleteRequest(
            source: ServerFsLocation('srv1'),
            rootPaths: ['/data/a.txt'],
            disposition: DeleteDisposition.permanent,
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(remoteFs.entryAt('/data/a.txt'), isNotNull);
    });

    test(
      'remote trash disposition is refused when the opt-in is off',
      () async {
        final queue = newQueue();
        remoteFs.addFile('/data/a.txt', [1]);
        await expectLater(
          queue.enqueueDelete(
            const DeleteRequest(
              source: ServerFsLocation('srv1'),
              rootPaths: ['/data/a.txt'],
              disposition: DeleteDisposition.trash,
            ),
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(remoteFs.entryAt('/data/a.txt'), isNotNull);
      },
    );

    test('a filesystem root cannot be deleted', () async {
      final queue = newQueue(remoteTrashEnabled: (_) => true);
      await expectLater(
        queue.enqueueDelete(
          const DeleteRequest(
            source: ServerFsLocation('srv1'),
            rootPaths: ['/'],
            disposition: DeleteDisposition.permanent,
            confirmed: true,
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'remote opt-in OFF: confirmed permanent delete unlinks post-order',
      () async {
        final queue = newQueue();
        remoteFs.addFile('/data/photos/a.txt', [1]);
        remoteFs.addFile('/data/photos/b.txt', [2]);

        final task = await queue.enqueueDelete(
          const DeleteRequest(
            source: ServerFsLocation('srv1'),
            rootPaths: ['/data/photos'],
            disposition: DeleteDisposition.permanent,
            confirmed: true,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        // Post-order: the children unlink before their container.
        expect(remoteFs.calls.where((c) => c.startsWith('delete:')).toList(), [
          'delete:/data/photos/a.txt',
          'delete:/data/photos/b.txt',
          'delete:/data/photos',
        ]);
        expect(remoteFs.entryAt('/data/photos'), isNull);
        for (final item in task.items) {
          expect(item.state, TransferItemState.completed);
          expect(item.disposition, ItemDisposition.permanent);
        }
        // The journal recorded trashed-vs-permanent per item, and the
        // history row carries the task's requested disposition.
        expect(
          persistence.journal.whereType<FileCompletedRecord>().map(
            (r) => r.disposition,
          ),
          everyElement(ItemDisposition.permanent),
        );
        expect(
          persistence.historyEntries.single.disposition,
          DeleteDisposition.permanent,
        );
        expect(
          persistence.historyEntries.single.operation,
          TransferOperation.delete,
        );
      },
    );

    test(
      'remote opt-in ON: entries rename into .poltergeist-trash/<runId>/',
      () async {
        final queue = newQueue(
          remoteTrashEnabled: (id) => id == 'srv1',
          remoteTrash: RemoteTrash(runIdMinter: () => 'run-7'),
        );
        remoteFs.addFile('/data/photos/a.txt', [1]);
        remoteFs.addFile('/data/docs/a.txt', [2]);

        final task = await queue.enqueueDelete(
          const DeleteRequest(
            source: ServerFsLocation('srv1'),
            rootPaths: ['/data/photos', '/data/docs/a.txt'],
            disposition: DeleteDisposition.trash,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        const runDir = '/data/.poltergeist-trash/run-7';
        // Both levels are 0700 (created then chmod'ed by the fake).
        expect(remoteFs.modes['/data/.poltergeist-trash'], 0x1C0);
        expect(remoteFs.modes[runDir], 0x1C0);
        // Flat seq-prefixed names in post-order — the photos subtree
        // enumerates first (child a.txt at 1, its container at 2), then
        // the same-basename docs leaf at 3. No collision is possible.
        expect(remoteFs.fileBytes['$runDir/000001-a.txt'], [1]);
        expect(remoteFs.entryAt('$runDir/000002-photos'), isNotNull);
        expect(remoteFs.fileBytes['$runDir/000003-a.txt'], [2]);
        // The directory itself moved (empty — its children trashed first).
        expect(remoteFs.entryAt('/data/photos'), isNull);
        expect(remoteFs.entryAt('/data/docs/a.txt'), isNull);
        expect(remoteFs.deleteCalls, 0);
        expect(
          persistence.journal.whereType<FileCompletedRecord>().map(
            (r) => r.disposition,
          ),
          everyElement(ItemDisposition.remoteTrash),
        );
        expect(
          persistence.historyEntries.single.disposition,
          DeleteDisposition.trash,
        );
      },
    );

    test('remote trash move failure fails the item — never degrades to '
        'permanent', () async {
      final queue = newQueue(remoteTrashEnabled: (_) => true);
      remoteFs.addFile('/data/a.txt', [1]);
      remoteFs.renameFailure = (oldPath, newPath) => const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'rename',
        message: 'denied',
      );

      final task = await queue.enqueueDelete(
        const DeleteRequest(
          source: ServerFsLocation('srv1'),
          rootPaths: ['/data/a.txt'],
          disposition: DeleteDisposition.trash,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.failed);
      // The source survives — no fallback unlink ever ran.
      expect(remoteFs.entryAt('/data/a.txt'), isNotNull);
      expect(remoteFs.deleteCalls, 0);
    });

    test('local trash delivers through the backend; the VFS raw delete '
        'never runs', () async {
      final queue = newQueue(
        localTrash: LocalTrashService.withBackend(localBackend),
      );
      localSide.addFile('/tmp/poltergeist/a.txt', [1]);

      final task = await queue.enqueueDelete(
        const DeleteRequest(
          source: LocalFsLocation(),
          rootPaths: ['/tmp/poltergeist/a.txt'],
          disposition: DeleteDisposition.trash,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(localBackend.trashed, ['/tmp/poltergeist/a.txt']);
      // Trash delivery is the backend's, not a raw unlink.
      expect(localSide.deleteCalls, 0);
      // The entry stays in the fake tree — the backend's reported
      // delivery stands in for the OS having moved it.
      expect(task.items.single.disposition, ItemDisposition.osTrash);
      expect(
        persistence.journal.whereType<FileCompletedRecord>().single.disposition,
        ItemDisposition.osTrash,
      );
    });

    test('local trash unavailable → TrashException; permanent still '
        'requires its own confirm', () async {
      localBackend.available = false;
      final queue = newQueue(
        localTrash: LocalTrashService.withBackend(localBackend),
      );
      localSide.addFile('/tmp/poltergeist/a.txt', [1]);
      await expectLater(
        queue.enqueueDelete(
          const DeleteRequest(
            source: LocalFsLocation(),
            rootPaths: ['/tmp/poltergeist/a.txt'],
            disposition: DeleteDisposition.trash,
          ),
        ),
        throwsA(
          isA<TrashException>().having(
            (e) => e.kind,
            'kind',
            TrashErrorKind.unavailable,
          ),
        ),
      );
      // The file survives — unavailable never degrades to unlink.
      expect(localSide.entryAt('/tmp/poltergeist/a.txt'), isNotNull);
      expect(localSide.deleteCalls, 0);
      // The test's name promises this: permanent demands its own confirm.
      await expectLater(
        queue.enqueueDelete(
          const DeleteRequest(
            source: LocalFsLocation(),
            rootPaths: ['/tmp/poltergeist/a.txt'],
            disposition: DeleteDisposition.permanent,
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(localSide.deleteCalls, 0);
    });

    test('flagged descendants are disclosed and never deleted', () async {
      final queue = newQueue();
      remoteFs.addFile('/data/photos/a.txt', [1]);
      remoteFs.addFile('/data/photos/badflag.txt', [2]);

      final confirmation = await queue.prepareDelete(
        source: const ServerFsLocation('srv1'),
        rootPaths: ['/data/photos'],
      );
      expect(confirmation.flaggedCount, 1);
      expect(confirmation.quantified, isTrue);
      expect(confirmation.totalItems, 3); // dir + 2 children
      expect(confirmation.effectiveDisposition, DeleteDisposition.permanent);

      final task = await queue.enqueueDelete(
        const DeleteRequest(
          source: ServerFsLocation('srv1'),
          rootPaths: ['/data/photos'],
          disposition: DeleteDisposition.permanent,
          confirmed: true,
        ),
      );
      await awaitTaskDone(task);

      // The flagged leaf is a skipped row; the directory's permanent
      // delete then fails honestly — it was never emptied.
      final flagged = task.items.singleWhere(
        (i) => i.sourcePath.endsWith('badflag.txt'),
      );
      expect(flagged.state, TransferItemState.skipped);
      final dir = task.items.singleWhere((i) => i.isDirectory);
      expect(dir.state, TransferItemState.failed);
      expect(task.state, TransferTaskState.failed);
      // And nothing about the flag was silently unlinked.
      expect(remoteFs.entryAt('/data/photos/badflag.txt'), isNotNull);
      expect(remoteFs.entryAt('/data/photos'), isNotNull);
    });

    test('prepareDelete resolves remote trash by opt-in and counts', () async {
      final queue = newQueue(remoteTrashEnabled: (_) => true);
      remoteFs.addFile('/data/a.txt', [1, 2, 3]);
      remoteFs.addFile('/data/b.txt', [4]);

      final confirmation = await queue.prepareDelete(
        source: const ServerFsLocation('srv1'),
        rootPaths: ['/data/a.txt', '/data/b.txt'],
      );
      expect(confirmation.effectiveDisposition, DeleteDisposition.trash);
      expect(confirmation.remoteTrashOptIn, isTrue);
      expect(confirmation.trashUnavailable, isFalse);
      expect(confirmation.names, ['a.txt', 'b.txt']);
      expect(confirmation.totalItems, 2);
      expect(confirmation.totalBytes, 4);
    });

    test('prepareDelete falls back to unquantified on a walk error', () async {
      final queue = newQueue();
      remoteFs.addFile('/data/a.txt', [1]);
      remoteFs.statFailure = (path) => const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'stat',
        message: 'denied',
      );

      final confirmation = await queue.prepareDelete(
        source: const ServerFsLocation('srv1'),
        rootPaths: ['/data/a.txt'],
      );
      expect(confirmation.quantified, isFalse);
      expect(confirmation.totalItems, isNull);
    });

    test('a restored delete task resumes pending items, terminal rows '
        'never resurrect', () async {
      // Phase 1: a persisted delete task that ran to completion.
      final store = persistence;
      final first = newQueue(
        remoteTrashEnabled: (_) => true,
        remoteTrash: RemoteTrash(runIdMinter: () => 'run-1'),
      );
      remoteFs.addFile('/data/a.txt', [1]);
      remoteFs.addFile('/data/b.txt', [2]);
      final task = await first.enqueueDelete(
        const DeleteRequest(
          source: ServerFsLocation('srv1'),
          rootPaths: ['/data/a.txt', '/data/b.txt'],
          disposition: DeleteDisposition.trash,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);

      // Phase 2: rebuild a queue over the journaled records — the
      // completed items replay as terminal and nothing re-dispatches.
      // Rebuild the replay model the way open() does: re-apply every
      // journaled record into a fresh task's items.
      final replayed = <String, RestoredPlanItem>{};
      for (final record in store.journal) {
        if (record is PlanEntryRecord) {
          replayed[record.itemId] = RestoredPlanItem(
            itemId: record.itemId,
            isDirectory: record.isDirectory,
            sourcePath: record.sourcePath,
            destinationPath: record.destinationPath,
            containerKey: record.containerKey,
            name: record.name,
            source: RemoteFileEntry(
              path: record.sourcePath,
              name: record.name ?? remoteBasename(record.sourcePath),
              type: record.sourceType ?? RemoteFileType.file,
              size: record.sourceSize,
            ),
            existing: null,
            outcome: null,
            error: null,
            failureKind: null,
            resolvedPath: null,
          );
        } else if (record is FileCompletedRecord) {
          final prior = replayed[record.itemId]!;
          replayed[record.itemId] = RestoredPlanItem(
            itemId: prior.itemId,
            isDirectory: prior.isDirectory,
            sourcePath: prior.sourcePath,
            destinationPath: prior.destinationPath,
            containerKey: prior.containerKey,
            name: prior.name,
            source: prior.source,
            existing: prior.existing,
            outcome: RestoredItemOutcome.completed,
            error: null,
            failureKind: null,
            resolvedPath: record.resolvedPath,
            disposition: record.disposition,
          );
        }
      }
      final spec = store.journal.whereType<TaskEnqueuedRecord>().single.spec;
      store.replayValue = TransferJournalReplay(
        tasks: [
          RestoredTransferTask(
            taskId: task.id,
            spec: spec,
            enqueuedAt: task.enqueuedAt,
            wasPaused: false,
            scanComplete: true,
            totalBytes: 3,
            skippedSymlinks: 0,
            items: replayed.values.toList(),
            sweepDirectories: const {},
          ),
        ],
      );

      final renames = remoteFs.renameCalls;
      final second = newQueue(
        remoteTrashEnabled: (_) => true,
        remoteTrash: RemoteTrash(runIdMinter: () => 'run-1'),
        store: store,
      );
      await second.restore();
      await pump();

      final restored = second.tasks.single;
      expect(restored.isTerminal, isTrue);
      expect(restored.state, TransferTaskState.completed);
      expect(
        restored.items.map((i) => i.disposition),
        everyElement(ItemDisposition.remoteTrash),
      );
      // Nothing re-ran: no new renames, no deletes.
      expect(remoteFs.renameCalls, renames);
      expect(remoteFs.deleteCalls, 0);
    });

    // 07 §3.5's exit criterion: a recursive delete of a 10k-entry tree
    // shows progress and cancels cleanly on both local and remote. The
    // fixture is 100 directories × 100 files under the root — 10 101
    // deletable items — held mid-walk by a listing gate so the
    // progress/cancel assertions observe a genuinely in-flight scan.
    group('a 10k-entry delete tree', () {
      const scaleDirectories = 100;
      const scaleFilesPerDirectory = 100;
      const scaleItems = 1 + scaleDirectories +
          scaleDirectories * scaleFilesPerDirectory;

      void buildTree(FakeTreeFileSystem fs, String root) {
        for (var d = 0; d < scaleDirectories; d++) {
          final dir = '$root/d${d.toString().padLeft(3, '0')}';
          for (var f = 0; f < scaleFilesPerDirectory; f++) {
            fs.addFile(
              '$dir/f${f.toString().padLeft(4, '0')}.txt',
              const [1],
            );
          }
        }
      }

      Future<TransferTask> enqueueTreeDelete(
        TransferQueue queue,
        FsLocation source,
        String root,
      ) =>
          queue.enqueueDelete(
            DeleteRequest(
              source: source,
              rootPaths: [root],
              disposition: DeleteDisposition.permanent,
              confirmed: true,
            ),
          );

      // Holds the walk partway: the listing of d050 never returns until
      // [gate] completes, so d000–d049 have emitted (and executed) while
      // the rest of the tree is still undiscovered.
      Completer<void> holdMidWalk(FakeTreeFileSystem fs, String root) {
        final gate = Completer<void>();
        fs.listGate = (path) => path == '$root/d050' ? gate : null;
        return gate;
      }

      void releaseWalk(FakeTreeFileSystem fs, Completer<void> gate) {
        fs.listGate = null;
        gate.complete();
      }

      // A 10k-entry walk through the fake VFS is cheap on a developer
      // host but spends real event-loop turns per item on CI; Windows
      // runners exhausted the default 400-pump window before the first
      // delete landed. The gate still holds the scan — the wait just
      // needs the room.
      Future<void> awaitScaleDone(TransferTask task) => pumpUntil(
        () => task.isTerminal,
        maxPumps: 4000,
        reason: 'task ${task.id} never settled',
      );

      for (final remote in [true, false]) {
        final side = remote ? 'remote' : 'local';
        test(
          'reports growing progress mid-scan and completes post-order '
          '($side)',
          () async {
            final queue = newQueue();
            final fs = remote ? remoteFs : localSide;
            final source = remote
                ? const ServerFsLocation('srv1')
                : const LocalFsLocation();
            const root = '/data/tree';
            buildTree(fs, root);
            final gate = holdMidWalk(fs, root);

            final task = await enqueueTreeDelete(queue, source, root);
            // Depth-first post-order: d000–d049's subtrees are already
            // deleted while the walk still sits inside d050.
            await pumpUntil(
              () => task.completedFiles > 0,
              maxPumps: 4000,
              reason: 'delete dispatch never overlapped the scan',
            );
            expect(task.scanComplete, isFalse);
            expect(task.totalFiles, greaterThan(0));
            expect(task.totalFiles, lessThan(10000));
            expect(
              events
                  .whereType<TransferQueueProgressEvent>()
                  .any((e) => !e.scanComplete && e.taskCompletedFiles > 0),
              isTrue,
              reason: 'progress events must flow while the scan runs',
            );

            releaseWalk(fs, gate);
            await awaitScaleDone(task);
            expect(task.state, TransferTaskState.completed);
            expect(task.scanComplete, isTrue);
            expect(task.items, hasLength(scaleItems));
            expect(task.completedFiles, 10000);
            expect(task.completedDirectories, scaleDirectories + 1);
            expect(fs.deleteCalls, scaleItems);
            // Post-order end-to-end: the root itself unlinks last.
            expect(
              fs.calls.where((c) => c.startsWith('delete:')).last,
              'delete:$root',
            );
            expect(fs.entryAt(root), isNull);
          },
        );

        test(
          'cancels cleanly mid-walk without orphaning the queue ($side)',
          () async {
            final queue = newQueue();
            final fs = remote ? remoteFs : localSide;
            final source = remote
                ? const ServerFsLocation('srv1')
                : const LocalFsLocation();
            const root = '/data/tree';
            buildTree(fs, root);
            final gate = holdMidWalk(fs, root);

            final task = await enqueueTreeDelete(queue, source, root);
            await pumpUntil(
              () => task.completedFiles > 0,
              maxPumps: 4000,
              reason: 'delete dispatch never overlapped the scan',
            );
            queue.cancelTask(task.id);
            releaseWalk(fs, gate);
            await awaitScaleDone(task);

            expect(task.state, TransferTaskState.cancelled);
            // The tree is only partway gone: the gated half never
            // listed, and the root outlives every descendant.
            expect(fs.deleteCalls, lessThan(scaleItems));
            expect(fs.entryAt(root), isNotNull);

            // Clean unwind means the queue still takes work — a small
            // follow-up delete runs to completion.
            fs.addFile('/data/leftover.txt', const [1]);
            final followUp = await queue.enqueueDelete(
              DeleteRequest(
                source: source,
                rootPaths: const ['/data/leftover.txt'],
                disposition: DeleteDisposition.permanent,
                confirmed: true,
              ),
            );
            await awaitScaleDone(followUp);
            expect(followUp.state, TransferTaskState.completed);
          },
        );
      }
    });
  });
}
