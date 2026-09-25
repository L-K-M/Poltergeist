// 07 §3.5's M5-bridge boot composition, proven end to end at the app
// seam: startTransferQueue builds the real TransferQueue over
// FileTransferPersistence inside the app-support directory, restores
// the crashed session's journaled survivors (journaled-paused stays
// paused; every other non-terminal task replays queued behind the
// forced restore pause), and hands one queue seam to every consumer —
// the mounted shell's restored banner, the pane drop delegate, and the
// quit guard's close-time flush. A third boot's replay proves the
// flush's durability.
//
// With POLTERGEIST_CAPTURE=1 the restored panel also lands as a PNG —
// real fonts load when the host provides them
// (POLTERGEIST_CAPTURE_FONT_DIR or the DejaVu fallback), the same
// convention as activity_panel_capture_test.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/activity_panel_controller.dart';
import 'package:poltergeist_app/services/quit_guard.dart';
import 'package:poltergeist_app/services/transfer_queue_session.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/activity/activity_panel.dart';
import 'package:poltergeist_app/ui/panes/pane_drop_area.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    '../../tasks/run3-task74/captures';

bool get _captureOn => Platform.environment['POLTERGEIST_CAPTURE'] == '1';

Future<ByteData> _fontBytes(String path) async {
  final bytes = File(path).readAsBytesSync();
  return ByteData.sublistView(bytes);
}

Future<void> _loadRealFonts() async {
  final home = Platform.environment['HOME'];
  final dir = Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      (home == null ? '' : '$home/.local/share/fonts');
  final sans = File('$dir/DejaVuSans.ttf');
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final iconsLoader = FontLoader('MaterialIcons')
      ..addFont(_fontBytes(icons.path));
    await iconsLoader.load();
  }
  if (!sans.existsSync()) return;
  final loader = FontLoader('DejaVu Sans')..addFont(_fontBytes(sans.path));
  if (sansBold.existsSync()) loader.addFont(_fontBytes(sansBold.path));
  await loader.load();
}

void main() {
  late Directory tempDir;
  late Directory supportDir;
  late Directory srcDir;
  late Directory destDir;

  // "Crashed" sessions stay tracked so tearDown can still clean them
  // up — a kill abandons the store without shutdown.
  final sessions = <TransferQueueSession>[];

  /// The production composition entrypoint — the same call main.dart
  /// makes, pointed at the test's support directory.
  Future<TransferQueueSession> boot() async {
    final session = await startTransferQueue(
      supportDirectoryPath: supportDir.path,
    );
    expect(session, isNotNull);
    sessions.add(session!);
    return session;
  }

  TransferTaskSpec copySpec(String name) => TransferTaskSpec(
    source: const LocalFsLocation(),
    destination: const LocalFsLocation(),
    rootPaths: ['${srcDir.path}/$name'],
    destinationDir: destDir.path,
    policy: ResolvedConflictPolicy(
      files: ConflictResolution.replace,
      folders: ConflictResolution.merge,
    ),
  );

  /// Real-clock polling for the real futures the queue's IO resolves —
  /// only callable inside `tester.runAsync`.
  Future<void> pumpUntil(
    bool Function() condition, {
    String reason = '',
  }) async {
    for (var i = 0; i < 400; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('pumpUntil timed out${reason.isEmpty ? '' : ': $reason'}');
  }

  bool isShown(Finder finder) => finder.evaluate().isNotEmpty;

  /// Inside `runAsync` everything is real-time: poll on a real clock so
  /// the close chain's IO hops are not hostage to a fixed delay.
  Future<void> waitFor(WidgetTester tester, bool Function() met) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!met() && DateTime.now().isBefore(deadline)) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await tester.pump();
    if (!met()) {
      fail('waitFor timed out after 5s');
    }
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('poltergeist-boot-queue-');
    tempDir = Directory(tempDir.resolveSymbolicLinksSync());
    // supportDir is deliberately not created: FileTransferPersistence
    // owns the directory creation inside open().
    supportDir = Directory('${tempDir.path}/support');
    srcDir = Directory('${tempDir.path}/src')..createSync();
    destDir = Directory('${tempDir.path}/dest')..createSync();
  });

  tearDown(() async {
    // Session teardown must run inside the test's runAsync — awaiting a
    // queue dispose in the binding's teardown zone deadlocks (the same
    // trap app.dart's dispose documents for the engine session). Widget
    // tests drain `sessions` before ending; the plain test's teardown
    // zone is real and reaches here.
    for (final session in sessions) {
      await session.dispose();
    }
    sessions.clear();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('a supplied lease seam carries remote tasks end to end', () async {
    // Production composes the engine's bridged EngineConnectionManager
    // (protocol v13); the core bridge suites prove the port itself. Here
    // the boot path must hand the queue the seam it was given — and the
    // checkout session reads the same instance back.
    final remote = _OneFileRemote('/srv/site/index.html', [1, 2, 3, 4]);
    final connections = _LeasingConnections(remote);
    final session = await startTransferQueue(
      supportDirectoryPath: supportDir.path,
      connections: connections,
    );
    expect(session, isNotNull);
    sessions.add(session!);
    expect(identical(session.connections, connections), isTrue);
    final task = session.queue.enqueue(
      TransferTaskSpec(
        source: const ServerFsLocation('server-1'),
        destination: const LocalFsLocation(),
        rootPaths: const ['/srv/site/index.html'],
        destinationDir: destDir.path,
        policy: ResolvedConflictPolicy(
          files: ConflictResolution.replace,
          folders: ConflictResolution.merge,
        ),
      ),
    );
    await pumpUntil(() => task.isTerminal, reason: 'bridged task stuck');
    expect(task.state, TransferTaskState.completed);
    expect(File('${destDir.path}/index.html').readAsBytesSync(), [1, 2, 3, 4]);
    expect(connections.leases, greaterThan(0));
    expect(connections.released, connections.leases);
  });

  test('an engine-less boot fails remote endpoints honestly', () async {
    final session = await boot();
    // No engine spawned, so no seam was supplied: the fallback cannot
    // lease a channel — the task must land as a visible failed row,
    // never hang in scanning.
    final task = session.queue.enqueue(
      TransferTaskSpec(
        source: const ServerFsLocation('server-1'),
        destination: const LocalFsLocation(),
        rootPaths: const ['/srv/site/index.html'],
        destinationDir: destDir.path,
        policy: ResolvedConflictPolicy(
          files: ConflictResolution.replace,
          folders: ConflictResolution.merge,
        ),
      ),
    );
    await pumpUntil(() => task.isTerminal, reason: 'remote task stuck');
    expect(task.state, TransferTaskState.failed);
  });

  testWidgets('boot composes a restoring queue into the shell', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (_captureOn) await tester.runAsync(_loadRealFonts);

    try {
      late TransferQueueSession session;
      late String doneId, pausedId, queuedId;
      await tester.runAsync(() async {
        // Session 1: a live app session with the real journal.
        final first = await boot();
        File('${srcDir.path}/done.txt').writeAsStringSync('done!');
        File('${srcDir.path}/paused.txt').writeAsStringSync('paused?');
        File('${srcDir.path}/queued.txt').writeAsStringSync('queued?');

        final done = first.queue.enqueue(copySpec('done.txt'));
        await pumpUntil(
          () => done.isTerminal,
          reason: 'first task stuck',
        );
        expect(done.state, TransferTaskState.completed);
        doneId = done.id;

        first.queue.pauseQueue();
        final paused = first.queue.enqueue(copySpec('paused.txt'));
        first.queue.pauseTask(paused.id);
        final queued = first.queue.enqueue(copySpec('queued.txt'));
        await pumpUntil(
          () => paused.state == TransferTaskState.paused,
          reason: 'pause never journaled',
        );
        expect(queued.isTerminal, isFalse);
        pausedId = paused.id;
        queuedId = queued.id;
        await first.queue.flushJournal();
        // The kill: no dispose — the journal on disk is all the next
        // session gets.

        // Session 2: the production boot composition.
        session = await boot();
        expect(session.queue.isPaused, isTrue);
        final restoredPaused = session.queue.tasks.singleWhere(
          (task) => task.id == pausedId,
        );
        final restoredQueued = session.queue.tasks.singleWhere(
          (task) => task.id == queuedId,
        );
        expect(restoredPaused.state, TransferTaskState.paused);
        expect(restoredQueued.state, TransferTaskState.queued);
        expect(restoredPaused.wasRestored, isTrue);
        expect(session.queue.history.single.taskId, doneId);
      });

      // Mount the app over the composed queue and a real quit guard —
      // the same three consumers main.dart hands the seam to.
      final navigatorKey = GlobalKey<NavigatorState>();
      final errors = <Object>[];
      final guard = QuitGuard(
        navigatorKey: navigatorKey,
        onError: (error, _) => errors.add(error),
      );
      await tester.pumpWidget(
        PoltergeistApp(
          navigatorKey: navigatorKey,
          transferQueue: session.queue,
          quitGuard: guard,
        ),
      );
      await tester.pump();

      // The panel surfaces the restored queue — boot-held live tasks
      // un-hide it (the arrival edge cannot fire for tasks the journal
      // already held when the mirror bound).
      expect(
        find.byKey(const ValueKey('activity.restoredBanner')),
        findsOneWidget,
      );

      // The pane drop producer targets the same queue instance the
      // panel and the quit guard see — one queue, one journal.
      final dropArea = tester.widget<PaneDropArea>(
        find.byType(PaneDropArea).first,
      );
      expect(dropArea.delegate, isNotNull);
      expect(identical(dropArea.delegate!.queue, session.queue), isTrue);
      File('${srcDir.path}/drop.txt').writeAsStringSync('drop!');
      // The enqueue runs in the real zone: dispatching a task starts a
      // real-IO scan whose continuations must live on the real clock —
      // a fake-zone scan parks mid-flight and its `done` never drains
      // at session dispose.
      late final TransferTask dropped;
      await tester.runAsync(() async {
        dropped = dropArea.delegate!.enqueue(
          source: const LocalFsLocation(),
          rootPaths: ['${srcDir.path}/drop.txt'],
          destination: const LocalFsLocation(),
          destinationDir: destDir.path,
          operation: TransferOperation.copy,
        )!;
      });
      expect(
        session.queue.tasks.map((task) => task.id),
        contains(dropped.id),
      );

      // The close path: live tasks warn, Pause and Quit journals the
      // pause and flushes through the same composed queue.
      await tester.runAsync(() async {
        var closed = false;
        bool? closeAnswer;
        final closing = guard.confirmClose().then((answer) {
          closed = true;
          closeAnswer = answer;
          return answer;
        });
        await waitFor(
          tester,
          () => isShown(find.byKey(const ValueKey('quit.dialog'))),
        );
        expect(
          find.byKey(const ValueKey('quit.dialog')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('quit.pauseAndQuit')));
        // The close either resolves or the flush-failure warning opens
        // — both are observable; neither may stall the test.
        await waitFor(
          tester,
          () =>
              closed ||
              isShown(find.byKey(const ValueKey('quitFlush.dialog'))),
        );
        expect(
          find.byKey(const ValueKey('quitFlush.dialog')),
          findsNothing,
        );
        expect(closed, isTrue);
        expect(await closing, isTrue);
        expect(closeAnswer, isTrue);
        expect(errors, isEmpty);
      });

      // Durability proof: a third boot replays everything the flush
      // fsynced — the quit verb's pause made every survivor journaled
      // paused, and the completed task stays in history.
      await tester.runAsync(() async {
        final third = await boot();
        expect(
          third.queue.tasks.map((task) => task.id),
          containsAll([pausedId, queuedId, dropped.id]),
        );
        for (final task in third.queue.tasks) {
          expect(task.state, TransferTaskState.paused);
        }
        expect(third.queue.history.single.taskId, doneId);
      });

      // The restored panel, captured over the real composed queue.
      if (_captureOn) {
        final captureController = ActivityPanelController(
          queue: session.queue,
        );
        final base = buildPoltergeistTheme(Brightness.dark);
        final theme = base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
          primaryTextTheme: base.primaryTextTheme.apply(
            fontFamily: 'DejaVu Sans',
          ),
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('capture.restoredPanel'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme,
              localizationsDelegates:
                  AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Column(
                  children: [
                    const Spacer(),
                    SizedBox(
                      height: 420,
                      child: ListenableBuilder(
                        listenable: captureController,
                        builder: (context, _) => ActivityPanel(
                          controller: captureController,
                          onClose: () {},
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('activity.restoredBanner')),
          findsOneWidget,
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('capture.restoredPanel')),
        );
        final bytes = (await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          try {
            final data = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            return data!.buffer.asUint8List();
          } finally {
            image.dispose();
          }
        }))!;
        final outDir = Directory(_captureDir)
          ..createSync(recursive: true);
        final file = File('${outDir.path}/boot-restored-queue.png');
        // ignore: avoid_print
        print('capture: ${file.absolute.path}');
        file.writeAsBytesSync(bytes);
        // Its queue-event subscription must be cancelled before the
        // session disposes — see the finally below.
        captureController.dispose();
      }
    } finally {
      // Two teardown traps, both documented on the engine session's
      // own lifecycle: the queue's real async dispose deadlocks in the
      // binding's teardown zone, and a still-mounted activity
      // controller's live event subscription can stall the queue's
      // broadcast close on a fake-zone delivery that never lands while
      // runAsync waits on the real clock. Unmount first — widget
      // dispose cancels the subscription synchronously — then drain
      // every session inside runAsync while the test is still live.
      // tearDown's loop is the plain-test path.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        for (final session in sessions) {
          await session.dispose();
        }
        sessions.clear();
      });
    }
  });
}

/// One remote file for the lease-seam composition test: stat and
/// download are all a remote→local single-file task needs.
final class _OneFileRemote implements RemoteFileSystem {
  _OneFileRemote(this.path, this.bytes);

  final String path;
  final List<int> bytes;

  RemoteFileEntry get _entry => RemoteFileEntry(
    path: path,
    name: path.split('/').last,
    type: RemoteFileType.file,
    size: bytes.length,
  );

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    if (path == this.path) return _entry;
    throw RemoteFileException(
      kind: RemoteFileErrorKind.notFound,
      operation: 'stat',
      path: path,
      message: 'no such path',
    );
  }

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    await destination.addStream(Stream.value(bytes));
    onProgress?.call(bytes.length, bytes.length);
    return _entry;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final class _LeasingConnections implements ConnectionManager {
  _LeasingConnections(this.fs);

  final RemoteFileSystem fs;
  int leases = 0;
  int released = 0;

  @override
  Future<TransferChannelLease> leaseTransferChannel(String serverId) async {
    leases++;
    return _Lease(fs, () => released++);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final class _Lease implements TransferChannelLease {
  _Lease(this.fs, this._onRelease);

  @override
  final RemoteFileSystem fs;
  final void Function() _onRelease;

  @override
  Future<void> release() async => _onRelease();

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {}
}
