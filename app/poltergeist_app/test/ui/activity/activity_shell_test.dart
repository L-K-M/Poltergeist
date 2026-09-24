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
    await tester.tap(find.text(l10n.menuServer));
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
    await tester.tap(find.text(l10n.menuServer));
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
