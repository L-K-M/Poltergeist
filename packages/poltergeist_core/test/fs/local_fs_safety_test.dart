@OnPlatform({
  'windows': Skip(
    'local_fs_safety tests need POSIX symlink creation and NAME_MAX',
  ),
})
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

// The public local-safety helpers (03 §2.3): the port of Séance's
// RemoteFilesController statics, plus the crash-recovery sweep for
// orphaned *.poltergeist-<8 hex>.backup siblings. Callers reach these
// through the poltergeist_core barrel — one implementation, four call
// sites (LocalFileSystem.upload today; the transfer queue's download
// executor, the checkout store, and the sync executor as they land).

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pg-lfssafety');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
  });

  String pathOf(String name) => p.join(root.path, name);

  Future<File> putFile(String name, [String content = 'content']) async {
    final file = File(pathOf(name));
    await file.writeAsString(content);
    return file;
  }

  /// Any `.poltergeist-` temp/backup siblings left anywhere under the
  /// fixture — empty after every operation, success or failure.
  List<String> siblingLitter() => root
      .listSync(recursive: true, followLinks: false)
      .map((entity) => p.basename(entity.path))
      .where((name) => name.contains('poltergeist-'))
      .toList();

  group('validatePathComponent', () {
    test('accepts a plain component and returns silently', () {
      expect(() => validatePathComponent('notes v2.txt'), returnsNormally);
    });

    for (final (name, why) in <(String, String)>[
      ('', 'empty'),
      ('.', 'current directory'),
      ('..', 'parent escape'),
      ('a/b', 'forward separator'),
      (r'a\b', 'backslash separator — rejected everywhere by design'),
      ('a\u0000b', 'NUL byte'),
    ]) {
      test('rejects "$name" ($why)', () {
        expect(() => validatePathComponent(name), throwsFormatException);
      });
    }
  });

  group('validateLocalName', () {
    test('accepts plain names, including embedded spaces and hyphens', () {
      expect(() => validateLocalName('my file v2.txt'), returnsNormally);
      expect(() => validateLocalName('my-file.txt'), returnsNormally);
      expect(() => validateLocalName('a.b.c'), returnsNormally);
    });

    for (final (name, why) in <(String, String)>[
      ('CON', 'reserved device name'),
      ('con', 'reserved, case-insensitive'),
      ('NUL.txt', 'reserved name with extension'),
      ('Com1.tar.gz', 'reserved COM name by base segment'),
      ('lpt9', 'reserved LPT name'),
      (r'CLOCK$', 'reserved clock name'),
      (r'CONIN$', 'reserved console-input name'),
      (r'CONOUT$', 'reserved console-output name'),
      ('com\u00b9', 'superscript COM alternate'),
      ('aux.', 'reserved name with trailing dot'),
      ('aux .txt', 'reserved name with trailing space in the base'),
      ('name.', 'trailing dot'),
      ('name ', 'trailing space'),
      ('a<b', 'forbidden character'),
      ('a:b', 'NTFS alternate-data-stream separator'),
      ('a*b', 'glob character'),
      ('a?b', 'wildcard character'),
      ('a|b', 'pipe character'),
      ('a\u0000b', 'NUL byte'),
      ('a\u0001b', 'C0 control'),
      ('a\u007fb', 'DEL'),
    ]) {
      test('rejects "$name" ($why)', () {
        expect(() => validateLocalName(name), throwsFormatException);
      });
    }

    test('rejects the component hazards too (checked first)', () {
      expect(() => validateLocalName('..'), throwsFormatException);
      expect(() => validateLocalName('a/b'), throwsFormatException);
    });
  });

  group('ensureSafeLocalDirectory', () {
    test('creates the directory and every missing parent', () async {
      await ensureSafeLocalDirectory(pathOf('a/b/c'));
      expect(
        FileSystemEntity.typeSync(pathOf('a/b/c')),
        FileSystemEntityType.directory,
      );
    });

    test('is idempotent on an existing directory', () async {
      await Directory(pathOf('there')).create();
      await ensureSafeLocalDirectory(pathOf('there'));
      expect(
        FileSystemEntity.typeSync(pathOf('there')),
        FileSystemEntityType.directory,
      );
    });

    test('refuses to traverse through a symlink component', () async {
      final real = await putFile('realfile');
      final link = Link(pathOf('lnk'));
      await link.create(real.path);
      await expectLater(
        ensureSafeLocalDirectory(pathOf('lnk/sub')),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            contains('Refusing to follow'),
          ),
        ),
      );
      // The link itself survives untouched.
      expect(await link.target(), real.path);
    });

    test('refuses when an existing component is a regular file', () async {
      await putFile('blocker');
      await expectLater(
        ensureSafeLocalDirectory(pathOf('blocker/child')),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            contains('Refusing to follow'),
          ),
        ),
      );
    });

    test('refuses when the path itself is an existing file', () async {
      final file = await putFile('occupied');
      await expectLater(
        ensureSafeLocalDirectory(file.path),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('rejects an unsafe created component name at its mkdir', () async {
      // 09 §3.5: every locally created name is validated — intermediate
      // directories included; pkg/CON/x.txt fails at the CON mkdir.
      await expectLater(
        ensureSafeLocalDirectory(pathOf('pkg/CON')),
        throwsFormatException,
      );
      expect(
        FileSystemEntity.typeSync(pathOf('pkg/CON')),
        FileSystemEntityType.notFound,
      );
    });

    test('leaves an existing oddly named ancestor usable', () async {
      // Existing components are type-checked, not re-validated: a legal
      // POSIX name that Windows would refuse stays traversable.
      final odd = Directory(pathOf('trailing.'));
      await odd.create();
      await ensureSafeLocalDirectory(pathOf('trailing./child'));
      expect(
        FileSystemEntity.typeSync(pathOf('trailing./child')),
        FileSystemEntityType.directory,
      );
    });

    test('rejects a lexical parent component', () async {
      await expectLater(
        ensureSafeLocalDirectory(pathOf('a/../b')),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('replaceLocalFile', () {
    test('replaces the target and leaves no backup behind', () async {
      final target = await putFile('data', 'old');
      final part = await putFile('part', 'new');
      await replaceLocalFile(part, target);
      expect(target.readAsStringSync(), 'new');
      expect(siblingLitter(), isEmpty);
    });

    test('a missing target is a plain rename, not a dance', () async {
      final part = await putFile('part', 'new');
      final target = File(pathOf('fresh'));
      await replaceLocalFile(part, target);
      expect(target.readAsStringSync(), 'new');
      expect(part.existsSync(), isFalse);
      expect(siblingLitter(), isEmpty);
    });

    test(
      'refuses to replace a symlink, leaving it and its target intact',
      () async {
        final realTarget = await putFile('real', 'safe');
        final link = Link(pathOf('lnk'));
        await link.create(realTarget.path);
        final part = await putFile('part', 'new');
        await expectLater(
          replaceLocalFile(part, File(link.path)),
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.message,
              'message',
              contains('Refusing to replace'),
            ),
          ),
        );
        expect(await link.target(), realTarget.path);
        expect(realTarget.readAsStringSync(), 'safe');
        expect(siblingLitter(), isEmpty);
      },
    );

    test('refuses to replace a directory', () async {
      final dir = await Directory(pathOf('dir')).create();
      final part = await putFile('part', 'new');
      await expectLater(
        replaceLocalFile(part, File(dir.path)),
        throwsA(isA<FileSystemException>()),
      );
      expect(dir.existsSync(), isTrue);
      expect(siblingLitter(), isEmpty);
    });

    test('restores the original when the second rename fails', () async {
      final target = await putFile('data', 'old');
      // A part that vanished before its rename — the deterministic
      // mid-dance failure.
      final ghost = File(pathOf('missing-part'));
      await expectLater(
        replaceLocalFile(ghost, target),
        throwsA(isA<FileSystemException>()),
      );
      expect(target.readAsStringSync(), 'old');
      expect(siblingLitter(), isEmpty);
    });

    test(
      'fails before any rename when the backup name would overflow',
      () async {
        final longName = 'n' * 250;
        final target = await putFile(longName, 'original');
        final part = await putFile('part', 'new');
        await expectLater(
          replaceLocalFile(part, target),
          throwsA(
            isA<FileSystemException>().having(
              (error) => error.message,
              'message',
              contains('file-name limit'),
            ),
          ),
        );
        expect(target.readAsStringSync(), 'original');
        expect(siblingLitter(), isEmpty);
      },
    );

    test('counts a lone surrogate as three backup-name bytes', () async {
      // A lone surrogate has no valid UTF-8 form, but Dart's encoder
      // emits it as a 3-byte (WTF-8-style) sequence; the guard must
      // fail before any rename rather than under-count.
      final name = 'm' * 227 + '\uDC00';
      final target = File(pathOf(name));
      await target.writeAsString('original');
      final part = await putFile('part', 'new');
      await expectLater(
        replaceLocalFile(part, target),
        throwsA(isA<FileSystemException>()),
      );
      expect(target.readAsStringSync(), 'original');
      expect(siblingLitter(), isEmpty);
    });

    test('restores a crashed replace before running a new one', () async {
      // Simulate the crash window: the target was already parked under
      // its backup sibling when the process died.
      final crashed = await putFile('data', 'stranded');
      final backupPath = pathOf('data.poltergeist-0123abcd.backup');
      await crashed.rename(backupPath);

      final part = await putFile('part', 'new');
      await replaceLocalFile(part, File(pathOf('data')));

      expect(File(pathOf('data')).readAsStringSync(), 'new');
      // Without the pre-replace sweep, the stranded old content would
      // survive as a hidden orphan beside the fresh target.
      expect(siblingLitter(), isEmpty);
    });
  });

  group('restoreOrphanedLocalBackups', () {
    test('restores an orphan whose target is absent', () async {
      final orphan = await putFile(
        'data.poltergeist-0123abcd.backup',
        'stranded',
      );
      await restoreOrphanedLocalBackups(root);
      final restored = File(pathOf('data'));
      expect(restored.readAsStringSync(), 'stranded');
      expect(orphan.existsSync(), isFalse);
    });

    test('leaves a backup whose target still exists', () async {
      final stale = await putFile('data.poltergeist-0123abcd.backup', 'stale');
      final target = await putFile('data', 'current');
      await restoreOrphanedLocalBackups(root);
      expect(target.readAsStringSync(), 'current');
      expect(stale.readAsStringSync(), 'stale');
    });

    test('ignores names outside the backup pattern', () async {
      final notHex = await putFile('x.poltergeist-nothexx.backup', 'a');
      final noPrefix = await putFile('y.backup', 'b');
      final temp = await putFile('z.poltergeist-0123abcd.backup.tmp', 'c');
      final plain = await putFile('plain', 'd');
      await restoreOrphanedLocalBackups(root);
      expect(notHex.readAsStringSync(), 'a');
      expect(noPrefix.readAsStringSync(), 'b');
      expect(temp.readAsStringSync(), 'c');
      expect(plain.readAsStringSync(), 'd');
    });

    test('ignores a non-file entry shaped like a backup', () async {
      await Directory(pathOf('d.poltergeist-0123abcd.backup')).create();
      await restoreOrphanedLocalBackups(root);
      expect(
        FileSystemEntity.typeSync(pathOf('d.poltergeist-0123abcd.backup')),
        FileSystemEntityType.directory,
      );
    });

    test('with several orphans for one target, the newest wins', () async {
      final older = await putFile('a.poltergeist-11111111.backup', 'older');
      final newer = await putFile('a.poltergeist-22222222.backup', 'newer');
      await older.setLastModified(DateTime(2020, 1, 1));
      await newer.setLastModified(DateTime(2021, 1, 1));
      await restoreOrphanedLocalBackups(root);
      expect(File(pathOf('a')).readAsStringSync(), 'newer');
      // The loser stays parked under its own suffixed name — never
      // deleted; a later sweep skips it because the target now exists.
      expect(older.readAsStringSync(), 'older');
    });
  });

  group('Séance parity — the recursive-download commit shape', () {
    // Ported (adapted) from Séance
    // app/seance_app/test/remote_files_controller_test.dart @ 2e6d1f1,
    // test 'recursively uploads and downloads directories with aggregate
    // transfer' — the download half: nested destination creation, the
    // .part staging, and the backup-rename commit. Re-homed per 08 §2 to
    // the public helpers that now own the behavior; the controller-level
    // aggregate-transfer bookkeeping rides M4's transfer queue.
    test('commits a downloaded tree through the helpers', () async {
      final destination = pathOf('downloads');
      // The remote plan: folder/child.txt (Séance's fixture bytes).
      await ensureSafeLocalDirectory(p.join(destination, 'folder'));
      final local = File(p.join(destination, 'folder', 'child.txt'));
      final partial = File('${local.path}.poltergeist-0123abcd.part');
      await partial.create(exclusive: true);
      await partial.writeAsBytes([1, 2, 3]);
      try {
        await replaceLocalFile(partial, local);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
      expect(await local.readAsBytes(), [1, 2, 3]);
      expect(siblingLitter(), isEmpty);

      // Séance's overwrite branch: an existing local file with
      // overwriteExisting set goes through the same dance.
      final again = File('${local.path}.poltergeist-4567efab.part');
      await again.create(exclusive: true);
      await again.writeAsBytes([4, 5]);
      try {
        await replaceLocalFile(again, local);
      } finally {
        if (await again.exists()) await again.delete();
      }
      expect(await local.readAsBytes(), [4, 5]);
      expect(siblingLitter(), isEmpty);
    });
  });
}
