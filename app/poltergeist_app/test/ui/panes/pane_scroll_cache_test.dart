import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, RenderViewport;
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart';
import '../../support/test_panes.dart';

String _name(int index) => 'entry-${index.toString().padLeft(4, '0')}.txt';

void main() {
  for (final (platform, textScale) in [
    (TargetPlatform.linux, 1.0),
    (TargetPlatform.linux, 2.0),
    (TargetPlatform.macOS, 1.0),
    (TargetPlatform.macOS, 2.0),
    (TargetPlatform.windows, 1.0),
    (TargetPlatform.windows, 2.0),
    (TargetPlatform.android, 1.0),
    (TargetPlatform.iOS, 1.0),
  ]) {
    final mobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    testWidgets('${platform.name} listing preserves cache and scrolling '
        'at text scale $textScale', (tester) async {
      tester.view.physicalSize = const Size(960, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      try {
        final lanes = FakePaneLanes();
        lanes.nextLocalChannel = FakePaneChannel('/home/tester')
          ..listings['/home/tester'] = [
            for (var index = 0; index < 1000; index++)
              RemoteFileEntry(
                path: '/home/tester/${_name(index)}',
                name: _name(index),
                type: RemoteFileType.file,
                size: 10,
              ),
          ];
        final pane = PaneController(paneTabId: 'pane.left.tab1', lanes: lanes);
        await pane.openLocalHome();
        final strip = testPaneStrip(pane);
        final workspace = WorkspaceController(
          left: strip,
          right: testPaneStrip(
            PaneController(paneTabId: 'pane.right.tab1', lanes: lanes),
          ),
        );
        addTearDown(workspace.dispose);
        final focus = FocusNode();
        addTearDown(focus.dispose);
        var rowBuilds = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(
              body: PaneView(
                controller: pane,
                pane: strip,
                workspace: workspace,
                focusNode: focus,
                onSwapFocus: () {},
                onCancelRecovery: () {},
                clock: () {
                  rowBuilds++;
                  return DateTime(2026, 9, 29);
                },
              ),
            ),
          ),
        );

        final listingFinder = find.byWidgetPredicate(
          (widget) =>
              widget is ListView && widget.scrollDirection == Axis.vertical,
        );
        final listing = tester.widget<ListView>(listingFinder);
        final extent = listing.itemExtent!;
        final height = tester.getSize(listingFinder).height;
        final scroll = listing.controller!;
        final cachedRows = mobile
            ? (RenderAbstractViewport.defaultCacheExtent / extent).ceil()
            : 1;
        if (mobile) {
          final viewport = tester.renderObject<RenderViewport>(
            find.descendant(of: listingFinder, matching: find.byType(Viewport)),
          );
          expect(
            viewport.scrollCacheExtent.value,
            RenderAbstractViewport.defaultCacheExtent,
            reason: "mobile keeps Flutter's scrolling and accessibility cache",
          );
        }
        final rowPattern = RegExp(r'^entry-(\d{4})\.txt$');

        void expectCompleteBoundedViewport() {
          final offset = scroll.offset;
          final first = (offset / extent).floor();
          final end = ((offset + height) / extent).ceil();
          final built = tester
              .widgetList<Text>(
                find.descendant(of: listingFinder, matching: find.byType(Text)),
              )
              .map((text) => rowPattern.firstMatch(text.data ?? ''))
              .nonNulls
              .map((match) => int.parse(match.group(1)!))
              .toSet();
          expect(built, isNotEmpty);
          // One trailing row allows fractional viewport geometry without
          // pinning a particular host font.
          final earliest = math.max(0, first - cachedRows);
          final latest = math.min(999, end + cachedRows);
          expect(
            built,
            everyElement(inInclusiveRange(earliest, latest)),
            reason: 'only visible and nearby rows should be constructed',
          );
          for (
            var index = (offset / extent).ceil();
            index < ((offset + height) / extent).floor();
            index++
          ) {
            expect(
              find.text(_name(index)).hitTestable(),
              findsOneWidget,
              reason: 'fully visible row $index must render without a gap',
            );
          }
        }

        expect(
          rowBuilds,
          inInclusiveRange(1, (height / extent).ceil() + cachedRows + 1),
          reason: 'a cold listing should bound its speculative row work',
        );
        expectCompleteBoundedViewport();
        pane.setCursorIndex(1);
        await tester.pump();
        final originalSelectedLabel = tester.element(find.text(_name(1)));

        scroll.jumpTo(2 * extent);
        await tester.pump();
        expectCompleteBoundedViewport();
        scroll.jumpTo(100 * extent);
        await tester.pump();
        expectCompleteBoundedViewport();
        expect(find.text(_name(1)), findsNothing);
        expect(originalSelectedLabel.mounted, isFalse);

        scroll.jumpTo(0);
        await tester.pump();
        expectCompleteBoundedViewport();
        expect(
          tester.element(find.text(_name(1))),
          isNot(same(originalSelectedLabel)),
        );
        expect(pane.isRowSelected(1), isTrue);
        expect(
          tester
              .getSemantics(
                find.bySemanticsLabel(RegExp('^${RegExp.escape(_name(1))},')),
              )
              .getSemanticsData()
              .flagsCollection
              .isSelected,
          ui.Tristate.isTrue,
        );
        // Accessibility traversal must keep finding the next offscreen
        // row after each reveal, rather than ending at the viewport edge.
        for (var step = 0; step < 3; step++) {
          final before = scroll.offset;
          // Mobile retains enough cache to reach beyond the immediate
          // neighbor; desktop must keep at least that next row reachable.
          final next = ((before + height) / extent).ceil() + (mobile ? 1 : 0);
          final nextText = find.text(_name(next), skipOffstage: false);
          final nextSemantics = find.bySemanticsLabel(
            RegExp('^${RegExp.escape(_name(next))},'),
            skipOffstage: false,
          );
          expect(nextSemantics, findsOneWidget);
          expect(nextText.hitTestable(), findsNothing);
          final node = tester.getSemantics(nextSemantics);
          node.owner!.performAction(node.id, ui.SemanticsAction.showOnScreen);
          await tester.pumpAndSettle();

          expect(scroll.offset, greaterThan(before));
          expect(nextText.hitTestable(), findsOneWidget);
          final viewport = tester.getRect(listingFinder);
          final revealed = tester.getRect(nextText);
          expect(revealed.top, greaterThanOrEqualTo(viewport.top));
          expect(revealed.bottom, lessThanOrEqualTo(viewport.bottom));
          expectCompleteBoundedViewport();
        }
        expect(pane.isRowSelected(1), isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }
}
