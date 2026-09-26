import 'dart:ui' show Scene, SemanticsUpdate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_window_utils/widgets/macos_toolbar_passthrough.dart';
import 'package:poltergeist_app/services/workspace_windows/window_titlebar.dart';
import 'package:poltergeist_app/ui/shell/window_toolbar_passthrough.dart';

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

/// An extra window's macOS titlebar (00 D39): its toolbar band and the
/// click passthrough over its header controls.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = windowTitlebarChannel;
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == WindowTitlebarMethod.isToolbarBandVisible.name
          ? false
          : null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> bandChanged(Object? arguments) => messenger.handlePlatformMessage(
    channel.name,
    codec.encodeMethodCall(MethodCall('toolbarBandChanged', arguments)),
    (_) {},
  );

  test("a window's band starts from the runner's answer and follows its "
      'reports', () async {
    final titlebars = WindowTitlebars();
    final band = titlebars.bandFor(4);
    final other = titlebars.bandFor(5);
    expect(identical(titlebars.bandFor(4), band), isTrue);
    await pumpEventQueue();

    expect(calls.first.method, 'isToolbarBandVisible');
    expect((calls.first.arguments as Map)['viewId'], 4);
    // Entered full screen before Dart asked.
    expect(band.value, isFalse);

    await bandChanged({'viewId': 4, 'visible': true});
    expect(band.value, isTrue);
    expect(other.value, isFalse);

    // Malformed reports change nothing.
    await bandChanged({'viewId': 4});
    await bandChanged(true);
    expect(band.value, isTrue);
  });

  test('passthrough rectangles cross in logical pixels, and a missing '
      'runner is no error', () async {
    final titlebars = WindowTitlebars();
    await titlebars.updatePassthrough(
      2,
      'p',
      const Rect.fromLTWH(10, 4, 30, 20),
    );
    await titlebars.removePassthrough(2, 'p');
    expect(calls.map((call) => call.method), [
      'updatePassthrough',
      'removePassthrough',
    ]);
    expect(calls.first.arguments, {
      'viewId': 2,
      'id': 'p',
      'x': 10.0,
      'y': 4.0,
      'width': 30.0,
      'height': 20.0,
    });
    expect(calls.last.arguments, {'viewId': 2, 'id': 'p'});

    messenger.setMockMethodCallHandler(channel, null);
    await titlebars.removePassthrough(2, 'p');
  });

  group('WindowToolbarPassthrough', () {
    // One per test: a new view object would remount the subtree.
    late _ExtraView extraView;

    Future<void> pump(
      WidgetTester tester, {
      required int viewId,
      required WindowTitlebars titlebars,
      double left = 20,
      bool shown = true,
    }) async {
      final content = Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            if (shown)
              Positioned(
                left: left,
                top: 6,
                width: 40,
                height: 24,
                child: WindowToolbarPassthrough(
                  titlebars: titlebars,
                  child: const SizedBox.expand(),
                ),
              ),
          ],
        ),
      );
      await tester.pumpWidget(
        wrapWithView: viewId == 0,
        viewId == 0
            ? content
            : View(view: extraView, child: content),
      );
      await tester.pump();
    }

    testWidgets("an extra window's control reports its rectangle, again "
        'when it moves, and withdraws it when it goes', (tester) async {
      final titlebars = WindowTitlebars();
      extraView = _ExtraView(tester.view, viewId: 3);
      await pump(tester, viewId: 3, titlebars: titlebars);
      expect(find.byType(MacosToolbarPassthrough), findsNothing);

      final first = calls.single;
      expect(first.method, 'updatePassthrough');
      final arguments = first.arguments as Map;
      expect(arguments['viewId'], 3);
      expect(
        [arguments['x'], arguments['y'], arguments['width']],
        [20.0, 6.0, 40.0],
      );

      // Another frame with nothing moved: nothing new crosses.
      await tester.pump();
      expect(calls, hasLength(1));

      await pump(tester, viewId: 3, titlebars: titlebars, left: 60);
      expect(calls, hasLength(2));
      expect((calls.last.arguments as Map)['x'], 60.0);
      expect((calls.last.arguments as Map)['id'], arguments['id']);

      await pump(tester, viewId: 3, titlebars: titlebars, shown: false);
      expect(calls.last.method, 'removePassthrough');
      expect(calls.last.arguments, {'viewId': 3, 'id': arguments['id']});
      expect(calls, hasLength(3));
    });

    testWidgets("the main window's is macos_window_utils'", (tester) async {
      final content = Directionality(
        textDirection: TextDirection.ltr,
        child: WindowToolbarPassthrough(
          titlebars: WindowTitlebars(),
          child: const SizedBox(),
        ),
      );
      await tester.pumpWidget(content);
      expect(find.byType(MacosToolbarPassthrough), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpWidget(const SizedBox());
      expect(calls, isEmpty);
    });
  });
}
