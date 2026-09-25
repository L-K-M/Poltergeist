import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/ui/shell/header_activity_button.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_app_transfer_queue.dart';
import '../../support/shell_menus.dart';

/// The shell-level wiring (02 §6, D16, D21, D32): the Transfers tab's
/// show/hide command, the queue pause command's menu path, the header's
/// activity ring, and the empty→live auto-show edge — all through the
/// real WorkspaceShell composition rather than the panel widget alone.
void main() {
  late FakeAppTransferQueue queue;

  setUp(() {
    queue = FakeAppTransferQueue();
  });

  tearDown(() async {
    await queue.close();
  });

  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WorkspaceShell(transferQueue: queue),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('view.toggleActivityPanel shows the Transfers tab and '
      'hides the inspector (header and View menu)', (tester) async {
    await pumpShell(tester);
    // D32: the inspector is up by default, on Info — no transfer rows.
    expect(find.byKey(const ValueKey('inspector')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('activity.panel')),
      findsNothing,
    );
    // 10 §4: the header's activity button exists only while work runs.
    expect(
      find.byKey(const ValueKey('command.view.toggleActivityPanel')),
      findsNothing,
    );

    // The View menu row exists and carries the same command (D21's
    // menu path — command-palette-only would violate it).
    await openShellMenu(tester, AppMenuId.view);
    expect(
      find.byKey(const ValueKey('menu.item.view.toggleActivityPanel')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('menu.item.view.toggleActivityPanel')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('activity.panel')),
      findsOneWidget,
    );

    // While work runs the header button carries the same toggle: on the
    // Transfers tab it hides the inspector.
    queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('command.view.toggleActivityPanel')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('activity.panel')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('inspector')), findsNothing);
  });

  testWidgets('queue.togglePause has a Server-menu path and drives '
      'the queue gate', (tester) async {
    await pumpShell(tester);
    queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    await tester.pump();
    await tester.pump();

    await openShellMenu(tester, AppMenuId.server);
    final item = find.byKey(
      const ValueKey('menu.item.queue.togglePause'),
    );
    expect(item, findsOneWidget);
    await tester.tap(item);
    await tester.pumpAndSettle();
    expect(queue.pauseQueueCalls, 1);
    expect(queue.isPaused, isTrue);
  });

  testWidgets('queue.togglePause is disabled when no queue seam is '
      'wired', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WorkspaceShell(),
      ),
    );
    await tester.pumpAndSettle();

    await openShellMenu(tester, AppMenuId.server);
    final item = tester.widget<MenuItemButton>(
      find.byKey(const ValueKey('menu.item.queue.togglePause')),
    );
    // The row stays present but inert — a registered command keeps
    // its menu path even while unwired.
    expect(item.onPressed, isNull);
  });

  testWidgets('new work switches the inspector to Transfers and rings '
      'the activity button while it runs', (tester) async {
    await pumpShell(tester);
    expect(
      find.byKey(const ValueKey('activity.panel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('header.activityRing')),
      findsNothing,
    );

    // D16's empty→live edge re-opens the queue's only window: the
    // Info tab yields to Transfers (10 §2's honest-state rule).
    final task = queue.addTask(
      state: TransferTaskState.running,
      totalBytes: 4000,
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('activity.panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('header.activityRing')),
      findsOneWidget,
    );

    // The ring is the live-work signal only: it leaves with the work,
    // after a short linger (10 §4: hidden while idle).
    task.state = TransferTaskState.completed;
    queue.emit(TransferQueueTaskEvent(task.id, task.state));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('command.view.toggleActivityPanel')),
      findsOneWidget,
    );
    await tester.pump(headerActivityHideDelay);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('header.activityRing')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('command.view.toggleActivityPanel')),
      findsNothing,
    );
  });

  testWidgets('a transfer that stops and restarts inside the linger '
      'keeps the activity button still', (tester) async {
    await pumpShell(tester);
    final newFolder = find.byKey(const ValueKey('command.file.newFolder'));
    final idleX = tester.getTopLeft(newFolder).dx;

    final first = queue.addTask(
      state: TransferTaskState.running,
      totalBytes: 4000,
    );
    await tester.pump();
    await tester.pumpAndSettle();
    final busyX = tester.getTopLeft(newFolder).dx;
    // The button claims its room once, while work starts.
    expect(busyX, lessThan(idleX));

    first.state = TransferTaskState.completed;
    queue.emit(TransferQueueTaskEvent(first.id, first.state));
    await tester.pump();
    await tester.pump(headerActivityHideDelay ~/ 2);
    expect(tester.getTopLeft(newFolder).dx, busyX);

    // The next task lands inside the linger: nothing moves.
    queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    await tester.pump();
    await tester.pump(headerActivityHideDelay * 2);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(newFolder).dx, busyX);
    expect(
      find.byKey(const ValueKey('header.activityRing')),
      findsOneWidget,
    );
  });

  testWidgets('new work re-opens a user-hidden inspector on Transfers', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(
      find.byKey(const ValueKey('command.view.toggleInspector')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inspector')), findsNothing);

    queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('inspector')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('activity.panel')),
      findsOneWidget,
    );
  });

  testWidgets('the inspector splitter drags the width and persists on '
      'release (D32 §3.1)', (tester) async {
    double? saved;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WorkspaceShell(
          transferQueue: queue,
          onInspectorWidthChanged: (width) async => saved = width,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final splitter = find.byKey(const ValueKey('inspector.splitter'));
    expect(splitter, findsOneWidget);
    final before = tester.getSize(
      find.byKey(const ValueKey('inspector.region')),
    );
    // Dragging left grows the inspector; the commit lands on release.
    await tester.drag(splitter, const Offset(-60, 0));
    await tester.pumpAndSettle();
    final after = tester.getSize(
      find.byKey(const ValueKey('inspector.region')),
    );
    expect(after.width, greaterThan(before.width));
    expect(saved, closeTo(after.width, 0.01));
  });

}
