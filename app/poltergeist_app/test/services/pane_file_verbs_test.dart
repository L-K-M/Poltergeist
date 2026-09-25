// The pane file-verb service surface (02 §8.3): PaneController's
// createFolder/createFile over the browse channel, and PaneFileOps'
// delete/duplicate routing through the transfer queue — the APIs the UI
// layer's commands call. No widgets: commands, menus, and dialogs are
// the UI layer's.

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_file_ops.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';
import 'pane_controller_test.dart' show FakePaneChannel, FakePaneLanes;

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
}) => RemoteFileEntry(path: '/home/tester/$name', name: name, type: type);

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  Future<(PaneController, FakePaneChannel)> browsing(
    List<RemoteFileEntry> entries,
  ) async {
    final lanes = FakePaneLanes();
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = entries;
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    addTearDown(controller.dispose);
    await controller.openLocalHome();
    await _settle();
    return (controller, channel);
  }

  group('createFolder / createFile', () {
    test(
      'creates the localized default, selects it, opens its rename',
      () async {
        final (pane, channel) = await browsing([_entry('notes.txt')]);
        final created = await pane.createFolder();
        expect(created, '/home/tester/untitled folder');
        expect(channel.createCalls, ['dir:/home/tester/untitled folder']);
        await _settle();
        expect(pane.entries.map((e) => e.name), contains('untitled folder'));
        expect(pane.entries[pane.cursorIndex!].name, 'untitled folder');
        expect(pane.inlineRenameActive, isTrue);
        expect(pane.renameTarget?.name, 'untitled folder');
      },
    );

    test('numbers past names the listing already shows', () async {
      final (pane, channel) = await browsing([
        _entry('untitled file'),
        _entry('untitled file (2)'),
      ]);
      final created = await pane.createFile();
      expect(created, '/home/tester/untitled file (3)');
      expect(channel.createCalls, ['file:/home/tester/untitled file (3)']);
    });

    test('a name taken behind the listing\'s back numbers on', () async {
      final (pane, channel) = await browsing(const []);
      // Created by someone else after the listing was taken.
      channel.created.add('/home/tester/untitled folder');
      final created = await pane.createFolder();
      expect(created, '/home/tester/untitled folder (2)');
      expect(channel.createCalls, [
        'dir:/home/tester/untitled folder',
        'dir:/home/tester/untitled folder (2)',
      ]);
    });

    test('an explicit name is used verbatim', () async {
      final (pane, channel) = await browsing(const []);
      expect(await pane.createFolder(name: 'Reports'), '/home/tester/Reports');
      expect(channel.createCalls, ['dir:/home/tester/Reports']);
    });

    test('a typed refusal reaches the caller, nothing refreshes', () async {
      final (pane, channel) = await browsing(const []);
      channel.createFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'create directory',
        message: 'denied',
      );
      final listCallsBefore = channel.listCalls.length;
      await expectLater(
        pane.createFolder(),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.permissionDenied,
          ),
        ),
      );
      await _settle();
      expect(channel.listCalls.length, listCallsBefore);
      expect(pane.inlineRenameActive, isFalse);
    });

    test('an unbound pane cannot create', () async {
      final pane = PaneController(paneTabId: 'pane.left');
      addTearDown(pane.dispose);
      expect(await pane.createFolder(), isNull);
      expect(await pane.createFile(), isNull);
    });
  });

  group('PaneFileOps', () {
    test('delete prepares the selection, then enqueues it confirmed', () async {
      final (pane, _) = await browsing([_entry('a.txt'), _entry('b.txt')]);
      pane.selectAll();
      final queue = FakeAppTransferQueue();
      final ops = PaneFileOps(queue);

      final confirmation = await ops.prepareDeleteSelection(pane);
      expect(confirmation, isNotNull);
      expect(queue.prepareDeleteCalls.single.preferTrash, isTrue);
      expect(queue.prepareDeleteCalls.single.rootPaths, [
        '/home/tester/a.txt',
        '/home/tester/b.txt',
      ]);
      expect(queue.prepareDeleteCalls.single.source, isA<LocalFsLocation>());

      final task = await ops.deleteSelection(
        confirmation!,
        disposition: confirmation.effectiveDisposition,
        pane: pane,
      );
      final request = queue.enqueuedDeletes.single;
      expect(request.disposition, DeleteDisposition.trash);
      expect(request.confirmed, isTrue);
      expect(task.spec.operation, TransferOperation.delete);
    });

    test(
      'the permanent gesture asks for and runs a permanent delete',
      () async {
        final (pane, _) = await browsing([_entry('a.txt')]);
        pane.selectAll();
        final queue = FakeAppTransferQueue();
        final ops = PaneFileOps(queue);
        final confirmation = await ops.prepareDeleteSelection(
          pane,
          permanent: true,
        );
        expect(queue.prepareDeleteCalls.single.preferTrash, isFalse);
        await ops.deleteSelection(
          confirmation!,
          disposition: confirmation.effectiveDisposition,
        );
        expect(
          queue.enqueuedDeletes.single.disposition,
          DeleteDisposition.permanent,
        );
      },
    );

    test('nothing selected means nothing to delete or duplicate', () async {
      final (pane, _) = await browsing([_entry('a.txt')]);
      final queue = FakeAppTransferQueue();
      final ops = PaneFileOps(queue);
      expect(await ops.prepareDeleteSelection(pane), isNull);
      expect(ops.duplicateSelection(pane), isNull);
      expect(queue.prepareDeleteCalls, isEmpty);
      expect(queue.enqueuedSpecs, isEmpty);
    });

    test('duplicate enqueues a keep-both copy beside the selection', () async {
      final (pane, _) = await browsing([
        _entry('a.txt'),
        _entry('dir', type: RemoteFileType.directory),
      ]);
      pane.selectAll();
      final queue = FakeAppTransferQueue();
      final task = PaneFileOps(queue).duplicateSelection(pane);
      expect(task, isNotNull);
      final spec = queue.enqueuedSpecs.single;
      expect(spec.destinationDir, '/home/tester');
      expect(spec.operation, TransferOperation.copy);
      expect(spec.policy.files, ConflictResolution.keepBoth);
      expect(spec.policy.folders, ConflictResolution.keepBoth);
      expect(spec.source, isA<LocalFsLocation>());
      expect(spec.destination, isA<LocalFsLocation>());
    });

    test('a settled task refreshes the pane that still shows it', () async {
      final (pane, channel) = await browsing([_entry('a.txt')]);
      pane.selectAll();
      final queue = FakeAppTransferQueue();
      final task = PaneFileOps(queue).duplicateSelection(pane)!;
      await _settle();
      final before = channel.listCalls.length;
      queue.emit(TransferQueueTaskEvent(task.id, TransferTaskState.running));
      await _settle();
      expect(channel.listCalls.length, before);
      queue.emit(TransferQueueTaskEvent(task.id, TransferTaskState.completed));
      await _settle();
      expect(channel.listCalls.length, before + 1);
    });
  });
}
