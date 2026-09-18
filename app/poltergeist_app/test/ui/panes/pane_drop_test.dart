import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_drop.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_drop_area.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_app_transfer_queue.dart';
import '../../support/test_panes.dart';

RemoteFileEntry _entryAt(
  String dir,
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
}) {
  return RemoteFileEntry(
    path: '$dir/$name',
    name: name,
    type: type,
    size: size,
    modifiedAt: DateTime(2026, 9, 10, 12),
  );
}

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

/// Drives one platform→Dart `desktop_drop` channel message — the same
/// route a real OS drag takes.
Future<void> _osChannel(
  WidgetTester tester,
  String method,
  Object? arguments,
) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'desktop_drop',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, arguments),
    ),
    (_) {},
  );
  await tester.pump();
}

/// A complete OS drop gesture at [at] carrying [paths].
Future<void> _osDropAt(
  WidgetTester tester,
  Offset at,
  List<String> paths,
) async {
  await _osChannel(tester, 'entered', [at.dx, at.dy]);
  await _osChannel(tester, 'performOperation', paths);
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
  late controller_test.FakePaneChannel rightChannel;

  setUp(() {
    // D14's surfaces are desktop gestures — the widget-test default
    // platform is Android, so the suite pins Linux explicitly.
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
  });

  tearDown(() {
    workspace.dispose();
    leftNode.dispose();
    rightNode.dispose();
  });

  /// The platform override must reset inside the test body — the
  /// binding's invariant check runs before package:test's tearDown
  /// callbacks, so resetting there is already too late.
  void dndWidgets(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  /// Binds left to '/home/tester' (docs dir, report.txt, link) and
  /// right to '/srv/other' (images dir, index.html) — each open
  /// consumes one scripted channel.
  Future<void> bindLocals() async {
    final leftChannel = controller_test.FakePaneChannel('/home/tester');
    leftChannel.listings['/home/tester'] = [
      _entryAt('/home/tester', 'docs', type: RemoteFileType.directory),
      _entryAt('/home/tester', 'report.txt', size: 2048),
      _entryAt('/home/tester', 'link', type: RemoteFileType.symbolicLink),
    ];
    leftChannel.listings['/home/tester/docs'] = [
      _entryAt('/home/tester/docs', 'nested.txt'),
    ];
    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();

    rightChannel = controller_test.FakePaneChannel('/home/tester');
    rightChannel.listings['/srv/other'] = [
      _entryAt('/srv/other', 'images', type: RemoteFileType.directory),
      _entryAt('/srv/other', 'index.html', size: 512),
    ];
    rightChannel.listings['/srv/other/images'] = [
      _entryAt('/srv/other/images', 'logo.png', size: 99),
    ];
    lanes.nextLocalChannel = rightChannel;
    await right.openLocalAt('/srv/other');
  }

  /// Binds right to remote srv-1 at '/srv/home' (index.html, sub dir).
  Future<void> bindRightRemote() async {
    rightChannel = controller_test.FakePaneChannel('/srv/home');
    rightChannel.listings['/srv/home'] = [
      _entryAt('/srv/home', 'sub', type: RemoteFileType.directory),
      _entryAt('/srv/home', 'index.html', size: 512),
    ];
    lanes.nextRemoteChannel = rightChannel;
    await right.connectRemote(_bookmark('srv-1'));
  }

  Future<void> pumpShell(
    WidgetTester tester, {
    bool withDelegate = true,
    bool? supportsOsDrop,
    bool tickerEnabled = true,
    bool rightTabs = false,
    bool rightHidden = false,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final drop = withDelegate ? delegate : null;
    final rightWidget = rightHidden
        ? const SizedBox()
        : rightTabs
        ? PaneTabsView(
            tabs: rightStrip,
            workspace: workspace,
            focusNode: rightNode,
            onSwapFocus: () => leftNode.requestFocus(),
            onCancelRecovery: () => unawaited(right.cancelRecovery()),
            dropDelegate: drop,
            supportsOsDrop: supportsOsDrop,
          )
        : PaneView(
            controller: right,
            pane: rightStrip,
            workspace: workspace,
            focusNode: rightNode,
            onSwapFocus: () => leftNode.requestFocus(),
            onCancelRecovery: () => unawaited(right.cancelRecovery()),
            dropDelegate: drop,
            supportsOsDrop: supportsOsDrop,
            clock: () => DateTime(2026, 9, 15, 10),
          );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: TickerMode(
            enabled: tickerEnabled,
            child: Row(
              children: [
                Expanded(
                  child: PaneView(
                    controller: left,
                    pane: leftStrip,
                    workspace: workspace,
                    focusNode: leftNode,
                    onSwapFocus: () => rightNode.requestFocus(),
                    onCancelRecovery: () =>
                        unawaited(left.cancelRecovery()),
                    dropDelegate: drop,
                    supportsOsDrop: supportsOsDrop,
                    clock: () => DateTime(2026, 9, 15, 10),
                  ),
                ),
                Expanded(child: rightWidget),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A point well below the last row of the right pane's listing — the
  /// "current directory" drop target.
  Offset rightPaneBackground(WidgetTester tester) {
    final rect = tester.getRect(
      find.byWidgetPredicate(
        (w) =>
            (w is PaneView && w.controller == right) ||
            (w is PaneTabsView && w.tabs == rightStrip),
      ),
    );
    return Offset(rect.center.dx, rect.bottom - 60);
  }

  Future<TestGesture> dragRowOnto(
    WidgetTester tester,
    Finder row,
    Offset target,
  ) async {
    final gesture = await tester.startGesture(tester.getCenter(row));
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    return gesture;
  }

  /// Releases the drag and drains the double-tap tracker's countdown —
  /// the row's tap machinery starts it on pointer-down and a pending
  /// timer fails the test-end invariant.
  Future<void> endDrag(WidgetTester tester, TestGesture gesture) async {
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
  }

  dndWidgets('a row drag onto the other pane’s background enqueues a '
      'same-filesystem move into its current directory', (tester) async {
    await bindLocals();
    await pumpShell(tester);

    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      rightPaneBackground(tester),
    );
    await endDrag(tester, gesture);

    expect(queue.enqueuedSpecs, hasLength(1));
    final spec = queue.enqueuedSpecs.single;
    expect(spec.operation, TransferOperation.move);
    expect(spec.rootPaths, ['/home/tester/report.txt']);
    expect(spec.destinationDir, '/srv/other');
    expect(spec.source, isA<LocalFsLocation>());
    expect(spec.destination, isA<LocalFsLocation>());
  });

  dndWidgets('a row drag onto a folder row lands in that folder', (
    tester,
  ) async {
    await bindLocals();
    await pumpShell(tester);

    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      tester.getCenter(find.text('images')),
    );
    await endDrag(tester, gesture);

    expect(queue.enqueuedSpecs, hasLength(1));
    expect(
      queue.enqueuedSpecs.single.destinationDir,
      '/srv/other/images',
    );
  });

  dndWidgets('a dragged selected row carries the whole selection in '
      'listing order', (tester) async {
    await bindLocals();
    // Sorted order is directories-first: docs, link, report.txt —
    // rows 0 and 2 select {docs, report.txt}, the grabbed row inside.
    left.setCursorIndex(0);
    left.setCursorIndex(2, update: SelectionUpdate.toggle);
    await pumpShell(tester);

    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      rightPaneBackground(tester),
    );
    await endDrag(tester, gesture);

    expect(queue.enqueuedSpecs, hasLength(1));
    expect(queue.enqueuedSpecs.single.rootPaths, [
      '/home/tester/docs',
      '/home/tester/report.txt',
    ]);
  });

  dndWidgets('a dragged unselected row inside a selection drags only '
      'itself', (tester) async {
    await bindLocals();
    // Sorted order docs, link, report.txt — range 0-1 selects
    // {docs, link}; 'report.txt' stays out.
    left.setCursorIndex(0);
    left.setCursorIndex(1, update: SelectionUpdate.range);
    await pumpShell(tester);

    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      rightPaneBackground(tester),
    );
    await endDrag(tester, gesture);

    expect(queue.enqueuedSpecs, hasLength(1));
    expect(queue.enqueuedSpecs.single.rootPaths, [
      '/home/tester/report.txt',
    ]);
  });

  dndWidgets('a drop on a scrolled listing resolves the rendered row, '
      'not the unscrolled index', (tester) async {
    // The right listing overflows: 'adir' is row 0 (dirs sort first),
    // sixty files push the viewport. Without the scroll offset in the
    // hit math a top-of-viewport drop would resolve to 'adir'.
    final leftChannel = controller_test.FakePaneChannel('/home/tester');
    leftChannel.listings['/home/tester'] = [
      _entryAt('/home/tester', 'report.txt', size: 2048),
    ];
    lanes.nextLocalChannel = leftChannel;
    await left.openLocalHome();

    rightChannel = controller_test.FakePaneChannel('/home/tester');
    rightChannel.listings['/srv/other'] = [
      _entryAt('/srv/other', 'adir', type: RemoteFileType.directory),
      for (var i = 0; i < 60; i++)
        _entryAt('/srv/other', 'f$i.txt', size: 64),
    ];
    lanes.nextLocalChannel = rightChannel;
    await right.openLocalAt('/srv/other');
    await pumpShell(tester);

    // Rows are a fixed 28px — scrolling ten rows in puts row 10 at the
    // viewport top; it is a file, so the drop must read current-dir.
    final rightPane = find.byWidgetPredicate(
      (w) => w is PaneView && w.controller == right,
    );
    // The pane carries two ListViews — the listing (vertical) and the
    // path-bar's segment strip (horizontal).
    final listing = find.descendant(
      of: rightPane,
      matching: find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.vertical,
      ),
    );
    tester.widget<ListView>(listing).controller!.jumpTo(28 * 10);
    await tester.pump();

    final listTop = tester.getTopLeft(listing);
    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      Offset(listTop.dx + 300, listTop.dy + 14),
    );
    await endDrag(tester, gesture);

    expect(queue.enqueuedSpecs, hasLength(1));
    expect(queue.enqueuedSpecs.single.destinationDir, '/srv/other');
  });

  dndWidgets('a drop onto the rows’ own directory refuses a move but '
      'accepts the copy modifier', (tester) async {
    await bindLocals();
    await pumpShell(tester);

    // Left's listing background == the rows' parent: a move is a no-op.
    final leftRect = tester.getRect(find.byType(PaneView).first);
    final leftBackground = Offset(
      leftRect.center.dx,
      leftRect.bottom - 60,
    );
    var gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      leftBackground,
    );
    await endDrag(tester, gesture);
    expect(queue.enqueuedSpecs, isEmpty);

    // Ctrl (Windows/Linux) forces the copy — the §5.2 conflict flow
    // answers the self-collision at run time.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      leftBackground,
    );
    await endDrag(tester, gesture);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(queue.enqueuedSpecs, hasLength(1));
    expect(
      queue.enqueuedSpecs.single.operation,
      TransferOperation.copy,
    );
    expect(
      queue.enqueuedSpecs.single.destinationDir,
      '/home/tester',
    );
  });

  dndWidgets('the move modifier forces a move across filesystems', (
    tester,
  ) async {
    await bindLocals();
    await bindRightRemote();
    await pumpShell(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      rightPaneBackground(tester),
    );
    await endDrag(tester, gesture);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(queue.enqueuedSpecs, hasLength(1));
    final spec = queue.enqueuedSpecs.single;
    expect(spec.operation, TransferOperation.move);
    expect(
      spec.destination,
      isA<ServerFsLocation>().having((s) => s.serverId, 'id', 'srv-1'),
    );
    expect(spec.destinationDir, '/srv/home');
  });

  dndWidgets('a local→remote drop defaults to copy and labels it an '
      'upload', (tester) async {
    await bindLocals();
    await bindRightRemote();
    await pumpShell(tester);

    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      rightPaneBackground(tester),
    );
    await tester.pump();
    expect(find.text('Upload to /srv/home'), findsOneWidget);
    await endDrag(tester, gesture);

    expect(
      queue.enqueuedSpecs.single.operation,
      TransferOperation.copy,
    );
  });

  dndWidgets('the hover overlay names the move verb on a folder row', (
    tester,
  ) async {
    await bindLocals();
    await pumpShell(tester);

    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      tester.getCenter(find.text('images')),
    );
    await tester.pump();
    expect(find.text('Move to /srv/other/images'), findsOneWidget);
    await endDrag(tester, gesture);
  });

  dndWidgets('macOS maps ⌥ to copy', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await bindLocals();
    await pumpShell(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      rightPaneBackground(tester),
    );
    await endDrag(tester, gesture);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

    expect(
      queue.enqueuedSpecs.single.operation,
      TransferOperation.copy,
    );
  });

  dndWidgets('a folder row held under a drag spring-loads open', (
    tester,
  ) async {
    await bindLocals();
    await pumpShell(tester);

    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      tester.getCenter(find.text('images')),
    );
    await tester.pump(const Duration(seconds: 1, milliseconds: 200));
    await tester.pump();

    expect(
      right.location,
      const LocalPaneLocation('/srv/other/images'),
    );
    await tester.pump();
    await endDrag(tester, gesture);

    // The drop lands in the spring-loaded directory.
    expect(queue.enqueuedSpecs, hasLength(1));
    expect(
      queue.enqueuedSpecs.single.destinationDir,
      '/srv/other/images',
    );
  });

  dndWidgets('a drag over a busy pane enqueues nothing', (tester) async {
    await bindLocals();
    await pumpShell(tester);

    // Park the right pane's next listing mid-flight.
    final hold = Completer<void>();
    rightChannel.holdNext = hold;
    right.navigate('/srv/other/images');
    await tester.pump();

    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      rightPaneBackground(tester),
    );
    await endDrag(tester, gesture);

    expect(queue.enqueuedSpecs, isEmpty);
    // Let the parked listing settle before teardown disposes the pane.
    hold.complete();
    await tester.pump();
  });

  dndWidgets('no queue seam mounts no row Draggables and accepts '
      'nothing', (tester) async {
    await bindLocals();
    await pumpShell(tester, withDelegate: false);

    expect(find.byType(Draggable<PaneEntryDrag>), findsNothing);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('report.txt')),
    );
    await tester.pump();
    await gesture.moveTo(rightPaneBackground(tester));
    await tester.pump();
    expect(find.byType(PaneEntryDragAvatar), findsNothing);
    await endDrag(tester, gesture);
    expect(queue.enqueuedSpecs, isEmpty);
  });

  dndWidgets('a hidden second pane mounts no drop target — a drag '
      'released over its space enqueues nothing', (tester) async {
    await bindLocals();
    // The shell unmounts a hidden pane whole (pane-toggle #139): this
    // fixture's SizedBox is exactly what the shell produces — no
    // DragTarget, no DropTarget, nothing to land on.
    await pumpShell(tester, rightHidden: true);

    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      const Offset(1050, 400),
    );
    await endDrag(tester, gesture);

    expect(queue.enqueuedSpecs, isEmpty);
    // The OS channel sees the same absence: the hidden pane's
    // DropTarget never subscribed.
    await _osDropAt(tester, const Offset(1050, 400), [
      '/tmp/incoming.txt',
    ]);
    expect(queue.enqueuedSpecs, isEmpty);
  });

  dndWidgets('OS drop-in copies into the pane’s current directory', (
    tester,
  ) async {
    await bindLocals();
    await pumpShell(tester);

    await _osDropAt(tester, rightPaneBackground(tester), [
      '/tmp/incoming.txt',
      '/tmp/photo.png',
    ]);

    expect(queue.enqueuedSpecs, hasLength(1));
    final spec = queue.enqueuedSpecs.single;
    expect(spec.operation, TransferOperation.copy);
    expect(spec.rootPaths, ['/tmp/incoming.txt', '/tmp/photo.png']);
    expect(spec.destinationDir, '/srv/other');
  });

  dndWidgets('OS drop-in onto a folder row lands in that folder', (
    tester,
  ) async {
    await bindLocals();
    await pumpShell(tester);

    await _osDropAt(
      tester,
      tester.getCenter(find.text('images')),
      ['/tmp/incoming.txt'],
    );

    expect(queue.enqueuedSpecs, hasLength(1));
    expect(
      queue.enqueuedSpecs.single.destinationDir,
      '/srv/other/images',
    );
  });

  dndWidgets('OS drop hover shows the copy label and clears on exit', (
    tester,
  ) async {
    await bindLocals();
    await pumpShell(tester);

    final at = rightPaneBackground(tester);
    await _osChannel(tester, 'entered', [at.dx, at.dy]);
    expect(find.text('Copy to /srv/other'), findsOneWidget);
    await _osChannel(tester, 'exited', null);
    expect(find.text('Copy to /srv/other'), findsNothing);
  });

  dndWidgets('an OS drop onto its own source path enqueues nothing', (
    tester,
  ) async {
    await bindLocals();
    await pumpShell(tester);

    // Copying '/srv/other/images' onto '/srv/other/images' itself is a
    // self-containment refusal.
    await _osDropAt(
      tester,
      tester.getCenter(find.text('images')),
      ['/srv/other/images'],
    );
    expect(queue.enqueuedSpecs, isEmpty);
  });

  dndWidgets('a paused ticker disables the OS drop target', (
    tester,
  ) async {
    await bindLocals();
    await pumpShell(tester, tickerEnabled: false);

    await _osDropAt(tester, rightPaneBackground(tester), [
      '/tmp/incoming.txt',
    ]);
    expect(queue.enqueuedSpecs, isEmpty);
  });

  dndWidgets('a pushed route disables the OS drop target', (
    tester,
  ) async {
    await bindLocals();
    await pumpShell(tester);

    // The covering route makes the pane tree offstage — the drop point
    // has to be captured before the push (finders skip offstage).
    final at = rightPaneBackground(tester);
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('covering')),
          ),
        );
    await tester.pumpAndSettle();

    await _osDropAt(tester, at, ['/tmp/incoming.txt']);
    expect(queue.enqueuedSpecs, isEmpty);
  });

  dndWidgets('supportsOsDrop:false mounts no DropTarget', (tester) async {
    await bindLocals();
    await pumpShell(tester, supportsOsDrop: false);

    expect(find.byType(DropTarget), findsNothing);
    await _osDropAt(tester, rightPaneBackground(tester), [
      '/tmp/incoming.txt',
    ]);
    expect(queue.enqueuedSpecs, isEmpty);
  });

  dndWidgets('a mobile platform mounts no DropTarget and no row '
      'Draggables', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await bindLocals();
    await pumpShell(tester);

    expect(find.byType(DropTarget), findsNothing);
    expect(find.byType(Draggable<PaneEntryDrag>), findsNothing);
  });

  dndWidgets('a drop on a tab header lands in that tab’s current '
      'directory', (tester) async {
    await bindLocals();
    final second = PaneController(
      paneTabId: 'pane.right.tab2',
      lanes: lanes,
    );
    rightStrip.addTab(second);
    final secondChannel =
        controller_test.FakePaneChannel('/home/tester');
    secondChannel.listings['/srv/else'] = [
      _entryAt('/srv/else', 'readme.md'),
    ];
    lanes.nextLocalChannel = secondChannel;
    await second.openLocalAt('/srv/else');
    // The first tab stays active — the chip under test is inactive.
    rightStrip.activateTab(rightStrip.tabs.first);
    await pumpShell(tester, rightTabs: true);

    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      tester.getCenter(find.text('else')),
    );
    await endDrag(tester, gesture);

    expect(queue.enqueuedSpecs, hasLength(1));
    expect(queue.enqueuedSpecs.single.destinationDir, '/srv/else');
  });

  dndWidgets('a drag hovering a tab header for 700 ms activates it', (
    tester,
  ) async {
    await bindLocals();
    final second = PaneController(
      paneTabId: 'pane.right.tab2',
      lanes: lanes,
    );
    final secondTab = rightStrip.addTab(second);
    final secondChannel =
        controller_test.FakePaneChannel('/home/tester');
    secondChannel.listings['/srv/else'] = [
      _entryAt('/srv/else', 'readme.md'),
    ];
    lanes.nextLocalChannel = secondChannel;
    await second.openLocalAt('/srv/else');
    rightStrip.activateTab(rightStrip.tabs.first);
    await pumpShell(tester, rightTabs: true);
    expect(rightStrip.activeTab, isNot(secondTab));

    final gesture = await dragRowOnto(
      tester,
      find.text('report.txt'),
      tester.getCenter(find.text('else')),
    );
    // Below the 700 ms dwell the tab must NOT have switched — an
    // instant switch under a passing drag is the regression this pins.
    await tester.pump(const Duration(milliseconds: 600));
    expect(rightStrip.activeTab, isNot(secondTab));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(rightStrip.activeTab, secondTab);
    await endDrag(tester, gesture);
  });
}
