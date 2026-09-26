import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/quick_look_channel.dart';

/// The macOS panel's channel with several workspace windows (00 D39): one
/// panel, one handler, each window's calls and close edge under its view.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('poltergeist/quicklook');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'isVisible' ? true : null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> closed(Object? arguments) => messenger.handlePlatformMessage(
    channel.name,
    codec.encodeMethodCall(MethodCall('closed', arguments)),
    (_) {},
  );

  test('every call names the window it comes from', () async {
    final panel = MethodChannelQuickLook(viewId: 2);
    addTearDown(panel.dispose);

    await panel.showPreview(['/tmp/a'], 0);
    await panel.updatePreview(['/tmp/a', '/tmp/b'], 1);
    expect(await panel.isVisible(), isTrue);
    await panel.hidePreview();

    expect(calls.map((call) => call.method), [
      'showPreview',
      'updatePreview',
      'isVisible',
      'hidePreview',
    ]);
    for (final call in calls) {
      expect((call.arguments as Map)['viewId'], 2, reason: call.method);
    }
    expect((calls.first.arguments as Map)['paths'], ['/tmp/a']);
    expect((calls[1].arguments as Map)['index'], 1);
  });

  test("the close edge reaches its window's session only", () async {
    final main = MethodChannelQuickLook();
    final extra = MethodChannelQuickLook(viewId: 1);
    addTearDown(main.dispose);
    addTearDown(extra.dispose);
    var mainClosed = 0;
    var extraClosed = 0;
    main.onClosed.listen((_) => mainClosed++);
    extra.onClosed.listen((_) => extraClosed++);

    await closed({'viewId': 1});
    await pumpEventQueue();
    expect((mainClosed, extraClosed), (0, 1));

    // A bare edge is the main window's, as before there were windows.
    await closed(null);
    await pumpEventQueue();
    expect((mainClosed, extraClosed), (1, 1));
  });

  test("a closed window's session hears nothing, and the others still "
      'do', () async {
    final main = MethodChannelQuickLook();
    addTearDown(main.dispose);
    final extra = MethodChannelQuickLook(viewId: 1);
    var mainClosed = 0;
    main.onClosed.listen((_) => mainClosed++);
    extra.dispose();

    await closed({'viewId': 1});
    await closed({'viewId': 0});
    await pumpEventQueue();
    expect(mainClosed, 1);
  });
}
