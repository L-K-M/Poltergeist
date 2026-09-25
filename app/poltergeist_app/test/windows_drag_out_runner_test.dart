import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/os_drag_out.dart';

String _read(String path) => File(path).readAsStringSync();

/// The channel strings `windows/runner/drag_out.cpp` declares in its
/// marked contract block, by constant name without the `k` prefix
/// (`SessionIdKey` → `sessionId`). Empty when the block is gone.
Map<String, String> _contract(String source) {
  final block = RegExp(
    r'// BEGIN poltergeist/dragout CONTRACT\n(.*?)'
    r'// END poltergeist/dragout CONTRACT',
    dotAll: true,
  ).firstMatch(source);
  if (block == null) return const {};
  return {
    for (final match in RegExp(
      r'^constexpr char k(\w+)\[\] = "([^"]*)";$',
      multiLine: true,
    ).allMatches(block.group(1)!))
      match.group(1)!: match.group(2)!,
  };
}

/// Records the Dart side of the native callbacks.
class _Delegate implements DragOutBackendDelegate {
  final ended = <(String, DragOutOperation?)>[];

  @override
  Future<void> fulfilPromise(DragOutPromiseRequest request) async {}

  @override
  void cancelPromise(String sessionId, String promiseId) {}

  @override
  void sessionEnded(String sessionId, DragOutOperation? operation) =>
      ended.add((sessionId, operation));
}

/// The Windows drag-out backend's contract (00 D14's 2026-09-25
/// amendment). No host that runs this suite can build or run
/// `windows/runner/drag_out.cpp`, so its half of the
/// `poltergeist/dragout` protocol is pinned from the source instead: the
/// file declares every channel string it reads or writes in one marked
/// block, and these tests check each against what the Dart backend
/// really sends and accepts, including the wire type the C++ parser
/// expects. A key renamed or retyped on either side fails here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(dragOutChannelName);
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final source = _read('windows/runner/drag_out.cpp');
  final contract = _contract(source);

  /// The contract's values whose constant names end in [suffix].
  Set<String> valuesOf(String suffix) => {
    for (final entry in contract.entries)
      if (entry.key.endsWith(suffix)) entry.value,
  };

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('declares the channel and the methods the Dart backend uses', () {
    expect(contract, isNotEmpty, reason: 'the contract block is missing');
    expect(contract['ChannelName'], dragOutChannelName);
    expect(valuesOf('Method'), {
      'startDrag',
      'promiseProgress',
      'sessionEnded',
    });
    // Every key the C++ reads or writes, so a new one cannot skip the
    // type checks below.
    expect(valuesOf('Key'), {
      // startDrag arguments.
      'sessionId',
      'items',
      'allowedOperations',
      'image',
      'imageSize',
      'imageAnchor',
      // Item maps.
      'kind',
      'path',
      // startDrag replies.
      'started',
      'reason',
      'message',
      // sessionEnded arguments (and sessionId above).
      'operation',
    });
  });

  test('parses the startDrag arguments Dart sends, with their wire '
      'types', () async {
    MethodCall? sent;
    messenger.setMockMethodCallHandler(channel, (call) async {
      sent = call;
      return {contract['StartedKey']: true};
    });
    final backend = MethodChannelDragOutBackend(
      support: DragOutSupport.localFiles,
    );
    final result = await backend.startDrag(
      DragOutRequest(
        sessionId: 'dragout-7',
        items: const [
          LocalDragOutItem(
            path: r'C:\Users\tester\report.txt',
            name: 'report.txt',
            isDirectory: false,
          ),
          LocalDragOutItem(
            path: r'C:\Users\tester\photos',
            name: 'photos',
            isDirectory: true,
          ),
        ],
        position: const Offset(-12, 300),
        allowedOperations: DragOutOperation.values.toSet(),
        image: DragOutImage(
          png: Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]),
          size: const Size(160, 32),
          anchor: const Offset(12, 16),
        ),
      ),
    );
    expect(result, isA<DragOutStarted>());
    expect(sent!.method, contract['StartDragMethod']);

    // What the StandardMethodCodec put on the wire, decoded the way
    // the C++ StandardCodecSerializer decodes it.
    final args = sent!.arguments as Map;
    expect(args[contract['SessionIdKey']], 'dragout-7');
    final items = args[contract['ItemsKey']] as List;
    expect(items, hasLength(2));
    for (final item in items) {
      expect(item, isA<Map>());
      // Only `file` items travel on Windows; a promise is refused.
      expect((item as Map)[contract['KindKey']], contract['FileKind']);
      expect(item[contract['PathKey']], isA<String>());
    }
    expect(items.first[contract['PathKey']], r'C:\Users\tester\report.txt');
    // AllowedEffects() maps exactly these three names.
    expect(args[contract['AllowedOperationsKey']], [
      contract['CopyOperation'],
      contract['MoveOperation'],
      contract['LinkOperation'],
    ]);
    expect(args[contract['ImageKey']], isA<Uint8List>());
    for (final key in ['ImageSizeKey', 'ImageAnchorKey']) {
      // PairAt() reads an EncodableList of two numbers: a Dart
      // List<double> is a codec LIST of FLOAT64s, not a Float64List.
      final pair = args[contract[key]];
      expect(pair, isA<List<Object?>>().having((l) => l.length, 'length', 2));
      expect(pair, isNot(isA<Float64List>()));
      expect(pair, everyElement(isA<double>()));
    }
    expect(args[contract['ImageSizeKey']], [160.0, 32.0]);
    expect(args[contract['ImageAnchorKey']], [12.0, 16.0]);
  });

  test('answers startDrag with replies the Dart backend reads', () async {
    final backend = MethodChannelDragOutBackend(
      support: DragOutSupport.localFiles,
    );
    const request = DragOutRequest(
      sessionId: 'dragout-8',
      items: [
        LocalDragOutItem(path: r'C:\a.txt', name: 'a.txt', isDirectory: false),
      ],
      position: Offset(-1, -1),
      allowedOperations: {DragOutOperation.copy},
    );
    final reasons = valuesOf('Reason');
    expect(reasons, {
      'buttonReleased',
      'noPointerEvent',
      'busy',
      'unsupportedItems',
      'failed',
    });
    for (final reason in reasons) {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          contract['StartedKey']: false,
          contract['ReasonKey']: reason,
          contract['MessageKey']: 'why',
        },
      );
      final refused = await backend.startDrag(request);
      expect(
        refused,
        isA<DragOutNotStarted>()
            .having((r) => r.reason.name, 'reason', reason)
            .having((r) => r.message, 'message', 'why'),
      );
    }
  });

  test('reports sessionEnded as the Dart delegate reads it', () async {
    final backend = MethodChannelDragOutBackend(
      support: DragOutSupport.localFiles,
    );
    final delegate = _Delegate();
    backend.delegate = delegate;
    final operations = valuesOf('Operation');
    expect(operations, {'copy', 'move', 'link', 'none'});
    for (final operation in operations) {
      ByteData? reply;
      await messenger.handlePlatformMessage(
        dragOutChannelName,
        codec.encodeMethodCall(
          MethodCall(contract['SessionEndedMethod']!, {
            contract['SessionIdKey']: 'dragout-9',
            contract['OperationKey']: operation,
          }),
        ),
        (data) => reply = data,
      );
      expect(codec.decodeEnvelope(reply!), isNull);
    }
    expect(delegate.ended, [
      for (final operation in operations)
        (
          'dragout-9',
          DragOutOperation.values
              .where((value) => value.name == operation)
              .firstOrNull,
        ),
    ]);
    expect(delegate.ended.where((e) => e.$2 == null), hasLength(1));
  });

  test('is compiled into the runner and wired into the window', () {
    final cmake = _read('windows/runner/CMakeLists.txt');
    expect(cmake, contains('"drag_out.cpp"'));
    // The drag image decodes the Dart PNG through WIC.
    expect(cmake, contains('"windowscodecs.lib"'));
    final window = _read('windows/runner/flutter_window.cpp');
    expect(window, contains('std::make_unique<DragOut>('));
    expect(window, contains('drag_out_->HandleWindowMessage(message)'));
    // Torn down before the engine its channel talks to.
    final teardown = window.substring(window.indexOf('::OnDestroy()'));
    expect(
      teardown.indexOf('drag_out_ = nullptr;'),
      allOf(
        isNonNegative,
        lessThan(teardown.indexOf('flutter_controller_ = nullptr;')),
      ),
    );
  });

  test('replies before the modal loop, resets the embedder press first, '
      'and never deletes', () {
    // startDrag posts the start message; only its handler enters the
    // drag loop, after the synthesized release.
    final start = source.indexOf('void DragOut::StartDrag(');
    final run = source.indexOf('bool DragOut::HandleWindowMessage(');
    expect(start, isNonNegative);
    expect(run, isNonNegative);
    final startBody = source.substring(start, source.indexOf('\n}\n', start));
    expect(startBody, contains('PostMessageW('));
    expect(startBody, isNot(contains('SHDoDragDrop(')));
    final runBody = source.substring(run, source.indexOf('\n}\n', run));
    final release = runBody.indexOf('EndEmbedderPress();');
    expect(release, isNonNegative);
    expect(runBody.indexOf('SHDoDragDrop('), greaterThan(release));
    expect(
      source.substring(source.indexOf('void DragOut::EndEmbedderPress(')),
      contains('SendMessageW(view_, WM_LBUTTONUP,'),
    );
    // D15: a destination that reports a move has moved (or will move)
    // the file itself; the source never deletes on its behalf.
    expect(
      source,
      isNot(
        matches(
          RegExp(
            r'\b(DeleteFileW?|RemoveDirectoryW?|SHFileOperationW?|'
            r'IFileOperation|DeleteItems?)\b',
          ),
        ),
      ),
    );
  });
}
