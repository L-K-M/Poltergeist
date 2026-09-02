import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/ui/layout/pane_allocation.dart';

const _desktopBoundary = 1080.0;
const _mobileBoundary = 680.0;
const _splitterExtent = 16.0;

void main() {
  group('allocatePanes', () {
    test('keeps both panes at the compact boundary', () {
      final allocation = allocatePanes(
        width: _mobileBoundary,
        ratio: 0.5,
        secondPaneIntent: SecondPaneIntent.shown,
      );

      expect(allocation.stage, LayoutStage.compact);
      expect(allocation.showsSecondPane, isTrue);
      expect(allocation.primaryWidth, allocation.secondaryWidth);
      expect(allocation.totalWidth, _mobileBoundary);
    });

    test('auto-hides the second pane below the mobile boundary', () {
      final allocation = allocatePanes(
        width: _mobileBoundary - 1,
        ratio: 0.5,
        secondPaneIntent: SecondPaneIntent.shown,
      );

      expect(allocation.stage, LayoutStage.mobile);
      expect(allocation.showsSecondPane, isFalse);
      expect(allocation.primaryWidth, _mobileBoundary - 1);
      expect(allocation.secondaryWidth, 0);
    });

    test('switches from compact to desktop at the boundary', () {
      final compact = allocatePanes(
        width: _desktopBoundary - 1,
        ratio: 0.5,
        secondPaneIntent: SecondPaneIntent.shown,
      );
      final desktop = allocatePanes(
        width: _desktopBoundary,
        ratio: 0.5,
        secondPaneIntent: SecondPaneIntent.shown,
      );

      expect(compact.stage, LayoutStage.compact);
      expect(desktop.stage, LayoutStage.desktop);
    });

    test('preserves explicit second-pane hiding after regrowth', () {
      final allocation = allocatePanes(
        width: 1180,
        ratio: 0.5,
        secondPaneIntent: SecondPaneIntent.hidden,
      );

      expect(allocation.stage, LayoutStage.desktop);
      expect(allocation.showsSecondPane, isFalse);
      expect(allocation.primaryWidth, 1180);
      expect(allocation.secondaryWidth, 0);
    });

    test('clamps a restored ratio to usable pane widths', () {
      final allocation = allocatePanes(
        width: 720,
        ratio: 0.99,
        secondPaneIntent: SecondPaneIntent.shown,
      );

      expect(allocation.stage, LayoutStage.compact);
      expect(allocation.primaryWidth, 464);
      expect(allocation.splitterWidth, _splitterExtent);
      expect(allocation.secondaryWidth, 240);
      expect(
        allocation.primaryWidth +
            allocation.splitterWidth +
            allocation.secondaryWidth,
        allocation.totalWidth,
      );
      expect(allocation.totalWidth, 720);
    });
  });
}
