import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/ui/inspector/inspector_view.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_app/ui/shell/shell_splitter.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_app_transfer_queue.dart';
import '../../support/shell_commands.dart';

/// D32's inspector column (10 §3) through the real WorkspaceShell: its
/// default-shown Info tab, the header toggle and its alert badge, the
/// restored visibility and tab, the responsive overlay stage, and the
/// splitter's keyboard, reset, and drag-to-hide paths (10 §3.1).
void main() {
  late FakeAppTransferQueue queue;

  setUp(() {
    queue = FakeAppTransferQueue();
  });

  tearDown(() async {
    await queue.close();
  });

  final inspector = find.byKey(const ValueKey('inspector'));
  final region = find.byKey(const ValueKey('inspector.region'));
  final overlay = find.byKey(const ValueKey('inspector.overlay'));
  final splitter = find.byKey(const ValueKey('inspector.splitter'));
  final toggle = find.byKey(
    const ValueKey('command.$kViewToggleInspectorCommandId'),
  );

  Future<void> pumpShell(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    SessionState? restored,
    double initialInspectorWidth = inspectorDefaultWidth,
    Future<void> Function(double width)? onInspectorWidthChanged,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WorkspaceShell(
          transferQueue: queue,
          restoredSession: restored,
          initialInspectorWidth: initialInspectorWidth,
          onInspectorWidthChanged: onInspectorWidthChanged,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SessionState session({
    bool? inspectorHidden,
    String? inspectorTab,
    bool activityPanelHidden = true,
  }) => SessionState(
    activePaneId: 'pane.left',
    secondPaneHidden: false,
    activityPanelHidden: activityPanelHidden,
    inspectorHidden: inspectorHidden,
    inspectorTab: inspectorTab,
    panes: const [],
  );

  bool inspectorChecked(WidgetTester tester) =>
      shellCommand(tester, kViewToggleInspectorCommandId).checked!();

  testWidgets('the inspector is up by default on Info; the header toggle '
      'hides and re-shows it', (tester) async {
    await pumpShell(tester);
    expect(region, findsOneWidget);
    expect(inspector, findsOneWidget);
    expect(find.byKey(const ValueKey('activity.panel')), findsNothing);
    expect(inspectorChecked(tester), isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(inspector, findsNothing);
    expect(splitter, findsNothing);
    expect(inspectorChecked(tester), isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(inspector, findsOneWidget);
  });

  testWidgets('the toggle badges the alert count; Alerts lists the failed '
      'task and view.showAlerts opens it', (tester) async {
    await pumpShell(tester);
    Finder badgeOn(Finder finder) =>
        find.descendant(of: finder, matching: find.byType(Badge));
    expect(badgeOn(toggle), findsNothing);

    final task = queue.addTask(state: TransferTaskState.failed, error: 'x');
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: badgeOn(toggle), matching: find.text('1')),
      findsOneWidget,
    );

    // View ▸ Alerts opens the tab that lists it, with its verbs.
    await runShellCommand(tester, kViewShowAlertsCommandId);
    final row = find.byKey(ValueKey('alert.task:${task.id}'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('Retry')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(ValueKey('alert.task:${task.id}.dismiss')));
    await tester.pumpAndSettle();
    expect(row, findsNothing);
    expect(badgeOn(toggle), findsNothing);
    expect(find.byKey(const ValueKey('alerts.empty')), findsOneWidget);
  });

  testWidgets('a restored session keeps the user\'s hide and tab', (
    tester,
  ) async {
    await pumpShell(
      tester,
      restored: session(inspectorHidden: true, inspectorTab: 'alerts'),
    );
    expect(inspector, findsNothing);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('alerts.empty')), findsOneWidget);
  });

  testWidgets('a pre-inspector session with the activity panel open '
      'lands on Transfers', (tester) async {
    await pumpShell(tester, restored: session(activityPanelHidden: false));
    expect(inspector, findsOneWidget);
    expect(find.byKey(const ValueKey('activity.panel')), findsOneWidget);
  });

  testWidgets('a narrow window folds the inspector into an overlay, not a '
      'persisted hide (10 §3.2)', (tester) async {
    // No sidebar in this composition, so the inline inspector needs its
    // width plus two 260 px panes and the splitters (814 px).
    await pumpShell(tester, size: const Size(700, 800));
    expect(region, findsNothing);
    expect(splitter, findsNothing);
    expect(overlay, findsOneWidget);
    expect(inspectorChecked(tester), isTrue);

    // The header button still toggles the overlay.
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(overlay, findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(overlay, findsOneWidget);

    // Regrowth brings it back inline on its own.
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();
    expect(overlay, findsNothing);
    expect(region, findsOneWidget);
  });

  testWidgets('the splitter resizes by 16 px per arrow key and persists '
      'each press once', (tester) async {
    final saved = <double>[];
    await pumpShell(
      tester,
      onInspectorWidthChanged: (width) async => saved.add(width),
    );
    tester
        .widget<ShellSplitter>(splitter)
        .focusNode!
        .requestFocus();
    await tester.pump();

    // The inspector sits right of its splitter: ← grows it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      tester.getSize(region).width,
      inspectorDefaultWidth + shellSplitterKeyStep,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      tester.getSize(region).width,
      inspectorDefaultWidth - shellSplitterKeyStep,
    );
    expect(saved, [
      inspectorDefaultWidth + shellSplitterKeyStep,
      inspectorDefaultWidth,
      inspectorDefaultWidth - shellSplitterKeyStep,
    ]);
  });

  testWidgets('double-clicking the splitter resets the default width', (
    tester,
  ) async {
    final saved = <double>[];
    await pumpShell(
      tester,
      initialInspectorWidth: 400,
      onInspectorWidthChanged: (width) async => saved.add(width),
    );
    expect(tester.getSize(region).width, 400);

    await tester.tap(splitter);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(splitter);
    await tester.pumpAndSettle();
    expect(tester.getSize(region).width, inspectorDefaultWidth);
    expect(saved.last, inspectorDefaultWidth);
  });

  testWidgets('dragging well past the minimum hides the inspector as a '
      'user hide', (tester) async {
    await pumpShell(tester);
    // 280 → past 240 − 48: a deliberate fling, not a nudge.
    await tester.drag(splitter, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(inspector, findsNothing);
    expect(inspectorChecked(tester), isFalse);

    // Re-shown, it comes back at the minimum, never below it.
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.getSize(region).width, inspectorMinWidth);
  });
}
