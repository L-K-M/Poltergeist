@OnPlatform({
  'windows': Skip('LocalFileSystem tests require POSIX chmod/chown and /bin/sh'),
})
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

// LocalFileSystem — the one VFS's local half (D3, 03 §2.2) — against a
// temp-directory fixture. Every interface method, the error taxonomy of
// the pinned RemoteFileException funnel, symlink handling, and the
// path-traversal rejection at the upload boundary. chmod/chown stderr
// mapping and the swapped-type safety check run through PATH-injected
// fake binaries (the production seam: the constructor's environment is
// the inherited base for those subprocesses).

/// Dart has no octal literal; sizes and modes read best as octal here.
int oct(String digits) => int.parse(digits, radix: 8);

const int permissionsMask = 0xFFF;

/// True when this process cannot be refused by mode bits (root on any
/// POSIX host — the suite itself is POSIX-only via the `@OnPlatform`
/// Windows skip on this library).
final bool runningAsRoot =
    !Platform.isWindows &&
    int.tryParse(Process.runSync('id', ['-u']).stdout.toString().trim()) == 0;

/// Whether this host's filesystem treats `a` and `A` as distinct
/// entries — false on default macOS/Windows volumes, where the two
/// case-variant rename tests below describe a different world.
final bool caseSensitiveFs = () {
  final probe = Directory.systemTemp.createTempSync('pg-case');
  try {
    File('${probe.path}/a').writeAsStringSync('x');
    return !File('${probe.path}/A').existsSync();
  } finally {
    probe.deleteSync(recursive: true);
  }
}();

/// Runs [future] to completion and returns the thrown failure, failing
/// the test when the operation unexpectedly succeeds.
Future<Object> failureOf(Future<Object?> future) async {
  try {
    await future;
  } on Object catch (error) {
    return error;
  }
  fail('expected the operation to fail');
}

RemoteFileException remoteFailure(Object error) =>
    error is RemoteFileException
        ? error
        : fail('not a RemoteFileException: $error');

/// A collecting [StreamSink] with an optional first-chunk hook (the
/// deterministic mid-download mutation seam).
class _CollectingSink implements StreamSink<List<int>> {
  final bytes = <int>[];
  final errors = <Object>[];
  bool _hooked = false;
  final void Function(List<int> chunk)? onFirstChunk;

  _CollectingSink({this.onFirstChunk});

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      if (!_hooked) {
        _hooked = true;
        onFirstChunk?.call(chunk);
      }
    }
  }

  @override
  void add(List<int> data) => bytes.addAll(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) => errors.add(error);

  final _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() {
    if (!_done.isCompleted) _done.complete();
    return Future.value();
  }
}

void main() {
  late Directory root;
  late LocalFileSystem fs;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pg-localfs');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    fs = LocalFileSystem(environment: Platform.environment);
  });

  String pathOf(String name) => '${root.path}/$name';

  /// Separator-robust basename (listSync joins with the host separator,
  /// but fixtures here always build with `/`).
  String basenameOf(String path) => path.split(RegExp(r'[\\/]')).last;

  /// A chmod that fails loudly — a silently failed fixture chmod would
  /// surface later as misleading assertion failures.
  void chmodSync(String mode, String path) {
    final result = Process.runSync('chmod', [mode, path]);
    if (result.exitCode != 0) {
      fail('fixture chmod $mode $path failed: ${result.stderr}');
    }
  }

  Future<File> putFile(String name, [String content = 'content']) async {
    final file = File(pathOf(name));
    await file.writeAsString(content);
    // Pin the mode so the 644 assertions below are umask-independent.
    chmodSync('644', file.path);
    return file;
  }

  Future<Directory> putDir(String name) async {
    final dir = Directory(pathOf(name));
    await dir.create();
    return dir;
  }

  Future<Link> putLink(String name, String target) async {
    final link = Link(pathOf(name));
    await link.create(target);
    return link;
  }

  /// Any `.poltergeist-*` temp/backup siblings left anywhere under the
  /// fixture — must be empty after every operation, success or failure.
  /// followLinks: false keeps the scan inside the fixture even when a
  /// test leaves a symlink behind.
  List<String> siblingLitter() => root
      .listSync(recursive: true, followLinks: false)
      .map((entity) => basenameOf(entity.path))
      .where((name) => name.contains('poltergeist-'))
      .toList();

  int modeOf(String path) => FileStat.statSync(path).mode & permissionsMask;

  /// An fs whose chmod/chown resolve to fake scripts in a PATH-injected
  /// bin directory.
  (LocalFileSystem, Directory) fakeBinFs() {
    final bin = Directory.systemTemp.createTempSync('pg-fakebin');
    addTearDown(() => bin.deleteSync(recursive: true));
    return (
      LocalFileSystem(
        environment: {
          'PATH': '${bin.path}:${Platform.environment['PATH'] ?? ''}',
          'HOME': Platform.environment['HOME'] ?? '/',
        },
      ),
      bin,
    );
  }

  void installFake(Directory bin, String name, String body) {
    final script = File('${bin.path}/$name');
    script.writeAsStringSync('#!/bin/sh\n$body\n');
    chmodSync('755', script.path);
  }

  group('canonicalize', () {
    test('resolves an existing path through symlinks', () async {
      final file = await putFile('real.txt');
      await putLink('alias', file.path);
      expect(
        await fs.canonicalize(pathOf('alias')),
        await File(file.path).resolveSymbolicLinks(),
      );
    });

    test('never throws for a missing path — normalized absolute form', () async {
      expect(
        await fs.canonicalize('${root.path}/gone/../child/x'),
        '${root.path}/child/x',
      );
    });

    test('expands ~ through the injected home', () async {
      final homeFs = LocalFileSystem(environment: {
        'HOME': root.path,
        'USERPROFILE': root.path,
      });
      final realRoot = await Directory(root.path).resolveSymbolicLinks();
      expect(await homeFs.canonicalize('~'), realRoot);
      // Missing paths normalize lexically (the plan's rule): the home
      // prefix stays as given — resolved only where the host itself has
      // no symlink on the way (macOS /var → /private/var differs).
      expect(await homeFs.canonicalize('~/gone/../y'), '${root.path}/y');
    });

    test('anchors a relative path to the working directory', () async {
      final previous = Directory.current;
      Directory.current = root;
      addTearDown(() => Directory.current = previous);
      expect(await fs.canonicalize('sub/../rel'), '${root.path}/rel');
    });
  });

  group('listDirectory', () {
    test('reports files, directories, and dotfiles with metadata', () async {
      await putFile('b.txt', '12345');
      await putDir('a-dir');
      await putFile('.hidden');
      final entries = await fs.listDirectory(root.path);
      expect(
        entries.map((e) => e.name),
        unorderedEquals(['b.txt', 'a-dir', '.hidden']),
      );
      final file = entries.singleWhere((e) => e.name == 'b.txt');
      expect(file.type, RemoteFileType.file);
      expect(file.size, 5);
      expect(file.modifiedAt, isNotNull);
      expect(file.mode! & permissionsMask, oct('644'));
      final dir = entries.singleWhere((e) => e.name == 'a-dir');
      expect(dir.type, RemoteFileType.directory);
      expect(dir.isDirectory, isTrue);
    });

    test('symlinks report as links with null metadata, targets not leaked', () async {
      final file = await putFile('target.txt', '1234567890');
      await putLink('alias', file.path);
      await putLink('broken', pathOf('nowhere'));
      final entries = await fs.listDirectory(root.path);
      expect(
        entries.map((e) => e.name),
        unorderedEquals(['target.txt', 'alias', 'broken']),
      );
      for (final name in ['alias', 'broken']) {
        final link = entries.singleWhere((e) => e.name == name);
        expect(link.type, RemoteFileType.symbolicLink);
        expect(link.isSymbolicLink, isTrue);
        expect(link.size, isNull);
        expect(link.modifiedAt, isNull);
        expect(link.accessedAt, isNull);
        expect(link.mode, isNull);
      }
    });

    test('an empty directory lists empty', () async {
      expect(await fs.listDirectory(root.path), isEmpty);
    });

    test('missing directory fails notFound with the funnel message shape', () async {
      final error = remoteFailure(
        await failureOf(fs.listDirectory(pathOf('gone'))),
      );
      expect(error.kind, RemoteFileErrorKind.notFound);
      expect(error.message, startsWith('Could not list "${pathOf('gone')}": '));
    });

    test('a file path fails other ("Not a directory"), never a silent list', () async {
      final file = await putFile('plain');
      final error = remoteFailure(await failureOf(fs.listDirectory(file.path)));
      expect(error.kind, RemoteFileErrorKind.other);
      expect(error.message, contains('Not a directory'));
    });

    test('an unreadable directory fails permissionDenied', () async {
      if (runningAsRoot) return;
      final dir = await putDir('locked');
      await putFile('locked/inside');
      chmodSync('000', dir.path);
      try {
        final error = remoteFailure(await failureOf(fs.listDirectory(dir.path)));
        expect(error.kind, RemoteFileErrorKind.permissionDenied);
      } finally {
        // Restore before teardowns run: the fixture teardown must be
        // able to recurse through this directory.
        chmodSync('755', dir.path);
      }
    });

    test('a path under an unreadable directory stats permissionDenied, not notFound', () async {
      // dart:io's stat folds EACCES into notFound; the re-probe must
      // surface the real errno (same for download and the attribute
      // writes) — the SFTP adapter answers permission-denied here.
      if (runningAsRoot) return;
      final dir = await putDir('locked');
      await putFile('locked/inside');
      chmodSync('000', dir.path);
      try {
        final statError = remoteFailure(
          await failureOf(fs.stat(pathOf('locked/inside'))),
        );
        expect(statError.kind, RemoteFileErrorKind.permissionDenied);
        final downloadError = remoteFailure(
          await failureOf(fs.download(pathOf('locked/inside'), _CollectingSink())),
        );
        expect(downloadError.kind, RemoteFileErrorKind.permissionDenied);
      } finally {
        chmodSync('755', dir.path);
      }
    });
  });

  group('stat', () {
    test('follows links by default (target identity)', () async {
      final file = await putFile('target', 'xyz');
      await putLink('alias', file.path);
      final entry = await fs.stat(pathOf('alias'));
      expect(entry.type, RemoteFileType.file);
      expect(entry.size, 3);
      expect(entry.name, 'alias');
    });

    test('followLinks: false reports the link itself with null metadata', () async {
      final file = await putFile('target', 'xyz');
      await putLink('alias', file.path);
      final entry = await fs.stat(pathOf('alias'), followLinks: false);
      expect(entry.type, RemoteFileType.symbolicLink);
      expect(entry.size, isNull);
      expect(entry.modifiedAt, isNull);
      expect(entry.mode, isNull);
      expect(entry.uid, isNull);
      expect(entry.gid, isNull);
    });

    test('missing path fails notFound in both modes', () async {
      for (final follow in [true, false]) {
        final error = remoteFailure(
          await failureOf(fs.stat(pathOf('gone'), followLinks: follow)),
        );
        expect(error.kind, RemoteFileErrorKind.notFound);
        expect(error.operation, 'inspect');
      }
    });
  });

  group('setMode', () {
    test('changes permissions', () async {
      final file = await putFile('f');
      await fs.setMode(file.path, oct('600'));
      expect(modeOf(file.path), oct('600'));
    });

    test('rejects out-of-range permissions with RangeError', () {
      expect(() => fs.setMode(pathOf('f'), -1), throwsRangeError);
      expect(() => fs.setMode(pathOf('f'), 0x1000), throwsRangeError);
    });

    test('missing path fails notFound', () async {
      final error = remoteFailure(
        await failureOf(fs.setMode(pathOf('gone'), oct('644'))),
      );
      expect(error.kind, RemoteFileErrorKind.notFound);
    });

    test('refuses symlinks (unsupported) — the target keeps its mode', () async {
      final file = await putFile('target');
      final link = await putLink('alias', file.path);
      final error = remoteFailure(
        await failureOf(fs.setMode(link.path, oct('600'))),
      );
      expect(error.kind, RemoteFileErrorKind.unsupported);
      expect(error.message, contains('Symbolic link'));
      expect(modeOf(file.path), oct('644'));
    });

    test('maps a chmod EPERM stderr line to permissionDenied', () async {
      final file = await putFile('f');
      final (fakeFs, bin) = fakeBinFs();
      installFake(
        bin,
        'chmod',
        "echo \"chmod: changing permissions of 'x': Operation not permitted\" >&2; exit 1",
      );
      final error = remoteFailure(
        await failureOf(fakeFs.setMode(file.path, oct('600'))),
      );
      expect(error.kind, RemoteFileErrorKind.permissionDenied);
    });

    test('maps a chmod ENOENT stderr line to notFound', () async {
      await putFile('f');
      final (fakeFs, bin) = fakeBinFs();
      installFake(
        bin,
        'chmod',
        "echo \"chmod: cannot access 'x': No such file or directory\" >&2; exit 1",
      );
      final error = remoteFailure(
        await failureOf(fakeFs.setMode(pathOf('f'), oct('600'))),
      );
      expect(error.kind, RemoteFileErrorKind.notFound);
    });

    test('an unmapped chmod stderr fails other with the line as detail', () async {
      await putFile('f');
      final (fakeFs, bin) = fakeBinFs();
      installFake(bin, 'chmod', "echo \"chmod: something novel\" >&2; exit 1");
      final error = remoteFailure(
        await failureOf(fakeFs.setMode(pathOf('f'), oct('600'))),
      );
      expect(error.kind, RemoteFileErrorKind.other);
      expect(error.message, contains('something novel'));
    });

    test('classifies by the trailing stderr segment, never a substring match', () async {
      await putFile('f');
      // The path legally embeds "Operation not permitted"; the real
      // failure is ENOENT. A substring scan would misclassify.
      final (fakeFs, bin) = fakeBinFs();
      installFake(
        bin,
        'chmod',
        "echo \"chmod: cannot access '/tmp/x/Operation not permitted': No such file or directory\" >&2; exit 1",
      );
      final error = remoteFailure(
        await failureOf(fakeFs.setMode(pathOf('f'), oct('600'))),
      );
      expect(error.kind, RemoteFileErrorKind.notFound);
    });

    test('a path swapped to a symlink mid-write fails with the landing site', () async {
      final file = await putFile('f');
      final elsewhere = await putFile('elsewhere', 'secret');
      // Fake chmod: perform the swap ($3 is the path — `--` $2 is the
      // mode), then exit 0. The refuse-first check saw a regular file;
      // the write lands through a fresh link.
      final bin = Directory.systemTemp.createTempSync('pg-swapbin');
      addTearDown(() => bin.deleteSync(recursive: true));
      final script = File('${bin.path}/chmod');
      script.writeAsStringSync(
        '#!/bin/sh\nrm -f "\$3"\nln -s "\$SWAP_TARGET" "\$3"\nexit 0\n',
      );
      chmodSync('755', script.path);
      final swapFs = LocalFileSystem(
        environment: {
          'PATH': '${bin.path}:${Platform.environment['PATH'] ?? ''}',
          'SWAP_TARGET': elsewhere.path,
        },
      );
      final error = remoteFailure(
        await failureOf(swapFs.setMode(file.path, oct('600'))),
      );
      expect(error, isA<LocalPathTypeChangedException>());
      final changed = error as LocalPathTypeChangedException;
      expect(
        changed.targetPath,
        await File(elsewhere.path).resolveSymbolicLinks(),
      );
      expect(changed.kind, isNot(RemoteFileErrorKind.conflict));
    });
  });

  group('setTimes', () {
    test('sets the modification time and preserves the access time', () async {
      final file = await putFile('f');
      final accessBefore = (await fs.stat(file.path)).accessedAt;
      final when = DateTime.utc(2024, 1, 2, 3, 4, 5);
      await fs.setTimes(file.path, modifiedAt: when);
      final entry = await fs.stat(file.path);
      expect(entry.modifiedAt, when);
      expect(entry.accessedAt, accessBefore, reason: 'the omitted half keeps its current value');
    });

    test('sets the access time and preserves the modification time', () async {
      final file = await putFile('f');
      final modifyBefore = (await fs.stat(file.path)).modifiedAt;
      final when = DateTime.utc(2023, 6, 1, 12, 0, 0);
      await fs.setTimes(file.path, accessedAt: when);
      final entry = await fs.stat(file.path);
      expect(entry.accessedAt, when);
      expect(entry.modifiedAt, modifyBefore, reason: 'the omitted half keeps its current value');
    });

    test('sets both halves independently of each other', () async {
      final file = await putFile('f');
      final access = DateTime.utc(2022, 1, 1);
      final modify = DateTime.utc(2025, 1, 1);
      await fs.setTimes(file.path, accessedAt: access, modifiedAt: modify);
      final entry = await fs.stat(file.path);
      expect(entry.accessedAt, access);
      expect(entry.modifiedAt, modify);
    });

    test('requires at least one timestamp (ArgumentError)', () {
      expect(() => fs.setTimes(pathOf('f')), throwsArgumentError);
    });

    test('directories and FIFOs fail unsupported (dart:io cannot set them)', () async {
      final dir = await putDir('d');
      final error = remoteFailure(
        await failureOf(
          fs.setTimes(dir.path, modifiedAt: DateTime.utc(2024)),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.unsupported);
      if (Platform.isLinux) {
        // A FIFO would block dart:io's open-for-writing forever — the
        // pre-check must refuse it before any open.
        final fifo = Directory.systemTemp.createTempSync('pg-fifo');
        addTearDown(() => fifo.deleteSync(recursive: true));
        final mkfifo = await Process.run('mkfifo', ['${fifo.path}/pipe']);
        if (mkfifo.exitCode != 0) {
          fail('mkfifo fixture failed: ${mkfifo.stderr}');
        }
        final fifoError = remoteFailure(
          await failureOf(
            fs.setTimes('${fifo.path}/pipe', modifiedAt: DateTime.utc(2024)),
          ),
        );
        expect(fifoError.kind, RemoteFileErrorKind.unsupported);
      }
    });

    test('refuses symlinks — the target keeps its times', () async {
      final file = await putFile('target');
      final before = (await fs.stat(file.path)).modifiedAt;
      final link = await putLink('alias', file.path);
      final error = remoteFailure(
        await failureOf(fs.setTimes(link.path, modifiedAt: DateTime.utc(2024))),
      );
      expect(error.kind, RemoteFileErrorKind.unsupported);
      expect((await fs.stat(file.path)).modifiedAt, before);
    });

    test('missing path fails notFound', () async {
      final error = remoteFailure(
        await failureOf(
          fs.setTimes(pathOf('gone'), modifiedAt: DateTime.utc(2024)),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.notFound);
    });
  });

  group('setOwner', () {
    test('chown to the current owner succeeds and leaves the file intact', () async {
      final file = await putFile('f');
      final uid = int.parse(
        Process.runSync('id', ['-u']).stdout.toString().trim(),
      );
      await fs.setOwner(file.path, uid: uid);
      expect(file.existsSync(), isTrue);
      expect(modeOf(file.path), oct('644'));
    });

    test('requires at least one id (ArgumentError) and range-checks both', () {
      expect(() => fs.setOwner(pathOf('f')), throwsArgumentError);
      expect(() => fs.setOwner(pathOf('f'), uid: -1), throwsRangeError);
      expect(() => fs.setOwner(pathOf('f'), gid: 0x100000000), throwsRangeError);
    });

    test('refuses symlinks before chown ever runs', () async {
      final file = await putFile('target');
      final link = await putLink('alias', file.path);
      final bin = Directory.systemTemp.createTempSync('pg-chownbin');
      addTearDown(() => bin.deleteSync(recursive: true));
      final record = File('${bin.path}/calls');
      final script = File('${bin.path}/chown');
      script.writeAsStringSync(
        '#!/bin/sh\necho "chown: \$*" >> "\$RECORD"\nexit 0\n',
      );
      chmodSync('755', script.path);
      final fakeFs = LocalFileSystem(
        environment: {
          'PATH': '${bin.path}:${Platform.environment['PATH'] ?? ''}',
          'RECORD': record.path,
        },
      );
      final error = remoteFailure(
        await failureOf(fakeFs.setOwner(link.path, uid: 1)),
      );
      expect(error.kind, RemoteFileErrorKind.unsupported);
      expect(
        record.existsSync(),
        isFalse,
        reason: 'chown must not run for a link',
      );
    });

    test('maps a chown EPERM stderr line to permissionDenied', () async {
      await putFile('f');
      final (fakeFs, bin) = fakeBinFs();
      installFake(
        bin,
        'chown',
        "echo \"chown: changing ownership of 'x': Operation not permitted\" >&2; exit 1",
      );
      final error = remoteFailure(
        await failureOf(fakeFs.setOwner(pathOf('f'), uid: 0)),
      );
      expect(error.kind, RemoteFileErrorKind.permissionDenied);
    });

    test('the utility argv is option-guarded before any operand', () async {
      // Pins the `--` end-of-options guard centrally inserted by
      // _runUtility: a dash-prefixed path operand can never parse as
      // an option, absolute or relative.
      final file = await putFile('-R');
      final bin = Directory.systemTemp.createTempSync('pg-argvbin');
      addTearDown(() => bin.deleteSync(recursive: true));
      final record = File('${bin.path}/argv');
      final script = File('${bin.path}/chmod');
      script.writeAsStringSync(
        '#!/bin/sh\nfor a in "\$@"; do echo "\$a" >> "\$RECORD"; done\nexit 0\n',
      );
      chmodSync('755', script.path);
      final fakeFs = LocalFileSystem(
        environment: {
          'PATH': '${bin.path}:${Platform.environment['PATH'] ?? ''}',
          'RECORD': record.path,
        },
      );
      await fakeFs.setMode(file.path, oct('600'));
      final argv = record
          .readAsStringSync()
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();
      expect(argv, ['--', '600', file.path]);
    });
  });

  group('readSymbolicLink', () {
    test('returns the target verbatim (absolute and relative)', () async {
      final file = await putFile('target');
      final link = await putLink('abs', file.path);
      final rel = await putLink('rel', 'target');
      expect(await fs.readSymbolicLink(link.path), file.path);
      expect(await fs.readSymbolicLink(rel.path), 'target');
    });

    test('missing path fails notFound', () async {
      final error = remoteFailure(
        await failureOf(fs.readSymbolicLink(pathOf('gone'))),
      );
      expect(error.kind, RemoteFileErrorKind.notFound);
    });
  });

  group('createSymbolicLink', () {
    test('creates the link and round-trips through readSymbolicLink', () async {
      await fs.createSymbolicLink(pathOf('lnk'), pathOf('dest'));
      expect(await fs.readSymbolicLink(pathOf('lnk')), pathOf('dest'));
    });

    test('an existing item at the link path conflicts before any change', () async {
      final file = await putFile('occupied');
      final error = remoteFailure(
        await failureOf(fs.createSymbolicLink(file.path, 'x')),
      );
      expect(error.kind, RemoteFileErrorKind.conflict);
      expect(error.message, contains('already exists'));
      expect(file.existsSync(), isTrue);
      expect(Link(file.path).existsSync(), isFalse);
    });

    test('a missing parent fails notFound (never auto-parents)', () async {
      final error = remoteFailure(
        await failureOf(fs.createSymbolicLink(pathOf('gone/lnk'), 'x')),
      );
      expect(error.kind, RemoteFileErrorKind.notFound);
    });
  });

  group('createDirectory', () {
    test('creates a directory whose parent exists', () async {
      await fs.createDirectory(pathOf('new'));
      expect(Directory(pathOf('new')).existsSync(), isTrue);
    });

    test('an existing directory conflicts (dart:io create() is a no-op there)', () async {
      final dir = await putDir('exists');
      final error = remoteFailure(await failureOf(fs.createDirectory(dir.path)));
      expect(error.kind, RemoteFileErrorKind.conflict);
      expect(error.message, contains('already exists'));
    });

    test('an existing file conflicts', () async {
      final file = await putFile('occupied');
      final error = remoteFailure(await failureOf(fs.createDirectory(file.path)));
      expect(error.kind, RemoteFileErrorKind.conflict);
    });

    test('a missing parent fails notFound — never recursive', () async {
      final error = remoteFailure(
        await failureOf(fs.createDirectory(pathOf('gone/child'))),
      );
      expect(error.kind, RemoteFileErrorKind.notFound);
      expect(Directory(pathOf('gone')).existsSync(), isFalse);
    });
  });

  group('rename', () {
    test('renames a file', () async {
      final file = await putFile('old', 'data');
      await fs.rename(file.path, pathOf('new'));
      expect(File(file.path).existsSync(), isFalse);
      expect(File(pathOf('new')).readAsStringSync(), 'data');
    });

    test('renames a directory', () async {
      final dir = await putDir('dir');
      await putFile('dir/inside', 'x');
      await fs.rename(dir.path, pathOf('dir2'));
      expect(Directory(dir.path).existsSync(), isFalse);
      expect(File(pathOf('dir2/inside')).existsSync(), isTrue);
    });

    test('renames a symlink itself — the target stays put and reachable', () async {
      final file = await putFile('target');
      final link = await putLink('lnk', file.path);
      await fs.rename(link.path, pathOf('lnk2'));
      expect(Link(link.path).existsSync(), isFalse);
      expect(await Link(pathOf('lnk2')).target(), file.path);
      expect(file.existsSync(), isTrue);
    });

    test('an existing destination conflicts without overwrite, both intact', () async {
      final a = await putFile('a', 'A');
      final b = await putFile('b', 'B');
      final error = remoteFailure(await failureOf(fs.rename(a.path, b.path)));
      expect(error.kind, RemoteFileErrorKind.conflict);
      expect(error.path, b.path);
      expect(File(a.path).readAsStringSync(), 'A');
      expect(File(b.path).readAsStringSync(), 'B');
    });

    test('overwrite replaces the destination', () async {
      await putFile('a', 'A');
      final b = await putFile('b', 'B');
      await fs.rename(pathOf('a'), b.path, overwrite: true);
      expect(b.readAsStringSync(), 'A');
      expect(File(pathOf('a')).existsSync(), isFalse);
      expect(siblingLitter(), isEmpty, reason: 'no backup litter after replace');
    });

    test('a missing source fails notFound and the destination is untouched', () async {
      final untouched = await putFile('dest', 'D');
      final error = remoteFailure(
        await failureOf(fs.rename(pathOf('gone'), untouched.path)),
      );
      expect(error.kind, RemoteFileErrorKind.notFound);
      expect(untouched.readAsStringSync(), 'D');
    });

    test('case-only rename succeeds via the two-step and leaves no siblings', () async {
      // Runs on every host — the two-step exists exactly for the
      // case-insensitive ones; only the vanished-old-spelling assert
      // needs a case-sensitive volume (a case-insensitive stat still
      // finds the renamed entry).
      final file = await putFile('a.txt', 'data');
      await fs.rename(file.path, pathOf('A.TXT'));
      if (caseSensitiveFs) {
        expect(File(pathOf('a.txt')).existsSync(), isFalse);
      }
      expect(File(pathOf('A.TXT')).readAsStringSync(), 'data');
      expect(
        Directory(root.path)
            .listSync()
            .map((entity) => basenameOf(entity.path)),
        ['A.TXT'],
      );
    });

    test('same-lowercase but distinct entries are two files, not one rename', () async {
      // Needs a case-sensitive host: elsewhere the two names are one
      // entry and the fixture below would silently collapse.
      if (!caseSensitiveFs) return;
      final lower = await putFile('a', 'lower');
      final upper = await putFile('A', 'upper');
      final error = remoteFailure(
        await failureOf(fs.rename(lower.path, upper.path)),
      );
      expect(error.kind, RemoteFileErrorKind.conflict);
      expect(File(lower.path).readAsStringSync(), 'lower');
      expect(File(upper.path).readAsStringSync(), 'upper');
    });
  });

  group('delete', () {
    test('deletes a file', () async {
      final file = await putFile('f');
      await fs.delete(await fs.stat(file.path, followLinks: false));
      expect(file.existsSync(), isFalse);
    });

    test('deletes a symlink without touching its target', () async {
      final file = await putFile('target');
      final link = await putLink('lnk', file.path);
      await fs.delete(await fs.stat(link.path, followLinks: false));
      expect(Link(link.path).existsSync(), isFalse);
      expect(file.existsSync(), isTrue);
    });

    test('deletes an empty directory', () async {
      final dir = await putDir('empty');
      await fs.delete(await fs.stat(dir.path, followLinks: false));
      expect(dir.existsSync(), isFalse);
    });

    test("a non-empty directory keeps Séance's wording and stays intact", () async {
      final dir = await putDir('full');
      await putFile('full/inside');
      final error = remoteFailure(
        await failureOf(fs.delete(await fs.stat(dir.path, followLinks: false))),
      );
      expect(error.kind, RemoteFileErrorKind.other);
      expect(error.message, contains('Only an empty directory can be deleted.'));
      expect(File(pathOf('full/inside')).existsSync(), isTrue);
    });

    test('a missing path fails notFound', () async {
      final entry = RemoteFileEntry(
        path: pathOf('gone'),
        name: 'gone',
        type: RemoteFileType.file,
      );
      final error = remoteFailure(await failureOf(fs.delete(entry)));
      expect(error.kind, RemoteFileErrorKind.notFound);
    });
  });

  group('download', () {
    test('streams the bytes and returns the digest of exactly what streamed', () async {
      final file = await putFile('f', 'hello world');
      final sink = _CollectingSink();
      final entry = await fs.download(file.path, sink);
      expect(String.fromCharCodes(sink.bytes), 'hello world');
      expect(entry.contentSha256, sha256Of('hello world'));
      expect(entry.size, 11);
      expect(entry.type, RemoteFileType.file);
    });

    test('the digest oracle is UTF-8, not UTF-16 code units (non-ASCII)', () async {
      // writeAsString encodes UTF-8; the streamed digest must match a
      // UTF-8 oracle — a codeUnits oracle would silently disagree here.
      final file = await putFile('f', 'héllo wörld');
      final sink = _CollectingSink();
      final entry = await fs.download(file.path, sink);
      expect(entry.contentSha256, sha256.convert(utf8.encode('héllo wörld')).toString());
      expect(entry.contentSha256, isNot(sha256.convert('héllo wörld'.codeUnits).toString()));
    });

    test('reports progress with a known total', () async {
      final file = await putFile('f', '0123456789');
      final reports = <(int, int?)>[];
      await fs.download(
        file.path,
        _CollectingSink(),
        onProgress: (transferred, total) => reports.add((transferred, total)),
      );
      expect(reports.last, (10, 10));
      expect(reports.first.$1, greaterThan(0));
      // Cumulative progress must never regress mid-stream.
      for (var i = 1; i < reports.length; i++) {
        expect(reports[i].$1, greaterThanOrEqualTo(reports[i - 1].$1));
      }
    });

    test('computeHash: false returns no digest', () async {
      final file = await putFile('f', 'abc');
      final entry = await fs.download(
        file.path,
        _CollectingSink(),
        computeHash: false,
      );
      expect(entry.contentSha256, isNull);
    });

    test('a missing file fails notFound', () async {
      final error = remoteFailure(
        await failureOf(fs.download(pathOf('gone'), _CollectingSink())),
      );
      expect(error.kind, RemoteFileErrorKind.notFound);
    });

    test('a symlink and a directory fail unsupported — links are never followed down', () async {
      final file = await putFile('target');
      final link = await putLink('lnk', file.path);
      final dir = await putDir('d');
      final linkError = remoteFailure(
        await failureOf(fs.download(link.path, _CollectingSink())),
      );
      final dirError = remoteFailure(
        await failureOf(fs.download(dir.path, _CollectingSink())),
      );
      expect(linkError.kind, RemoteFileErrorKind.unsupported);
      expect(dirError.kind, RemoteFileErrorKind.unsupported);
      expect(linkError.message, contains('Only regular local files'));
    });

    test('an out-of-band change during the stream fails conflict', () async {
      final file = await putFile('f', 'first-content');
      final sink = _CollectingSink(
        onFirstChunk: (_) => file.writeAsStringSync('replaced-different-length'),
      );
      final error = remoteFailure(await failureOf(fs.download(file.path, sink)));
      expect(error.kind, RemoteFileErrorKind.conflict);
      expect(error.message, contains('changed while it was downloading'));
    });

    test('cancellation before the start throws cancelled and streams nothing', () async {
      final file = await putFile('f', 'data');
      final cancellation = RemoteTransferCancellation()..cancel();
      final sink = _CollectingSink();
      final error = remoteFailure(
        await failureOf(fs.download(file.path, sink, cancellation: cancellation)),
      );
      expect(error.kind, RemoteFileErrorKind.cancelled);
      expect(sink.bytes, isEmpty);
    });

    test('cancellation mid-stream throws cancelled (sticky)', () async {
      final file = await putFile('f', 'a-fairly-longer-payload-to-stream');
      final cancellation = RemoteTransferCancellation();
      final sink = _CollectingSink(onFirstChunk: (_) => cancellation.cancel());
      final error = remoteFailure(
        await failureOf(fs.download(file.path, sink, cancellation: cancellation)),
      );
      expect(error.kind, RemoteFileErrorKind.cancelled);
    });
  });

  group('upload', () {
    test('writes the content and returns the digested entry', () async {
      final entry = await fs.upload(pathOf('out'), Stream.value(utf8.encode('payload')));
      expect(File(pathOf('out')).readAsStringSync(), 'payload');
      expect(entry.contentSha256, sha256Of('payload'));
      expect(entry.size, 7);
      expect(entry.type, RemoteFileType.file);
      expect(siblingLitter(), isEmpty);
    });

    test('honors preserveMode', () async {
      await fs.upload(pathOf('out'), Stream.value([1]), preserveMode: oct('755'));
      expect(modeOf(pathOf('out')), oct('755'));
    });

    test('carries the existing mode over an overwrite by default', () async {
      final file = await putFile('existing');
      await fs.setMode(file.path, oct('640'));
      await fs.upload(file.path, Stream.value(utf8.encode('new')), overwrite: true);
      expect(modeOf(file.path), oct('640'));
    });

    test('an existing target conflicts without overwrite, content intact', () async {
      final file = await putFile('existing', 'old');
      final error = remoteFailure(
        await failureOf(fs.upload(file.path, Stream.value(utf8.encode('new')))),
      );
      expect(error.kind, RemoteFileErrorKind.conflict);
      expect(file.readAsStringSync(), 'old');
      expect(siblingLitter(), isEmpty);
    });

    test('overwrite replaces the target with no leftover backup', () async {
      final file = await putFile('existing', 'old-content');
      await fs.upload(file.path, Stream.value(utf8.encode('new')), overwrite: true);
      expect(file.readAsStringSync(), 'new');
      expect(siblingLitter(), isEmpty);
    });

    test('a declared length mismatch fails other and cleans the temp', () async {
      final error = remoteFailure(
        await failureOf(
          fs.upload(pathOf('out'), Stream.value(utf8.encode('12345')), length: 10),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.other);
      expect(error.message, contains('Upload ended after 5 of 10 bytes.'));
      expect(siblingLitter(), isEmpty);
      expect(File(pathOf('out')).existsSync(), isFalse);
    });

    test('expectedTarget matching the current snapshot commits', () async {
      final file = await putFile('existing', 'v1');
      final expected = await fs.stat(file.path, followLinks: false);
      await fs.upload(
        file.path,
        Stream.value(utf8.encode('v2')),
        overwrite: true,
        expectedTarget: expected,
      );
      expect(file.readAsStringSync(), 'v2');
    });

    test('expectedTarget digest mismatch fails conflict even with a matching snapshot', () async {
      final file = await putFile('existing', 'same-size');
      final current = await fs.stat(file.path, followLinks: false);
      final poisoned = RemoteFileEntry(
        path: current.path,
        name: current.name,
        type: current.type,
        size: current.size,
        modifiedAt: current.modifiedAt,
        mode: current.mode,
        contentSha256: sha256Of('not-the-content'),
      );
      final error = remoteFailure(
        await failureOf(
          fs.upload(
            file.path,
            Stream.value(utf8.encode('x')),
            overwrite: true,
            expectedTarget: poisoned,
          ),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.conflict);
      expect(
        error.message,
        contains('changed on disk before the upload started'),
      );
      expect(file.readAsStringSync(), 'same-size');
    });

    test('a mid-upload replacement fails the post-stream CAS check', () async {
      final file = await putFile('existing', 'v1');
      final expected = await fs.stat(file.path, followLinks: false);
      Stream<List<int>> content() async* {
        yield [1, 2, 3];
        await file.writeAsString('swapped-under-the-upload');
        yield [4, 5, 6];
      }

      final error = remoteFailure(
        await failureOf(
          fs.upload(
            file.path,
            content(),
            overwrite: true,
            expectedTarget: expected,
          ),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.conflict);
      expect(
        error.message,
        contains('changed on disk while the upload was running'),
      );
      expect(siblingLitter(), isEmpty);
    });

    test('a target created mid-upload conflicts without overwrite', () async {
      Stream<List<int>> content() async* {
        yield [1];
        await File(pathOf('raced')).writeAsString('appeared');
        yield [2];
      }

      final error = remoteFailure(await failureOf(fs.upload(pathOf('raced'), content())));
      expect(error.kind, RemoteFileErrorKind.conflict);
      expect(error.message, contains('was created while the upload was running'));
      expect(File(pathOf('raced')).readAsStringSync(), 'appeared');
      expect(siblingLitter(), isEmpty);
    });

    test('a source stream error fails other, cleans the temp, leaves no target', () async {
      Stream<List<int>> content() async* {
        yield [1, 2, 3];
        throw StateError('source broke');
      }

      final error = remoteFailure(await failureOf(fs.upload(pathOf('out'), content())));
      expect(error.kind, RemoteFileErrorKind.other);
      expect(File(pathOf('out')).existsSync(), isFalse);
      expect(siblingLitter(), isEmpty);
    });

    test('cancellation mid-stream throws cancelled and cleans the temp', () async {
      final cancellation = RemoteTransferCancellation();
      Stream<List<int>> content() async* {
        yield [1, 2, 3];
        cancellation.cancel();
        yield [4, 5, 6];
      }

      final error = remoteFailure(
        await failureOf(
          fs.upload(pathOf('out'), content(), cancellation: cancellation),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.cancelled);
      expect(File(pathOf('out')).existsSync(), isFalse);
      expect(siblingLitter(), isEmpty);
    });

    test('an overwrite onto an existing directory refuses safely, dir intact', () async {
      // Adapter parity: the SFTP upload surfaces this as a late `other`
      // from the final rename, never a conflict — the dance's refusal is
      // the local equivalent, and it fires before any mutation.
      final dir = await putDir('occupied');
      final error = remoteFailure(
        await failureOf(
          fs.upload(dir.path, Stream.value(utf8.encode('x')), overwrite: true),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.other);
      expect(error.message, contains('non-regular local file'));
      expect(Directory(dir.path).existsSync(), isTrue);
      expect(siblingLitter(), isEmpty);
    });

    test('an overwrite onto a symlink target refuses instead of escaping through it', () async {
      final target = await putFile('target', 'safe');
      final link = await putLink('lnk', target.path);
      final error = remoteFailure(
        await failureOf(
          fs.upload(link.path, Stream.value(utf8.encode('x')), overwrite: true),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.other);
      expect(error.message, contains('non-regular local file'));
      expect(target.readAsStringSync(), 'safe');
      expect(await Link(link.path).target(), target.path);
      expect(siblingLitter(), isEmpty);
    });

    test('a target name too long for a backup fails the replace, original intact', () async {
      final longName = 'n' * 250;
      final file = await putFile(longName, 'original');
      final error = remoteFailure(
        await failureOf(
          fs.upload(file.path, Stream.value(utf8.encode('x')), overwrite: true),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.other);
      expect(error.message, contains('file-name limit'));
      expect(file.readAsStringSync(), 'original');
      expect(siblingLitter(), isEmpty);
    });

    test('a lone surrogate in the target name hits the byte guard, not the OS', () async {
      // A lone surrogate has no valid UTF-8 form, but Dart's encoder
      // still emits it as a 3-byte (WTF-8-style) sequence; the guard
      // must count those bytes and fail before any rename runs.
      final name = 'm' * 227 + '\uDC00';
      final file = File(pathOf(name));
      await file.writeAsString('original');
      final error = remoteFailure(
        await failureOf(
          fs.upload(file.path, Stream.value(utf8.encode('x')), overwrite: true),
        ),
      );
      expect(error.kind, RemoteFileErrorKind.other);
      expect(error.message, contains('file-name limit'));
      expect(file.readAsStringSync(), 'original');
      expect(siblingLitter(), isEmpty);
    });

    group('path-traversal rejection at the boundary', () {
      for (final case_ in <(String, String)>[
        ('..', 'parent escape'),
        ('.', 'current directory'),
        (r'a\b', 'backslash separator'),
        ('CON', 'reserved device name'),
        ('NUL.txt', 'reserved name with extension'),
        ('Com1.tar.gz', 'reserved COM name by base segment'),
        ('aux.', 'reserved name with trailing dot'),
        ('aux .txt', 'reserved name with trailing space in the base'),
        ('name.', 'trailing dot'),
        ('name ', 'trailing space'),
        ('a<b', 'forbidden character'),
      ]) {
        test('rejects "${case_.$1}" (${case_.$2}) before touching the disk', () async {
          final target = '${root.path}/${case_.$1}';
          await expectLater(
            () => fs.upload(target, Stream.value([1])),
            throwsFormatException,
          );
          expect(siblingLitter(), isEmpty);
          if (case_.$1 != '.' && case_.$1 != '..') {
            expect(File(target).existsSync(), isFalse);
          }
        });
      }
    });
  });

  group('error funnel message shape', () {
    test('every I/O failure carries the Could-not shape', () async {
      // Closures, not hot futures: an error future with no listener yet
      // trips the zone's unhandled-error callback mid-list.
      final operations = <Future<Object?> Function()>[
        () => fs.listDirectory(pathOf('gone')),
        () => fs.stat(pathOf('gone')),
        () => fs.rename(pathOf('gone'), pathOf('x')),
        () => fs.readSymbolicLink(pathOf('gone')),
        () => fs.createDirectory(pathOf('gone/child')),
        () => fs.setMode(pathOf('gone'), oct('644')),
      ];
      for (final operation in operations) {
        final error = remoteFailure(await failureOf(operation()));
        expect(
          error.message,
          matches(RegExp(
            '^Could not ${RegExp.escape(error.operation)} "[^"]+": .+',
          )),
          reason: 'bad shape: ${error.message}',
        );
        expect(error.path, isNotNull);
      }
    });
  });
}

String sha256Of(String content) =>
    sha256.convert(utf8.encode(content)).toString();
