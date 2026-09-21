@TestOn('vm')
library;

import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

/// Serves Windows-style paths over a real POSIX temp directory, so the
/// drive-root and case-mismatch branches of trash exclusion can run on
/// non-Windows CI. canonicalize echoes the caller's path verbatim —
/// like a remote FS that does not case-normalize — which is precisely
/// what the case-folded trash comparison exists to survive.
final class _WindowsPathFs implements RemoteFileSystem {
  _WindowsPathFs(this._inner, this._winRoot, this._realRoot);

  final LocalFileSystem _inner;

  /// The Windows path (e.g. `C:\` or `C:\Sync`) [_realRoot] stands for.
  final String _winRoot;

  /// The POSIX directory standing in for [_winRoot].
  final String _realRoot;

  String _toReal(String path) {
    final winLower = _winRoot.toLowerCase().replaceAll(
      RegExp(r'[\\/]+$'),
      '',
    );
    final lower = path.toLowerCase();
    if (lower == winLower || lower == '$winLower\\') return _realRoot;
    if (lower.startsWith('$winLower\\')) {
      return '$_realRoot/${path.substring(winLower.length + 1).replaceAll('\\', '/')}';
    }
    return path;
  }

  @override
  Future<String> canonicalize(String path) async => path;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) =>
      _inner.listDirectory(_toReal(path));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '_WindowsPathFs does not implement ${invocation.memberName}',
  );
}

/// Robust root detection — the `USER` env var is unset in many root
/// containers, where chmod-based permission tests silently misbehave.
bool runningAsRoot() {
  if (Platform.isWindows) return false;
  try {
    final result = Process.runSync('id', ['-u']);
    return result.exitCode == 0 && result.stdout.toString().trim() == '0';
  } catch (_) {
    return false;
  }
}

void main() {
  late LocalFileSystem fs;
  late Directory root;

  setUp(() async {
    fs = LocalFileSystem();
    root = await Directory.systemTemp.createTemp('poltergeist-scan-test-');
  });

  tearDown(() async {
    // Restore listability first: permission tests chmod paths 000/555.
    try {
      await Process.run('chmod', ['-R', 'u+rwx', root.path]);
    } catch (_) {}
    if (await root.exists()) await root.delete(recursive: true);
  });

  File touch(String rel, [String content = 'x']) {
    final file = File('${root.path}/$rel');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    return file;
  }

  void chmod(String path, int octalMode) {
    final result = Process.runSync('chmod', [
      octalMode.toRadixString(8),
      path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('chmod failed: ${result.stderr}');
    }
  }

  Future<ScanResult> scan({
    SyncRuleSet rules = const SyncRuleSet(),
    String? trashPath,
    bool? caseSensitivityOverride,
    bool probeCaseSensitivity = false,
    ScanCancellation? cancellation,
    void Function(int)? onProgress,
  }) => TreeScanner(fs).scan(
    root.path,
    side: SyncSide.left,
    rules: rules,
    trashPath: trashPath,
    caseSensitivityOverride: caseSensitivityOverride,
    probeCaseSensitivity: probeCaseSensitivity,
    cancellation: cancellation,
    onProgress: onProgress,
  );

  group('TreeScanner', () {
    test('walks a tree into a sorted flat map of /-separated keys', () async {
      touch('a.txt', 'aaa');
      touch('dir/b.txt', 'bb');
      touch('dir/sub/c.txt', 'c');
      Directory('${root.path}/empty').createSync();

      final result = await scan();

      expect(
        result.entries.keys.toList(),
        [
          'a.txt',
          'dir',
          'dir/b.txt',
          'dir/sub',
          'dir/sub/c.txt',
          'empty',
        ],
      );
      expect(result.entries['a.txt']!.kind, EntryKind.file);
      expect(result.entries['a.txt']!.size, 3);
      expect(result.entries['dir']!.kind, EntryKind.directory);
      expect(result.entries['empty']!.kind, EntryKind.directory);
      expect(result.warnings, isEmpty);
    });

    test('truncates mtimes to whole seconds', () async {
      final file = touch('a.txt');
      final mtime = DateTime.fromMillisecondsSinceEpoch(101900);
      await fs.setTimes(file.path, modifiedAt: mtime);

      final result = await scan();

      expect(result.entries['a.txt']!.mtimeSecs, 101);
    });

    test('two scans of one tree produce identical snapshots', () async {
      touch('a.txt', 'aaa');
      touch('dir/b.txt', 'bb');
      final first = await scan();
      final second = await scan();

      expect(second.entries.keys, first.entries.keys);
      for (final key in first.entries.keys) {
        final a = first.entries[key]!;
        final b = second.entries[key]!;
        expect(b.kind, a.kind, reason: key);
        expect(b.size, a.size, reason: key);
        expect(b.mtimeSecs, a.mtimeSecs, reason: key);
        expect(b.mode, a.mode, reason: key);
      }
      expect(second.warnings.length, first.warnings.length);
    });

    test(
      'records symlinks as entries and never follows them',
      () async {
        touch('a.txt', 'aaa');
        touch('real/inner.txt', 'i');
        Link('${root.path}/link-to-real').createSync('real');
        Link('${root.path}/link-file').createSync('a.txt');
        Link('${root.path}/dangling').createSync('missing-target');

        final result = await scan();

        expect(result.entries['link-to-real']!.kind, EntryKind.symlink);
        expect(result.entries['link-file']!.kind, EntryKind.symlink);
        expect(result.entries['dangling']!.kind, EntryKind.symlink);
        // The link to a directory was not descended.
        expect(result.entries.keys, isNot(contains('link-to-real/inner.txt')));
        // One aggregated warning, not one per link.
        final linkWarnings = result.warnings.where(
          (w) => w.message.contains('symbolic'),
        );
        expect(linkWarnings, hasLength(1));
        expect(linkWarnings.single.message, '3 symbolic links skipped.');
      },
      // dart:io Link is a no-op stub on Windows without developer mode.
      skip: Platform.isWindows,
    );

    test(
      'a symlink pointing at its own directory does not recurse',
      () async {
        touch('dir/child.txt', 'c');
        Link('${root.path}/dir/loop').createSync('.');

        final result = await scan();

        expect(result.entries['dir']!.kind, EntryKind.directory);
        expect(result.entries['dir/loop']!.kind, EntryKind.symlink);
        expect(result.entries['dir/child.txt']!.kind, EntryKind.file);
        expect(result.entries.keys, hasLength(3));
      },
      skip: Platform.isWindows,
    );

    test(
      'an unlistable directory warns and excludes only its subtree',
      () async {
        touch('locked/inside.txt', 'i');
        touch('ok/sibling.txt', 's');
        chmod('${root.path}/locked', 0);

        try {
          final result = await scan();

          expect(result.entries.keys, isNot(contains('locked/inside.txt')));
          expect(result.entries, contains('locked'));
          expect(result.entries, contains('ok/sibling.txt'));
          expect(
            result.warnings.any(
              (w) =>
                  w.relativePath == 'locked' &&
                  w.side == SyncSide.left &&
                  w.message.contains('Could not list'),
            ),
            isTrue,
          );
        } finally {
          chmod('${root.path}/locked', 0x1C0); // 0700
        }
      },
      // chmod 000 does not restrict the owner on Windows, and root
      // bypasses it on POSIX.
      skip: Platform.isWindows || runningAsRoot(),
    );

    test(
      'an unlistable root aborts instead of returning an empty scan',
      () async {
        chmod(root.path, 0);
        try {
          await expectLater(
            scan(),
            throwsA(isA<RemoteFileException>()),
          );
        } finally {
          chmod(root.path, 0x1C0);
        }
      },
      skip: Platform.isWindows || runningAsRoot(),
    );

    test('a missing root aborts instead of scanning empty', () async {
      await expectLater(
        TreeScanner(
          fs,
        ).scan('${root.path}/does-not-exist', side: SyncSide.left),
        throwsA(isA<RemoteFileException>()),
      );
    });

    test('exclude globs prune subtrees; negation re-includes', () async {
      touch('build/out.bin', 'o');
      touch('a.log', 'l');
      touch('keep.log', 'k');
      touch('rooted.txt', 'r');
      touch('sub/rooted.txt', 'r');
      touch('dir/b.txt', 'b');

      final result = await scan(
        rules: const SyncRuleSet(
          excludeGlobs: ['build/', '*.log', '!keep.log', '/rooted.txt'],
        ),
      );

      expect(result.entries.keys, isNot(contains('build')));
      expect(result.entries.keys, isNot(contains('build/out.bin')));
      expect(result.entries.keys, isNot(contains('a.log')));
      expect(result.entries, contains('keep.log'));
      expect(result.entries.keys, isNot(contains('rooted.txt')));
      expect(result.entries, contains('sub/rooted.txt'));
      expect(result.entries, contains('dir/b.txt'));
    });

    test('app defaults are always excluded, even under a re-include', () async {
      touch('.DS_Store', 'd');
      touch('Thumbs.db', 't');
      touch('desktop.ini', 'i');
      touch('.poltergeist-trash/deleted.txt', 'x');
      touch('foo.poltergeist-9.tmp', 'x');
      touch('normal.txt', 'n');

      final result = await scan(
        rules: const SyncRuleSet(excludeGlobs: ['!*']),
      );

      expect(result.entries.keys, ['normal.txt']);
    });

    test('includeHidden: false drops dotfiles', () async {
      touch('.hiddenfile', 'h');
      touch('visible.txt', 'v');

      final shown = await scan(
        rules: const SyncRuleSet(includeHidden: false),
      );
      final defaultShown = await scan();

      expect(shown.entries.keys, ['visible.txt']);
      expect(defaultShown.entries.keys, contains('.hiddenfile'));
    });

    test('a configured trash subtree is excluded regardless of rules',
        () async {
      touch('.trash/deleted.txt', 'd');
      touch('normal.txt', 'n');

      final result = await scan(trashPath: '${root.path}/.trash');

      expect(result.entries.keys, ['normal.txt']);
    });

    test(
      'a case-mismatched Windows trash path is still excluded',
      () async {
        touch('trash/deleted.txt', 'd');
        touch('normal.txt', 'n');
        final win = _WindowsPathFs(fs, 'C:\\Sync', root.path);

        final result = await TreeScanner(win).scan(
          'C:\\Sync',
          side: SyncSide.left,
          trashPath: 'c:\\sync\\trash',
        );

        expect(result.entries.keys, ['normal.txt']);
      },
      skip: Platform.isWindows,
    );

    test(
      'a Windows drive-root pair excludes a nested trash subtree',
      () async {
        touch('trash/deep/deleted.txt', 'd');
        touch('normal.txt', 'n');
        final win = _WindowsPathFs(fs, 'C:\\', root.path);

        // The canonical root "C:\" loses its only backslash to trailing-
        // separator stripping — the case-insensitive branch must still
        // engage, and the relative must normalize to '/' separators.
        // (trash/ itself stays: the configured subtree is trash/deep.)
        final result = await TreeScanner(win).scan(
          'C:\\',
          side: SyncSide.left,
          trashPath: 'c:\\trash\\deep',
        );

        expect(result.entries.keys, ['normal.txt', 'trash']);
      },
      skip: Platform.isWindows,
    );

    test(
      'a case-variant trash equal to the Windows root is refused',
      () async {
        final win = _WindowsPathFs(fs, 'C:\\Sync', root.path);

        await expectLater(
          TreeScanner(win).scan(
            'C:\\Sync',
            side: SyncSide.left,
            trashPath: 'c:\\SYNC',
          ),
          throwsArgumentError,
        );
      },
      skip: Platform.isWindows,
    );

    test(
      'an out-of-range mtime keeps its original and warns',
      () async {
        final file = touch('old.txt');
        await fs.setTimes(file.path, modifiedAt: DateTime(2200));

        final result = await scan();

        final snapshot = result.entries['old.txt']!;
        expect(snapshot.mtimeSecs, greaterThan(maxSftpMtimeSecs));
        expect(
          result.warnings.any(
            (w) =>
                w.relativePath == 'old.txt' &&
                w.message.contains('outside the SFTP v3 range'),
          ),
          isTrue,
        );
      },
    );

    test('write probe reports the root\'s real case sensitivity', () async {
      // Ground truth independent of the probe: a differently-cased lookup
      // resolves on insensitive filesystems (APFS/NTFS) but not ext4.
      touch('CaseProbe.Source');
      final fsIsSensitive =
          !File('${root.path}/caseprobe.source').existsSync();

      final result = await scan(probeCaseSensitivity: true);

      expect(result.caseSensitive, fsIsSensitive);
      expect(result.caseSensitivityBasis, CaseSensitivityBasis.probe);
      expect(
        root
            .listSync()
            .whereType<File>()
            .any((f) => f.path.contains(TreeScanner.caseProbePrefix)),
        isFalse,
        reason: 'the probe file is cleaned up',
      );
    });

    test('a stranded probe file never enters the snapshot', () async {
      // NOTE: the `.poltergeist*` app default (evaluated after per-pair
      // rules) already excludes this file, so this test also passes with
      // the scanner's explicit skip removed — it pins the combined
      // behavior, which is the contract that matters (debris never
      // reaches a plan).
      touch('${TreeScanner.caseProbePrefix}-stranded');

      final result = await scan(
        rules: const SyncRuleSet(excludeGlobs: ['!*']),
      );

      expect(
        result.entries.keys.any((k) => k.contains('caseprobe')),
        isFalse,
      );
    });

    test(
      'an unwritable root assumes case-sensitive and warns',
      () async {
        chmod(root.path, 0x16D); // 0555
        try {
          final result = await scan(probeCaseSensitivity: true);

          expect(result.caseSensitive, isTrue);
          expect(result.caseSensitivityBasis, CaseSensitivityBasis.assumption);
          expect(
            result.warnings.any(
              (w) => w.message.contains('Could not probe case sensitivity'),
            ),
            isTrue,
          );
        } finally {
          chmod(root.path, 0x1C0);
        }
      },
      skip: Platform.isWindows || runningAsRoot(),
    );

    test('an explicit override answers without probing', () async {
      final result = await scan(caseSensitivityOverride: false);

      expect(result.caseSensitive, isFalse);
      expect(result.caseSensitivityBasis, CaseSensitivityBasis.override);
    });

    test('without a probe or override the sensitivity is an assumption',
        () async {
      final result = await scan();

      expect(result.caseSensitive, isTrue);
      expect(result.caseSensitivityBasis, CaseSensitivityBasis.assumption);
    });

    test('a pre-cancelled token aborts the scan', () async {
      touch('a.txt');
      final token = ScanCancellation()..cancel();

      await expectLater(
        scan(cancellation: token),
        throwsA(isA<ScanCancelled>()),
      );
    });

    test('cancellation between listings aborts the walk', () async {
      touch('one/a.txt');
      touch('two/b.txt');
      final token = ScanCancellation();

      await expectLater(
        scan(
          cancellation: token,
          // Fires after the root listing is absorbed — the two pending
          // subdirectories keep the loop alive for the next check.
          onProgress: (_) => token.cancel(),
        ),
        throwsA(isA<ScanCancelled>()),
      );
    });

    test('progress reports the running entry count', () async {
      touch('a.txt');
      touch('dir/b.txt');
      final counts = <int>[];

      final result = await scan(onProgress: counts.add);

      expect(counts, isNotEmpty);
      expect(counts.last, result.entries.length);
    });
  });
}
