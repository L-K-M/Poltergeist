import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/drag_out_controller.dart';
import 'package:poltergeist_app/services/os_drag_out.dart';
import 'package:poltergeist_app/services/pane_drop.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_app_transfer_queue.dart';
import '../../support/fake_drag_out.dart';
import '../../support/shell_commands.dart';

/// OS drag-out's composition through the real WorkspaceShell (00 D14's
/// amendment): one controller over the shell's queue reaches every pane
/// and reports its refusals in the Alerts tab.
void main() {
  late FakeAppTransferQueue queue;
  late FakeDragOutBackend backend;

  setUp(() {
    queue = FakeAppTransferQueue();
    backend = FakeDragOutBackend(support: DragOutSupport.localFilesAndPromises);
  });

  tearDown(() async => queue.close());

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WorkspaceShell(
          transferQueue: queue,
          dragOutBackend: backend,
          dragOutProducer: FakeDragOutProducer(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  DragOutController shellDragOut(WidgetTester tester) => tester
      .widgetList<PaneView>(find.byType(PaneView))
      .map((pane) => pane.dragOut)
      .toSet()
      .single!;

  /// Hands a drag of the remote folder `/srv/site` to the backend.
  Future<void> handOffSite(WidgetTester tester, DragOutController dragOut) =>
      tester.runAsync(
        () => dragOut.handOff(
          PaneEntryDrag(
            source: const ServerFsLocation('srv-1'),
            rootPaths: const ['/srv/site'],
            entries: const [
              RemoteFileEntry(
                path: '/srv/site',
                name: 'site',
                type: RemoteFileType.directory,
              ),
            ],
          ),
          position: const Offset(1500, 10),
          style: DragOutImageStyle(
            palette: const DragOutImagePalette(
              background: Colors.white,
              foreground: Colors.black,
              badge: Colors.blue,
              onBadge: Colors.white,
            ),
            devicePixelRatio: 1,
            itemCountLabel: (count) => '$count',
          ),
        ),
      );

  testWidgets("a Pause on a folder promise's Transfers row ends the drop "
      'and says so under Alerts', (tester) async {
    await pumpShell(tester);
    final dragOut = shellDragOut(tester);
    await handOffSite(tester, dragOut);

    Object? failure;
    unawaited(
      dragOut
          .fulfilPromise(
            DragOutPromiseRequest(
              sessionId: backend.requests.single.sessionId,
              promiseId: 'p1',
              destinationPath: '/Users/me/Desktop/site',
            ),
          )
          .catchError((Object error) => failure = error),
    );
    await tester.pump();
    final task = queue.tasks.single..state = TransferTaskState.running;
    queue.emit(TransferQueueTaskEvent(task.id, task.state));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('inspector.tab.transfers')));
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('activity.task.${task.id}')),
        matching: find.byIcon(Icons.pause),
      ),
    );
    await tester.pump();

    // The OS stops waiting at once, and nothing lands after it gave up.
    expect(queue.pauseTaskCalls, [task.id]);
    expect(queue.cancelTaskCalls, [task.id]);
    expect(
      failure,
      isA<DragOutPromiseException>().having(
        (error) => error.failure,
        'failure',
        DragOutPromiseFailure.paused,
      ),
    );
    await runShellCommand(tester, kViewShowAlertsCommandId);
    expect(find.text("Couldn't drag “site” out"), findsOneWidget);
    expect(
      find.text('The download to /Users/me/Desktop was paused, so it stopped.'),
      findsOneWidget,
    );
  });

  testWidgets('the shell hands its drag-out controller to the panes and '
      'lists a refused promise under Alerts', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WorkspaceShell(
          transferQueue: queue,
          dragOutBackend: backend,
          dragOutProducer: FakeDragOutProducer(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final controllers = {
      for (final pane in tester.widgetList<PaneView>(find.byType(PaneView)))
        pane.dragOut,
    };
    expect(controllers, hasLength(1));
    final dragOut = controllers.single!;
    expect(backend.attached, same(dragOut));
    expect(dragOut.support, DragOutSupport.localFilesAndPromises);

    // A folder promise while the queue is paused: refused at once.
    queue.pauseQueue();
    await tester.runAsync(() async {
      await dragOut.handOff(
        PaneEntryDrag(
          source: const ServerFsLocation('srv-1'),
          rootPaths: const ['/srv/site'],
          entries: const [
            RemoteFileEntry(
              path: '/srv/site',
              name: 'site',
              type: RemoteFileType.directory,
            ),
          ],
        ),
        position: const Offset(1500, 10),
        style: DragOutImageStyle(
          palette: const DragOutImagePalette(
            background: Colors.white,
            foreground: Colors.black,
            badge: Colors.blue,
            onBadge: Colors.white,
          ),
          devicePixelRatio: 1,
          itemCountLabel: (count) => '$count',
        ),
      );
      await expectLater(
        dragOut.fulfilPromise(
          DragOutPromiseRequest(
            sessionId: backend.requests.single.sessionId,
            promiseId: 'p1',
            destinationPath: '/Users/me/Desktop/site',
          ),
        ),
        throwsA(isA<DragOutPromiseException>()),
      );
    });
    await runShellCommand(tester, kViewShowAlertsCommandId);
    expect(find.text("Couldn't drag “site” out"), findsOneWidget);
    expect(
      find.text(
        'Transfers are paused. Resume them, then drag it to '
        '/Users/me/Desktop again.',
      ),
      findsOneWidget,
    );
  });
}
