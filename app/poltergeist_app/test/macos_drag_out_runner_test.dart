import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/os_drag_out.dart';

String _read(String path) => File(path).readAsStringSync();

/// The body of the Swift function whose declaration starts with
/// [signature]: everything up to the first line that closes a member at
/// the file's two-space indentation.
String _body(String swift, String signature) {
  final start = swift.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing `$signature`');
  final end = swift.indexOf('\n  }\n', start);
  expect(end, greaterThan(start), reason: 'unterminated `$signature`');
  return swift.substring(start, end);
}

Set<String> _matches(RegExp pattern, String text, [int group = 1]) => {
  for (final match in pattern.allMatches(text)) match.group(group)!,
};

/// What each Swift cast accepts, as the Standard codec's wire value
/// decodes on the Dart side. A list must arrive as a plain list: a typed
/// list decodes natively as `FlutterStandardTypedData`, which no array
/// cast accepts.
bool _castAccepts(String cast, Object? value) => switch (cast) {
  'String' => value is String,
  'Bool' => value is bool,
  'NSNumber' => value is num,
  '[String]' =>
    value is List && value is! TypedData && value.every((e) => e is String),
  '[NSNumber]' =>
    value is List && value is! TypedData && value.every((e) => e is num),
  '[[String: Any]]' =>
    value is List &&
        value.every((e) => e is Map && e.keys.every((k) => k is String)),
  _ => throw ArgumentError('no wire rule for the Swift cast $cast'),
};

/// Every `<variable>["key"]` read in [swift] with the cast Swift applies:
/// a direct `as? T`, or the cast inside the named helper it is passed to.
Map<String, String> _reads(
  String swift,
  String variable, {
  Map<String, String> helpers = const {},
}) {
  final casts = <String, String>{};
  final all = _matches(RegExp('\\b$variable\\["(\\w+)"\\]'), swift);
  for (final match in RegExp(
    '\\b$variable\\["(\\w+)"\\]\\s+as\\?\\s+'
    r'(\[\[String: Any\]\]|\[String\]|\[NSNumber\]|String|Bool|NSNumber)(?!\w)',
  ).allMatches(swift)) {
    casts[match.group(1)!] = match.group(2)!;
  }
  helpers.forEach((helper, cast) {
    for (final match in RegExp(
      'Self\\.$helper\\($variable\\["(\\w+)"\\]\\)',
    ).allMatches(swift)) {
      casts[match.group(1)!] = cast;
    }
  });
  expect(
    casts.keys.toSet(),
    all,
    reason: 'every $variable read needs a cast this test can check',
  );
  return casts;
}

/// Records the Dart side of the native callbacks.
class _Delegate implements DragOutBackendDelegate {
  final fulfilled = <DragOutPromiseRequest>[];
  final cancelled = <(String, String)>[];
  final ended = <(String, DragOutOperation?)>[];

  @override
  Future<void> fulfilPromise(DragOutPromiseRequest request) async =>
      fulfilled.add(request);

  @override
  void cancelPromise(String sessionId, String promiseId) =>
      cancelled.add((sessionId, promiseId));

  @override
  void sessionEnded(String sessionId, DragOutOperation? operation) =>
      ended.add((sessionId, operation));
}

/// The macOS drag-out backend's contract (00 D14's 2026-09-25
/// amendment). No Mac runs here, so these checks pin what could drift
/// quietly: the Swift side reads exactly the keys the Dart backend sends,
/// with casts that accept the wire types Dart produces; the Dart backend
/// parses exactly what the Swift side sends back; the file is compiled
/// into the Runner target; and the rules the design rests on hold (no
/// delete, the embedder's press ends before the session, nothing waits
/// for Dart on the merged main thread).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(dragOutChannelName);
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final swift = _read('macos/Runner/DragOutChannel.swift');

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Every call the Dart backend sends, as the native side decodes it.
  Future<List<MethodCall>> sentByDart() async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'startDrag' ? {'started': true} : null;
    });
    final backend = MethodChannelDragOutBackend(
      support: DragOutSupport.localFilesAndPromises,
    );
    for (final items in const [
      [
        LocalDragOutItem(
          path: '/Users/me/report.txt',
          name: 'report.txt',
          isDirectory: false,
        ),
        LocalDragOutItem(
          path: '/Users/me/site',
          name: 'site',
          isDirectory: true,
        ),
      ],
      [
        PromisedDragOutItem(
          promiseId: 'p1',
          name: 'photo.jpg',
          isDirectory: false,
          size: 4096,
        ),
        PromisedDragOutItem(promiseId: 'p2', name: 'logs', isDirectory: true),
      ],
    ]) {
      await backend.startDrag(
        DragOutRequest(
          sessionId: 'dragout-1',
          items: items,
          position: const Offset(1500, 40),
          allowedOperations: DragOutOperation.values.toSet(),
          image: DragOutImage(
            png: Uint8List.fromList([1, 2, 3]),
            size: const Size(120, 36),
            anchor: const Offset(0, 6),
          ),
        ),
      );
    }
    await backend.startDrag(
      const DragOutRequest(
        sessionId: 'dragout-2',
        items: [
          LocalDragOutItem(path: '/tmp/a', name: 'a', isDirectory: false),
        ],
        position: Offset(-4, 10),
        allowedOperations: {DragOutOperation.copy},
      ),
    );
    backend
      ..reportProgress(
        sessionId: 'dragout-1',
        promiseId: 'p1',
        completedBytes: 512,
        totalBytes: 4096,
      )
      ..reportProgress(
        sessionId: 'dragout-1',
        promiseId: 'p2',
        completedBytes: 0,
      );
    await pumpEventQueue();
    return calls;
  }

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

  group('Dart to Swift', () {
    test('Swift handles exactly the methods Dart invokes', () async {
      final handled = _matches(
        RegExp(r'case "(\w+)":'),
        _body(swift, 'private func handle('),
      );
      final invoked = {for (final call in await sentByDart()) call.method};
      expect(handled, {'startDrag', 'promiseProgress'});
      expect(invoked, handled);
    });

    test('startDrag: every key Swift reads arrives with a type its cast '
        'accepts, and Dart sends nothing macOS has not decided on', () async {
      final reads = _reads(
        swift,
        'args',
        helpers: {'point': '[NSNumber]', 'dragOperations': '[String]'},
      );
      // The helpers' own casts, which the table above stands for.
      expect(
        _body(swift, 'private static func point('),
        contains('value as? [NSNumber], pair.count == 2'),
      );
      expect(
        _body(swift, 'private static func dragOperations('),
        contains('value as? [String]'),
      );
      // Read by the other backends; macOS draws Finder's icons and places
      // the frame from the event AppKit is handed instead.
      const unreadOnMac = {'position', 'image', 'imageSize'};
      const required = {'sessionId', 'items'};

      final starts = [
        for (final call in await sentByDart())
          if (call.method == 'startDrag') call.arguments as Map,
      ];
      expect(starts, hasLength(3));
      for (final arguments in starts) {
        expect(arguments.keys.toSet(), {...reads.keys, ...unreadOnMac});
        reads.forEach((key, cast) {
          final value = arguments[key];
          if (value == null && !required.contains(key)) return;
          expect(
            _castAccepts(cast, value),
            isTrue,
            reason: 'startDrag.$key is ${value.runtimeType}, Swift casts $cast',
          );
        });
      }
    });

    test(
      'startDrag items: file and promise maps match the Swift parse',
      () async {
        final reads = _reads(swift, 'raw');
        final kinds = _matches(
          RegExp(r'case "(\w+)":'),
          _body(swift, 'private static func parseItem('),
        );
        expect(kinds, {'file', 'promise'});
        // What Swift refuses the item without (guard lets).
        const required = {
          'file': {'kind', 'path'},
          'promise': {'kind', 'promiseId', 'name'},
        };

        final items = [
          for (final call in await sentByDart())
            if (call.method == 'startDrag')
              for (final item in (call.arguments as Map)['items'] as List)
                item as Map,
        ];
        expect({for (final item in items) item['kind']}, kinds);
        for (final item in items) {
          final kind = item['kind'] as String;
          expect(
            reads.keys.toSet().containsAll(item.keys.cast<String>()),
            isTrue,
            reason: 'Swift ignores a $kind key: ${item.keys}',
          );
          for (final key in required[kind]!) {
            expect(item[key], isNotNull, reason: '$kind.$key is required');
          }
          for (final MapEntry(:key, :value) in item.entries) {
            if (value == null) continue;
            expect(
              _castAccepts(reads[key]!, value),
              isTrue,
              reason:
                  '$kind.$key is ${value.runtimeType}, Swift casts '
                  '${reads[key]}',
            );
          }
        }
      },
    );

    test('allowed operations: Swift knows every name Dart can send and '
        'never maps one to delete', () {
      final body = _body(swift, 'private static func dragOperations(');
      final names = _matches(RegExp(r'case "(\w+)": operations\.insert'), body);
      expect(names, {for (final op in DragOutOperation.values) op.name});
      expect(body, isNot(contains('.delete')));
      expect(body, isNot(contains('.generic')));
    });

    test('promiseProgress: every key Swift reads arrives with a type its '
        'cast accepts', () async {
      final reads = _reads(swift, 'update');
      final updates = [
        for (final call in await sentByDart())
          if (call.method == 'promiseProgress') call.arguments as Map,
      ];
      expect(updates, hasLength(2));
      for (final arguments in updates) {
        expect(arguments.keys.toSet(), reads.keys.toSet());
        reads.forEach((key, cast) {
          final value = arguments[key];
          if (value == null && key == 'totalBytes') return;
          expect(
            _castAccepts(cast, value),
            isTrue,
            reason:
                'promiseProgress.$key is ${value.runtimeType}, Swift '
                'casts $cast',
          );
        });
      }
    });
  });

  group('Swift to Dart', () {
    /// `invokeMethod("name", arguments: [...])` → the literal's keys.
    Map<String, Set<String>> invocations() => {
      for (final match in RegExp(
        r'invokeMethod\(\s*"(\w+)",\s*arguments:\s*\[([^\]]*)\]',
      ).allMatches(swift))
        match.group(1)!: _matches(RegExp(r'"(\w+)":'), match.group(2)!),
    };

    test(
      'Swift sends exactly the callbacks Dart parses, with their keys',
      () async {
        final sent = invocations();
        expect(sent, {
          'fulfilPromise': {'sessionId', 'promiseId', 'destinationPath'},
          'cancelPromise': {'sessionId', 'promiseId'},
          'sessionEnded': {'sessionId', 'operation'},
        });

        final backend = MethodChannelDragOutBackend(
          support: DragOutSupport.localFilesAndPromises,
        );
        final delegate = _Delegate();
        backend.delegate = delegate;
        // Every value Swift sends is a String (ids, `url.path`, and
        // operationName's result).
        Map<String, String> arguments(String method) => {
          for (final key in sent[method]!) key: '$key-value',
        };
        expect(
          await fromNative('fulfilPromise', arguments('fulfilPromise')),
          isNull,
        );
        await fromNative('cancelPromise', arguments('cancelPromise'));
        expect(delegate.fulfilled.single.sessionId, 'sessionId-value');
        expect(delegate.fulfilled.single.promiseId, 'promiseId-value');
        expect(
          delegate.fulfilled.single.destinationPath,
          'destinationPath-value',
        );
        expect(delegate.cancelled, [('sessionId-value', 'promiseId-value')]);
      },
    );

    test(
      'every session end Swift reports reads back as its operation',
      () async {
        final names = _matches(
          RegExp(r'return "(\w+)"'),
          _body(swift, 'private static func operationName('),
        );
        expect(names, {'move', 'link', 'copy', 'none'});
        final backend = MethodChannelDragOutBackend(
          support: DragOutSupport.localFilesAndPromises,
        );
        final delegate = _Delegate();
        backend.delegate = delegate;
        for (final name in names) {
          await fromNative('sessionEnded', {
            'sessionId': 'dragout-1',
            'operation': name,
          });
        }
        expect(delegate.ended, [
          for (final name in names)
            (
              'dragout-1',
              DragOutOperation.values
                  .where((op) => op.name == name)
                  .firstOrNull,
            ),
        ]);
        expect(delegate.ended.last.$2, isNull, reason: 'none reads as null');
      },
    );

    test('every startDrag reply Swift builds reads back as it means', () async {
      final reasons = _matches(RegExp(r'refusal\("(\w+)"'), swift);
      expect(reasons, {
        'failed',
        'busy',
        'unsupportedItems',
        'noPointerEvent',
        'buttonReleased',
      });
      expect(swift, contains('result(["started": true])'));
      expect(
        _body(swift, 'private static func refusal('),
        allOf(
          contains('["started": false, "reason": reason]'),
          contains('reply["message"] = message'),
        ),
      );

      final backend = MethodChannelDragOutBackend(
        support: DragOutSupport.localFilesAndPromises,
      );
      const request = DragOutRequest(
        sessionId: 'dragout-1',
        items: [
          LocalDragOutItem(path: '/tmp/a', name: 'a', isDirectory: false),
        ],
        position: Offset(-4, 10),
        allowedOperations: {DragOutOperation.copy},
      );
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'started': true},
      );
      expect(await backend.startDrag(request), isA<DragOutStarted>());
      for (final reason in reasons) {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {'started': false, 'reason': reason, 'message': 'why'},
        );
        expect(
          await backend.startDrag(request),
          isA<DragOutNotStarted>()
              .having((r) => r.reason.name, 'reason', reason)
              .having((r) => r.message, 'message', 'why'),
        );
      }
    });

    test('the failures Swift completes as a user cancel are real codes', () {
      final quiet = RegExp(
        r'quietFailures: Set<String> = \[([^\]]*)\]',
      ).firstMatch(swift);
      expect(quiet, isNotNull);
      expect(_matches(RegExp(r'"(\w+)"'), quiet!.group(1)!), {
        DragOutPromiseFailure.cancelled.name,
        DragOutPromiseFailure.ownDrop.name,
      });
    });
  });

  group('source rules', () {
    test('serves the channel the Dart backend talks to', () {
      expect(swift, contains('channelName = "$dragOutChannelName"'));
    });

    test('is compiled into the Runner target and created with the window', () {
      final project = _read('macos/Runner.xcodeproj/project.pbxproj');
      final buildFile = RegExp(
        r'(\w{24}) /\* DragOutChannel\.swift in Sources \*/ = '
        r'\{isa = PBXBuildFile; fileRef = (\w{24}) ',
      ).firstMatch(project);
      expect(buildFile, isNotNull);
      final fileRef = buildFile!.group(2)!;
      expect(
        project,
        contains(
          '$fileRef /* DragOutChannel.swift */ = {isa = PBXFileReference; '
          'lastKnownFileType = sourcecode.swift; path = DragOutChannel.swift; '
          'sourceTree = "<group>"; };',
        ),
      );
      final phases = RegExp(
        r'isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);',
        dotAll: true,
      ).allMatches(project).map((m) => m.group(1)!);
      final runnerSources = phases.singleWhere(
        (files) => files.contains('MainFlutterWindow.swift in Sources'),
      );
      expect(runnerSources, contains('${buildFile.group(1)} /* '));
      final runnerGroup = RegExp(
        r'/\* Runner \*/ = \{\s*isa = PBXGroup;\s*children = \((.*?)\);',
        dotAll: true,
      ).firstMatch(project);
      expect(runnerGroup!.group(1), contains('$fileRef /* DragOutChannel'));

      final window = _read('macos/Runner/MainFlutterWindow.swift');
      final created = window.indexOf('dragOutChannel = DragOutChannel(');
      expect(created, isNonNegative);
      expect(window.indexOf('super.awakeFromNib()'), greaterThan(created));
      expect(window, contains('private var dragOutChannel: DragOutChannel?'));
    });

    test('never offers or performs a delete', () {
      expect(swift, isNot(contains('.delete')));
      expect(
        swift,
        isNot(matches(RegExp(r'\b(removeItem|trashItem|unlink|rmdir)\b'))),
      );
      expect(
        _body(
          swift,
          'func draggingSession(\n    _ session: NSDraggingSession,\n'
          '    sourceOperationMaskFor',
        ),
        contains('activeSession?.operations ?? []'),
      );
      expect(swift, contains('? .copy\n      : Self.dragOperations('));
    });

    test('ends the embedder press before the session starts', () {
      final start = _body(swift, 'private func startDrag(');
      final release = start.indexOf('endFlutterPress(controller, window:');
      final begin = start.indexOf('view.beginDraggingSession(');
      expect(release, isNonNegative);
      expect(begin, greaterThan(release));
      // The mask is asked for as soon as the session begins.
      expect(start.indexOf('activeSession = ActiveSession('), lessThan(begin));
      // Dart hears `started` before anything the session reports, and
      // every refusal is a reply too.
      final started = start.indexOf('result(["started": true])');
      expect(started, greaterThan(release));
      expect(started, lessThan(begin));
      expect(start, isNot(contains('return Self.refusal(')));
      expect(
        RegExp(r'result\(Self\.refusal\(').allMatches(start).length,
        RegExp(r'Self\.refusal\(').allMatches(start).length,
      );
      expect(
        _body(swift, 'private func endFlutterPress('),
        allOf(contains('with: .leftMouseUp'), contains('controller.mouseUp(')),
      );
    });

    test('records the press whichever view it hit', () {
      expect(
        swift,
        contains(
          'NSEvent.addLocalMonitorForEvents(\n'
          '      matching: [.leftMouseDown, .leftMouseDragged]',
        ),
      );
      expect(swift, contains('self?.record(event)\n      return event'));
      expect(swift, contains('NSEvent.removeMonitor('));
    });

    test('never waits for Dart on the main thread', () {
      expect(
        swift,
        isNot(
          matches(
            RegExp(
              r'DispatchSemaphore|DispatchGroup|\.wait\(|main\.sync|'
              r'RunLoop|\bsleep\(|usleep|waitUntilAllOperationsAreFinished',
            ),
          ),
        ),
      );
      final write = _body(
        swift,
        'func filePromiseProvider(\n    _ filePromiseProvider: '
        'NSFilePromiseProvider,\n    writePromiseTo',
      );
      expect(write, contains('DispatchQueue.main.async'));
      expect(_body(swift, 'func operationQueue(for'), contains('promiseQueue'));
    });

    test('publishes cancellable progress on the promised URL', () {
      final fulfil = _body(swift, 'private func fulfil(');
      expect(
        fulfil,
        allOf([
          contains('progress.fileURL = url'),
          contains('progress.kind = .file'),
          contains('progress.fileOperationKind = .downloading'),
          contains('progress.isCancellable = true'),
          contains('"cancelPromise"'),
          contains('progress.publish()'),
          contains('progress.unpublish()'),
          contains('"destinationPath": url.path'),
          contains('completionHandler(Self.completionError(reply))'),
        ]),
      );
    });

    test('promises folders as folders and draws Finder icons', () {
      expect(
        _body(swift, 'private static func contentType('),
        allOf(
          contains('if isDirectory { return .folder }'),
          contains('?? .data'),
        ),
      );
      expect(swift, contains('NSWorkspace.shared.icon(forFile: path)'));
      expect(swift, contains('NSWorkspace.shared.icon(for: type)'));
      expect(swift, contains('session.draggingFormation = .pile'));
    });
  });
}
