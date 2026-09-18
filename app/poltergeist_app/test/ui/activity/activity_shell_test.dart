import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_app_transfer_queue.dart';

/// The shell-level wiring (02 §6, D16, D21): the panel's show/hide
/// command, the queue pause command's menu path, the status-bar
/// summary, and the empty→live auto-show edge — all through the real
/// WorkspaceShell composition rather than the panel widget alone.
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

  AppLocalizations l10nOf(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(MenuBar)));

  testWidgets('view.toggleActivityPanel reveals and hides the panel '
      '(toolbar and View menu)', (tester) async {
    await pumpShell(tester);
    expect(
      find.byKey(const ValueKey('activity.panel')),
      findsNothing,
    );

    // The toolbar button (D21's first path).
    await tester.tap(
      find.byKey(const ValueKey('command.view.toggleActivityPanel')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('activity.panel')),
      findsOneWidget,
    );

    // The View menu row exists and carries the same command (D21's
    // menu path — command-palette-only would violate it).
    final l10n = l10nOf(tester);
    await tester.tap(find.text(l10n.menuView));
    await tester.pumpAndSettle();
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
      findsNothing,
    );
  });

  testWidgets('queue.togglePause has a Commands-menu path and drives '
      'the queue gate', (tester) async {
    await pumpShell(tester);
    queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    await tester.pump();
    await tester.pump();

    final l10n = l10nOf(tester);
    await tester.tap(find.text(l10n.menuCommands));
    await tester.pumpAndSettle();
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

    final l10n = l10nOf(tester);
    await tester.tap(find.text(l10n.menuCommands));
    await tester.pumpAndSettle();
    final item = tester.widget<MenuItemButton>(
      find.byKey(const ValueKey('menu.item.queue.togglePause')),
    );
    // The row stays present but inert — a registered command keeps
    // its menu path even while unwired.
    expect(item.onPressed, isNull);
  });

  testWidgets('a hidden panel auto-shows on the empty→live edge and '
      'the status chip counts live work', (tester) async {
    await pumpShell(tester);
    expect(
      find.byKey(const ValueKey('activity.panel')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('statusbar.transferChip')),
      findsNothing,
    );

    queue.addTask(state: TransferTaskState.running, totalBytes: 4000);
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('activity.panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('statusbar.transferChip')),
      findsOneWidget,
    );
  });

  testWidgets('the splitter drags the panel height and persists on '
      'release', (tester) async {
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
          onActivityPanelHeightChanged: (height) async => saved = height,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('command.view.toggleActivityPanel')),
    );
    await tester.pumpAndSettle();

    final splitter = find.byKey(const ValueKey('activity.splitter'));
    expect(splitter, findsOneWidget);
    final before = tester.getSize(
      find.byKey(const ValueKey('activity.panel')),
    );
    // Dragging up grows the panel; the commit lands on release.
    await tester.drag(splitter, const Offset(0, -60));
    await tester.pumpAndSettle();
    final after = tester.getSize(
      find.byKey(const ValueKey('activity.panel')),
    );
    expect(after.height, greaterThan(before.height));
    expect(saved, closeTo(after.height, 0.01));
  });

  testWidgets('the splitter clamps instead of throwing when the '
      'reported window is shorter than twice the panel floor', (
    tester,
  ) async {
    // The resize ceiling is half the reported window: a window under
    // 240px puts it below the 120px floor, where an unguarded clamp
    // throws. The override keeps the real layout roomy so the pane
    // column still fits — the exercise is the clamp, not the squeeze.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1400, 230)),
          child: WorkspaceShell(transferQueue: queue),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('command.view.toggleActivityPanel')),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('activity.splitter')),
      const Offset(0, -20),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
