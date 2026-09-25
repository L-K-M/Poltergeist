import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/macos_toolbar_band_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(windowChannelName);
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Plays one native → Dart call and returns the raw reply envelope.
  Future<ByteData?> fromNative(String method, Object? arguments) async {
    ByteData? reply;
    await messenger.handlePlatformMessage(
      windowChannelName,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (data) => reply = data,
    );
    return reply;
  }

  test('starts windowed and follows the runner\'s switches', () async {
    final band = MacosToolbarBandChannel();
    addTearDown(band.dispose);
    expect(band.value, isTrue);

    await fromNative('toolbarBandChanged', false);
    expect(band.value, isFalse);

    await fromNative('toolbarBandChanged', true);
    expect(band.value, isTrue);
  });

  test('start adopts a window restored straight into full screen', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'isToolbarBandVisible');
      return false;
    });
    final band = MacosToolbarBandChannel();
    addTearDown(band.dispose);

    await band.start();
    expect(band.value, isFalse);
  });

  test('no runner side keeps the windowed layout', () async {
    // No mock handler: the lookup throws MissingPluginException.
    final band = MacosToolbarBandChannel();
    addTearDown(band.dispose);

    await band.start();
    expect(band.value, isTrue);
  });

  test('a malformed switch is refused and changes nothing', () async {
    final band = MacosToolbarBandChannel();
    addTearDown(band.dispose);

    final reply = await fromNative('toolbarBandChanged', 'no');
    expect(
      () => codec.decodeEnvelope(reply!),
      throwsA(isA<PlatformException>()),
    );
    expect(band.value, isTrue);
  });
}
