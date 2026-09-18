import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_drop.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';

void main() {
  group('fsLocationForLocation', () {
    test('a local pane maps to the local endpoint', () {
      expect(
        fsLocationForLocation(const LocalPaneLocation('/home/tester')),
        isA<LocalFsLocation>(),
      );
    });

    test('a remote pane maps to its bound server id', () {
      final fs = fsLocationForLocation(
        const RemotePaneLocation('srv-1', '/srv/www'),
      );
      expect(fs, isA<ServerFsLocation>());
      expect((fs as ServerFsLocation).serverId, 'srv-1');
    });
  });

  group('paneDropSameFilesystem', () {
    test('local↔local shares one namespace', () {
      expect(
        paneDropSameFilesystem(
          const LocalFsLocation(),
          const LocalFsLocation(),
        ),
        isTrue,
      );
    });

    test('two remote panes share a filesystem only on one server id', () {
      expect(
        paneDropSameFilesystem(
          const ServerFsLocation('srv-1'),
          const ServerFsLocation('srv-1'),
        ),
        isTrue,
      );
      expect(
        paneDropSameFilesystem(
          const ServerFsLocation('srv-1'),
          const ServerFsLocation('srv-2'),
        ),
        isFalse,
      );
      expect(
        paneDropSameFilesystem(
          const LocalFsLocation(),
          const ServerFsLocation('srv-1'),
        ),
        isFalse,
      );
    });
  });

  group('localVolumeOf', () {
    test('extracts a drive letter case-insensitively', () {
      expect(localVolumeOf(r'C:\Users\x'), 'C:');
      expect(localVolumeOf(r'd:\work'), 'D:');
    });

    test('extracts a UNC share root', () {
      expect(localVolumeOf(r'\\nas\media\movies'), r'\\nas\media');
      expect(localVolumeOf(r'\\NAS\media'), r'\\nas\media');
    });

    test('POSIX paths carry no volume boundary', () {
      expect(localVolumeOf('/home/tester'), isNull);
      expect(localVolumeOf('/mnt/usb/x'), isNull);
    });
  });

  group('paneDropVerb', () {
    TransferOperation verb({
      FsLocation source = const LocalFsLocation(),
      List<String> sourceRoots = const ['/home/tester/a.txt'],
      FsLocation destination = const LocalFsLocation(),
      String destinationDir = '/srv/other',
      bool copy = false,
      bool move = false,
    }) => paneDropVerb(
      source: source,
      sourceRoots: sourceRoots,
      destination: destination,
      destinationDir: destinationDir,
      copyModifier: copy,
      moveModifier: move,
    );

    test('defaults to move inside one filesystem', () {
      expect(verb(), TransferOperation.move);
    });

    test('defaults to copy across endpoints', () {
      expect(
        verb(destination: const ServerFsLocation('srv-1')),
        TransferOperation.copy,
      );
      expect(
        verb(
          source: const ServerFsLocation('srv-1'),
          destination: const LocalFsLocation(),
        ),
        TransferOperation.copy,
      );
      expect(
        verb(
          source: const ServerFsLocation('srv-1'),
          sourceRoots: const ['/srv/www/a.txt'],
          destination: const ServerFsLocation('srv-2'),
        ),
        TransferOperation.copy,
      );
    });

    test('defaults to move on one server (server-side rename)', () {
      expect(
        verb(
          source: const ServerFsLocation('srv-1'),
          sourceRoots: const ['/srv/www/a.txt'],
          destination: const ServerFsLocation('srv-1'),
        ),
        TransferOperation.move,
      );
    });

    test('a same-namespace local drop across drives defaults to copy', () {
      expect(
        verb(
          sourceRoots: const [r'C:\Users\x\a.txt'],
          destinationDir: r'D:\backups',
        ),
        TransferOperation.copy,
      );
      expect(
        verb(
          sourceRoots: const [r'C:\Users\x\a.txt'],
          destinationDir: r'C:\Users\x\docs',
        ),
        TransferOperation.move,
      );
    });

    test('modifiers force the verb, move winning the race', () {
      expect(verb(copy: true), TransferOperation.copy);
      expect(
        verb(
          move: true,
          destination: const ServerFsLocation('srv-1'),
        ),
        TransferOperation.move,
      );
      expect(verb(copy: true, move: true), TransferOperation.move);
    });
  });

  group('paneDropAllowed', () {
    bool allowed({
      FsLocation source = const LocalFsLocation(),
      List<String> roots = const ['/home/tester/a.txt'],
      FsLocation destination = const LocalFsLocation(),
      String dir = '/srv/other',
      TransferOperation operation = TransferOperation.move,
    }) => paneDropAllowed(
      source: source,
      sourceRoots: roots,
      destination: destination,
      destinationDir: dir,
      operation: operation,
    );

    test('a folder never drops onto itself or into its own subtree', () {
      expect(
        allowed(roots: const ['/home/tester/docs'], dir: '/home/tester/docs'),
        isFalse,
      );
      expect(
        allowed(
          roots: const ['/home/tester/docs'],
          dir: '/home/tester/docs/inner',
        ),
        isFalse,
      );
      // A sibling name sharing the prefix is NOT inside the subtree.
      expect(
        allowed(
          roots: const ['/home/tester/docs'],
          dir: '/home/tester/docs2',
        ),
        isTrue,
      );
    });

    test('a move onto the source parent is refused; a copy is not', () {
      expect(
        allowed(dir: '/home/tester', operation: TransferOperation.move),
        isFalse,
      );
      expect(
        allowed(dir: '/home/tester', operation: TransferOperation.copy),
        isTrue,
      );
    });

    test('containment does not apply across filesystems', () {
      // '/srv/www' on a remote pane is a different namespace than the
      // local '/srv/www' — path-shape collisions must not refuse.
      expect(
        allowed(
          roots: const ['/srv/www'],
          destination: const ServerFsLocation('srv-1'),
          dir: '/srv/www',
        ),
        isTrue,
      );
    });

    test('a trailing-separator destination spelling still refuses', () {
      expect(
        allowed(
          roots: const ['/home/tester/docs'],
          dir: '/home/tester/docs/',
        ),
        isFalse,
      );
    });
  });

  group('PaneDropDelegate.enqueue', () {
    test('composes one spec per gesture and enqueues it', () {
      final queue = FakeAppTransferQueue();
      final delegate = PaneDropDelegate(queue: queue);
      final task = delegate.enqueue(
        source: const LocalFsLocation(),
        rootPaths: const ['/home/tester/a.txt', '/home/tester/b.txt'],
        destination: const ServerFsLocation('srv-1'),
        destinationDir: '/srv/www',
        operation: TransferOperation.copy,
      );
      expect(task, isNotNull);
      expect(queue.enqueuedSpecs, hasLength(1));
      final spec = queue.enqueuedSpecs.single;
      expect(spec.source, isA<LocalFsLocation>());
      expect(
        spec.destination,
        isA<ServerFsLocation>().having(
          (s) => s.serverId,
          'serverId',
          'srv-1',
        ),
      );
      expect(spec.rootPaths, ['/home/tester/a.txt', '/home/tester/b.txt']);
      expect(spec.destinationDir, '/srv/www');
      expect(spec.operation, TransferOperation.copy);
    });

    test('a drop carrying no roots enqueues nothing', () {
      final queue = FakeAppTransferQueue();
      final delegate = PaneDropDelegate(queue: queue);
      expect(
        delegate.enqueue(
          source: const LocalFsLocation(),
          rootPaths: const [],
          destination: const LocalFsLocation(),
          destinationDir: '/srv/other',
          operation: TransferOperation.move,
        ),
        isNull,
      );
      expect(queue.enqueuedSpecs, isEmpty);
    });

    test('resolves the §5.2 direction bucket at enqueue time', () {
      final queue = FakeAppTransferQueue();
      final delegate = PaneDropDelegate(
        queue: queue,
        conflictPolicy: ConflictPolicy(
          uploadFiles: ConflictResolution.replace,
          downloadFiles: ConflictResolution.skip,
          localFiles: ConflictResolution.keepBoth,
          remoteToRemoteFiles: ConflictResolution.replaceIfNewer,
        ),
      );
      delegate.enqueue(
        source: const LocalFsLocation(),
        rootPaths: const ['/tmp/a'],
        destination: const ServerFsLocation('srv-1'),
        destinationDir: '/srv/www',
        operation: TransferOperation.copy,
      );
      delegate.enqueue(
        source: const ServerFsLocation('srv-1'),
        rootPaths: const ['/srv/www/b'],
        destination: const LocalFsLocation(),
        destinationDir: '/tmp',
        operation: TransferOperation.copy,
      );
      delegate.enqueue(
        source: const LocalFsLocation(),
        rootPaths: const ['/tmp/c'],
        destination: const LocalFsLocation(),
        destinationDir: '/tmp/d',
        operation: TransferOperation.move,
      );
      delegate.enqueue(
        source: const ServerFsLocation('srv-1'),
        rootPaths: const ['/srv/www/e'],
        destination: const ServerFsLocation('srv-2'),
        destinationDir: '/data',
        operation: TransferOperation.copy,
      );
      expect(
        queue.enqueuedSpecs[0].policy.files,
        ConflictResolution.replace,
      );
      expect(
        queue.enqueuedSpecs[1].policy.files,
        ConflictResolution.skip,
      );
      expect(
        queue.enqueuedSpecs[2].policy.files,
        ConflictResolution.keepBoth,
      );
      expect(
        queue.enqueuedSpecs[3].policy.files,
        ConflictResolution.replaceIfNewer,
      );
    });

    test('the absent settings matrix applies the ask defaults', () {
      final queue = FakeAppTransferQueue();
      PaneDropDelegate(queue: queue).enqueue(
        source: const LocalFsLocation(),
        rootPaths: const ['/tmp/a'],
        destination: const ServerFsLocation('srv-1'),
        destinationDir: '/srv/www',
        operation: TransferOperation.copy,
      );
      expect(
        queue.enqueuedSpecs.single.policy.files,
        ConflictResolution.ask,
      );
    });
  });
}
