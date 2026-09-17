import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'transfer_fakes.dart';

/// The app-level recursive walker (07 §3.5): bounded streaming
/// enumeration over the one VFS, producing per-item work entries for
/// upload/download and enumerate-and-report output for delete (the D15
/// follow-up owns execution — the walker never deletes).
void main() {
  late FakeTreeFileSystem remote;
  late Directory tempDir;
  late LocalFileSystem local;

  setUp(() {
    remote = FakeTreeFileSystem();
    tempDir = Directory.systemTemp.createTempSync('walker_test_');
    local = LocalFileSystem();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Drains a walk to a flat event list.
  Future<List<WalkEvent>> collect(
    RecursiveWalker walker,
    List<String> roots,
  ) => walker.walk(roots).toList();

  List<WalkEntryEvent> entriesOf(List<WalkEvent> events) =>
      events.whereType<WalkEntryEvent>().toList();

  RecursiveWalker remoteWalker({
    WalkPurpose purpose = WalkPurpose.transfer,
    FsLocation destination = const ServerFsLocation('dst'),
    bool Function(RemoteFileEntry)? isFlaggedEntry,
    RemoteTransferCancellation? cancellation,
  }) => RecursiveWalker(
    source: remote,
    location: const ServerFsLocation('src'),
    purpose: purpose,
    destination: destination,
    isFlaggedEntry: isFlaggedEntry,
    cancellation: cancellation,
  );

  group('transfer enumeration', () {
    test('emits parents-first work entries with container linkage',
        () async {
      remote.addDirectory('/src/dir/sub');
      remote.addFile('/src/dir/a.txt', 'aaa'.codeUnits);
      remote.addFile('/src/dir/sub/b.txt', 'bb'.codeUnits);
      remote.addSymlink('/src/dir/link');

      final walker = remoteWalker();
      final events = await collect(walker, ['/src/dir']);
      final entries = entriesOf(events);

      // dir (work), a.txt, sub (work), link (skipped symlink), b.txt.
      expect(
        entries.map((e) => e.entry.path),
        containsAllInOrder([
          '/src/dir',
          '/src/dir/a.txt',
          '/src/dir/sub',
          '/src/dir/link',
          '/src/dir/sub/b.txt',
        ]),
      );
      expect(entries[0].kind, WalkItemKind.directory);
      expect(entries[0].container, isNull);
      expect(entries[1].kind, WalkItemKind.file);
      expect(entries[1].container, same(entries[0].node));
      expect(entries[3].kind, WalkItemKind.symbolicLink);
      final sub = entries.firstWhere((e) => e.entry.path == '/src/dir/sub');
      final b = entries.firstWhere((e) => e.entry.path.endsWith('b.txt'));
      expect(b.container, same(sub.node));
      expect(b.depth, 2);

      // A directory's listing-close marker arrives after its children.
      final closed = events.whereType<WalkListingClosedEvent>().toList();
      expect(closed.length, 2);
      expect(
        events.indexOf(closed.first),
        greaterThan(events.indexOf(entries[3])),
      );

      expect(walker.isComplete, isTrue);
      expect(walker.discoveredFiles, 2);
      expect(walker.discoveredDirectories, 2);
      expect(walker.discoveredBytes, 5);
      expect(walker.discoveredSymlinks, 1); // the symlink
    });

    test('file and symlink roots enumerate like listed children',
        () async {
      remote.addFile('/solo.txt', 'x'.codeUnits);
      remote.addSymlink('/alias');

      final events = await collect(remoteWalker(), ['/solo.txt', '/alias']);
      final entries = entriesOf(events);
      expect(entries[0].kind, WalkItemKind.file);
      expect(entries[1].kind, WalkItemKind.symbolicLink);
    });

    test('a root stat failure reports and the walk continues', () async {
      remote.addFile('/ok.txt', 'ok'.codeUnits);

      final events = await collect(remoteWalker(), ['/missing', '/ok.txt']);
      final failure = events.whereType<WalkRootFailedEvent>().single;
      expect(failure.rootPath, '/missing');
      expect(failure.error.kind, RemoteFileErrorKind.notFound);
      expect(entriesOf(events).single.entry.path, '/ok.txt');
    });

    test('a failed listing reports and does not stop sibling roots',
        () async {
      remote.addDirectory('/a/childless');
      remote.addFile('/b/file.txt', 'b'.codeUnits);
      remote.listFailure = (path) => path == '/a/childless'
          ? RemoteFileException(
              kind: RemoteFileErrorKind.permissionDenied,
              operation: 'list',
              path: path,
              message: 'denied',
            )
          : null;

      final events = await collect(remoteWalker(), ['/a/childless', '/b']);
      final failed = events.whereType<WalkListingFailedEvent>().single;
      expect(failed.directory.path, '/a/childless');
      expect(failed.error.kind, RemoteFileErrorKind.permissionDenied);
      expect(
        entriesOf(events).map((e) => e.entry.path),
        contains('/b/file.txt'),
      );
    });

    test('enumeration is pull-bound: no listing runs ahead of the '
        'consumer (a huge tree cannot OOM pending output)', () async {
      remote.addDirectory('/src/sub');
      remote.addFile('/src/first.txt', 'f'.codeUnits);
      remote.addFile('/src/sub/deep.txt', 'd'.codeUnits);

      final walker = remoteWalker();
      final iterator = StreamIterator(walker.walk(['/src']));

      // The first pull stats the root and yields the dir entry — no
      // listing has run yet.
      expect(await iterator.moveNext(), isTrue);
      expect(remote.listCalls, 0);

      // Pulling the root's children runs exactly one listing; the
      // pending subdirectory is not listed until its entries are
      // demanded.
      expect(await iterator.moveNext(), isTrue); // /src/first.txt
      expect(remote.listCalls, 1);
      expect(
        remote.calls.where((c) => c.startsWith('list:')),
        ['list:/src'],
      );

      // Drain the rest: the sub listing runs only as entries are pulled.
      while (await iterator.moveNext()) {}
      expect(remote.listCalls, 2);
      expect(walker.isComplete, isTrue);
      await iterator.cancel();
    });

    test('growing totals only increase while the walk runs', () async {
      remote.addDirectory('/src/more');
      remote.addFile('/src/a.bin', List.filled(10, 1));
      remote.addFile('/src/more/b.bin', List.filled(20, 2));
      final gate = Completer<void>();
      remote.listGate = (path) => path == '/src/more' ? gate : null;

      final walker = remoteWalker();
      final seen = <WalkEvent>[];
      final subscription = walker.walk(['/src']).listen(seen.add);
      await pumpUntil(
        () => walker.discoveredFiles == 1,
        reason: 'first file never discovered',
      );
      expect(walker.discoveredBytes, 10);
      expect(walker.isComplete, isFalse);

      gate.complete();
      await subscription.asFuture<void>();
      expect(walker.discoveredFiles, 2);
      expect(walker.discoveredBytes, 30);
      expect(walker.isComplete, isTrue);
      await subscription.cancel();
    });

    test('mid-walk cancel stops enumeration — no further listings',
        () async {
      remote.addDirectory('/src/a');
      remote.addDirectory('/src/b');
      remote.addFile('/src/a/one.txt', '1'.codeUnits);
      remote.addFile('/src/b/two.txt', '2'.codeUnits);
      final gate = Completer<void>();
      remote.listGate = (path) => path == '/src/a' ? gate : null;
      final token = RemoteTransferCancellation();

      final walker = remoteWalker(cancellation: token);
      final seen = <WalkEvent>[];
      Object? walkError;
      final finished = Completer<void>();
      walker.walk(['/src']).listen(
        seen.add,
        // An async* stream delivers error-then-done on a throw.
        onError: (Object e) {
          walkError = e;
          if (!finished.isCompleted) finished.complete();
        },
        onDone: () {
          if (!finished.isCompleted) finished.complete();
        },
      );
      // /src listed; the BFS then pulled /src/a's listing, which is now
      // gated in flight.
      await pumpUntil(
        () => remote.calls.contains('list:/src/a'),
        reason: 'the gated listing never started',
      );
      token.cancel();
      gate.complete();
      await finished.future;

      expect(walkError, isA<RemoteFileException>());
      expect(
        (walkError! as RemoteFileException).kind,
        RemoteFileErrorKind.cancelled,
      );
      // /src/b was never listed; the drained /src/a listing was
      // discarded at the walker's next check point.
      expect(remote.calls, isNot(contains('list:/src/b')));
      expect(
        entriesOf(seen).map((e) => e.entry.path),
        isNot(contains('/src/a/one.txt')),
      );
      expect(walker.isComplete, isFalse);
    });
  });

  group('destination name safety (ported RemoteFilesController rules)',
      () {
    test('Windows-reserved and forbidden names reject to a local '
        'destination — exact rule table', () async {
      const rejected = [
        'CON', 'con', 'PRN', 'AUX', 'NUL', 'CLOCK\$',
        'COM1', 'COM9', 'LPT1', 'LPT9', 'com¹', 'lpt²',
        'CONIN\$', 'CONOUT\$',
        'nul.txt', 'Com1.tar.gz', 'aux .txt',
        'name.', 'name ',
        'a:b', 'a*b', 'a?b', 'a"b', 'a<b', 'a>b', 'a|b',
        'a\x01b', 'a\x7fb',
      ];
      const accepted = [
        'cone.txt', 'com0', 'com10', 'lpt', 'auxiliary', 'CONX',
        'file .txt', 'normal.txt',
      ];
      for (final name in [...rejected, ...accepted]) {
        remote.addFile('/src/$name', 'x'.codeUnits);
      }

      final events = await collect(
        remoteWalker(destination: const LocalFsLocation()),
        ['/src'],
      );
      final entries = entriesOf(events);
      for (final name in rejected) {
        final entry =
            entries.where((e) => e.entry.name == name).singleOrNull;
        expect(
          entry?.kind,
          WalkItemKind.rejectedName,
          reason: '"$name" should reject to a local destination',
        );
        expect(entry!.detail, isNotEmpty);
      }
      for (final name in accepted) {
        final entry =
            entries.where((e) => e.entry.name == name).singleOrNull;
        expect(
          entry?.kind,
          WalkItemKind.file,
          reason: '"$name" should be accepted',
        );
      }
    });

    test('remote destinations use the component rules — separators and '
        'dot-names reject, reserved names pass', () async {
      // A bare name like CON is legal on a POSIX server: only the
      // structural component rules apply.
      remote.addFile('/src/CON', 'x'.codeUnits);
      remote.addFile('/src/nul.txt', 'x'.codeUnits);
      remote.addFile('/src/trailing.', 'x'.codeUnits);
      remote.addFile('/src/still ok.txt', 'x'.codeUnits);
      remote.directories['/src']!.add(
        RemoteFileEntry(
          path: '/src/evil\x00name',
          name: 'evil\x00name',
          type: RemoteFileType.file,
        ),
      );

      final events = await collect(remoteWalker(), ['/src']);
      final byName = {
        for (final e in entriesOf(events)) e.entry.name: e.kind,
      };
      expect(byName['CON'], WalkItemKind.file);
      expect(byName['nul.txt'], WalkItemKind.file);
      expect(byName['trailing.'], WalkItemKind.file);
      expect(byName['still ok.txt'], WalkItemKind.file);
      expect(byName['evil\x00name'], WalkItemKind.rejectedName);
    });

    test('overlong names reject (>255 UTF-8 bytes)', () async {
      remote.addFile('/src/${'x' * 256}', 'x'.codeUnits);
      final events = await collect(remoteWalker(), ['/src']);
      expect(
        entriesOf(events).map((e) => e.kind).toList(),
        [WalkItemKind.directory, WalkItemKind.rejectedName],
      );
    });
  });

  group('traversal containment', () {
    test('a listed entry whose path escapes the parent fails the walk '
        'loudly', () async {
      remote.addDirectory('/src/dir');
      remote.directories['/src/dir']!.add(
        const RemoteFileEntry(
          path: '/outside/evil.txt',
          name: 'evil.txt',
          type: RemoteFileType.file,
          size: 1,
        ),
      );

      await expectLater(
        collect(remoteWalker(), ['/src/dir']),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.message,
            'message',
            contains('outside the walk root'),
          ),
        ),
      );
    });

    test('a ".." name or a separator-carrying name fails the walk loudly',
        () async {
      remote.addDirectory('/src/dir');
      remote.directories['/src/dir']!.add(
        const RemoteFileEntry(
          path: '/src/dir/..',
          name: '..',
          type: RemoteFileType.directory,
        ),
      );

      await expectLater(
        collect(remoteWalker(), ['/src/dir']),
        throwsA(isA<RemoteFileException>()),
      );
    });

    test('a symlink loop is reported, never followed', () async {
      // /src/dir/loop links back to /src/dir — the entry is a link, so
      // the walk reports it instead of recursing forever.
      remote.addDirectory('/src/dir');
      remote.addFile('/src/dir/a.txt', 'a'.codeUnits);
      remote.addSymlink('/src/dir/loop');

      final events = await collect(remoteWalker(), ['/src/dir']);
      final link =
          entriesOf(events).singleWhere((e) => e.entry.path.endsWith('loop'));
      expect(link.kind, WalkItemKind.symbolicLink);
      // Exactly one listing ran — no recursion through the link.
      expect(remote.listCalls, 1);
    });
  });

  group('§13 flagged names', () {
    test('a flagged entry is reported, never silently skipped — and a '
        'flagged directory is never listed', () async {
      remote.addDirectory('/src/flaggeddir');
      remote.addFile('/src/flaggeddir/inside.txt', 'i'.codeUnits);
      remote.addFile('/src/plain.txt', 'p'.codeUnits);
      remote.addFile('/src/badname.txt', 'b'.codeUnits);

      // The §13 detector seam: production wiring waits on the upstream
      // raw-name metadata (STATUS item 13); the test flags by name.
      bool flagged(RemoteFileEntry entry) =>
          entry.name == 'flaggeddir' || entry.name == 'badname.txt';
      final walker = remoteWalker(isFlaggedEntry: flagged);
      final events = await collect(walker, ['/src']);
      final entries = entriesOf(events);

      final flaggedKinds = entries
          .where((e) => e.kind == WalkItemKind.flagged)
          .map((e) => e.entry.name)
          .toList();
      expect(flaggedKinds, containsAll(['flaggeddir', 'badname.txt']));
      expect(walker.flaggedEntries, 2);
      // The flagged directory's name can never round-trip to the wire,
      // so its listing never runs — descendants stay undiscovered.
      expect(
        remote.calls.where((c) => c.startsWith('list:')),
        isNot(contains('list:/src/flaggeddir')),
      );
      expect(
        entries.map((e) => e.entry.path),
        isNot(contains('/src/flaggeddir/inside.txt')),
      );
      // Unflagged siblings still enumerate.
      expect(
        entries.singleWhere((e) => e.entry.name == 'plain.txt').kind,
        WalkItemKind.file,
      );
    });

    test('a flagged entry whose path trips containment still reports '
        'flagged — §13 dominates the escape check', () async {
      remote.addDirectory('/src');
      // Lossy decode produced a path that does not join under its
      // container — without the §13-first ordering this aborts the
      // walk as an escape instead of reporting the bad name.
      remote.directories['/src']!.add(
        const RemoteFileEntry(
          path: '/elsewhere/lossy.txt',
          name: 'lossy.txt',
          type: RemoteFileType.file,
          size: 1,
        ),
      );

      final walker = remoteWalker(
        isFlaggedEntry: (entry) => entry.name == 'lossy.txt',
      );
      final entries = entriesOf(await collect(walker, ['/src']));
      expect(
        entries.singleWhere((e) => e.entry.name == 'lossy.txt').kind,
        WalkItemKind.flagged,
      );
      expect(walker.flaggedEntries, 1);
      expect(walker.isComplete, isTrue);
    });

    test('a flagged directory with an escaping path is terminal — '
        'its children are never enumerated', () async {
      remote.addDirectory('/src');
      remote.addDirectory('/elsewhere/evil');
      remote.directories['/src']!.add(
        const RemoteFileEntry(
          path: '/elsewhere/evil',
          name: 'evil',
          type: RemoteFileType.directory,
        ),
      );
      remote.directories['/elsewhere/evil']!.add(
        const RemoteFileEntry(
          path: '/elsewhere/evil/innocent.txt',
          name: 'innocent.txt',
          type: RemoteFileType.file,
          size: 1,
        ),
      );

      final walker = remoteWalker(
        isFlaggedEntry: (entry) => entry.path == '/elsewhere/evil',
      );
      final entries = entriesOf(await collect(walker, ['/src']));
      expect(
        entries.any((e) => e.entry.name == 'innocent.txt'),
        isFalse,
        reason: 'descending into a flagged directory would enumerate '
            'outside the requested root and re-open the escape',
      );
      expect(walker.flaggedEntries, 1);
      expect(walker.isComplete, isTrue);
    });
  });

  group('delete enumeration (enumerate + report only — execution is the '
      'D15 trash follow-up)', () {
    RecursiveWalker deleteWalker({
      bool Function(RemoteFileEntry)? isFlaggedEntry,
      RemoteTransferCancellation? cancellation,
    }) => RecursiveWalker(
      source: remote,
      location: const ServerFsLocation('src'),
      purpose: WalkPurpose.delete,
      isFlaggedEntry: isFlaggedEntry,
      cancellation: cancellation,
    );

    test('emits children before their container and symlinks as leaf '
        'targets', () async {
      remote.addDirectory('/tree/sub');
      remote.addFile('/tree/a.txt', 'a'.codeUnits);
      remote.addFile('/tree/sub/b.txt', 'bb'.codeUnits);
      remote.addSymlink('/tree/sub/link');

      final walker = deleteWalker();
      final events = await collect(walker, ['/tree']);
      final entries = entriesOf(events);
      final paths = entries.map((e) => e.entry.path).toList();

      // Post-order: every descendant lands before /tree itself.
      expect(paths.last, '/tree');
      expect(paths, containsAllInOrder([
        '/tree/a.txt',
        '/tree/sub/b.txt',
        '/tree/sub/link',
        '/tree/sub',
        '/tree',
      ]));
      expect(
        entries.singleWhere((e) => e.entry.path == '/tree/sub/link').kind,
        WalkItemKind.symbolicLink,
      );
      expect(walker.discoveredFiles, 2);
      expect(walker.discoveredDirectories, 2);
      // The boundary: enumeration never deletes — no VFS delete ran.
      expect(remote.deleteCalls, 0);
    });

    test('delete walks run over the local filesystem too', () async {
      // p.join throughout: local paths carry the platform separator.
      final root = p.join(tempDir.path, 'd');
      Directory(p.join(root, 'sub')).createSync(recursive: true);
      File(p.join(root, 'f.txt')).writeAsBytesSync([1]);
      File(p.join(root, 'sub', 'g.txt')).writeAsBytesSync([2, 3]);

      final walker = RecursiveWalker(
        source: local,
        location: const LocalFsLocation(),
        purpose: WalkPurpose.delete,
      );
      final events = await collect(walker, [root]);
      final paths =
          entriesOf(events).map((e) => e.entry.path).toList();
      expect(paths.last, root);
      expect(paths, contains(p.join(root, 'f.txt')));
      expect(paths, contains(p.join(root, 'sub', 'g.txt')));
      expect(
        paths.indexOf(p.join(root, 'sub', 'g.txt')),
        lessThan(paths.indexOf(p.join(root, 'sub'))),
      );
      expect(tempDir.existsSync(), isTrue); // nothing was deleted
    });

    test('a POSIX-local name carrying a backslash is not an escape',
        () async {
      final root = p.join(tempDir.path, 'd');
      Directory(root).createSync();
      File('$root/a\\b.txt').writeAsBytesSync([1]);

      final walker = RecursiveWalker(
        source: local,
        location: const LocalFsLocation(),
        purpose: WalkPurpose.delete,
      );
      final paths = entriesOf(await collect(walker, [root]))
          .map((e) => e.entry.path)
          .toList();
      expect(paths, contains('$root/a\\b.txt'));
    },
        skip: p.style == p.Style.windows
            ? r'\ is a separator on Windows local sources'
            : null);

    test('a failed listing reports the directory; the walk continues',
        () async {
      remote.addDirectory('/t/locked');
      remote.addFile('/t/ok.txt', 'o'.codeUnits);
      remote.listFailure = (path) => path == '/t/locked'
          ? RemoteFileException(
              kind: RemoteFileErrorKind.permissionDenied,
              operation: 'list',
              path: path,
              message: 'denied',
            )
          : null;

      final events = await collect(deleteWalker(), ['/t']);
      expect(
        events.whereType<WalkListingFailedEvent>().single.directory.path,
        '/t/locked',
      );
      final paths = entriesOf(events).map((e) => e.entry.path).toList();
      // /t/locked itself is still reported (its delete is the
      // consumer's call — it may fail honestly), /t last.
      expect(paths.last, '/t');
      expect(paths, contains('/t/ok.txt'));
    });

    test('mid-walk cancel stops a delete enumeration', () async {
      remote.addDirectory('/t/a');
      remote.addDirectory('/t/b');
      remote.addFile('/t/a/f.txt', 'f'.codeUnits);
      final gate = Completer<void>();
      remote.listGate = (path) => path == '/t/a' ? gate : null;
      final token = RemoteTransferCancellation();

      final walker = deleteWalker(cancellation: token);
      final seen = <WalkEvent>[];
      Object? error;
      final finished = Completer<void>();
      walker.walk(['/t']).listen(
        seen.add,
        onError: (Object e) {
          error = e;
          if (!finished.isCompleted) finished.complete();
        },
        onDone: () {
          if (!finished.isCompleted) finished.complete();
        },
      );
      // The DFS has descended into /t/a, whose listing is now gated in
      // flight.
      await pumpUntil(() => remote.calls.contains('list:/t/a'));
      token.cancel();
      gate.complete();
      await finished.future;
      expect(error, isA<RemoteFileException>());
      // /t/a's gated listing drained but its children were discarded at
      // the next check point; /t's own post-order entry never emitted.
      expect(
        entriesOf(seen).map((e) => e.entry.path),
        isNot(contains('/t/a/f.txt')),
      );
      expect(
        entriesOf(seen).map((e) => e.entry.path),
        isNot(contains('/t')),
      );
    });
  });
}
