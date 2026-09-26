import 'dart:ui' show Scene, SemanticsUpdate;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/window_drop_in.dart';
import 'package:poltergeist_app/ui/panes/window_drop_target.dart';

/// Another view for the test binding: the test view's metrics under
/// another id, rendering nowhere.
final class _ExtraView extends TestFlutterView {
  _ExtraView(TestFlutterView view, {required this.viewId})
    : super(
        view: view,
        platformDispatcher: view.platformDispatcher,
        display: view.display,
      );

  @override
  final int viewId;

  @override
  void render(Scene scene, {Size? size}) {}

  @override
  void updateSemantics(SemanticsUpdate update) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> report(String method, Object? arguments) =>
      messenger.handlePlatformMessage(
        windowDropInChannel.name,
        codec.encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  group('WindowDropIn', () {
    late WindowDropIn dropIn;
    late List<WindowDropEvent> one;
    late List<WindowDropEvent> two;

    void onOne(WindowDropEvent event) => one.add(event);
    void onTwo(WindowDropEvent event) => two.add(event);

    setUp(() {
      dropIn = WindowDropIn();
      one = [];
      two = [];
      dropIn
        ..addListener(1, onOne)
        ..addListener(2, onTwo);
    });

    tearDown(() {
      dropIn
        ..removeListener(1, onOne)
        ..removeListener(2, onTwo);
    });

    test("each report reaches its own view's listeners only", () async {
      await report('entered', {
        'viewId': 1,
        'position': [10.0, 20.0],
      });
      await report('updated', {
        'viewId': 1,
        'position': [11.0, 21.0],
      });
      await report('exited', {'viewId': 2});
      await report('dropped', {
        'viewId': 1,
        'position': [12.0, 22.0],
        'paths': ['/tmp/a.txt', '', 7, '/tmp/b'],
      });

      expect(one, hasLength(3));
      final [entered, updated, dropped] = one;
      expect(entered, isA<WindowDropHover>());
      expect((entered as WindowDropHover).entered, isTrue);
      expect(entered.position, const Offset(10, 20));
      expect((updated as WindowDropHover).entered, isFalse);
      expect(updated.position, const Offset(11, 21));
      // Empty and non-string paths are left out.
      expect((dropped as WindowDropDone).paths, ['/tmp/a.txt', '/tmp/b']);
      expect(dropped.position, const Offset(12, 22));
      expect(two.single, isA<WindowDropExit>());
    });

    test('malformed reports and unknown views are ignored', () async {
      await report('entered', {'viewId': 1});
      await report('entered', {
        'viewId': 'one',
        'position': [1.0, 2.0],
      });
      await report('entered', [1.0, 2.0]);
      await report('dropped', {
        'viewId': 1,
        'position': [1.0, 2.0],
      });
      await report('teleported', {
        'viewId': 1,
        'position': [1.0, 2.0],
      });
      await report('exited', {'viewId': 9});

      expect(one, isEmpty);
      expect(two, isEmpty);
    });

    test('a removed listener hears nothing more', () async {
      dropIn.removeListener(1, onOne);
      await report('exited', {'viewId': 1});
      expect(one, isEmpty);
      dropIn.addListener(1, onOne);
    });
  });

  group('WindowDropTarget', () {
    Future<List<String>> pumpTarget(
      WidgetTester tester, {
      required int viewId,
      required ValueNotifier<bool> enabled,
    }) async {
      final seen = <String>[];
      await tester.pumpWidget(
        wrapWithView: viewId == 0,
        Builder(
          builder: (context) {
            final target = ValueListenableBuilder<bool>(
              valueListenable: enabled,
              builder: (context, enable, _) => Directionality(
                textDirection: TextDirection.ltr,
                child: WindowDropTarget(
                  enable: enable,
                  onDragEntered: (d) => seen.add('entered ${d.localPosition}'),
                  onDragUpdated: (d) => seen.add('updated ${d.localPosition}'),
                  onDragExited: (_) => seen.add('exited'),
                  onDragDone: (d) => seen.add(
                    'done ${[for (final file in d.files) file.path]}',
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            );
            return viewId == 0
                ? target
                : View(
                    view: _ExtraView(tester.view, viewId: viewId),
                    child: target,
                  );
          },
        ),
      );
      return seen;
    }

    testWidgets('an extra view takes its own reports, not desktop_drop\'s', (
      tester,
    ) async {
      final enabled = ValueNotifier(true);
      final seen = await pumpTarget(tester, viewId: 1, enabled: enabled);
      expect(find.byType(DropTarget), findsNothing);

      await report('entered', {
        'viewId': 1,
        'position': [5.0, 6.0],
      });
      await report('updated', {
        'viewId': 1,
        'position': [7.0, 8.0],
      });
      // Outside the view's bounds: the drag has left the target.
      await report('updated', {
        'viewId': 1,
        'position': [-5.0, 8.0],
      });
      await report('updated', {
        'viewId': 1,
        'position': [9.0, 9.0],
      });
      await report('dropped', {
        'viewId': 1,
        'position': [9.0, 9.0],
        'paths': ['/tmp/a.txt'],
      });

      expect(seen, [
        'entered Offset(5.0, 6.0)',
        'updated Offset(7.0, 8.0)',
        'exited',
        'entered Offset(9.0, 9.0)',
        'exited',
        'done [/tmp/a.txt]',
      ]);
    });

    testWidgets('disabling it mid-hover ends the hover and stops listening', (
      tester,
    ) async {
      final enabled = ValueNotifier(true);
      final seen = await pumpTarget(tester, viewId: 1, enabled: enabled);

      await report('entered', {
        'viewId': 1,
        'position': [5.0, 6.0],
      });
      enabled.value = false;
      await tester.pump();
      await report('dropped', {
        'viewId': 1,
        'position': [5.0, 6.0],
        'paths': ['/tmp/a.txt'],
      });

      expect(seen, ['entered Offset(5.0, 6.0)', 'exited']);
    });

    testWidgets("the main view is desktop_drop's", (tester) async {
      final seen = await pumpTarget(
        tester,
        viewId: 0,
        enabled: ValueNotifier(true),
      );
      expect(find.byType(DropTarget), findsOneWidget);

      await report('entered', {
        'viewId': 0,
        'position': [5.0, 6.0],
      });
      expect(seen, isEmpty);
    });
  });
}
