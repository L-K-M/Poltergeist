// OS drag-out's in-app half (00 D14's 2026-09-25 amendment): a pane row
// drag that leaves the window is handed to the native session once, the
// Flutter drag ends, and in-app drags never reach the backend. Remote
// rows where only local files travel show the Download To… hint and keep
// dragging in-app; a drag of ours that comes back through desktop_drop
// lands with the in-app verb rules.

import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/drag_out_controller.dart';
import 'package:poltergeist_app/services/os_drag_out.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_drop.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_drop_area.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_app_transfer_queue.dart';
import '../../support/fake_drag_out.dart';
import '../../support/test_panes.dart';

RemoteFileEntry _entryAt(
  String dir,
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
}) => RemoteFileEntry(
  path: '$dir/$name',
  name: name,
  type: type,
  size: size,
  modifiedAt: DateTime(2026, 9, 10, 12),
);

Bookmark _bookmark(String id) {
  final now = DateTime.utc(2026, 9, 12);
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: 'web.example.com',
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 22,
        username: 'tester',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/srv/home',
    sortKey: id,
    createdAt: now,
    updatedAt: now,
  );
}

/// One platform→Dart `desktop_drop` channel message.
Future<void> _osChannel(
  WidgetTester tester,
  String method,
  Object? arguments,
) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'desktop_drop',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );
  await tester.pump();
}

void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController left;
  late PaneController right;
  late PaneTabsController leftStrip;
  late PaneTabsController rightStrip;
  late WorkspaceController workspace;
  late FocusNode leftNode;
  late FocusNode rightNode;
  late FakeAppTransferQueue queue;
  late PaneDropDelegate delegate;
  late FakeDragOutBackend backend;
  late FakeDragOutProducer files;
  late DragOutController dragOut;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    lanes = controller_test.FakePaneLanes();
    left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    leftStrip = testPaneStrip(left);
    rightStrip = testPaneStrip(right);
    workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    leftNode = FocusNode();
    rightNode = FocusNode();
    queue = FakeAppTransferQueue();
    delegate = PaneDropDelegate(queue: queue);
    backend = FakeDragOutBackend();
    files = FakeDragOutProducer();
    dragOut = DragOutController(
      backend: backend,
      files: files,
      queue: queue,
      dropStagingDirectory: '/var/folders/xy/T/Drops',
    );
  });

  tearDown(() {
    dragOut.dispose();
    workspace.dispose();
    leftNode.dispose();
    rightNode.dispose();
  });

  void dndWidgets(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  /// Left: '/home/tester' (docs, report.txt, notes.txt); right:
  /// '/srv/other' (images, index.html).
  Future<void> bindLocals() async {
    final leftChannel = controller_test.FakePaneChannel('/home/tester');
    leftChannel.listings['/home/tester'] = [
      _entryAt('/home/tester', 'docs', type: RemoteFileType.directory),
      _entryAt('/home/tester', 'notes.txt', size: 10),
      _entryAt('/home/tester', 'report.txt', size: 2048),
    ];
    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();

    final rightChannel = controller_test.FakePaneChannel('/home/tester');
    rightChannel.listings['/srv/other'] = [
      _entryAt('/srv/other', 'images', type: RemoteFileType.directory),
      _entryAt('/srv/other', 'index.html', size: 512),
    ];
    lanes.nextLocalChannel = rightChannel;
    await right.openLocalAt('/srv/other');
  }

  /// Left: local '/home/tester'; right: remote srv-1 at '/srv/home'.
  Future<void> bindLocalAndRemote() async {
    final leftChannel = controller_test.FakePaneChannel('/home/tester');
    leftChannel.listings['/home/tester'] = [
      _entryAt('/home/tester', 'report.txt', size: 2048),
    ];
    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();

    final rightChannel = controller_test.FakePaneChannel('/srv/home');
    rightChannel.listings['/srv/home'] = [
      _entryAt('/srv/home', 'sub', type: RemoteFileType.directory),
      _entryAt('/srv/home', 'index.html', size: 512),
    ];
    lanes.nextRemoteChannel = rightChannel;
    await right.connectRemote(_bookmark('srv-1'));
  }

  Future<void> pumpShell(WidgetTester tester, {bool withDragOut = true}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    PaneView pane(
      PaneController controller,
      PaneTabsController strip,
      FocusNode node,
      FocusNode other,
    ) => PaneView(
      controller: controller,
      pane: strip,
      workspace: workspace,
      focusNode: node,
      onSwapFocus: () => other.requestFocus(),
      onCancelRecovery: () => unawaited(controller.cancelRecovery()),
      dropDelegate: delegate,
      dragOut: withDragOut ? dragOut : null,
      clock: () => DateTime(2026, 9, 15, 10),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Row(
            children: [
              Expanded(child: pane(left, leftStrip, leftNode, rightNode)),
              Expanded(child: pane(right, rightStrip, rightNode, leftNode)),
            ],
          ),
        ),
      ),
    );
  }

  Offset paneBackground(WidgetTester tester, PaneController controller) {
    final rect = tester.getRect(
      find.byWidgetPredicate(
        (w) => w is PaneView && w.controller == controller,
      ),
    );
    return Offset(rect.center.dx, rect.bottom - 60);
  }

  /// Presses [row], moves inside the window, then past its right edge.
  Future<TestGesture> dragOutOfWindow(WidgetTester tester, Finder row) async {
    final gesture = await tester.startGesture(tester.getCenter(row));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveTo(const Offset(1300, 200));
    await tester.pump();
    await gesture.moveTo(const Offset(1450, 200));
    await tester.pump();
    await tester.pump();
    return gesture;
  }

  Future<void> endDrag(WidgetTester tester, TestGesture gesture) async {
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
  }

  dndWidgets('a row dragged past the window edge hands off once and the '
      'Flutter drag ends', (tester) async {
    await bindLocals();
    await pumpShell(tester);

    final gesture = await dragOutOfWindow(tester, find.text('report.txt'));
    expect(backend.requests, hasLength(1));
    final request = backend.requests.single;
    expect(request.position, const Offset(1450, 200));
    expect(request.items.map((item) => item.toChannel()), [
      {
        'kind': 'file',
        'path': '/home/tester/report.txt',
        'name': 'report.txt',
        'isDirectory': false,
      },
    ]);
    // The in-app avatar is gone: the native session owns the drag now.
    expect(find.byType(PaneEntryDragAvatar), findsNothing);

    // Further moves outside never start a second session, and the real
    // release lands no in-app drop.
    await gesture.moveTo(const Offset(1500, 300));
    await tester.pump();
    await gesture.moveTo(paneBackground(tester, right));
    await tester.pump();
    await endDrag(tester, gesture);
    expect(backend.requests, hasLength(1));
    expect(queue.enqueuedSpecs, isEmpty);
    expect(tester.takeException(), isNull);

    // The pane still answers the next click: nothing stayed stuck.
    await tester.tap(find.text('notes.txt'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(left.cursorIndex, 1);
  });

  dndWidgets('a multi-selection hands off every selected item', (tester) async {
    await bindLocals();
    // docs, notes.txt, report.txt: select docs and report.txt.
    left.setCursorIndex(0);
    left.setCursorIndex(2, update: SelectionUpdate.toggle);
    await pumpShell(tester);

    final gesture = await dragOutOfWindow(tester, find.text('report.txt'));
    await endDrag(tester, gesture);
    final items = backend.requests.single.items.cast<LocalDragOutItem>();
    expect(items.map((item) => (item.path, item.isDirectory)), [
      ('/home/tester/docs', true),
      ('/home/tester/report.txt', false),
    ]);
  });

  dndWidgets('an in-app drag never reaches the native backend', (tester) async {
    await bindLocals();
    await pumpShell(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('report.txt')),
    );
    await tester.pump();
    await gesture.moveTo(paneBackground(tester, right));
    await tester.pump();
    await endDrag(tester, gesture);

    expect(backend.requests, isEmpty);
    expect(queue.enqueuedSpecs.single.operation, TransferOperation.move);
    expect(queue.enqueuedSpecs.single.destinationDir, '/srv/other');
  });

  dndWidgets('remote rows where only files travel show the hint and keep '
      'dragging in-app', (tester) async {
    await bindLocalAndRemote();
    await pumpShell(tester);

    final gesture = await dragOutOfWindow(tester, find.text('index.html'));
    expect(backend.requests, isEmpty);
    expect(right.notice, PaneNotice.dragOutRemote);
    await tester.pump();
    expect(
      find.text(
        "Remote items can't be dragged out of Poltergeist here yet. "
        'Use Download To… instead.',
      ),
      findsOneWidget,
    );
    // Still an in-app drag: back over the local pane, it downloads.
    expect(find.byType(PaneEntryDragAvatar), findsOneWidget);
    await gesture.moveTo(paneBackground(tester, left));
    await tester.pump();
    await endDrag(tester, gesture);
    final spec = queue.enqueuedSpecs.single;
    expect(spec.source, const ServerFsLocation('srv-1'));
    expect(spec.destinationDir, '/home/tester');
    await tester.pump(right.noticeLifetime);
  });

  dndWidgets('a refused native start leaves the in-app drag running', (
    tester,
  ) async {
    await bindLocals();
    backend.nextResult = const DragOutNotStarted(DragOutRefusal.noPointerEvent);
    await pumpShell(tester);

    final gesture = await dragOutOfWindow(tester, find.text('report.txt'));
    expect(backend.requests, hasLength(1));
    expect(find.byType(PaneEntryDragAvatar), findsOneWidget);
    await gesture.moveTo(paneBackground(tester, right));
    await tester.pump();
    await endDrag(tester, gesture);
    expect(queue.enqueuedSpecs.single.destinationDir, '/srv/other');
  });

  dndWidgets('without a drag-out controller the edge changes nothing', (
    tester,
  ) async {
    await bindLocals();
    await pumpShell(tester, withDragOut: false);

    final gesture = await dragOutOfWindow(tester, find.text('report.txt'));
    expect(find.byType(PaneEntryDragAvatar), findsOneWidget);
    await endDrag(tester, gesture);
    expect(queue.enqueuedSpecs, isEmpty);
  });

  dndWidgets('a new gesture can hand off again', (tester) async {
    await bindLocals();
    await pumpShell(tester);

    await endDrag(
      tester,
      await dragOutOfWindow(tester, find.text('report.txt')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await endDrag(
      tester,
      await dragOutOfWindow(tester, find.text('notes.txt')),
    );
    expect(backend.requests, hasLength(2));
    expect(
      (backend.requests.last.items.single as LocalDragOutItem).path,
      '/home/tester/notes.txt',
    );
  });

  group('own-drag echo', () {
    dndWidgets('a local drag that comes back through desktop_drop lands '
        'with the in-app verb, not the OS-drop copy', (tester) async {
      await bindLocals();
      await pumpShell(tester);

      final gesture = await dragOutOfWindow(tester, find.text('report.txt'));
      // The OS session carries the drag back over the right pane.
      final target = paneBackground(tester, right);
      await _osChannel(tester, 'entered', [target.dx, target.dy]);
      expect(find.text('Move to /srv/other'), findsOneWidget);
      await _osChannel(tester, 'performOperation', ['/home/tester/report.txt']);
      await endDrag(tester, gesture);

      final spec = queue.enqueuedSpecs.single;
      expect(spec.operation, TransferOperation.move);
      expect(spec.rootPaths, ['/home/tester/report.txt']);
      expect(spec.destinationDir, '/srv/other');
    });

    dndWidgets('a foreign OS drop while our session runs is still a copy', (
      tester,
    ) async {
      await bindLocals();
      await pumpShell(tester);

      final gesture = await dragOutOfWindow(tester, find.text('report.txt'));
      final target = paneBackground(tester, right);
      await _osChannel(tester, 'entered', [target.dx, target.dy]);
      await _osChannel(tester, 'performOperation', ['/elsewhere/photo.jpg']);
      await endDrag(tester, gesture);

      final spec = queue.enqueuedSpecs.single;
      expect(spec.operation, TransferOperation.copy);
      expect(spec.rootPaths, ['/elsewhere/photo.jpg']);
    });

    dndWidgets('a remote promise echoed into desktop_drop staging routes '
        'in-app as a download', (tester) async {
      backend.support = DragOutSupport.localFilesAndPromises;
      await bindLocalAndRemote();
      await pumpShell(tester);

      final gesture = await dragOutOfWindow(tester, find.text('index.html'));
      final request = backend.requests.single;
      // desktop_drop calls the promise into its staging folder first.
      await expectLater(
        dragOut.fulfilPromise(
          DragOutPromiseRequest(
            sessionId: request.sessionId,
            promiseId: 'p1',
            destinationPath: '/var/folders/xy/T/Drops/20260925/index.html',
          ),
        ),
        throwsA(isA<DragOutPromiseException>()),
      );
      final target = paneBackground(tester, left);
      await _osChannel(tester, 'entered', [target.dx, target.dy]);
      await _osChannel(tester, 'performOperation', <String>[]);
      await endDrag(tester, gesture);

      expect(files.produces, isEmpty);
      final spec = queue.enqueuedSpecs.single;
      expect(spec.source, const ServerFsLocation('srv-1'));
      expect(spec.rootPaths, ['/srv/home/index.html']);
      expect(spec.destinationDir, '/home/tester');
      expect(spec.operation, TransferOperation.copy);
    });
  });
}
