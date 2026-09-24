// Synchronize's auto-run rule (D32 §7, amending 05 §8 rail 1): a plan
// that only creates runs straight after its scan; any deletion,
// replacement, or conflict holds it on the review with the reasons.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/rsync_endpoints.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/services/sync_state_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart' show TransferTaskState;
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../support/sync_harness.dart';

SyncPlanController _fake(
  SyncPair pair,
  List<SyncItem> items, {
  SyncPlanIntent intent = SyncPlanIntent.synchronize,
}) => SyncPlanController(
  pair: pair,
  environment: testSyncEnvironment(Directory.systemTemp.createTempSync()),
  syncTasks: SyncQueueTasks(),
  scanner: FakeSyncScanner(
    left: testScanResult('/left', const {}),
    right: testScanResult('/right', const {}),
  ),
  differ: FakeSyncDiffer(testPlan(pair, items)),
  deviceId: 'test-device',
  intent: intent,
  rsyncEndpoints: resolveRsyncEndpoints,
);

Future<void> _settle(SyncPlanController controller) async {
  controller.start();
  await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
}

SyncItem _update(String path) => testItem(
  path,
  left: testFile(size: 5, mtimeSecs: 20),
  right: testFile(size: 4, mtimeSecs: 10),
  suggested: SyncActionType.updateLeftToRight,
  reason: SyncReason.sizeDiffers,
);

SyncItem _delete(String path) => testItem(
  path,
  right: testFile(),
  suggested: SyncActionType.deleteRight,
  reason: SyncReason.onlyOnRight,
);

void main() {
  group('syncAutoRunHold', () {
    SyncEffectiveStats stats(List<SyncItem> items) =>
        computeSyncEffectiveStats(testPlan(testSyncPair(), items));

    test('a creates-only plan may run unreviewed', () {
      expect(
        syncAutoRunHold(
          stats([
            testItem(
              'new.txt',
              left: testFile(),
              suggested: SyncActionType.copyLeftToRight,
              reason: SyncReason.onlyOnLeft,
            ),
            testItem(
              'dir',
              left: testDir,
              suggested: SyncActionType.makeDirRight,
              reason: SyncReason.onlyOnLeft,
            ),
            testItem('same.txt', left: testFile(), right: testFile()),
          ]),
        ),
        isNull,
      );
    });

    test('counts deletions, empty folders, replacements, conflicts', () {
      final hold = syncAutoRunHold(
        stats([
          _update('a.txt'),
          _delete('gone.txt'),
          _delete('also-gone.txt'),
          testItem(
            'empty',
            right: testDir,
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
          testItem(
            'both.txt',
            left: testFile(),
            right: testFile(size: 9),
            suggested: SyncActionType.conflict,
            reason: SyncReason.bothChanged,
          ),
        ]),
      )!;
      expect(hold.deletes, 2);
      expect(hold.emptyFolders, 1);
      expect(hold.replaces, 1);
      expect(hold.conflicts, 1);
    });
  });

  group('SyncPlanIntent.synchronize', () {
    test('a plan with a replacement holds on the review', () async {
      final controller = _fake(testSyncPair(), [_update('a.txt')]);
      addTearDown(controller.dispose);
      await _settle(controller);
      expect(controller.phase, SyncPlanPhase.ready);
      expect(controller.lastRun, isNull);
      final hold = controller.reviewHold!;
      expect(hold.replaces, 1);
      expect(hold.deletes, 0);
    });

    test('the hold follows overrides and clears on dismiss', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      final gone = _delete('gone.txt');
      final controller = _fake(pair, [gone, _update('a.txt')]);
      addTearDown(controller.dispose);
      await _settle(controller);
      expect(controller.reviewHold!.deletes, 1);

      controller.applyOverride(gone, SyncActionType.skip);
      expect(controller.reviewHold!.deletes, 0);
      expect(controller.reviewHold!.replaces, 1);

      controller.dismissReviewHold();
      expect(controller.reviewHold, isNull);
    });

    test('a rescan never auto-runs and drops the banner', () async {
      final controller = _fake(testSyncPair(), [_update('a.txt')]);
      addTearDown(controller.dispose);
      await _settle(controller);
      expect(controller.reviewHold, isNotNull);
      await controller.rescan();
      expect(controller.phase, SyncPlanPhase.ready);
      expect(controller.reviewHold, isNull);
    });

    test('the review intent never holds or runs', () async {
      final controller = _fake(testSyncPair(), [
        _update('a.txt'),
      ], intent: SyncPlanIntent.review);
      addTearDown(controller.dispose);
      await _settle(controller);
      expect(controller.reviewHold, isNull);
      expect(controller.lastRun, isNull);
    });

    test('a creates-only plan runs to completion on its own', () async {
      final scratch = Directory.systemTemp.createTempSync('pg-intent-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final left = Directory('${scratch.path}/left')..createSync();
      final right = Directory('${scratch.path}/right')..createSync();
      File('${left.path}/a.txt').writeAsStringSync('alpha');
      final tasks = SyncQueueTasks();
      final controller = SyncPlanController(
        pair: testSyncPair(left: left.path, right: right.path),
        environment: testSyncEnvironment(scratch),
        syncTasks: tasks,
        deviceId: 'test-device',
        intent: SyncPlanIntent.synchronize,
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.completed);
      expect(File('${right.path}/a.txt').readAsStringSync(), 'alpha');
      expect(tasks.tasks.single.state, TransferTaskState.completed);
      expect(controller.reviewHold, isNull);
    });

    test('an overwrite on a real tree waits for review', () async {
      final scratch = Directory.systemTemp.createTempSync('pg-intent-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final left = Directory('${scratch.path}/left')..createSync();
      final right = Directory('${scratch.path}/right')..createSync();
      File('${left.path}/a.txt').writeAsStringSync('new contents');
      File('${right.path}/a.txt').writeAsStringSync('old');
      final controller = SyncPlanController(
        pair: testSyncPair(left: left.path, right: right.path),
        environment: testSyncEnvironment(scratch),
        syncTasks: SyncQueueTasks(),
        deviceId: 'test-device',
        intent: SyncPlanIntent.synchronize,
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      expect(controller.reviewHold!.replaces, 1);
      expect(File('${right.path}/a.txt').readAsStringSync(), 'old');
    });
  });

  test('loadStoredSyncPairState finds a touched record by fold', () async {
    final states = MemorySyncStateStore();
    final pair = testSyncPair();
    expect(await loadStoredSyncPairState(states, pair), isNull);
    await states.save(
      syncPairId(pair, leftCaseInsensitive: true, rightCaseInsensitive: true),
      SyncPairState(mtimeUnreliableRight: true, touchedAt: DateTime.utc(2026)),
    );
    final state = await loadStoredSyncPairState(states, pair);
    expect(state?.mtimeUnreliableRight, isTrue);
  });
}
