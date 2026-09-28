import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import '../engine/engine_bridge_harness.dart';
import 'transfer_fakes.dart';

void main() {
  late Directory local;
  late FakeTreeFileSystem remote;
  late BridgeHarness harness;
  late TransferQueue queue;

  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('upload-permissions-');
    local = Directory(await temp.resolveSymbolicLinks());
    remote = FakeTreeFileSystem()..addDirectory('/dst');
    harness = BridgeHarness({'server': remote});
    queue = TransferQueue(connections: harness.connections);
  });

  tearDown(() async {
    await queue.dispose();
    await harness.dispose();
    await local.delete(recursive: true);
  });

  RemoteFileException denied(String path) => RemoteFileException(
    kind: RemoteFileErrorKind.permissionDenied,
    operation: 'upload',
    path: path,
    message: 'Could not upload "$path": Permission denied',
  );

  TransferTask transfer({
    required FsLocation source,
    required FsLocation destination,
    required String sourcePath,
    required String destinationDir,
    TransferOperation operation = TransferOperation.copy,
  }) => queue.enqueue(
    TransferTaskSpec(
      source: source,
      destination: destination,
      rootPaths: [sourcePath],
      destinationDir: destinationDir,
      operation: operation,
      policy: ResolvedConflictPolicy(
        files: ConflictResolution.replace,
        folders: ConflictResolution.merge,
      ),
    ),
  );

  for (final operation in [TransferOperation.copy, TransferOperation.move]) {
    test('local upload uses server defaults for ${operation.name}', () async {
      final source = File('${local.path}/gh')..writeAsBytesSync([1, 2, 3]);
      if (!Platform.isWindows) {
        await LocalFileSystem().setMode(source.path, 0x1ED); // 0755
      }
      remote.uploadModeFailure = (path, _) => denied(path);

      final task = transfer(
        source: const LocalFsLocation(),
        destination: const ServerFsLocation('server'),
        sourcePath: source.path,
        destinationDir: '/dst',
        operation: operation,
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed, reason: task.error);
      expect(remote.fileBytes['/dst/gh'], [1, 2, 3]);
      expect(remote.modes, isEmpty);
      expect(remote.mtimes['/dst/gh'], isNotNull);
      expect(await source.exists(), operation != TransferOperation.move);
    });
  }

  test('replacement retains the destination mode', () async {
    final source = File('${local.path}/gh')..writeAsBytesSync([1, 2, 3]);
    const destinationMode = 0x180; // 0600, different from the local mode.
    remote.addFile('/dst/gh', [9], mode: destinationMode);

    final task = transfer(
      source: const LocalFsLocation(),
      destination: const ServerFsLocation('server'),
      sourcePath: source.path,
      destinationDir: '/dst',
    );
    await awaitTaskDone(task);

    expect(task.state, TransferTaskState.completed, reason: task.error);
    expect(remote.fileBytes['/dst/gh'], [1, 2, 3]);
    expect(remote.modes['/dst/gh'], destinationMode);
  });

  for (final modeDenied in [false, true]) {
    test(
      '${modeDenied ? 'required mode' : 'write'} denial fails a move safely',
      () async {
        final source = File('${local.path}/gh')..writeAsBytesSync([1, 2, 3]);
        remote.addFile('/dst/gh', [9], mode: 0x180);
        if (modeDenied) {
          remote.uploadModeFailure = (path, _) => denied(path);
        } else {
          remote.uploadFailure = denied;
        }

        final task = transfer(
          source: const LocalFsLocation(),
          destination: const ServerFsLocation('server'),
          sourcePath: source.path,
          destinationDir: '/dst',
          operation: TransferOperation.move,
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.failed);
        expect(task.error, contains('Permission denied'));
        expect(remote.fileBytes['/dst/gh'], [9]);
        expect(source.readAsBytesSync(), [1, 2, 3]);
        expect(remote.uploadCalls, 1);
      },
    );
  }

  test('remote copies still preserve source permissions', () async {
    const mode = 0x1ED; // 0755
    remote.addFile('/src/gh', [1, 2, 3], mode: mode);

    final task = transfer(
      source: const ServerFsLocation('server'),
      destination: const ServerFsLocation('server'),
      sourcePath: '/src/gh',
      destinationDir: '/dst',
    );
    await awaitTaskDone(task);

    expect(task.state, TransferTaskState.completed, reason: task.error);
    expect(remote.modes['/dst/gh'], mode);
  });

  test('downloads still preserve executable permissions', () async {
    const mode = 0x1ED; // 0755
    remote.addFile('/src/gh', [1, 2, 3], mode: mode);

    final task = transfer(
      source: const ServerFsLocation('server'),
      destination: const LocalFsLocation(),
      sourcePath: '/src/gh',
      destinationDir: local.path,
    );
    await awaitTaskDone(task);

    expect(task.state, TransferTaskState.completed, reason: task.error);
    expect((await File('${local.path}/gh').stat()).mode & 0xFFF, mode);
  }, skip: Platform.isWindows ? 'Windows has no Unix mode bits.' : false);
}
