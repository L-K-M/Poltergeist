import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/activity_panel_controller.dart';
import 'package:poltergeist_app/ui/activity/activity_panel.dart';
import 'package:poltergeist_app/ui/inspector/inspector_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_app_transfer_queue.dart';

/// 02 §6's panel over the scripted queue seam: every assertion reads
/// what the queue reports or records what the panel asked of it — no
/// test reaches inside widgets for state the queue owns.
void main() {
  late FakeAppTransferQueue queue;
  late ActivityPanelController controller;

  setUp(() {
    queue = FakeAppTransferQueue();
    controller = ActivityPanelController(queue: queue);
  });

  tearDown(() async {
    controller.dispose();
    await queue.close();
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    // The panel is bottom chrome (D16) — pin it low with room above so
    // the bandwidth popover's upward anchor lands on-screen, as it
    // does over the panes in the real shell.
    tester.view.physicalSize = const Size(1100, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              const Spacer(),
              SizedBox(
                height: 360,
                // The shell mounts the panel inside a ListenableBuilder;
                // the direct harness mirrors that composition.
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => ActivityPanel(
                    controller: controller,
                    onClose: () {},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('empty queue renders the empty state, not fake rows', (
    tester,
  ) async {
    await pumpPanel(tester);
    expect(find.text('No transfers in progress.'), findsOneWidget);
    expect(find.byKey(const ValueKey('activity.taskList')), findsNothing);
  });

  testWidgets('task rows render while tasks exist, with honest state '
      'labels', (tester) async {
    await pumpPanel(tester);
    queue.addTask(
      state: TransferTaskState.running,
      rootPaths: const ['/home/tester/report.pdf'],
      totalFiles: 3,
      transferredBytes: 500,
      totalBytes: 2000,
    );
    queue.addTask(
      state: TransferTaskState.queued,
      rootPaths: const ['/home/tester/photos.zip'],
    );
    await settle(tester);

    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('photos.zip'), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Queued'), findsOneWidget);
    expect(find.byKey(const ValueKey('activity.taskList')), findsOneWidget);
  });

  testWidgets('the footer totals grow with a + while a scan runs', (
    tester,
  ) async {
    await pumpPanel(tester);
    final task = queue.addTask(
      state: TransferTaskState.scanning,
      scanComplete: false,
      totalFiles: 3,
      completedFiles: 1,
      transferredBytes: 512,
      totalBytes: 2048,
    );
    await settle(tester);

    final footer = find.byKey(const ValueKey('activity.footer'));
    final text = tester.widget<Text>(
      find.descendant(of: footer, matching: find.byType(Text)),
    );
    expect(text.data, contains('1+'));
    expect(text.data, contains('3+'));

    task.scanComplete = true;
    queue.emitRefresh();
    await settle(tester);
    final settled = tester.widget<Text>(
      find.descendant(of: footer, matching: find.byType(Text)),
    );
    expect(settled.data, isNot(contains('+')));
  });

  testWidgets('per-item cancel reaches the queue with item identity', (
    tester,
  ) async {
    await pumpPanel(tester);
    final task = queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    queue.addItem(task, name: 'a.txt');
    final item = queue.addItem(task, name: 'b.txt');
    await settle(tester);

    // Expand (>1 item gate) then cancel b.txt's pending row.
    await tester.tap(find.byTooltip('Show files'));
    await settle(tester);
    expect(find.byKey(ValueKey('activity.item.${item.id}')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('activity.itemSkip.${item.id}')));
    await settle(tester);
    expect(queue.cancelItemCalls, [(task.id, item.id)]);
    expect(item.state, TransferItemState.cancelled);
  });

  testWidgets('failed items offer Retry only when the queue says '
      're-enqueueable', (tester) async {
    await pumpPanel(tester);
    final task = queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    final retryable = queue.addItem(
      task,
      name: 'dead.txt',
      state: TransferItemState.failed,
      error: 'permission denied',
    );
    final stale = queue.addItem(
      task,
      name: 'gone.txt',
      state: TransferItemState.failed,
      error: 'record missing',
    );
    queue.nonRetryableItems.add(stale.id);
    await settle(tester);

    await tester.tap(find.byTooltip('Show files'));
    await settle(tester);

    expect(
      find.byKey(ValueKey('activity.itemRetry.${retryable.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('activity.itemRetry.${stale.id}')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(ValueKey('activity.itemRetry.${retryable.id}')),
    );
    await settle(tester);
    expect(queue.retryItemCalls, [(task.id, retryable.id)]);
  });

  testWidgets('task verbs follow state: cancel on live, retry+remove '
      'on failed', (tester) async {
    await pumpPanel(tester);
    final live = queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    final failed = queue.addTask(state: TransferTaskState.failed);
    queue.addItem(failed, state: TransferItemState.failed);
    await settle(tester);

    await tester.tap(find.byKey(ValueKey('activity.cancel.${live.id}')));
    await settle(tester);
    expect(queue.cancelTaskCalls, [live.id]);

    await tester.tap(find.byKey(ValueKey('activity.retry.${failed.id}')));
    await settle(tester);
    expect(queue.retryTaskCalls, [failed.id]);

    // The failed task re-queued — back to live, so Remove is gone and
    // Cancel returns.
    expect(
      find.byKey(ValueKey('activity.remove.${failed.id}')),
      findsNothing,
    );
  });

  testWidgets('drag handles exist only on reorderable pending rows; a '
      'drag lands as moveTask with beforeTaskId', (tester) async {
    await pumpPanel(tester);
    queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    final first = queue.addTask(state: TransferTaskState.queued);
    final second = queue.addTask(state: TransferTaskState.queued);
    queue.addTask(state: TransferTaskState.completed);
    await settle(tester);

    // Display bands: live, pending, terminal. Only the pending band
    // carries drag handles.
    expect(
      find.descendant(
        of: find.byKey(ValueKey('activity.task.${first.id}')),
        matching: find.byIcon(Icons.drag_indicator),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(ValueKey('activity.task.${queue.tasks[0].id}')),
        matching: find.byIcon(Icons.drag_indicator),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(ValueKey('activity.task.${queue.tasks[3].id}')),
        matching: find.byIcon(Icons.drag_indicator),
      ),
      findsNothing,
    );

    // Drag the first pending row below the second — drop inside the
    // pending band lands behind it (beforeTaskId null).
    final handle = find.descendant(
      of: find.byKey(ValueKey('activity.task.${first.id}')),
      matching: find.byIcon(Icons.drag_indicator),
    );
    // A reorder fires once the drag crosses the next row's midpoint —
    // task rows are ~100px, so pull well past.
    await tester.drag(handle, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(queue.moveTaskCalls, isNotEmpty);
    expect(queue.moveTaskCalls.last.$1, first.id);
    final order = [for (final t in queue.tasks) t.id];
    expect(order.indexOf(first.id), greaterThan(order.indexOf(second.id)));
  });

  testWidgets('the header pause button drives the queue gate', (
    tester,
  ) async {
    await pumpPanel(tester);
    queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('activity.pause')));
    await settle(tester);
    expect(queue.pauseQueueCalls, 1);
    expect(queue.isPaused, isTrue);

    await tester.tap(find.byKey(const ValueKey('activity.pause')));
    await settle(tester);
    expect(queue.resumeQueueCalls, 1);
    expect(queue.isPaused, isFalse);
  });

  testWidgets('the bandwidth popover applies presets and validates '
      'custom input', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.byKey(const ValueKey('activity.bandwidth')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('activity.bandwidthPopover')),
      findsOneWidget,
    );

    // Preset chip: 256 KB/s download.
    await tester.tap(find.byKey(const ValueKey('bandwidth.down.1')));
    await tester.pumpAndSettle();
    expect(queue.downloadLimiter.bytesPerSecond, 256000);

    // Custom invalid input stays an inline error — nothing applied.
    await tester.tap(find.byKey(const ValueKey('bandwidth.up.custom')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('bandwidth.up.field')),
      'fast',
    );
    await tester.tap(find.byKey(const ValueKey('bandwidth.up.set')));
    await tester.pumpAndSettle();
    expect(queue.uploadLimiter.bytesPerSecond, isNull);
    expect(find.textContaining('Enter a rate'), findsOneWidget);

    // A valid custom rate applies immediately.
    await tester.enterText(
      find.byKey(const ValueKey('bandwidth.up.field')),
      '2 MB/s',
    );
    await tester.tap(find.byKey(const ValueKey('bandwidth.up.set')));
    await tester.pumpAndSettle();
    expect(queue.uploadLimiter.bytesPerSecond, 2000000);
  });

  testWidgets('a persisted non-preset limit opens as Custom with the '
      'rate filled in', (tester) async {
    // Seeding reads the theme platform for the prefilled text — that
    // lookup belongs in didChangeDependencies, not initState.
    queue.downloadLimiter.bytesPerSecond = 12345;
    await pumpPanel(tester);
    await tester.tap(find.byKey(const ValueKey('activity.bandwidth')));
    await tester.pumpAndSettle();

    final custom = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('bandwidth.down.custom')),
    );
    expect(custom.selected, isTrue);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('bandwidth.down.field')),
    );
    expect(field.controller!.text, isNotEmpty);
  });

  testWidgets('the popover barrier absorbs taps instead of leaking '
      'them to the panel', (tester) async {
    await pumpPanel(tester);
    queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('activity.bandwidth')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('activity.bandwidthPopover')),
      findsOneWidget,
    );

    // Tap-outside dismisses — and must not also fire the control
    // behind the barrier (modal semantics, not translucent). The tap
    // misses the button's render object entirely under an opaque
    // barrier, which is exactly the behavior under test.
    await tester.tap(
      find.byKey(const ValueKey('activity.pause')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(queue.pauseQueueCalls, 0);
    expect(
      find.byKey(const ValueKey('activity.bandwidthPopover')),
      findsNothing,
    );
  });

  testWidgets('the tabs expose their selected state to screen readers',
      (tester) async {
    await pumpPanel(tester);
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('activity.tab.activity')),
          )
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('activity.tab.history')),
          )
          .flagsCollection
          .isSelected,
      Tristate.isFalse,
    );
  });

  testWidgets('the conflict strip renders parked conflicts and the '
      'dialog submits verb + apply-to-all scope', (tester) async {
    await pumpPanel(tester);
    final task = queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    final itemA = queue.addItem(task, name: 'a.txt');
    final itemB = queue.addItem(task, name: 'b.txt');
    queue.addConflict(task, itemA);
    queue.addConflict(task, itemB);
    await settle(tester);

    expect(
      find.byKey(const ValueKey('activity.conflicts')),
      findsOneWidget,
    );
    expect(find.text('a.txt'), findsWidgets);
    expect(find.text('b.txt'), findsWidgets);

    await tester.tap(
      find.byKey(ValueKey('activity.conflictResolve.${itemA.id}')),
    );
    await tester.pumpAndSettle();

    // The dialog lists the file verbs and the apply-to-all checkbox
    // (N = the other parked conflict).
    for (final verb in ['replace', 'replaceIfNewer', 'keepBoth', 'skip']) {
      expect(
        find.byKey(ValueKey('conflict.verb.$verb')),
        findsOneWidget,
        reason: 'file conflicts offer $verb',
      );
    }
    expect(find.byKey(const ValueKey('conflict.verb.merge')),
        findsNothing); // files cannot merge
    await tester.tap(find.byKey(const ValueKey('conflict.applyToAll')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('conflict.verb.replace')));
    await tester.pumpAndSettle();

    expect(
      queue.resolveConflictCalls.single,
      (
        task.id,
        itemA.id,
        ConflictResolution.replace,
        ConflictResolutionScope.task,
      ),
    );
    // Apply-to-all cleared BOTH parked conflicts in the task.
    expect(controller.pendingConflicts, isEmpty);
  });

  testWidgets('a directory conflict offers Merge; Stop cancels the '
      'task', (tester) async {
    await pumpPanel(tester);
    final task = queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    final dir = queue.addItem(task, name: 'assets', isDirectory: true);
    queue.addConflict(task, dir, isDirectory: true);
    await settle(tester);

    await tester.tap(
      find.byKey(ValueKey('activity.conflictResolve.${dir.id}')),
    );
    await tester.pumpAndSettle();
    // 02 §5.2's five-verb model: a folder collision offers all five.
    for (final verb in [
      'replace',
      'replaceIfNewer',
      'keepBoth',
      'skip',
      'merge',
    ]) {
      expect(
        find.byKey(ValueKey('conflict.verb.$verb')),
        findsOneWidget,
        reason: 'folder conflicts offer $verb',
      );
    }

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(queue.cancelTaskCalls, [task.id]);
    expect(task.state, TransferTaskState.cancelled);
  });

  testWidgets('the History tab lists persisted records, filters, and '
      'clears', (tester) async {
    await pumpPanel(tester);
    queue.addHistory(rootPaths: const ['/home/tester/report.pdf']);
    queue.addHistory(
      taskId: 'done-2',
      rootPaths: const ['/home/tester/photos.zip'],
      outcome: TransferTaskState.failed,
      error: 'connection lost',
    );
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('activity.tab.history')));
    await settle(tester);
    expect(find.textContaining('report.pdf'), findsWidgets);
    expect(find.textContaining('photos.zip'), findsWidgets);
    expect(find.textContaining('connection lost'), findsWidgets);

    await tester.enterText(
      find.byKey(const ValueKey('history.filter')),
      'photos',
    );
    await settle(tester);
    expect(find.textContaining('report.pdf'), findsNothing);
    expect(find.textContaining('photos.zip'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('history.clear')));
    await settle(tester);
    expect(queue.clearHistoryCalls, 1);
    expect(find.text('No transfer history yet.'), findsOneWidget);
  });

  testWidgets('the restored banner offers Resume and Discard', (
    tester,
  ) async {
    await pumpPanel(tester);
    final restored = queue.addTask(
      state: TransferTaskState.paused,
      wasRestored: true,
    );
    await settle(tester);
    expect(
      find.byKey(const ValueKey('activity.restoredBanner')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('activity.restoredBanner.resume')),
    );
    await settle(tester);
    expect(queue.resumeQueueCalls, 1);
    expect(queue.resumeTaskCalls, [restored.id]);

    // The banner clears once no live restored tasks remain — Discard
    // on a fresh set cancels them.
    restored.state = TransferTaskState.cancelled;
    queue.emitRefresh();
    final other = queue.addTask(
      state: TransferTaskState.paused,
      wasRestored: true,
    );
    await settle(tester);
    await tester.tap(
      find.byKey(const ValueKey('activity.restoredBanner.discard')),
    );
    await settle(tester);
    expect(queue.cancelTaskCalls, contains(other.id));
    expect(
      find.byKey(const ValueKey('activity.restoredBanner')),
      findsNothing,
    );
  });

  testWidgets('clear-completed drops only completed rows', (
    tester,
  ) async {
    await pumpPanel(tester);
    final done = queue.addTask(state: TransferTaskState.completed);
    final failed = queue.addTask(state: TransferTaskState.failed);
    await settle(tester);

    await tester.tap(
      find.byKey(const ValueKey('activity.clearCompleted')),
    );
    await settle(tester);
    expect(queue.removeTaskCalls, [done.id]);
    expect(controller.tasks.map((t) => t.id), [failed.id]);
  });

  testWidgets('embedded at the inspector minimum width, the header fits '
      'and keeps every queue control (D32)', (tester) async {
    tester.view.physicalSize = const Size(1100, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final task = queue.addTask(
      state: TransferTaskState.running,
      totalBytes: 4000,
    );
    // The conflict strip and the restored banner share the column too.
    final item = queue.addItem(task, name: 'a-long-conflicting-name.txt');
    queue.addConflict(task, item);
    queue.addTask(state: TransferTaskState.paused, wasRestored: true);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: SizedBox(
              width: inspectorMinWidth,
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) => ActivityPanel(
                  controller: controller,
                  embedded: true,
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);

    // No RenderFlex overflow: the tab labels yield, the buttons stay.
    expect(tester.takeException(), isNull);
    for (final key in [
      'activity.pause',
      'activity.clearCompleted',
      'activity.tab.activity',
      'activity.tab.history',
      'activity.restoredBanner.resume',
      'activity.restoredBanner.discard',
      'activity.conflictResolve.${item.id}',
    ]) {
      expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
    }
    // The inspector toggle owns visibility — no ✕ in the tab.
    expect(find.byKey(const ValueKey('activity.close')), findsNothing);
  });
}
