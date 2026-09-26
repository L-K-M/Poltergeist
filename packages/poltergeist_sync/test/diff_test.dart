@TestOn('vm')
library;

import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

void main() {
  EntrySnapshot file({int size = 10, int? mtime = 100}) => EntrySnapshot(
    kind: EntryKind.file,
    size: size,
    mtimeSecs: mtime,
  );
  const dir = EntrySnapshot(kind: EntryKind.directory);
  const link = EntrySnapshot(kind: EntryKind.symlink, symlinkTarget: 'x');

  ScanResult scan(
    Map<String, EntrySnapshot> entries, {
    bool caseSensitive = true,
    CaseSensitivityBasis basis = CaseSensitivityBasis.probe,
    List<ScanWarning> warnings = const [],
    String rootPath = '/root',
  }) => ScanResult(
    rootPath: rootPath,
    entries: entries,
    warnings: warnings,
    caseSensitive: caseSensitive,
    caseSensitivityBasis: basis,
  );

  ScanWarning listingFailure(String path, {SyncSide side = SyncSide.left}) =>
      ScanWarning(
        relativePath: path,
        side: side,
        message: 'cannot list',
        kind: ScanWarningKind.listingFailure,
      );

  SyncPair pair(SyncRuleSet rules) => SyncPair(
    id: 'pair-1',
    name: 'test pair',
    left: const LocalEndpoint('/l'),
    right: const LocalEndpoint('/r'),
    rules: rules,
  );

  SyncItem itemOf(SyncPlan plan, String path) =>
      plan.items.singleWhere((i) => i.relativePath == path);

  group('Update (leftToRight, deletions none)', () {
    const rules = SyncRuleSet(direction: SyncDirection.leftToRight);

    test('a left-only file copies; a right-only file skips', () async {
      final plan = await diffScans(
        left: scan({'a.txt': file(), 'b.txt': file()}),
        right: scan({'b.txt': file(), 'c.txt': file()}),
        pair: pair(rules),
      );
      expect(itemOf(plan, 'a.txt').effective, SyncActionType.copyLeftToRight);
      expect(itemOf(plan, 'a.txt').reason, SyncReason.onlyOnLeft);
      expect(itemOf(plan, 'c.txt').effective, SyncActionType.skip);
      expect(itemOf(plan, 'c.txt').reason, SyncReason.onlyOnRight);
      expect(itemOf(plan, 'b.txt').effective, SyncActionType.skip);
      expect(itemOf(plan, 'b.txt').reason, SyncReason.equal);
    });

    test('the source wins even when the destination is newer', () async {
      final plan = await diffScans(
        left: scan({'a.txt': file(mtime: 100)}),
        right: scan({'a.txt': file(mtime: 200)}),
        pair: pair(rules),
      );
      final item = itemOf(plan, 'a.txt');
      expect(item.effective, SyncActionType.updateLeftToRight);
      // The backwards-in-time copy stays visible through the reason.
      expect(item.reason, SyncReason.newerOnRight);
    });

    test('a left-only directory makes a dir row', () async {
      final plan = await diffScans(
        left: scan({'d': dir, 'd/f.txt': file()}),
        right: scan({}),
        pair: pair(rules),
      );
      expect(itemOf(plan, 'd').effective, SyncActionType.makeDirRight);
      expect(itemOf(plan, 'd/f.txt').effective, SyncActionType.copyLeftToRight);
    });
  });

  group('Mirror (leftToRight, deletions trash)', () {
    const rules = SyncRuleSet(
      direction: SyncDirection.leftToRight,
      deletions: DeletionPolicy.trash,
    );

    test('a destination-only orphan deletes; source-only copies', () async {
      final plan = await diffScans(
        left: scan({'a.txt': file()}),
        right: scan({'b.txt': file()}),
        pair: pair(rules),
      );
      expect(itemOf(plan, 'a.txt').effective, SyncActionType.copyLeftToRight);
      expect(itemOf(plan, 'b.txt').effective, SyncActionType.deleteRight);
      expect(itemOf(plan, 'b.txt').reason, SyncReason.onlyOnRight);
    });

    test('rightToLeft mirrors the same shape on the left', () async {
      final plan = await diffScans(
        left: scan({'b.txt': file()}),
        right: scan({'a.txt': file()}),
        pair: pair(
          const SyncRuleSet(
            direction: SyncDirection.rightToLeft,
            deletions: DeletionPolicy.trash,
          ),
        ),
      );
      expect(itemOf(plan, 'a.txt').effective, SyncActionType.copyRightToLeft);
      expect(itemOf(plan, 'b.txt').effective, SyncActionType.deleteLeft);
    });
  });

  group('Additive (bidirectional)', () {
    const rules = SyncRuleSet(direction: SyncDirection.bidirectional);

    test('one-sided entries copy both ways', () async {
      final plan = await diffScans(
        left: scan({'a.txt': file()}),
        right: scan({'b.txt': file()}),
        pair: pair(rules),
      );
      expect(itemOf(plan, 'a.txt').effective, SyncActionType.copyLeftToRight);
      expect(itemOf(plan, 'b.txt').effective, SyncActionType.copyRightToLeft);
    });

    test('a differing pair is a bothChanged conflict under ask', () async {
      final plan = await diffScans(
        left: scan({'a.txt': file(mtime: 200)}),
        right: scan({'a.txt': file(mtime: 100, size: 10)}),
        pair: pair(rules),
      );
      final item = itemOf(plan, 'a.txt');
      expect(item.suggested, SyncActionType.conflict);
      expect(item.effective, SyncActionType.conflict);
      expect(item.reason, SyncReason.bothChanged);
    });

    test('newerWins resolves the conflict to the newer side', () async {
      final plan = await diffScans(
        left: scan({'a.txt': file(mtime: 200)}),
        right: scan({'a.txt': file(mtime: 100)}),
        pair: pair(
          const SyncRuleSet(
            direction: SyncDirection.bidirectional,
            conflictDefault: ConflictDefault.newerWins,
          ),
        ),
      );
      expect(itemOf(plan, 'a.txt').effective, SyncActionType.updateLeftToRight);
    });

    test('newerWins degrades to ask when mtimes are untrusted', () async {
      final plan = await diffScans(
        left: scan({'a.txt': file(mtime: 200)}),
        right: scan({'a.txt': file(mtime: 100)}),
        pair: pair(
          const SyncRuleSet(
            direction: SyncDirection.bidirectional,
            conflictDefault: ConflictDefault.newerWins,
          ),
        ),
        mtimeUnreliableLeft: true,
      );
      expect(itemOf(plan, 'a.txt').effective, SyncActionType.conflict);
    });

    test('keepLeft and keepRight resolve directionally', () async {
      final keepLeft = await diffScans(
        left: scan({'a.txt': file(size: 1)}),
        right: scan({'a.txt': file(size: 2)}),
        pair: pair(
          const SyncRuleSet(
            direction: SyncDirection.bidirectional,
            conflictDefault: ConflictDefault.keepLeft,
          ),
        ),
      );
      expect(itemOf(keepLeft, 'a.txt').effective, SyncActionType.updateLeftToRight);
      final keepRight = await diffScans(
        left: scan({'a.txt': file(size: 1)}),
        right: scan({'a.txt': file(size: 2)}),
        pair: pair(
          const SyncRuleSet(
            direction: SyncDirection.bidirectional,
            conflictDefault: ConflictDefault.keepRight,
          ),
        ),
      );
      expect(itemOf(keepRight, 'a.txt').effective, SyncActionType.updateRightToLeft);
    });
  });

  group('typeDiffers (05 §6 rule 4)', () {
    test('a no-delete mode auto-resolves to skip, suggested conflict', () async {
      final plan = await diffScans(
        left: scan({'p': file()}),
        right: scan({'p': dir, 'p/inner.txt': file()}),
        pair: pair(
          const SyncRuleSet(
            direction: SyncDirection.leftToRight,
            conflictDefault: ConflictDefault.keepLeft,
          ),
        ),
      );
      final item = itemOf(plan, 'p');
      expect(item.reason, SyncReason.typeDiffers);
      expect(item.suggested, SyncActionType.conflict);
      expect(item.effective, SyncActionType.skip);
      // The replaced dir's contents are captured for the executor's
      // set-match and the per-file deletion count.
      expect(item.destinationSubtree, contains('p/inner.txt'));
    });

    test('a Mirror conflictDefault resolves to the create verb', () async {
      final plan = await diffScans(
        left: scan({'p': file()}),
        right: scan({'p': dir, 'p/inner.txt': file(size: 7)}),
        pair: pair(
          const SyncRuleSet(
            direction: SyncDirection.leftToRight,
            deletions: DeletionPolicy.trash,
            conflictDefault: ConflictDefault.keepLeft,
          ),
        ),
      );
      final item = itemOf(plan, 'p');
      expect(item.effective, SyncActionType.copyLeftToRight);
      // The embedded pre-delete tolls the removed subtree per file.
      expect(plan.totals.replacedFiles, 1);
      expect(plan.totals.replacedBytes, 7);
    });

    test('keepDestination under a one-way mirror resolves to skip', () async {
      final plan = await diffScans(
        left: scan({'p': file()}),
        right: scan({'p': dir}),
        pair: pair(
          const SyncRuleSet(
            direction: SyncDirection.leftToRight,
            deletions: DeletionPolicy.trash,
            conflictDefault: ConflictDefault.keepRight,
          ),
        ),
      );
      expect(itemOf(plan, 'p').effective, SyncActionType.skip);
    });

    group('a replaced directory subsumes its descendants', () {
      final right = scan({
        'p': dir,
        'p/inner.txt': file(size: 3),
        'p/sub': dir,
        'p/sub/deep.txt': file(size: 4),
      });

      test('a resolved replace is one row whose toll counts each file once',
          () async {
        final plan = await diffScans(
          left: scan({'p': file()}),
          right: right,
          pair: pair(
            const SyncRuleSet(
              direction: SyncDirection.leftToRight,
              deletions: DeletionPolicy.trash,
              conflictDefault: ConflictDefault.keepLeft,
            ),
          ),
        );
        // No separate rows: the parent's pre-delete removes the tree,
        // so a child row would double-count on the rails and then flip
        // to a spurious changed-since-preview conflict (05 §6 rule 4).
        expect(plan.items.map((i) => i.relativePath), ['p']);
        final item = itemOf(plan, 'p');
        expect(item.effective, SyncActionType.copyLeftToRight);
        expect(
          item.destinationSubtree!.keys,
          unorderedEquals(['p/inner.txt', 'p/sub', 'p/sub/deep.txt']),
        );
        expect(plan.totals.replacedFiles, 2);
        expect(assessDeletions(plan).removals[SyncSide.right], 2);
      });

      test('an unresolved kind conflict plans nothing under the directory',
          () async {
        final plan = await diffScans(
          left: scan({'p': file()}),
          right: right,
          pair: pair(
            const SyncRuleSet(
              direction: SyncDirection.leftToRight,
              deletions: DeletionPolicy.permanent,
            ),
          ),
        );
        // Leaving the row undecided must keep the folder whole — its
        // contents must not delete as orphans of their own.
        expect(plan.items.map((i) => i.relativePath), ['p']);
        expect(itemOf(plan, 'p').effective, SyncActionType.conflict);
        expect(assessDeletions(plan).removals[SyncSide.right], 0);
      });

      test('keeping the destination directory keeps its contents', () async {
        final plan = await diffScans(
          left: scan({'p': file()}),
          right: right,
          pair: pair(
            const SyncRuleSet(
              direction: SyncDirection.leftToRight,
              deletions: DeletionPolicy.trash,
              conflictDefault: ConflictDefault.keepRight,
            ),
          ),
        );
        expect(plan.items.map((i) => i.relativePath), ['p']);
        expect(itemOf(plan, 'p').effective, SyncActionType.skip);
      });

      test('Additive subsumes too — either side may be replaced', () async {
        final plan = await diffScans(
          left: scan({'p': file()}),
          right: right,
          pair: pair(
            const SyncRuleSet(direction: SyncDirection.bidirectional),
          ),
        );
        // Copies into a path the other side holds as a file could
        // never run; the kind decision on `p` owns the whole tree.
        expect(plan.items.map((i) => i.relativePath), ['p']);
      });

      test('the subtree follows the directory side\'s own spelling',
          () async {
        // NFC on the left, NFD on the right: one match key, but the
        // right's descendants were scanned under the NFD form.
        final plan = await diffScans(
          left: scan({'caf\u00e9': file()}),
          right: scan({'cafe\u0301': dir, 'cafe\u0301/x.txt': file()}),
          pair: pair(
            const SyncRuleSet(
              direction: SyncDirection.leftToRight,
              deletions: DeletionPolicy.trash,
            ),
          ),
        );
        expect(plan.items.map((i) => i.relativePath), ['caf\u00e9']);
        expect(
          plan.items.single.destinationSubtree!.keys,
          ['cafe\u0301/x.txt'],
        );
      });

      test('a source-side directory keeps its children as copy rows',
          () async {
        // One-way pairs never replace their source: the tree is what a
        // resolved mkdir fills, so its entries plan as usual.
        final plan = await diffScans(
          left: right,
          right: scan({'p': file()}),
          pair: pair(
            const SyncRuleSet(
              direction: SyncDirection.leftToRight,
              deletions: DeletionPolicy.trash,
              conflictDefault: ConflictDefault.keepLeft,
            ),
          ),
        );
        expect(itemOf(plan, 'p').effective, SyncActionType.makeDirRight);
        expect(
          itemOf(plan, 'p/inner.txt').effective,
          SyncActionType.copyLeftToRight,
        );
        expect(
          itemOf(plan, 'p/sub/deep.txt').effective,
          SyncActionType.copyLeftToRight,
        );
      });
    });
  });

  group('scan-error mirror (05 §6 rule 8)', () {
    test(
      'the clean side\'s subtree under a failed listing is skip rows',
      () async {
        final plan = await diffScans(
          left: scan({
            'ok.txt': file(),
          }, warnings: [listingFailure('logs')]),
          right: scan({'logs/a.txt': file(), 'logs/b.txt': file()}),
          pair: pair(
            const SyncRuleSet(
              direction: SyncDirection.leftToRight,
              deletions: DeletionPolicy.trash,
            ),
          ),
        );
        // Mirror would call these orphans and delete them — rule 8's
        // mirror makes them skip rows instead.
        for (final path in ['logs/a.txt', 'logs/b.txt']) {
          final item = itemOf(plan, path);
          expect(item.effective, SyncActionType.skip, reason: path);
          expect(item.reason, SyncReason.scanError, reason: path);
        }
        expect(itemOf(plan, 'ok.txt').effective, SyncActionType.copyLeftToRight);
      },
    );

    test('non-listing warnings do not trigger the mirror', () async {
      final plan = await diffScans(
        left: scan({}, warnings: [
          ScanWarning(
            relativePath: 'logs',
            side: SyncSide.left,
            message: 'informational',
            kind: ScanWarningKind.malformedName,
          ),
        ]),
        right: scan({'logs/a.txt': file()}),
        pair: pair(
          const SyncRuleSet(
            direction: SyncDirection.leftToRight,
            deletions: DeletionPolicy.trash,
          ),
        ),
      );
      expect(itemOf(plan, 'logs/a.txt').effective, SyncActionType.deleteRight);
    });
  });

  group('name hazards (05 §3)', () {
    test('NFC-collision twins are per-path skip items', () async {
      // 'café' NFC vs NFD — different byte forms, one normalized key.
      final plan = await diffScans(
        left: scan({'caf\u00e9.txt': file(), 'cafe\u0301.txt': file()}),
        right: scan({}),
        pair: pair(const SyncRuleSet()),
      );
      expect(plan.items, hasLength(2));
      final items = plan.items.where((i) => i.relativePath.contains('caf'));
      expect(items, hasLength(2));
      for (final item in items) {
        expect(item.reason, SyncReason.normalizationCollision);
        expect(item.effective, SyncActionType.skip);
      }
    });

    test(
      'case variants ask when the destination sensitivity is assumed',
      () async {
        final plan = await diffScans(
          left: scan({'Foo.txt': file(), 'foo.txt': file()}),
          right: scan(
            {},
            caseSensitive: true,
            basis: CaseSensitivityBasis.assumption,
          ),
          pair: pair(const SyncRuleSet()),
        );
        for (final path in ['Foo.txt', 'foo.txt']) {
          final item = itemOf(plan, path);
          expect(item.reason, SyncReason.caseCollision, reason: path);
          expect(item.effective, SyncActionType.conflict, reason: path);
        }
      },
    );

    test(
      'case variants skip against a probed-insensitive destination',
      () async {
        final plan = await diffScans(
          left: scan({'Foo.txt': file(), 'foo.txt': file()}),
          right: scan(
            {},
            caseSensitive: false,
            basis: CaseSensitivityBasis.probe,
          ),
          pair: pair(const SyncRuleSet()),
        );
        for (final path in ['Foo.txt', 'foo.txt']) {
          expect(itemOf(plan, path).effective, SyncActionType.skip,
              reason: path);
        }
      },
    );

    test(
      'case variants plan normally against a probed-sensitive side',
      () async {
        final plan = await diffScans(
          left: scan({'Foo.txt': file(), 'foo.txt': file()}),
          right: scan(
            {},
            caseSensitive: true,
            basis: CaseSensitivityBasis.probe,
          ),
          pair: pair(const SyncRuleSet()),
        );
        expect(
          itemOf(plan, 'Foo.txt').effective,
          SyncActionType.copyLeftToRight,
        );
        expect(
          itemOf(plan, 'foo.txt').effective,
          SyncActionType.copyLeftToRight,
        );
      },
    );

    test('a Windows-invalid name destined for a local side skips', () async {
      final plan = await diffScans(
        left: scan({'con.txt': file(), 'fine.txt': file()}),
        right: scan({}),
        pair: pair(const SyncRuleSet()),
      );
      final item = itemOf(plan, 'con.txt');
      expect(item.reason, SyncReason.invalidNameOnDestination);
      expect(item.effective, SyncActionType.skip);
      expect(itemOf(plan, 'fine.txt').effective, SyncActionType.copyLeftToRight);
    });

    test(
      'a matched invalid name is no hazard — it is written, not created',
      () async {
        final plan = await diffScans(
          left: scan({'con.txt': file(mtime: 200)}),
          right: scan({'con.txt': file(mtime: 100)}),
          pair: pair(const SyncRuleSet()),
        );
        expect(itemOf(plan, 'con.txt').effective, SyncActionType.updateLeftToRight);
      },
    );

    test('a hazard counterpart never plans as an orphan delete', () async {
      final plan = await diffScans(
        left: scan({'caf\u00e9.txt': file(), 'cafe\u0301.txt': file()}),
        right: scan({'caf\u00e9.txt': file()}),
        pair: pair(
          const SyncRuleSet(
            direction: SyncDirection.leftToRight,
            deletions: DeletionPolicy.trash,
          ),
        ),
      );
      // Right's café.txt is absorbed into the hazard rows — no third
      // item, and nothing deletes it.
      expect(plan.items, hasLength(2));
      expect(
        plan.items.where((i) => i.effective == SyncActionType.deleteRight),
        isEmpty,
      );
    });
  });

  group('symlinks (05 §3)', () {
    test('a one-sided symlink skips, never an orphan', () async {
      final plan = await diffScans(
        left: scan({'l': link}),
        right: scan({}),
        pair: pair(
          const SyncRuleSet(
            direction: SyncDirection.leftToRight,
            deletions: DeletionPolicy.trash,
          ),
        ),
      );
      expect(itemOf(plan, 'l').effective, SyncActionType.skip);
      expect(itemOf(plan, 'l').reason, SyncReason.excluded);
    });

    test('a file-vs-link pair is typeDiffers with skip', () async {
      final plan = await diffScans(
        left: scan({'p': file()}),
        right: scan({'p': link}),
        pair: pair(
          const SyncRuleSet(
            direction: SyncDirection.leftToRight,
            deletions: DeletionPolicy.trash,
          ),
        ),
      );
      final item = itemOf(plan, 'p');
      expect(item.reason, SyncReason.typeDiffers);
      expect(item.effective, SyncActionType.skip);
    });

    const mirror = SyncRuleSet(
      direction: SyncDirection.leftToRight,
      deletions: DeletionPolicy.trash,
    );

    test('the real directory under a source-side link is never an orphan',
        () async {
      final plan = await diffScans(
        left: scan({'data': link, 'keep.txt': file()}),
        right: scan({
          'data': dir,
          'data/photo1.jpg': file(),
          'data/sub': dir,
          'data/sub/photo2.jpg': file(),
          'keep.txt': file(),
        }),
        pair: pair(mirror),
      );
      // The link is excluded on both sides like a scan error: its
      // counterpart tree is skip rows a Mirror can never delete.
      expect(itemOf(plan, 'data').reason, SyncReason.typeDiffers);
      expect(itemOf(plan, 'data').effective, SyncActionType.skip);
      for (final path in [
        'data/photo1.jpg',
        'data/sub',
        'data/sub/photo2.jpg',
      ]) {
        final item = itemOf(plan, path);
        expect(item.effective, SyncActionType.skip, reason: path);
        expect(item.reason, SyncReason.excluded, reason: path);
      }
      expect(assessDeletions(plan).removals[SyncSide.right], 0);
    });

    test('a destination-side link is never written through', () async {
      final plan = await diffScans(
        left: scan({'p': dir, 'p/a.txt': file(), 'p/sub': dir}),
        right: scan({'p': link}),
        pair: pair(mirror),
      );
      // A copy under the link could only fail rail 7's parent-chain
      // check and gate the whole delete phase — it plans skip instead.
      for (final path in ['p/a.txt', 'p/sub']) {
        final item = itemOf(plan, path);
        expect(item.effective, SyncActionType.skip, reason: path);
        expect(item.reason, SyncReason.excluded, reason: path);
      }
    });

    test('the exclusion follows the match key across case folding', () async {
      final plan = await diffScans(
        left: scan({'Data': link}),
        right: scan(
          {'data': dir, 'data/photo.jpg': file()},
          caseSensitive: false,
        ),
        pair: pair(mirror),
      );
      expect(itemOf(plan, 'Data').effective, SyncActionType.skip);
      expect(itemOf(plan, 'data/photo.jpg').effective, SyncActionType.skip);
      expect(itemOf(plan, 'data/photo.jpg').reason, SyncReason.excluded);
    });
  });

  group('plan bookkeeping', () {
    test('items are path-sorted and totals count effective actions', () async {
      final plan = await diffScans(
        left: scan({'z.txt': file(size: 5), 'a.txt': file(size: 3)}),
        right: scan({'m.txt': file()}),
        pair: pair(const SyncRuleSet()),
      );
      expect(
        plan.items.map((i) => i.relativePath).toList(),
        ['a.txt', 'm.txt', 'z.txt'],
      );
      expect(plan.totals.counts[SyncActionType.copyLeftToRight], 2);
      expect(plan.totals.bytes[SyncActionType.copyLeftToRight], 8);
      expect(plan.totals.counts[SyncActionType.skip], 1);
      expect(plan.leftFileCount, 2);
      expect(plan.rightFileCount, 1);
    });

    test('warnings from both scans land on the plan', () async {
      final plan = await diffScans(
        left: scan({}, warnings: [listingFailure('x')]),
        right: scan({}, warnings: [listingFailure('y', side: SyncSide.right)]),
        pair: pair(const SyncRuleSet()),
      );
      expect(plan.warnings, hasLength(2));
    });
  });

  group('contentHash (05 §4)', () {
    test('requires both side file systems', () {
      expect(
        diffScans(
          left: scan({'a.txt': file()}),
          right: scan({'a.txt': file()}),
          pair: pair(
            const SyncRuleSet(comparison: ComparisonMode.contentHash),
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('size-equal pairs with different bytes differ', () async {
      final leftDir = await Directory.systemTemp.createTemp('syncdiff-l');
      final rightDir = await Directory.systemTemp.createTemp('syncdiff-r');
      addTearDown(() async {
        await leftDir.delete(recursive: true);
        await rightDir.delete(recursive: true);
      });
      await File('${leftDir.path}/a.txt').writeAsBytes([1, 2, 3]);
      await File('${rightDir.path}/a.txt').writeAsBytes([1, 2, 9]);
      final plan = await diffScans(
        left: scan({'a.txt': file(size: 3)}, rootPath: leftDir.path),
        right: scan({'a.txt': file(size: 3)}, rootPath: rightDir.path),
        pair: pair(
          const SyncRuleSet(comparison: ComparisonMode.contentHash),
        ),
        leftFileSystem: LocalFileSystem(),
        rightFileSystem: LocalFileSystem(),
      );
      final item = itemOf(plan, 'a.txt');
      expect(item.reason, SyncReason.contentDiffers);
      expect(item.effective, SyncActionType.updateLeftToRight);
    });

    test('size-equal pairs with identical bytes compare equal', () async {
      final leftDir = await Directory.systemTemp.createTemp('syncdiff-l');
      final rightDir = await Directory.systemTemp.createTemp('syncdiff-r');
      addTearDown(() async {
        await leftDir.delete(recursive: true);
        await rightDir.delete(recursive: true);
      });
      await File('${leftDir.path}/a.txt').writeAsBytes([4, 5, 6]);
      await File('${rightDir.path}/a.txt').writeAsBytes([4, 5, 6]);
      final plan = await diffScans(
        // Deliberately different mtimes: content decides, not the clock.
        left: scan({'a.txt': file(size: 3, mtime: 100)}, rootPath: leftDir.path),
        right: scan({'a.txt': file(size: 3, mtime: 999)}, rootPath: rightDir.path),
        pair: pair(
          const SyncRuleSet(comparison: ComparisonMode.contentHash),
        ),
        leftFileSystem: LocalFileSystem(),
        rightFileSystem: LocalFileSystem(),
      );
      expect(itemOf(plan, 'a.txt').effective, SyncActionType.skip);
      expect(itemOf(plan, 'a.txt').reason, SyncReason.equal);
    });
  });
}
