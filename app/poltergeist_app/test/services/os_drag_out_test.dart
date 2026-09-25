import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/os_drag_out.dart';

/// Records the Dart side of the native callbacks.
class _Delegate implements DragOutBackendDelegate {
  final fulfilled = <DragOutPromiseRequest>[];
  final cancelled = <(String, String)>[];
  final ended = <(String, DragOutOperation?)>[];
  Object? failWith;

  @override
  Future<void> fulfilPromise(DragOutPromiseRequest request) async {
    fulfilled.add(request);
    final error = failWith;
    if (error != null) throw error;
  }

  @override
  void cancelPromise(String sessionId, String promiseId) =>
      cancelled.add((sessionId, promiseId));

  @override
  void sessionEnded(String sessionId, DragOutOperation? operation) =>
      ended.add((sessionId, operation));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(dragOutChannelName);
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Plays one native → Dart call and decodes the reply envelope.
  Future<Object?> fromNative(String method, Object? arguments) async {
    ByteData? reply;
    await messenger.handlePlatformMessage(
      dragOutChannelName,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (data) => reply = data,
    );
    return codec.decodeEnvelope(reply!);
  }

  const request = DragOutRequest(
    sessionId: 'dragout-1',
    items: [
      LocalDragOutItem(
        path: '/home/tester/report.txt',
        name: 'report.txt',
        isDirectory: false,
      ),
      PromisedDragOutItem(promiseId: 'p1', name: 'site', isDirectory: true),
    ],
    position: Offset(1500, 40),
    allowedOperations: {DragOutOperation.move, DragOutOperation.copy},
  );

  test('startDrag sends the documented argument map', () async {
    MethodCall? sent;
    messenger.setMockMethodCallHandler(channel, (call) async {
      sent = call;
      return {'started': true};
    });
    final backend = MethodChannelDragOutBackend(
      support: DragOutSupport.localFiles,
    );
    final image = DragOutImage(
      png: Uint8List.fromList([1, 2, 3]),
      size: const Size(120, 28),
      anchor: const Offset(10, 14),
    );
    final result = await backend.startDrag(
      DragOutRequest(
        sessionId: request.sessionId,
        items: request.items,
        position: request.position,
        allowedOperations: request.allowedOperations,
        image: image,
      ),
    );
    expect(result, isA<DragOutStarted>());
    expect(sent!.method, 'startDrag');
    expect(sent!.arguments, {
      'sessionId': 'dragout-1',
      'position': [1500.0, 40.0],
      // Declaration order, never delete.
      'allowedOperations': ['copy', 'move'],
      'items': [
        {
          'kind': 'file',
          'path': '/home/tester/report.txt',
          'name': 'report.txt',
          'isDirectory': false,
        },
        {
          'kind': 'promise',
          'promiseId': 'p1',
          'name': 'site',
          'isDirectory': true,
          'size': null,
        },
      ],
      'image': Uint8List.fromList([1, 2, 3]),
      'imageSize': [120.0, 28.0],
      'imageAnchor': [10.0, 14.0],
    });
  });

  test('a refusal carries its reason; a missing native side is '
      'unsupported', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'started': false, 'reason': 'buttonReleased'},
    );
    final backend = MethodChannelDragOutBackend(
      support: DragOutSupport.localFiles,
    );
    final refused = await backend.startDrag(request);
    expect(
      refused,
      isA<DragOutNotStarted>().having(
        (r) => r.reason,
        'reason',
        DragOutRefusal.buttonReleased,
      ),
    );
    messenger.setMockMethodCallHandler(channel, null);
    final missing = await backend.startDrag(request);
    expect(
      missing,
      isA<DragOutNotStarted>().having(
        (r) => r.reason,
        'reason',
        DragOutRefusal.unsupported,
      ),
    );
  });

  test('fulfilPromise replies null on success and the failure code on '
      'error', () async {
    final backend = MethodChannelDragOutBackend(
      support: DragOutSupport.localFilesAndPromises,
    );
    final delegate = _Delegate();
    backend.delegate = delegate;
    final ok = await fromNative('fulfilPromise', {
      'sessionId': 'dragout-1',
      'promiseId': 'p1',
      'destinationPath': '/Users/me/Desktop/site',
    });
    expect(ok, isNull);
    expect(delegate.fulfilled.single.destinationPath, '/Users/me/Desktop/site');

    delegate.failWith = const DragOutPromiseException(
      DragOutPromiseFailure.exists,
      'already there',
    );
    await expectLater(
      fromNative('fulfilPromise', {
        'sessionId': 'dragout-1',
        'promiseId': 'p1',
        'destinationPath': '/Users/me/Desktop/site',
      }),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'exists')
            .having((e) => e.message, 'message', 'already there'),
      ),
    );
  });

  test('cancelPromise and sessionEnded reach the delegate', () async {
    final backend = MethodChannelDragOutBackend(
      support: DragOutSupport.localFiles,
    );
    final delegate = _Delegate();
    backend.delegate = delegate;
    await fromNative('cancelPromise', {
      'sessionId': 'dragout-1',
      'promiseId': 'p2',
    });
    await fromNative('sessionEnded', {
      'sessionId': 'dragout-1',
      'operation': 'move',
    });
    await fromNative('sessionEnded', {
      'sessionId': 'dragout-2',
      'operation': 'none',
    });
    expect(delegate.cancelled, [('dragout-1', 'p2')]);
    expect(delegate.ended, [
      ('dragout-1', DragOutOperation.move),
      ('dragout-2', null),
    ]);
  });

  test('promiseProgress is fire-and-forget, even unimplemented', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw MissingPluginException();
    });
    MethodChannelDragOutBackend(
      support: DragOutSupport.localFilesAndPromises,
    ).reportProgress(
      sessionId: 'dragout-1',
      promiseId: 'p1',
      completedBytes: 5,
      totalBytes: 9,
    );
    await pumpEventQueue();
    expect(calls.single.arguments, {
      'sessionId': 'dragout-1',
      'promiseId': 'p1',
      'completedBytes': 5,
      'totalBytes': 9,
    });
  });

  test('the platform picks promises on macOS, files on Linux and '
      'Windows, nothing elsewhere', () {
    expect(
      platformDragOutBackend(platform: TargetPlatform.macOS).support,
      DragOutSupport.localFilesAndPromises,
    );
    expect(
      platformDragOutBackend(platform: TargetPlatform.linux).support,
      DragOutSupport.localFiles,
    );
    expect(
      platformDragOutBackend(platform: TargetPlatform.windows).support,
      DragOutSupport.localFiles,
    );
    expect(
      platformDragOutBackend(platform: TargetPlatform.android).support,
      DragOutSupport.none,
    );
  });

  test('the no-op backend refuses as unsupported', () async {
    const backend = NoDragOutBackend();
    expect(backend.support, DragOutSupport.none);
    expect(
      await backend.startDrag(request),
      isA<DragOutNotStarted>().having(
        (r) => r.reason,
        'reason',
        DragOutRefusal.unsupported,
      ),
    );
  });
}
