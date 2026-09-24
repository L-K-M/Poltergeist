// The plan review's D32 §7 regrouping: action-class sections with
// tri-state headers, per-row include checkboxes wired to the override
// verbs, the column header, Space on the focused row, row semantics,
// and Synchronize's reason banner.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/rsync_endpoints.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/ui/sync/sync_plan_table.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../support/sync_harness.dart';
import 'sync_plan_view_test.dart' as view;

SyncItem _copy(String path) => testItem(
  path,
  left: testFile(size: 10, mtimeSecs: 1000),
  suggested: SyncActionType.copyLeftToRight,
  reason: SyncReason.onlyOnLeft,
);

SyncItem _update(String path) => testItem(
  path,
  left: testFile(size: 12, mtimeSecs: 2000),
  right: testFile(size: 10, mtimeSecs: 1000),
  suggested: SyncActionType.updateLeftToRight,
  reason: SyncReason.sizeDiffers,
);

SyncItem _delete(String path) => testItem(
  path,
  right: testFile(),
  suggested: SyncActionType.deleteRight,
  reason: SyncReason.onlyOnRight,
);

SyncItem _conflict(String path) => testItem(
  path,
  left: testFile(mtimeSecs: 30),
  right: testFile(mtimeSecs: 20, size: 9),
  suggested: SyncActionType.conflict,
  reason: SyncReason.bothChanged,
);

Future<SyncPlanController> _ready(
  WidgetTester tester,
  SyncPair pair,
  List<SyncItem> items, {
  SyncPlanIntent intent = SyncPlanIntent.review,
}) async {
  final scratch = Directory.systemTemp.createTempSync('pg-review-');
  addTearDown(() => scratch.deleteSync(recursive: true));
  final controller = SyncPlanController(
    pair: pair,
    environment: testSyncEnvironment(scratch),
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
  addTearDown(controller.dispose);
  await view.pumpSyncPlanView(
    tester,
    controller,
    clock: () => DateTime.utc(2026, 9, 24, 12),
  );
  await view.pumpToReady(tester, controller);
  return controller;
}

Checkbox _check(WidgetTester tester, String key) =>
    tester.widget<Checkbox>(find.byKey(ValueKey(key)));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
}

void main() {
  test('sections group by the suggested action class', () {
    final rows = [
      _conflict('c.txt'),
      _copy('a.txt'),
      testItem('same.txt', left: testFile(), right: testFile()),
      _delete('gone.txt'),
      _update('b.txt'),
    ];
    final sections = syncSections(rows);
    expect(sections.map((s) => s.section), [
      SyncSection.copy,
      SyncSection.update,
      SyncSection.delete,
      SyncSection.conflicts,
      SyncSection.skipped,
    ]);
    // An unchecked row keeps its section — overriding to skip does not
    // move it into Skipped.
    rows[1].effective = SyncActionType.skip;
    rows[1].userOverridden = true;
    expect(syncSectionOf(rows[1]), SyncSection.copy);
    expect(syncRowIncluded(rows[1]), isFalse);
    // An engine skip has nothing to include.
    expect(syncRowToggleable(rows[2]), isFalse);
    expect(syncSectionState([rows[1], _copy('x')]), isNull);
    expect(syncSectionState([_copy('x')]), isTrue);
    expect(syncSectionState([rows[1]]), isFalse);
  });

  testWidgets('renders sections, column headers, and row checkboxes', (
    tester,
  ) async {
    await _ready(
      tester,
      testSyncPair(rules: const SyncRuleSet(deletions: DeletionPolicy.trash)),
      [_copy('a.txt'), _update('b.txt'), _delete('gone.txt')],
    );
    expect(find.byKey(const ValueKey('sync.section.copy')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync.section.update')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync.section.delete')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync.section.skipped')), findsNothing);
    final header = find.byKey(const ValueKey('sync.plan.columns'));
    for (final label in ['Path', 'left', 'right', 'Reason']) {
      expect(
        find.descendant(of: header, matching: find.text(label)),
        findsOneWidget,
      );
    }
    expect(_check(tester, 'sync.row.a.txt.check').value, isTrue);
    expect(_check(tester, 'sync.section.copy.check').value, isTrue);
  });

  testWidgets('a row checkbox skips and restores the row in place', (
    tester,
  ) async {
    final item = _copy('a.txt');
    final controller = await _ready(tester, testSyncPair(), [
      item,
      _copy('b.txt'),
    ]);
    await _tap(tester, 'sync.row.a.txt.check');
    expect(item.effective, SyncActionType.skip);
    expect(item.userOverridden, isTrue);
    // Still listed under Copy, unchecked; the header reads mixed.
    expect(find.byKey(const ValueKey('sync.row.a.txt')), findsOneWidget);
    expect(_check(tester, 'sync.section.copy.check').value, isNull);
    expect(controller.stats!.newFilesTo(SyncSide.right), 1);

    await _tap(tester, 'sync.row.a.txt.check');
    expect(item.effective, SyncActionType.copyLeftToRight);
    expect(item.userOverridden, isFalse);
  });

  testWidgets('the section checkbox unchecks and rechecks the section', (
    tester,
  ) async {
    final a = _copy('a.txt');
    final b = _copy('b.txt');
    await _ready(tester, testSyncPair(), [a, b, _update('c.txt')]);
    await _tap(tester, 'sync.row.a.txt.check');
    // Mixed → unchecks everything.
    await _tap(tester, 'sync.section.copy.check');
    expect(a.effective, SyncActionType.skip);
    expect(b.effective, SyncActionType.skip);
    expect(_check(tester, 'sync.section.copy.check').value, isFalse);
    // The Update section is untouched.
    expect(_check(tester, 'sync.section.update.check').value, isTrue);
    // Empty → back to the suggestion for every row.
    await _tap(tester, 'sync.section.copy.check');
    expect(a.effective, SyncActionType.copyLeftToRight);
    expect(b.effective, SyncActionType.copyLeftToRight);
  });

  testWidgets('Space toggles the focused row; arrows move it', (tester) async {
    final a = _copy('a.txt');
    final b = _copy('b.txt');
    await _ready(tester, testSyncPair(), [a, b]);
    await tester.tap(find.text('a.txt'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(a.effective, SyncActionType.skip);
    expect(b.effective, SyncActionType.copyLeftToRight);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(b.effective, SyncActionType.skip);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(b.effective, SyncActionType.copyLeftToRight);
  });

  testWidgets('rows carry a semantics label', (tester) async {
    final handle = tester.ensureSemantics();
    await _ready(tester, testSyncPair(), [_copy('a.txt')]);
    expect(
      find.bySemanticsLabel('a.txt: copy to “right”, only exists here'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('Synchronize holds with the reason banner until dismissed', (
    tester,
  ) async {
    final controller = await _ready(
      tester,
      testSyncPair(rules: const SyncRuleSet(deletions: DeletionPolicy.trash)),
      [_update('b.txt'), _delete('gone.txt'), _conflict('c.txt')],
      intent: SyncPlanIntent.synchronize,
    );
    expect(controller.lastRun, isNull);
    expect(
      find.text(
        'This plan deletes 1 file, replaces 1 file, has 1 conflict — '
        'review before running.',
      ),
      findsOneWidget,
    );
    // Skipping the deletion shrinks the banner live.
    await _tap(tester, 'sync.row.gone.txt.check');
    expect(
      find.text(
        'This plan replaces 1 file, has 1 conflict — review before running.',
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('sync.plan.holdBanner')),
        matching: find.byType(TextButton),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('sync.plan.holdBanner')), findsNothing);
  });
}
