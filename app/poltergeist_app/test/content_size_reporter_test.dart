import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/content_size_reporter.dart';

void main() {
  testWidgets('reports bounded content size after the frame', (tester) async {
    final sizes = <Size>[];
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      SizedBox(
        width: 700,
        height: 500,
        child: ContentSizeReporter(
          onSize: sizes.add,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    expect(sizes, [const Size(700, 500)]);
  });

  testWidgets('does not report an unchanged size after a rebuild', (
    tester,
  ) async {
    final sizes = <Size>[];
    late StateSetter rebuild;
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return ContentSizeReporter(
            onSize: sizes.add,
            child: const SizedBox.expand(),
          );
        },
      ),
    );
    rebuild(() {});
    await tester.pump();

    expect(sizes, [const Size(700, 500)]);
  });

  testWidgets('reports only the latest size pending for a frame', (
    tester,
  ) async {
    final callbacks = <VoidCallback>[];
    final sizes = <Size>[];
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ContentSizeReporter(
        onSize: sizes.add,
        scheduleAfterFrame: callbacks.add,
        child: const SizedBox.expand(),
      ),
    );
    tester.view.physicalSize = const Size(800, 600);
    await tester.pump();
    for (final callback in callbacks) {
      callback();
    }

    expect(sizes, [const Size(800, 600)]);
  });

  testWidgets('drops an intermediate size when layout settles back', (
    tester,
  ) async {
    final callbacks = <VoidCallback>[];
    final sizes = <Size>[];
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ContentSizeReporter(
        onSize: sizes.add,
        scheduleAfterFrame: callbacks.add,
        child: const SizedBox.expand(),
      ),
    );
    callbacks.removeAt(0)();

    tester.view.physicalSize = const Size(800, 600);
    await tester.pump();
    tester.view.physicalSize = const Size(700, 500);
    await tester.pump();
    for (final callback in callbacks) {
      callback();
    }

    expect(sizes, [const Size(700, 500)]);
  });

  testWidgets('drops a pending report after unmount', (tester) async {
    final callbacks = <VoidCallback>[];
    final sizes = <Size>[];

    await tester.pumpWidget(
      ContentSizeReporter(
        onSize: sizes.add,
        scheduleAfterFrame: callbacks.add,
        child: const SizedBox.expand(),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    for (final callback in callbacks) {
      callback();
    }

    expect(sizes, isEmpty);
  });
}
