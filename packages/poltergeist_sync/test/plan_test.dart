@TestOn('vm')
library;

import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

void main() {
  group('SyncRuleSet defaults (05 §6)', () {
    const rules = SyncRuleSet();

    test('match the spec', () {
      expect(rules.direction, SyncDirection.leftToRight);
      expect(rules.deletions, DeletionPolicy.none);
      expect(rules.backups, BackupPolicy.trash);
      expect(rules.comparison, ComparisonMode.sizeAndMtime);
      expect(rules.mtimeToleranceSecs, 2);
      expect(rules.acceptedTimeShifts, isEmpty);
      expect(rules.conflictDefault, ConflictDefault.ask);
      expect(rules.excludeGlobs, isEmpty);
      expect(rules.includeHidden, isTrue);
      expect(rules.symlinks, SymlinkPolicy.skip);
      expect(rules.trashPathLeft, isNull);
      expect(rules.trashPathRight, isNull);
      expect(rules.maxDelete, 500);
      expect(rules.deleteFractionWarn, 0.5);
      expect(rules.preserveMtime, isTrue);
      expect(rules.transferConcurrency, 4);
    });

    test('transferConcurrency clamps to 1..8', () {
      expect(const SyncRuleSet(transferConcurrency: 0).transferConcurrency, 1);
      expect(const SyncRuleSet(transferConcurrency: 99).transferConcurrency, 8);
    });

    test('the other numeric knobs refuse nonsense values', () {
      // maxDelete 0 would trip the delete cap on the first deletion;
      // DeletionPolicy.none already expresses "no deletes".
      expect(const SyncRuleSet(maxDelete: 0).maxDelete, 1);
      expect(const SyncRuleSet(maxDelete: -3).maxDelete, 1);
      // A negative tolerance made |Δ| <= tolerance always false — every
      // equal file would look different.
      expect(const SyncRuleSet(mtimeToleranceSecs: -1).mtimeToleranceSecs, 0);
      expect(
        const SyncRuleSet(deleteFractionWarn: -0.5).deleteFractionWarn,
        0.0,
      );
      expect(
        const SyncRuleSet(deleteFractionWarn: 1.5).deleteFractionWarn,
        1.0,
      );
    });

    test('structurally equal sets compare equal', () {
      const a = SyncRuleSet(
        deletions: DeletionPolicy.trash,
        excludeGlobs: ['*.log'],
        acceptedTimeShifts: [3600],
        maxDelete: 100,
      );
      const b = SyncRuleSet(
        deletions: DeletionPolicy.trash,
        excludeGlobs: ['*.log'],
        acceptedTimeShifts: [3600],
        maxDelete: 100,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(const SyncRuleSet())));
      expect(a, isNot(equals(const SyncRuleSet(excludeGlobs: ['*.tmp']))));
    });
  });

  group('SyncRuleSet.copyWith', () {
    const full = SyncRuleSet(
      direction: SyncDirection.rightToLeft,
      deletions: DeletionPolicy.permanent,
      backups: BackupPolicy.none,
      comparison: ComparisonMode.contentHash,
      mtimeToleranceSecs: 5,
      acceptedTimeShifts: [3600, 7200],
      conflictDefault: ConflictDefault.keepRight,
      excludeGlobs: ['*.log'],
      includeHidden: false,
      symlinks: SymlinkPolicy.copyAsLink,
      trashPathLeft: '/l/trash',
      trashPathRight: '/r/trash',
      maxDelete: 9,
      deleteFractionWarn: 0.25,
      preserveMtime: false,
      transferConcurrency: 7,
    );

    test('with no arguments is a structurally equal copy', () {
      // Every field survives — the regression the pair editor had was
      // a rebuild that dropped acceptedTimeShifts and symlinks.
      expect(full.copyWith(), equals(full));
      expect(full.copyWith().symlinks, SymlinkPolicy.copyAsLink);
      expect(full.copyWith().acceptedTimeShifts, [3600, 7200]);
    });

    test('replaces only the named fields', () {
      final copy = full.copyWith(
        comparison: ComparisonMode.sizeOnly,
        includeHidden: true,
      );
      expect(copy.comparison, ComparisonMode.sizeOnly);
      expect(copy.includeHidden, isTrue);
      expect(copy.excludeGlobs, ['*.log']);
      expect(copy.maxDelete, 9);
      expect(copy.trashPathRight, '/r/trash');
    });

    test('trash-path getters can clear a path', () {
      final copy = full.copyWith(trashPathLeft: () => null);
      expect(copy.trashPathLeft, isNull);
      expect(copy.trashPathRight, '/r/trash');
      expect(
        full.copyWith(trashPathRight: () => '/elsewhere').trashPathRight,
        '/elsewhere',
      );
    });

    test('refuses a bidirectional set that still deletes', () {
      // A copy never guesses which field the caller meant — switching
      // to Additive has to drop the deletion policy explicitly.
      expect(
        () => full.copyWith(direction: SyncDirection.bidirectional),
        throwsArgumentError,
      );
      final additive = full.copyWith(
        direction: SyncDirection.bidirectional,
        deletions: DeletionPolicy.none,
      );
      expect(additive.direction, SyncDirection.bidirectional);
      expect(additive.deletions, DeletionPolicy.none);
    });

    test('keeps the constructor clamps', () {
      final copy = const SyncRuleSet().copyWith(
        mtimeToleranceSecs: -3,
        transferConcurrency: 99,
      );
      expect(copy.mtimeToleranceSecs, 0);
      expect(copy.transferConcurrency, 8);
    });
  });

  group('the three v1 modes encode as direction x deletion policy', () {
    test('Update: one-way, no deletions', () {
      const update = SyncRuleSet();
      expect(update.direction, SyncDirection.leftToRight);
      expect(update.deletions, DeletionPolicy.none);
    });

    test('Mirror: one-way with deletions', () {
      const mirror = SyncRuleSet(deletions: DeletionPolicy.trash);
      expect(mirror.deletions, isNot(DeletionPolicy.none));
    });

    test('Additive two-way: bidirectional, never deletes', () {
      const additive = SyncRuleSet(direction: SyncDirection.bidirectional);
      expect(additive.direction, SyncDirection.bidirectional);
      expect(additive.deletions, DeletionPolicy.none);
      // Not a v1 mode — the constructor refuses the combination rather
      // than letting a nonsense set reach the differ.
      expect(
        () => SyncRuleSet(
          direction: SyncDirection.bidirectional,
          deletions: DeletionPolicy.trash,
        ),
        throwsA(isA<AssertionError>()),
      );
      // The runtime twin of the assert (for release builds, where the
      // assert is stripped) accepts every supported combination and
      // rejects the invalid one — the static form is directly testable
      // where the constructor's own assert fires first in debug.
      const SyncRuleSet().ensureSupported();
      const SyncRuleSet(deletions: DeletionPolicy.trash).ensureSupported();
      const SyncRuleSet(
        direction: SyncDirection.bidirectional,
      ).ensureSupported();
      expect(
        () => SyncRuleSet.validateDirectionDeletions(
          SyncDirection.bidirectional,
          DeletionPolicy.trash,
        ),
        throwsArgumentError,
      );
      expect(
        () => SyncRuleSet.validateDirectionDeletions(
          SyncDirection.bidirectional,
          DeletionPolicy.none,
        ),
        returnsNormally,
      );
    });
  });

  group('SyncItem', () {
    test('starts pending, un-overridden, effective = suggested', () {
      final item = SyncItem(
        relativePath: 'a.txt',
        left: const EntrySnapshot(kind: EntryKind.file, size: 1),
        right: null,
        suggested: SyncActionType.copyLeftToRight,
        effective: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );

      expect(item.status, SyncItemStatus.pending);
      expect(item.userOverridden, isFalse);
      expect(item.error, isNull);
      // The mutable fields move at override/execution time.
      item.effective = SyncActionType.skip;
      item.userOverridden = true;
      expect(item.effective, SyncActionType.skip);
      expect(item.userOverridden, isTrue);
    });
  });

  group('SyncPair', () {
    test('holds endpoints and rules', () {
      final pair = SyncPair(
        id: 'p1',
        name: 'local mirror',
        left: const LocalEndpoint('/a'),
        right: const LocalEndpoint('/b'),
        rules: const SyncRuleSet(),
      );

      expect(pair.left, isA<LocalEndpoint>());
      expect((pair.left as LocalEndpoint).path, '/a');
      expect(pair.lastRunAt, isNull);
    });
  });
}
