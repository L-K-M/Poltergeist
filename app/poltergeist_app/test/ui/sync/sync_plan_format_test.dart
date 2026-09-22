// The §7 copy contract (M8): header clauses, action glyphs, reason
// strings, and the rail-3 trigger line — asserted verbatim so a copy
// regression fails a test, never a release.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/ui/sync/sync_plan_format.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../support/sync_harness.dart';

final _l10n = AppLocalizationsEn();

Future<SyncPlanController> _readyController(
  SyncPair pair,
  SyncPlan plan,
) async {
  final controller = testController(
    pair: pair,
    scanner: FakeSyncScanner(
      left: testScanResult('/left', const {}),
      right: testScanResult('/right', const {}),
    ),
    differ: FakeSyncDiffer(plan),
    environment: testSyncEnvironment(
      Directory.systemTemp.createTempSync(),
    ),
    syncTasks: SyncQueueTasks(),
  );
  addTearDown(controller.dispose);
  controller.start();
  await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
  return controller;
}

void main() {
  group('syncActionGlyph', () {
    test('maps every action to its §7 glyph', () {
      expect(
        syncActionGlyph(SyncActionType.copyLeftToRight),
        '→',
      );
      expect(
        syncActionGlyph(SyncActionType.updateLeftToRight),
        '⇒',
      );
      expect(
        syncActionGlyph(SyncActionType.copyRightToLeft),
        '←',
      );
      expect(
        syncActionGlyph(SyncActionType.updateRightToLeft),
        '⇐',
      );
      expect(syncActionGlyph(SyncActionType.makeDirLeft), '⊞');
      expect(syncActionGlyph(SyncActionType.deleteRight), '✕');
      expect(syncActionGlyph(SyncActionType.conflict), '↯');
      expect(syncActionGlyph(SyncActionType.skip), '–');
    });
  });

  group('header clauses', () {
    test('the one-way copy clause is §7 verbatim', () async {
      final pair = testSyncPair(
        left: '/home/me/docs',
        right: '/srv/www/docs',
      );
      final controller = await _readyController(
        pair,
        testPlan(pair, [
          testItem(
            'a.txt',
            left: testFile(size: 2048),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
          testItem(
            'b.txt',
            left: testFile(size: 10),
            right: testFile(size: 10),
            suggested: SyncActionType.updateLeftToRight,
            reason: SyncReason.newerOnLeft,
          ),
        ]),
      );
      expect(
        syncHeaderClauses(_l10n, controller),
        [
          'Copy 1 new file (2.0 KB), and update 1 on docs.',
          'Nothing will be deleted.',
        ],
      );
    });

    test('a dirs-only plan renders the folder-only headline', () async {
      final pair = testSyncPair();
      final controller = await _readyController(
        pair,
        testPlan(pair, [
          testItem(
            'sub',
            left: testDir,
            suggested: SyncActionType.makeDirRight,
            reason: SyncReason.onlyOnLeft,
          ),
        ]),
      );
      expect(
        syncHeaderClauses(_l10n, controller),
        ['Create 1 folder on right.', 'Nothing will be deleted.'],
      );
    });

    test('Additive aggregates both directions onto "both sides"',
        () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
      );
      final controller = await _readyController(
        pair,
        testPlan(pair, [
          testItem(
            'a.txt',
            left: testFile(size: 4),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
          testItem(
            'b.txt',
            right: testFile(size: 6),
            suggested: SyncActionType.copyRightToLeft,
            reason: SyncReason.onlyOnRight,
          ),
        ]),
      );
      expect(
        syncHeaderClauses(_l10n, controller),
        [
          'Copy 2 new files (10 B) on both sides.',
          'Nothing will be deleted.',
        ],
      );
    });

    test('deletion clauses distinguish trash from permanent', () async {
      final trashed = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      final trashedController = await _readyController(
        trashed,
        testPlan(trashed, [
          testItem(
            'old.txt',
            right: testFile(),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
        ]),
      );
      expect(
        syncHeaderClauses(_l10n, trashedController),
        [
          'Delete 1 file on right '
          '(moved to trash at .poltergeist-trash).',
        ],
      );

      final permanent = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.permanent),
      );
      final permanentController = await _readyController(
        permanent,
        testPlan(permanent, [
          testItem(
            'old.txt',
            right: testFile(),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
        ]),
      );
      expect(
        syncHeaderClauses(_l10n, permanentController),
        ['Delete 1 file on right permanently.'],
      );
    });

    test('a type-change replace carries its own clause', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      final controller = await _readyController(
        pair,
        testPlan(pair, [
          testItem(
            'thing',
            left: testFile(size: 3),
            right: testDir,
            suggested: SyncActionType.updateLeftToRight,
            reason: SyncReason.typeDiffers,
            destinationSubtree: const {
              'thing/a.txt': EntrySnapshot(
                kind: EntryKind.file,
                size: 1,
              ),
              'thing/b.txt': EntrySnapshot(
                kind: EntryKind.file,
                size: 2,
              ),
            },
          ),
        ]),
      );
      expect(
        syncHeaderClauses(_l10n, controller),
        [
          'update 1 on right.',
          // §7: {j} counts ROWS (one per replaced path) — the row's
          // 2-file toll rides the chip/rails/typed gate, not this
          // clause.
          'Replace 1 file of a different kind on right '
          '(previous version moved to trash at .poltergeist-trash).',
        ],
      );
    });

    test('empty-folder cleanups replace the green tail, never sit '
        'beside it', () async {
      // §7 + rail 3: a plan whose only removals are empty-dir cleanups
      // renders the Remove tail INSTEAD of 'Nothing will be deleted.'
      final pair = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      final controller = await _readyController(
        pair,
        testPlan(pair, [
          testItem(
            'empty',
            right: testDir,
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
          testItem(
            'a.txt',
            left: testFile(size: 4),
            suggested: SyncActionType.copyLeftToRight,
            reason: SyncReason.onlyOnLeft,
          ),
        ]),
      );
      expect(
        syncHeaderClauses(_l10n, controller),
        [
          'Copy 1 new file (4 B) on right.',
          'Remove 1 empty folder on right.',
        ],
      );
    });

    test('conflicts and the no-op tail render verbatim', () async {
      final pair = testSyncPair();
      final controller = await _readyController(
        pair,
        testPlan(pair, [
          testItem(
            'a.txt',
            left: testFile(mtimeSecs: 1),
            right: testFile(mtimeSecs: 2),
            suggested: SyncActionType.conflict,
            reason: SyncReason.bothChanged,
          ),
        ]),
      );
      expect(
        syncHeaderClauses(_l10n, controller),
        ['Nothing will be deleted.', '1 conflict needs a decision.'],
      );
      final empty = await _readyController(
        pair,
        testPlan(pair, [
          testItem('same.txt', left: testFile(), right: testFile()),
        ]),
      );
      expect(
        syncHeaderClauses(_l10n, empty),
        ['Both sides match. Nothing to do.'],
      );
    });
  });

  group('reason strings', () {
    SyncItem reasoned(SyncReason reason) => testItem(
      'a.txt',
      left: testFile(size: 4, mtimeSecs: 100),
      right: testFile(size: 8, mtimeSecs: 200),
      reason: reason,
    );

    test('each reason maps to its §7 string', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000 * 1000);
      expect(
        syncReasonText(
          _l10n,
          reasoned(SyncReason.onlyOnLeft),
          now: now,
        ),
        'only exists here',
      );
      expect(
        syncReasonText(
          _l10n,
          reasoned(SyncReason.newerOnLeft),
          now: now,
        ),
        'newer here (15m vs 13m)',
      );
      expect(
        syncReasonText(
          _l10n,
          reasoned(SyncReason.sizeDiffers),
          now: now,
        ),
        'sizes differ (4 B vs 8 B)',
      );
      expect(
        syncReasonText(
          _l10n,
          reasoned(SyncReason.contentDiffers),
          now: now,
        ),
        'contents differ',
      );
      expect(
        syncReasonText(
          _l10n,
          reasoned(SyncReason.bothChanged),
          now: now,
        ),
        'changed on both sides',
      );
      expect(
        syncReasonText(
          _l10n,
          reasoned(SyncReason.typeDiffers),
          now: now,
        ),
        'type differs (file here, file there)',
      );
      expect(
        syncReasonText(
          _l10n,
          reasoned(SyncReason.excluded),
          now: now,
        ),
        'excluded by rule',
      );
      expect(
        syncReasonText(
          _l10n,
          reasoned(SyncReason.caseCollision),
          now: now,
        ),
        'names differ only by case',
      );
      expect(
        syncReasonText(
          _l10n,
          reasoned(SyncReason.normalizationCollision),
          now: now,
        ),
        'names differ only by Unicode form',
      );
      expect(
        syncReasonText(
          _l10n,
          reasoned(SyncReason.invalidNameOnDestination),
          now: now,
        ),
        'name invalid on Windows',
      );
      expect(
        syncReasonText(
          _l10n,
          reasoned(SyncReason.scanError),
          now: now,
        ),
        'couldn\'t scan — subtree excluded',
      );
      expect(
        syncReasonText(
          _l10n,
          reasoned(SyncReason.equal),
          now: now,
        ),
        'identical',
      );
    });

    test('symlink rows carry their own reason string', () {
      final item = SyncItem(
        relativePath: 'link',
        left: const EntrySnapshot(
          kind: EntryKind.symlink,
          symlinkTarget: '/elsewhere',
        ),
        right: null,
        suggested: SyncActionType.skip,
        effective: SyncActionType.skip,
        reason: SyncReason.equal,
      );
      expect(
        syncReasonText(_l10n, item),
        'symbolic link — skipped',
      );
    });
  });

  group('rail-3 trigger copy', () {
    test('the 0.5 threshold renders "half"; others render the number',
        () {
      const trigger = SyncDeleteRailTrigger(
        side: SyncSide.right,
        deleteCount: 12,
        sideFileCount: 20,
        clause: DeleteRailClause.fraction,
      );
      expect(
        syncDeleteConfirmTrigger(_l10n, trigger, 0.5),
        'This will delete 12 of 20 files on right — more than '
        'half of that side. Type DELETE to continue.',
      );
      expect(
        syncDeleteConfirmTrigger(_l10n, trigger, 0.3),
        'This will delete 12 of 20 files on right — more than '
        '30 % of that side. Type DELETE to continue.',
      );
      const floor = SyncDeleteRailTrigger(
        side: SyncSide.left,
        deleteCount: 9,
        sideFileCount: 10,
        clause: DeleteRailClause.floor90,
      );
      expect(
        syncDeleteConfirmTrigger(_l10n, floor, 0.5),
        'This will delete 9 of 10 files on left — 90 % or more '
        'of that side. Type DELETE to continue.',
      );
    });
  });

  group('formatSyncSize', () {
    test('renders B/KB/MB per the pane style', () {
      expect(formatSyncSize(null), '—');
      expect(formatSyncSize(512), '512 B');
      expect(formatSyncSize(2048), '2.0 KB');
      expect(formatSyncSize(5 * 1024 * 1024), '5.0 MB');
      expect(formatSyncSize(200 * 1024 * 1024), '200 MB');
    });
  });
}
