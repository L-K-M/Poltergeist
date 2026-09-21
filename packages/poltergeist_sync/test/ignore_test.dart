@TestOn('vm')
library;

import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

void main() {
  group('SyncIgnoreRules', () {
    bool excluded(
      List<String> globs,
      String path, {
      bool isDirectory = false,
      bool includeHidden = true,
      String? trashRelativePath,
    }) => SyncIgnoreRules(
      excludeGlobs: globs,
      includeHidden: includeHidden,
      trashRelativePath: trashRelativePath,
    ).isExcluded(path, isDirectory: isDirectory);

    test('a slash-free pattern floats to every basename', () {
      expect(excluded(['*.log'], 'a.log'), isTrue);
      expect(excluded(['*.log'], 'x/y/b.log'), isTrue);
      expect(excluded(['*.log'], 'a.txt'), isFalse);
    });

    test('? matches one non-separator character', () {
      expect(excluded(['a?.txt'], 'ab.txt'), isTrue);
      expect(excluded(['a?.txt'], 'a/b.txt'), isFalse);
      expect(excluded(['a?.txt'], 'axb.txt'), isFalse);
    });

    test('a pattern with a middle slash anchors to the root', () {
      expect(excluded(['doc/*.md'], 'doc/a.md'), isTrue);
      expect(excluded(['doc/*.md'], 'x/doc/a.md'), isFalse);
    });

    test('a leading slash anchors to the root', () {
      expect(excluded(['/root.txt'], 'root.txt'), isTrue);
      expect(excluded(['/root.txt'], 'sub/root.txt'), isFalse);
    });

    test('** crosses separators', () {
      expect(excluded(['**/gen'], 'a/b/gen'), isTrue);
      expect(excluded(['**/gen'], 'gen'), isTrue);
      expect(excluded(['a/**/b'], 'a/b'), isTrue);
      expect(excluded(['a/**/b'], 'a/x/y/b'), isTrue);
      expect(excluded(['a/**'], 'a/x/y/z'), isTrue);
      expect(excluded(['**'], 'anything/at/all'), isTrue);
    });

    test('a trailing slash matches directories only', () {
      expect(excluded(['build/'], 'build', isDirectory: true), isTrue);
      expect(excluded(['build/'], 'build'), isFalse);
    });

    test('an excluded directory prunes its whole subtree', () {
      // The scanner never descends an excluded directory, but lookups on
      // deeper paths (the differ, the rsync exporter) must still answer
      // excluded — the ancestor check makes exclusion a property of the
      // path, not of the walk order.
      expect(excluded(['build/'], 'build/out.bin'), isTrue);
      expect(excluded(['build/'], 'build/x/y/out.bin'), isTrue);
    });

    test('! re-includes within its own rule list', () {
      expect(excluded(['*.log', '!keep.log'], 'a.log'), isTrue);
      expect(excluded(['*.log', '!keep.log'], 'keep.log'), isFalse);
    });

    test('! cannot resurrect a name inside an excluded directory', () {
      expect(
        excluded(['build/', '!build/keep.txt'], 'build/keep.txt'),
        isTrue,
      );
    });

    test('blank lines and # comments are ignored', () {
      expect(excluded(['', '# comment', 'a.txt'], 'a.txt'), isTrue);
      expect(excluded(['#a.txt'], 'b.txt'), isFalse);
    });

    test(r'\! and \# escape to literal names', () {
      expect(excluded([r'\!bang.txt'], '!bang.txt'), isTrue);
      expect(excluded([r'\#hash.txt'], '#hash.txt'), isTrue);
    });

    test('app defaults apply without any user rules', () {
      expect(excluded([], '.DS_Store'), isTrue);
      expect(excluded([], 'sub/Thumbs.db'), isTrue);
      expect(excluded([], 'desktop.ini'), isTrue);
      expect(excluded([], '.poltergeist-trash/x.txt'), isTrue);
      expect(excluded([], 'x.poltergeist-1.tmp'), isTrue);
      expect(excluded([], 'normal.txt'), isFalse);
    });

    test('user negations cannot re-include the app defaults', () {
      expect(excluded(['!*'], '.DS_Store'), isTrue);
      expect(excluded(['!.DS_Store'], '.DS_Store'), isTrue);
      expect(excluded(['!*.poltergeist-*'], 'x.poltergeist-1.tmp'), isTrue);
    });

    test('includeHidden: false inserts .* before the defaults', () {
      expect(
        excluded([], '.hidden', includeHidden: false),
        isTrue,
      );
      expect(
        excluded([], 'sub/.hidden', includeHidden: false),
        isTrue,
      );
      expect(
        excluded(['!*.important'], '.important', includeHidden: false),
        // The hidden rule sits AFTER user rules (05 §2.1's ordering), so
        // a user re-include cannot resurrect hidden files either.
        isTrue,
      );
      expect(excluded([], '.hidden'), isFalse);
    });

    test('the trash root is always excluded', () {
      expect(
        excluded([], '.trash/deleted.txt', trashRelativePath: '.trash'),
        isTrue,
      );
      expect(
        excluded([], '.trash', isDirectory: true, trashRelativePath: '.trash'),
        isTrue,
      );
      // A lookalike prefix must not exclude.
      expect(
        excluded([], '.trashy/x.txt', trashRelativePath: '.trash'),
        isFalse,
      );
      // Negations cannot re-include it either.
      expect(
        excluded(['!*'], '.trash/deleted.txt', trashRelativePath: '.trash'),
        isTrue,
      );
    });

    test('an empty or malformed trash root is rejected', () {
      expect(
        () => SyncIgnoreRules(trashRelativePath: ''),
        throwsArgumentError,
      );
      expect(
        () => SyncIgnoreRules(trashRelativePath: r'a\b'),
        throwsArgumentError,
      );
      expect(
        () => SyncIgnoreRules(trashRelativePath: 'a/'),
        throwsArgumentError,
      );
      // A leading separator would silently exclude nothing — the
      // relative keys it is compared against never carry one.
      expect(
        () => SyncIgnoreRules(trashRelativePath: '/a'),
        throwsArgumentError,
      );
      expect(
        () => SyncIgnoreRules(trashRelativePath: 'a/../b'),
        throwsArgumentError,
      );
      expect(
        () => SyncIgnoreRules(trashRelativePath: 'a/./b'),
        throwsArgumentError,
      );
    });
  });
}
