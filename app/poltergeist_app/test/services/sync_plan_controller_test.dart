// SyncPlanController coverage (M8): the scan→ready pipeline, the
// override vocabulary and its carve-outs, the rails' run gating, and
// the run/retry/restore lifecycle against real temp trees.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/rsync_endpoints.dart';
import 'package:poltergeist_app/services/sync_environment.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/services/sync_state_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../support/sync_harness.dart';

SyncPlanController _controller({
  required SyncPair pair,
  required SyncPlan plan,
  SyncEnvironment? environment,
  SyncQueueTasks? syncTasks,
  Directory? scratch,
}) {
  final left = testScanResult('/left', const {});
  final right = testScanResult('/right', const {});
  return testController(
    pair: pair,
    scanner: FakeSyncScanner(left: left, right: right),
    differ: FakeSyncDiffer(plan),
    environment:
        environment ??
        testSyncEnvironment(scratch ?? Directory.systemTemp.createTempSync()),
    syncTasks: syncTasks,
  );
}

Future<SyncPlanController> _ready(
  SyncPlanController controller,
) async {
  controller.start();
  await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
  return controller;
}

void main() {
  group('scan → ready', () {
    test('produces plan, stats, pairId, and ready phase', () async {
      final pair = testSyncPair();
      final plan = testPlan(pair, [
        testItem(
          'a.txt',
          left: testFile(size: 4),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
      ]);
      final controller = await _ready(
        _controller(pair: pair, plan: plan),
      );
      addTearDown(controller.dispose);
      expect(controller.plan, same(plan));
      expect(controller.stats!.countOf(SyncActionType.copyLeftToRight), 1);
      expect(controller.pairId, isNotEmpty);
      expect(controller.isRunning, isFalse);
    });

    test('a differ failure lands in the error phase', () async {
      final pair = testSyncPair();
      final scratch = Directory.systemTemp.createTempSync();
      final controller = SyncPlanController(
        pair: pair,
        environment: testSyncEnvironment(scratch),
        syncTasks: SyncQueueTasks(),
        scanner: FakeSyncScanner(
          left: testScanResult('/left', const {}),
          right: testScanResult('/right', const {}),
        ),
        differ: FakeSyncDiffer(null, error: StateError('boom')),
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.error);
      expect(controller.errorMessage, contains('boom'));
      expect(controller.errorKind, RemoteFileErrorKind.other);
    });
  });

  group('availableOverrides', () {
    test('Update mode offers copies and skip but no delete', () async {
      final pair = testSyncPair(); // Update defaults: deletions none.
      final item = testItem(
        'a.txt',
        left: testFile(),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [item])),
      );
      addTearDown(controller.dispose);
      final offers = controller.availableOverrides(item);
      expect(offers, containsAll(<SyncActionType>[
        SyncActionType.copyLeftToRight,
        SyncActionType.skip,
      ]));
      expect(offers, isNot(contains(SyncActionType.deleteRight)));
      expect(offers, isNot(contains(SyncActionType.deleteLeft)));
    });

    test('Mirror offers delete only for sides the item exists on',
        () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      final leftOnly = testItem(
        'a.txt',
        left: testFile(),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [leftOnly])),
      );
      addTearDown(controller.dispose);
      final offers = controller.availableOverrides(leftOnly);
      expect(offers, contains(SyncActionType.deleteLeft));
      expect(offers, isNot(contains(SyncActionType.deleteRight)));
    });

    test('conflict rows admit both copy directions', () async {
      final pair = testSyncPair(); // leftToRight Update.
      final conflict = testItem(
        'a.txt',
        left: testFile(mtimeSecs: 10),
        right: testFile(mtimeSecs: 20),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [conflict])),
      );
      addTearDown(controller.dispose);
      final offers = controller.availableOverrides(conflict);
      // A conflict asks the direction question itself — even a
      // one-way pair offers both copies plus skip.
      expect(offers, contains(SyncActionType.updateLeftToRight));
      expect(offers, contains(SyncActionType.updateRightToLeft));
      expect(offers, contains(SyncActionType.skip));
    });
  });

  group('applyOverride', () {
    test('a valid override mutates effective and reassesses', () async {
      final pair = testSyncPair();
      final item = testItem(
        'a.txt',
        left: testFile(size: 9),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [item])),
      );
      addTearDown(controller.dispose);
      expect(controller.stats!.countOf(SyncActionType.copyLeftToRight), 1);
      controller.applyOverride(item, SyncActionType.skip);
      expect(item.effective, SyncActionType.skip);
      expect(item.userOverridden, isTrue);
      expect(controller.stats!.countOf(SyncActionType.copyLeftToRight), 0);
      expect(controller.stats!.hasWork, isFalse);
    });

    test('an action outside the offer set is ignored', () async {
      final pair = testSyncPair(); // Update — delete is never offered.
      final item = testItem(
        'a.txt',
        left: testFile(),
        right: testFile(),
        suggested: SyncActionType.updateLeftToRight,
        reason: SyncReason.newerOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [item])),
      );
      addTearDown(controller.dispose);
      controller.applyOverride(item, SyncActionType.deleteRight);
      expect(item.effective, SyncActionType.updateLeftToRight);
      expect(item.userOverridden, isFalse);
    });

    test('re-picking the suggested action resets the override',
        () async {
      final pair = testSyncPair();
      final item = testItem(
        'a.txt',
        left: testFile(),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [item])),
      );
      addTearDown(controller.dispose);
      controller.applyOverride(item, SyncActionType.skip);
      expect(item.userOverridden, isTrue);
      controller.applyOverride(item, SyncActionType.copyLeftToRight);
      expect(item.effective, SyncActionType.copyLeftToRight);
      expect(item.userOverridden, isFalse);
    });

    test('a bulk copy reports typeDiffers rows it skipped', () async {
      final pair = testSyncPair();
      final typeChange = testItem(
        'thing',
        left: testDir,
        right: testFile(),
        suggested: SyncActionType.skip,
        reason: SyncReason.typeDiffers,
        destinationSubtree: const {'thing/a.txt': EntrySnapshot(
          kind: EntryKind.file,
          size: 1,
        )},
      );
      final plain = testItem(
        'b.txt',
        left: testFile(),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [typeChange, plain])),
      );
      addTearDown(controller.dispose);
      final skipped = controller.applyOverrideTo(
        [typeChange, plain],
        SyncActionType.copyLeftToRight,
      );
      // §6 rule 4: a no-delete mode's bulk copy must not silently
      // authorize a pre-delete — the type-differs row is reported.
      expect(skipped, contains(typeChange));
      expect(typeChange.effective, SyncActionType.skip);
      expect(plain.effective, SyncActionType.copyLeftToRight);
    });

    test('a bulk copy skips a typeDiffers row through its offered '
        'action', () async {
      // The carve-out is about the ACTION being rule-4 authorization:
      // the row's own offered copy/update verb is exactly that, so the
      // bulk path must skip it too — the exemption lives on the
      // per-row menu (applyOverride), not the bulk verb.
      final pair = testSyncPair(); // Update — deletions: none.
      final typeChange = testItem(
        'thing',
        left: testDir,
        right: testFile(),
        suggested: SyncActionType.skip,
        reason: SyncReason.typeDiffers,
        destinationSubtree: const {
          'thing/a.txt': EntrySnapshot(kind: EntryKind.file, size: 1),
        },
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [typeChange])),
      );
      addTearDown(controller.dispose);
      // updateLeftToRight IS this row's offered action (destination is
      // a file) — the offer-set check cannot catch it.
      expect(
        controller.availableOverrides(typeChange),
        contains(SyncActionType.updateLeftToRight),
      );
      final skipped = controller.applyOverrideTo(
        [typeChange],
        SyncActionType.updateLeftToRight,
      );
      expect(skipped, contains(typeChange));
      expect(typeChange.effective, SyncActionType.skip);
    });
  });

  group('resolveConflicts', () {
    test('keepLeft / keepRight / skip resolve every conflict row',
        () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
      );
      final conflict = testItem(
        'a.txt',
        left: testFile(mtimeSecs: 10),
        right: testFile(mtimeSecs: 20),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [conflict])),
      );
      addTearDown(controller.dispose);
      expect(controller.resolveConflicts(SyncConflictChoice.keepLeft), 1);
      expect(conflict.effective, SyncActionType.updateLeftToRight);
      conflict.effective = SyncActionType.conflict;
      expect(controller.resolveConflicts(SyncConflictChoice.keepRight), 1);
      expect(conflict.effective, SyncActionType.updateRightToLeft);
      conflict.effective = SyncActionType.conflict;
      expect(controller.resolveConflicts(SyncConflictChoice.skip), 1);
      expect(conflict.effective, SyncActionType.skip);
    });

    test('newerWins resolves by mtime and hides on untrusted clocks',
        () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
      );
      final conflict = testItem(
        'a.txt',
        left: testFile(mtimeSecs: 30),
        right: testFile(mtimeSecs: 20),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [conflict])),
      );
      addTearDown(controller.dispose);
      expect(controller.offersNewerWins, isTrue);
      expect(
        controller.resolveConflicts(SyncConflictChoice.newerWins),
        1,
      );
      expect(conflict.effective, SyncActionType.updateLeftToRight);
      controller.pairState.mtimeUnreliableLeft = true;
      expect(controller.offersNewerWins, isFalse);
    });

    test('a bulk keep leaves a typeDiffers row unresolved in a '
        'no-delete mode', () async {
      // §7: rule-4 authorization is per-item only — the bulk bar must
      // not smuggle it in on a typeDiffers row (every such row is a
      // conflict in a no-delete mode, so it lands in the bulk set).
      final pair = testSyncPair(); // Update — deletions: none.
      final typeChange = testItem(
        'thing',
        left: testDir,
        right: testFile(),
        suggested: SyncActionType.conflict,
        reason: SyncReason.typeDiffers,
        destinationSubtree: const {
          'thing/a.txt': EntrySnapshot(kind: EntryKind.file, size: 1),
        },
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [typeChange])),
      );
      addTearDown(controller.dispose);
      expect(
        controller.resolveConflicts(SyncConflictChoice.keepLeft),
        0,
      );
      expect(typeChange.effective, SyncActionType.conflict);
    });

    test('keep-destination in a one-way pair resolves to skip', () async {
      // Mirror L→R: keeping the right (destination) side writes
      // against the direction — the differ's keep-side semantics make
      // that a deliberate skip, never a source-side write.
      final pair = testSyncPair(
        rules: const SyncRuleSet(
          direction: SyncDirection.leftToRight,
          deletions: DeletionPolicy.trash,
        ),
      );
      final conflict = testItem(
        'a.txt',
        left: testFile(mtimeSecs: 10),
        right: testFile(mtimeSecs: 20),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [conflict])),
      );
      addTearDown(controller.dispose);
      expect(
        controller.resolveConflicts(SyncConflictChoice.keepRight),
        1,
      );
      expect(conflict.effective, SyncActionType.skip);
      // keepLeft keeps the source — that direction is permitted.
      conflict.effective = SyncActionType.conflict;
      expect(
        controller.resolveConflicts(SyncConflictChoice.keepLeft),
        1,
      );
      expect(conflict.effective, SyncActionType.updateLeftToRight);
    });

    test('newerWins treats a sub-tolerance delta as equal and refuses '
        'flagged clocks', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
      );
      // Default mtimeToleranceSecs is 2 — a 1-second gap is not
      // "newer", matching EntryComparator's verdict.
      final closeCall = testItem(
        'a.txt',
        left: testFile(mtimeSecs: 21),
        right: testFile(mtimeSecs: 20),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final realGap = testItem(
        'b.txt',
        left: testFile(mtimeSecs: 1000),
        right: testFile(mtimeSecs: 20),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final controller = await _ready(
        _controller(
          pair: pair,
          plan: testPlan(pair, [closeCall, realGap]),
        ),
      );
      addTearDown(controller.dispose);
      expect(
        controller.resolveConflicts(SyncConflictChoice.newerWins),
        1,
      );
      expect(closeCall.effective, SyncActionType.conflict);
      expect(realGap.effective, SyncActionType.updateLeftToRight);

      // An engine-flagged clock refuses even a real gap.
      realGap.effective = SyncActionType.conflict;
      controller.pairState.mtimeUnreliableRight = true;
      expect(
        controller.resolveConflicts(SyncConflictChoice.newerWins),
        0,
      );
      expect(realGap.effective, SyncActionType.conflict);
    });
  });

  group('updatePairDefinition', () {
    test('case overrides persist under the post-edit pairId through '
        'the rescan', () async {
      final scratch = Directory.systemTemp.createTempSync();
      addTearDown(() => scratch.deleteSync(recursive: true));
      final states = MemorySyncStateStore();
      final scanner = FakeSyncScanner(
        left: testScanResult('/left', const {}),
        right: testScanResult('/right', const {}),
      );
      final pair = testSyncPair();
      final controller = SyncPlanController(
        pair: pair,
        environment: testSyncEnvironment(scratch, states: states),
        syncTasks: SyncQueueTasks(),
        scanner: scanner,
        differ: FakeSyncDiffer(testPlan(pair, const [])),
        deviceId: 'test-device',
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      final originalPairId = controller.pairId!;

      // The editor's save: new endpoints plus a remote-side override
      // that disagrees with the probe — the override-mismatch rescan
      // fires, and the overrides must survive its state reload.
      final edited = SyncPair(
        id: pair.id,
        name: pair.name,
        left: const LocalEndpoint('/left2'),
        right: const LocalEndpoint('/right2'),
        rules: pair.rules,
      );
      await controller.updatePairDefinition(
        edited,
        caseOverrides: const SyncCaseOverrides(right: false),
      );
      expect(controller.phase, SyncPlanPhase.ready);
      expect(controller.pairId, isNot(originalPairId));
      expect(scanner.overrides[SyncSide.right], isFalse);
      expect(controller.pairState.caseSensitiveOverrideRight, isFalse);
      // Persisted under the FINAL pair id — not the stale pre-edit one.
      final stored = await states.load(controller.pairId!);
      expect(stored.caseSensitiveOverrideRight, isFalse);
    });
  });

  group('rails', () {
    test('rail 3 gates the run behind the typed confirmation', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      // 12 deletes of 20 files on the right: > 50 % and ≥ 10.
      final items = [
        for (var i = 0; i < 12; i++)
          testItem(
            'gone$i.txt',
            right: testFile(),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
        for (var i = 0; i < 8; i++)
          testItem(
            'keep$i.txt',
            right: testFile(),
            suggested: SyncActionType.skip,
          ),
      ];
      final controller = await _ready(
        _controller(
          pair: pair,
          plan: testPlan(pair, items, rightFileCount: 20),
        ),
      );
      addTearDown(controller.dispose);
      expect(controller.needsTypedConfirmation, isTrue);
      expect(controller.gate, isA<SyncRunNeedsConfirmation>());
      // A run() without the acknowledgement re-surfaces the gate —
      // nothing executes (items stay pending, phase never runs).
      await controller.run();
      expect(controller.phase, SyncPlanPhase.ready);
      expect(items.first.status, SyncItemStatus.pending);
      expect(controller.syncTasks.tasks, isEmpty);
    });

    test('rail 4 refuses the plan outright — run stays disabled',
        () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(
          deletions: DeletionPolicy.trash,
          maxDelete: 2,
        ),
      );
      final items = [
        for (var i = 0; i < 3; i++)
          testItem(
            'gone$i.txt',
            right: testFile(),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
      ];
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, items)),
      );
      addTearDown(controller.dispose);
      expect(controller.refusal, isNotNull);
      expect(controller.refusal!.deleteCount, 3);
      expect(controller.refusal!.maxDelete, 2);
      await controller.run(deleteConfirmed: true);
      expect(controller.phase, SyncPlanPhase.ready);
      expect(controller.syncTasks.tasks, isEmpty);
    });
  });

  group('run lifecycle (real engine over temp dirs)', () {
    late Directory scratch;
    late Directory left;
    late Directory right;

    setUp(() {
      scratch = Directory.systemTemp.createTempSync('pg-sync-ctl-');
      left = Directory('${scratch.path}/left')..createSync();
      right = Directory('${scratch.path}/right')..createSync();
    });
    tearDown(() => scratch.deleteSync(recursive: true));

    SyncPlanController realController(
      SyncRuleSet rules, {
      SyncQueueTasks? tasks,
      SyncEnvironment? environment,
    }) => SyncPlanController(
      pair: testSyncPair(
        left: left.path,
        right: right.path,
        rules: rules,
      ),
      environment: environment ?? testSyncEnvironment(scratch),
      syncTasks: tasks ?? SyncQueueTasks(),
      deviceId: 'test-device',
      rsyncEndpoints: resolveRsyncEndpoints,
    );

    test('copy run completes, item rows land in the panel task',
        () async {
      File('${left.path}/a.txt').writeAsStringSync('alpha');
      File('${left.path}/b.txt').writeAsStringSync('beta');
      final tasks = SyncQueueTasks();
      final controller = realController(const SyncRuleSet(),
          tasks: tasks);
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      expect(controller.stats!.newFilesTo(SyncSide.right), 2);

      await controller.run();
      expect(controller.phase, SyncPlanPhase.completed);
      expect(
        File('${right.path}/a.txt').readAsStringSync(),
        'alpha',
      );
      // The activity-panel task exists and finished completed.
      expect(tasks.tasks, hasLength(1));
      final task = tasks.tasks.single;
      expect(task.state, TransferTaskState.completed);
      expect(task.items.length, 2);
      // sync_state landed under the canonical pair id.
      expect(controller.pairId, isNotEmpty);
    });

    test('a failed item surfaces failed phase and retries to done',
        () async {
      final source = File('${left.path}/a.txt')..writeAsStringSync('x');
      final tasks = SyncQueueTasks();
      final controller = realController(const SyncRuleSet(),
          tasks: tasks);
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      // Vanish the source between preview and run — rail 7 flips the
      // item conflicted/failed rather than copying stale bytes.
      source.deleteSync();
      await controller.run();
      expect(
        controller.phase,
        isIn([SyncPlanPhase.failed, SyncPlanPhase.completed]),
      );
      final item = controller.lastRun!.plan.items.firstWhere(
        (i) => i.relativePath == 'a.txt',
      );
      expect(
        item.status,
        isIn([SyncItemStatus.failed, SyncItemStatus.conflicted]),
      );
      if (item.status == SyncItemStatus.failed) {
        expect(controller.canRetryFailed, isTrue);
        source.writeAsStringSync('x');
        await controller.retryFailed();
        expect(item.status, SyncItemStatus.done);
      }
    });

    test('mirror delete trashes and restoreTrashed returns the file',
        () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final tasks = SyncQueueTasks();
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        tasks: tasks,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      // 1 deletion of the side's 1 file trips rail 3's 90 % floor —
      // the typed acknowledgement is part of the run call.
      expect(controller.needsTypedConfirmation, isTrue);
      await controller.run(deleteConfirmed: true);
      expect(controller.phase, SyncPlanPhase.completed);
      expect(File('${right.path}/old.txt').existsSync(), isFalse);
      expect(controller.canRestore, isTrue);

      final report = await controller.restoreTrashed();
      expect(report.restored, isNotEmpty);
      expect(File('${right.path}/old.txt').readAsStringSync(), 'old');
    });

    test('the typed confirmation carries through to a real run',
        () async {
      // 10 deletes of 11 files on the right trips rail 3's fraction
      // clause (≥ 10 and > 50 %, under the 90 % floor).
      for (var i = 0; i < 10; i++) {
        File('${right.path}/gone$i.txt').writeAsStringSync('x');
      }
      File('${right.path}/keep.txt').writeAsStringSync('k');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      expect(controller.needsTypedConfirmation, isTrue);
      await controller.run();
      expect(controller.phase, SyncPlanPhase.ready);
      expect(File('${right.path}/gone0.txt').existsSync(), isTrue);
      await controller.run(deleteConfirmed: true);
      expect(controller.phase, SyncPlanPhase.completed);
      expect(File('${right.path}/gone0.txt').existsSync(), isFalse);
    });

    test('a retry rebinds the task — panel pause/cancel reach the '
        'retry run', () async {
      File('${left.path}/a.txt').writeAsStringSync('x');
      final gateFs = _CancelAwareGateFs();
      final tasks = SyncQueueTasks();
      final controller = realController(
        const SyncRuleSet(),
        tasks: tasks,
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => gateFs,
        ),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      // Fail the run: uploads throw — `failed` is the status
      // retryFailed re-runs (a vanished source reads `conflicted`).
      gateFs.failUploads = true;
      await controller.run();
      expect(controller.canRetryFailed, isTrue);
      final task = tasks.tasks.single;
      final binding = tasks.bindingFor(task.id)!;
      final firstCancellation = binding.cancellation;
      final firstPause = binding.pause;

      // Arm the gate so the retry blocks mid-upload, then drive the
      // panel verbs: they must land on the RETRY's controls, not the
      // dead run's detached objects.
      gateFs.failUploads = false;
      gateFs.arm();
      unawaited(controller.retryFailed());
      await pumpUntil(() => controller.isRunning);
      expect(binding.cancellation, isNot(same(firstCancellation)));
      expect(binding.pause, isNot(same(firstPause)));
      expect(tasks.cancel(task.id), isTrue);
      await pumpUntil(() => !controller.isRunning);
      expect(controller.phase, SyncPlanPhase.cancelled);
    });

    test('a fresh run retires the previous task row\u2019s retry', () async {
      File('${left.path}/a.txt').writeAsStringSync('x');
      final tasks = SyncQueueTasks();
      final controller = realController(const SyncRuleSet(),
          tasks: tasks);
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      File('${left.path}/a.txt').deleteSync();
      await controller.run();
      final firstTask = tasks.tasks.single;
      expect(tasks.canRetry(firstTask.id), isTrue);

      // A fresh run supersedes the failed one — the old row must not
      // keep routing retry into the newest _lastRun.
      File('${left.path}/a.txt').writeAsStringSync('x');
      await controller.run();
      expect(controller.phase, SyncPlanPhase.completed);
      expect(tasks.canRetry(firstTask.id), isFalse);
    });

    test('a rescan retires Retry Failed and the stale task row', () async {
      File('${left.path}/a.txt').writeAsStringSync('x');
      final tasks = SyncQueueTasks();
      final controller = realController(const SyncRuleSet(),
          tasks: tasks);
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      File('${left.path}/a.txt').deleteSync();
      await controller.run();
      expect(controller.canRetryFailed, isTrue);
      final firstTask = tasks.tasks.single;

      // A rescan renders a NEW plan — retrying the old run's failures
      // would execute work the reviewed plan no longer shows (rail 1).
      File('${left.path}/a.txt').writeAsStringSync('x');
      await controller.rescan();
      expect(controller.phase, SyncPlanPhase.ready);
      expect(controller.canRetryFailed, isFalse);
      expect(tasks.canRetry(firstTask.id), isFalse);
    });

    test('a cancelled run never stamps lastRunAt', () async {
      File('${left.path}/a.txt').writeAsStringSync('x');
      final gateFs = _CancelAwareGateFs();
      final controller = realController(
        const SyncRuleSet(),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => gateFs,
        ),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      // A cancelled run is not a sync — 'last synced' stays unset.
      gateFs.arm();
      unawaited(controller.run());
      await pumpUntil(() => controller.isRunning);
      controller.cancelRun();
      await pumpUntil(() => !controller.isRunning);
      expect(controller.phase, SyncPlanPhase.cancelled);
      expect(controller.pairState.lastRunAt, isNull);
    });

    test('a retry that completes stamps lastRunAt like a run',
        () async {
      File('${left.path}/a.txt').writeAsStringSync('x');
      final gateFs = _CancelAwareGateFs();
      final controller = realController(
        const SyncRuleSet(),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => gateFs,
        ),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      // The failed item is what retryFailed re-runs — an upload throw
      // rather than a vanished source (which reads `conflicted`).
      gateFs.failUploads = true;
      await controller.run();
      expect(controller.canRetryFailed, isTrue);
      controller.pairState.lastRunAt = null;
      gateFs.failUploads = false;
      await controller.retryFailed();
      expect(controller.pairState.lastRunAt, isNotNull);
    });
  });

  // 05 §2.1's export seam: `rsyncExport` renders the effective
  // ruleset with the plan's override count and engine-imposed skips;
  // the resolver is the injected seam the shell binds to the catalog.
  group('rsyncExport', () {
    final stamp = DateTime.utc(2026, 9, 22, 15, 4, 7);

    test('renders the effective ruleset with the injected resolver',
        () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      final controller = await _ready(
        _controller(
          pair: pair,
          plan: testPlan(pair, [
            testItem(
              'a.txt',
              left: testFile(size: 4),
              suggested: SyncActionType.copyLeftToRight,
              reason: SyncReason.onlyOnLeft,
            ),
          ]),
        ),
      );
      addTearDown(controller.dispose);

      expect(controller.canExportRsync, isTrue);
      final export = controller.rsyncExport(now: stamp);
      expect(export, isNotNull);
      expect(export!.text, contains('rsync -n -i'));
      expect(export.text, contains('--delete-delay'));
      expect(export.text, contains('rsync-20260922-150407'));
      expect(export.permanentDeletions, isFalse);
    });

    test('permanent+none flags the toast differentiation', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(
          deletions: DeletionPolicy.permanent,
          backups: BackupPolicy.none,
        ),
      );
      final controller = await _ready(
        _controller(
          pair: pair,
          plan: testPlan(pair, [
            testItem(
              'old.txt',
              right: testFile(),
              suggested: SyncActionType.deleteRight,
              reason: SyncReason.onlyOnRight,
            ),
          ]),
        ),
      );
      addTearDown(controller.dispose);

      final export = controller.rsyncExport(now: stamp)!;
      expect(export.permanentDeletions, isTrue);
    });

    test('manual overrides and engine skips land in the export',
        () async {
      final pair = testSyncPair();
      final plan = testPlan(pair, [
        testItem(
          'a.txt',
          left: testFile(size: 4),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
        testItem(
          'bad/sub',
          left: testDir,
          reason: SyncReason.scanError,
        ),
      ]);
      final controller = await _ready(
        _controller(pair: pair, plan: plan),
      );
      addTearDown(controller.dispose);
      // One manual override on the plan's first row.
      controller.applyOverrideTo([plan.items.first], SyncActionType.skip);

      final export = controller.rsyncExport(now: stamp)!;
      expect(export.text, contains('1 manual per-item override'));
      expect(export.text, contains("--exclude='/bad/sub'"));
      expect(
        export.text,
        contains('scan-error subtrees and symlinks are excluded'),
      );
    });

    test('a null resolver answer disables the export', () async {
      final pair = testSyncPair();
      final scratch = Directory.systemTemp.createTempSync();
      addTearDown(() => scratch.deleteSync(recursive: true));
      final controller = testController(
        pair: pair,
        scanner: FakeSyncScanner(
          left: testScanResult('/left', const {}),
          right: testScanResult('/right', const {}),
        ),
        differ: FakeSyncDiffer(testPlan(pair, const [])),
        environment: testSyncEnvironment(scratch),
        rsyncEndpoints: (_) => null,
      );
      addTearDown(controller.dispose);
      await _ready(controller);

      expect(controller.canExportRsync, isFalse);
      expect(controller.rsyncExport(now: stamp), isNull);
    });

    test('no plan yet — nothing to export', () {
      final pair = testSyncPair();
      final scratch = Directory.systemTemp.createTempSync();
      addTearDown(() => scratch.deleteSync(recursive: true));
      final controller = testController(
        pair: pair,
        scanner: FakeSyncScanner(
          left: testScanResult('/left', const {}),
          right: testScanResult('/right', const {}),
        ),
        differ: FakeSyncDiffer(testPlan(pair, const [])),
        environment: testSyncEnvironment(scratch),
      );
      addTearDown(controller.dispose);

      expect(controller.canExportRsync, isFalse);
      expect(controller.rsyncExport(now: stamp), isNull);
    });

    test('a mid-rescan stale plan is not exportable', () async {
      final pair = testSyncPair();
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, const [])),
      );
      addTearDown(controller.dispose);
      expect(controller.canExportRsync, isTrue);

      unawaited(controller.rescan());
      expect(controller.phase, SyncPlanPhase.scanning);
      // `_plan` still holds the previous scan's result — exporting it
      // would render current rules against stale skip paths.
      expect(controller.canExportRsync, isFalse);
      expect(controller.rsyncExport(now: stamp), isNull);

      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      expect(controller.canExportRsync, isTrue);
    });

    test('untrusted mtimes downgrade the export to --size-only',
        () async {
      final pair = testSyncPair();
      final scratch = Directory.systemTemp.createTempSync();
      addTearDown(() => scratch.deleteSync(recursive: true));
      // Seed the §4 flag under the id the scan will settle on — the
      // fakes report caseSensitive roots and no probe answers, so the
      // pairId resolves with the default fold flags.
      final states = MemorySyncStateStore();
      await states.save(
        syncPairId(pair),
        SyncPairState(mtimeUnreliableLeft: true),
      );
      final controller = await _ready(
        _controller(
          pair: pair,
          plan: testPlan(pair, const []),
          environment: testSyncEnvironment(scratch, states: states),
        ),
      );
      addTearDown(controller.dispose);

      final export = controller.rsyncExport(now: stamp)!;
      expect(export.text, contains('--size-only'));
      expect(export.text, isNot(contains('--modify-window')));
      expect(
        export.text,
        contains('mtimes untrusted'),
      );
    });
  });
}

/// An upload gate that releases early on cancellation — arming it
/// holds a run mid-copy until [disarm] or the run's own cancellation
/// unwinds it. Disarmed during scans: the case probe writes through
/// the same verb.
final class _CancelAwareGateFs extends LocalFileSystem {
  Completer<void>? _gate;
  bool failUploads = false;

  void arm() => _gate = Completer<void>();
  void disarm() => _gate = null;

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    // A generic throw lands in the executor's non-conflict bucket —
    // the item is `failed`, which is the status `retryFailed` re-runs
    // (a vanished source reads `conflicted` and is deliberately not
    // retryable).
    if (failUploads) throw StateError('injected upload failure');
    final gate = _gate;
    if (gate != null) {
      await Future.any([
        gate.future,
        if (cancellation != null) cancellation.whenCancelled,
      ]);
      cancellation?.throwIfCancelled();
    }
    return super.upload(
      path,
      content,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    );
  }
}
