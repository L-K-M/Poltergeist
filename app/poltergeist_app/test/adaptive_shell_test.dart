import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/ui/adaptive_shell.dart';
import 'package:poltergeist_app/ui/layout/pane_allocation.dart';

const _testWindowSize = Size(1180, 760);
const _keyboardResizeStepCountToEdge = 37;

Widget _pane(String name) => ColoredBox(
  color: Colors.white,
  child: Center(child: Text(name)),
);

Future<void> _pumpShell(
  WidgetTester tester, {
  Size size = _testWindowSize,
  TextDirection textDirection = TextDirection.ltr,
  double initialPaneRatio = 0.5,
  PaneRatioSaver? onPaneRatioChanged,
  void Function(Object, StackTrace)? onPaneRatioSaveError,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Directionality(
        textDirection: textDirection,
        child: AdaptiveShell(
          resizeLabel: 'Resize panes',
          formatRatio: (ratio) => '${(ratio * 100).round()}%',
          initialPaneRatio: initialPaneRatio,
          onPaneRatioChanged: onPaneRatioChanged,
          onPaneRatioSaveError: onPaneRatioSaveError,
          primary: _pane('A'),
          secondary: _pane('B'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('exposes keyed panes and splitter', (tester) async {
    await _pumpShell(tester);

    expect(find.byKey(AdaptiveShell.primaryPaneKey), findsOneWidget);
    expect(find.byKey(AdaptiveShell.secondaryPaneKey), findsOneWidget);
    expect(find.byKey(AdaptiveShell.splitterKey), findsOneWidget);
  });

  testWidgets('restores the initial pane ratio', (tester) async {
    const restoredRatio = 0.7;
    await _pumpShell(tester, initialPaneRatio: restoredRatio);

    final expectedWidth = allocatePanes(
      width: _testWindowSize.width,
      ratio: restoredRatio,
      secondPaneIntent: SecondPaneIntent.shown,
    ).primaryWidth;
    expect(
      tester.getSize(find.byKey(AdaptiveShell.primaryPaneKey)).width,
      expectedWidth,
    );
  });

  testWidgets('auto-hides and restores pane B across the mobile boundary', (
    tester,
  ) async {
    await _pumpShell(tester, size: const Size(679, 600));
    expect(find.byKey(AdaptiveShell.secondaryPaneKey), findsNothing);

    tester.view.physicalSize = const Size(680, 600);
    await tester.pump();
    expect(find.byKey(AdaptiveShell.secondaryPaneKey), findsOneWidget);
  });

  testWidgets('keyboard-resizes the focused splitter', (tester) async {
    await _pumpShell(tester);

    final before = tester
        .getSize(find.byKey(AdaptiveShell.primaryPaneKey))
        .width;
    await tester.tap(find.byKey(AdaptiveShell.splitterKey));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final after = tester
        .getSize(find.byKey(AdaptiveShell.primaryPaneKey))
        .width;

    expect(after - before, 16);
  });

  testWidgets('draws the accent outline while focused', (tester) async {
    await _pumpShell(tester);

    await tester.tap(find.byKey(AdaptiveShell.splitterKey));
    await tester.pump();

    final primary = Theme.of(
      tester.element(find.byKey(AdaptiveShell.splitterKey)),
    ).colorScheme.primary;
    final outline = find.byWidgetPredicate((widget) {
      if (widget case DecoratedBox(decoration: final BoxDecoration box)) {
        final border = box.border;
        return border is Border &&
            border.top.width == 2 &&
            border.top.color == primary;
      }

      return false;
    });
    expect(outline, findsOneWidget);
  });

  testWidgets('exposes focusable adjustable semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pumpShell(tester);

      final data = tester
          .getSemantics(find.byKey(AdaptiveShell.splitterKey))
          .getSemanticsData();
      expect(data.label, 'Resize panes');
      expect(data.value, '50%');
      expect(data.increasedValue, '51%');
      expect(data.decreasedValue, '49%');
      expect(data.flagsCollection.isFocused, isNot(ui.Tristate.none));
      expect(data.hasAction(ui.SemanticsAction.focus), isTrue);
      expect(data.hasAction(ui.SemanticsAction.increase), isTrue);
      expect(data.hasAction(ui.SemanticsAction.decrease), isTrue);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('announces the actual compact-width resize step', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pumpShell(tester, size: const Size(680, 600));

      final data = tester
          .getSemantics(find.byKey(AdaptiveShell.splitterKey))
          .getSemanticsData();
      expect(data.value, '50%');
      expect(data.increasedValue, '52%');
      expect(data.decreasedValue, '48%');
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('semantic increase follows RTL reading order', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pumpShell(tester, textDirection: TextDirection.rtl);

      final before = tester
          .getSize(find.byKey(AdaptiveShell.primaryPaneKey))
          .width;
      tester.semantics.increase(find.semantics.byLabel('Resize panes'));
      await tester.pump();
      final after = tester
          .getSize(find.byKey(AdaptiveShell.primaryPaneKey))
          .width;

      expect(after - before, 16);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('reports the normalized pane ratio after resizing', (
    tester,
  ) async {
    final savedRatios = <double>[];
    await _pumpShell(tester, onPaneRatioChanged: savedRatios.add);

    await tester.tap(find.byKey(AdaptiveShell.splitterKey));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(savedRatios, hasLength(1));
    expect(savedRatios.single, closeTo(0.513746, 0.000001));
  });

  testWidgets('reverts the latest ratio when persistence fails', (
    tester,
  ) async {
    final save = Completer<void>();
    final errors = <Object>[];
    unawaited(save.future.catchError((_) {}));
    await _pumpShell(
      tester,
      onPaneRatioChanged: (_) => save.future,
      onPaneRatioSaveError: (error, _) => errors.add(error),
    );

    final pane = find.byKey(AdaptiveShell.primaryPaneKey);
    final before = tester.getSize(pane).width;
    await tester.tap(find.byKey(AdaptiveShell.splitterKey));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.getSize(pane).width, before + 16);

    save.completeError(StateError('save failed'));
    await tester.pump();
    await tester.pump();

    expect(tester.getSize(pane).width, before);
    expect(errors, [isA<StateError>()]);
  });

  testWidgets('applies two drag updates before the next pump', (tester) async {
    await _pumpShell(tester);

    final splitter = find.byKey(AdaptiveShell.splitterKey);
    final before = tester
        .getSize(find.byKey(AdaptiveShell.primaryPaneKey))
        .width;
    final gesture = await tester.startGesture(tester.getCenter(splitter));
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump();
    await gesture.up();

    final after = tester
        .getSize(find.byKey(AdaptiveShell.primaryPaneKey))
        .width;
    expect(after - before, 32);
  });

  testWidgets('persists one final ratio after a drag', (tester) async {
    final savedRatios = <double>[];
    await _pumpShell(tester, onPaneRatioChanged: savedRatios.add);

    final splitter = find.byKey(AdaptiveShell.splitterKey);
    final gesture = await tester.startGesture(tester.getCenter(splitter));
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveBy(const Offset(12, 0));
    await tester.pump();

    expect(savedRatios, isEmpty);

    await gesture.up();
    await tester.pump();

    expect(savedRatios, hasLength(1));
    expect(savedRatios.single, closeTo(0.527491, 0.000001));
  });

  testWidgets('persists one final ratio after key repeats', (tester) async {
    final savedRatios = <double>[];
    await _pumpShell(tester, onPaneRatioChanged: savedRatios.add);

    await tester.tap(find.byKey(AdaptiveShell.splitterKey));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(savedRatios, isEmpty);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(savedRatios, hasLength(1));
    expect(savedRatios.single, closeTo(0.541237, 0.000001));
  });

  testWidgets('persists a held-key resize when focus leaves', (tester) async {
    final savedRatios = <double>[];
    await _pumpShell(tester, onPaneRatioChanged: savedRatios.add);

    await tester.tap(find.byKey(AdaptiveShell.splitterKey));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(savedRatios, isEmpty);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(savedRatios, hasLength(1));
    expect(savedRatios.single, closeTo(0.513746, 0.000001));
  });

  testWidgets('persists the final ratio when removed during a drag', (
    tester,
  ) async {
    final savedRatios = <double>[];
    await _pumpShell(tester, onPaneRatioChanged: savedRatios.add);

    final splitter = find.byKey(AdaptiveShell.splitterKey);
    final gesture = await tester.startGesture(tester.getCenter(splitter));
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveBy(const Offset(12, 0));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await gesture.removePointer();

    expect(savedRatios, hasLength(1));
    expect(savedRatios.single, closeTo(0.527491, 0.000001));
  });

  testWidgets('keeps the splitter at the right edge', (tester) async {
    final savedRatios = <double>[];
    await _pumpShell(tester, onPaneRatioChanged: savedRatios.add);

    await tester.tap(find.byKey(AdaptiveShell.splitterKey));
    for (var i = 0; i < _keyboardResizeStepCountToEdge; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.pump();

    final rightEdge = allocatePanes(
      width: _testWindowSize.width,
      ratio: 1,
      secondPaneIntent: SecondPaneIntent.shown,
    ).primaryWidth;
    expect(
      tester.getSize(find.byKey(AdaptiveShell.primaryPaneKey)).width,
      rightEdge,
    );
    expect(savedRatios.last, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      tester.getSize(find.byKey(AdaptiveShell.primaryPaneKey)).width,
      rightEdge,
    );
    expect(savedRatios.last, 1);
  });

  testWidgets('moves inward immediately from the right edge', (tester) async {
    await _pumpShell(tester);

    await tester.tap(find.byKey(AdaptiveShell.splitterKey));
    for (var i = 0; i < _keyboardResizeStepCountToEdge; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.pump();
    final edgeWidth = tester
        .getSize(find.byKey(AdaptiveShell.primaryPaneKey))
        .width;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    final inwardWidth = tester
        .getSize(find.byKey(AdaptiveShell.primaryPaneKey))
        .width;
    expect(edgeWidth - inwardWidth, 16);
  });

  testWidgets('drags inward immediately from the right edge', (tester) async {
    await _pumpShell(tester);

    await tester.tap(find.byKey(AdaptiveShell.splitterKey));
    for (var i = 0; i < _keyboardResizeStepCountToEdge; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.pump();
    final edgeWidth = tester
        .getSize(find.byKey(AdaptiveShell.primaryPaneKey))
        .width;

    final splitter = find.byKey(AdaptiveShell.splitterKey);
    final gesture = await tester.startGesture(tester.getCenter(splitter));
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.up();

    final inwardWidth = tester
        .getSize(find.byKey(AdaptiveShell.primaryPaneKey))
        .width;
    expect(edgeWidth - inwardWidth, closeTo(20, 0.000001));
  });

  testWidgets('keeps the splitter at the left edge', (tester) async {
    final savedRatios = <double>[];
    await _pumpShell(tester, onPaneRatioChanged: savedRatios.add);

    await tester.tap(find.byKey(AdaptiveShell.splitterKey));
    for (var i = 0; i < _keyboardResizeStepCountToEdge; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    }
    await tester.pump();

    final leftEdge = allocatePanes(
      width: _testWindowSize.width,
      ratio: 0,
      secondPaneIntent: SecondPaneIntent.shown,
    ).primaryWidth;
    expect(
      tester.getSize(find.byKey(AdaptiveShell.primaryPaneKey)).width,
      leftEdge,
    );
    expect(savedRatios.last, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(
      tester.getSize(find.byKey(AdaptiveShell.primaryPaneKey)).width,
      leftEdge,
    );
    expect(savedRatios.last, 0);
  });
}
