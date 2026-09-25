import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

RemoteFileEntry _entry(
  String name, {
  String parent = '/home/tester',
  RemoteFileType type = RemoteFileType.file,
}) {
  return RemoteFileEntry(
    path: '$parent/$name',
    name: name,
    type: type,
    size: type == RemoteFileType.file ? 10 : null,
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
    remotePath: '/',
    sortKey: 'k',
    createdAt: now,
    updatedAt: now,
  );
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

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    leftStrip = testPaneStrip(left);
    rightStrip = testPaneStrip(right);
    workspace = WorkspaceController(left: leftStrip, right: rightStrip);
    leftNode = FocusNode();
    rightNode = FocusNode();
  });

  tearDown(() {
    workspace.dispose();
    leftNode.dispose();
    rightNode.dispose();
  });

  /// A five-row local listing: dirs alpha/omega first, then files.
  List<RemoteFileEntry> fiveRows() => [
    _entry('alpha', type: RemoteFileType.directory),
    _entry('omega', type: RemoteFileType.directory),
    _entry('a.txt'),
    _entry('m.txt'),
    _entry('z.txt'),
  ];

  Future<void> pumpPanes(WidgetTester tester, {bool withChords = false}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final panes = Row(
      children: [
        Expanded(
          child: PaneView(
            controller: left,
            pane: leftStrip,
            workspace: workspace,
            focusNode: leftNode,
            onSwapFocus: () => rightNode.requestFocus(),
            onCancelRecovery: () => unawaited(left.cancelRecovery()),
          ),
        ),
        Expanded(
          child: PaneView(
            controller: right,
            pane: rightStrip,
            workspace: workspace,
            focusNode: rightNode,
            onSwapFocus: () => leftNode.requestFocus(),
            onCancelRecovery: () => unawaited(right.cancelRecovery()),
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        // D32 §6's pointer semantics are the desktop ones (select on
        // press, double-click opens); touch platforms open on tap. The
        // suite pins a desktop theme unless a test overrides the host.
        theme: ThemeData(
          platform: debugDefaultTargetPlatformOverride ?? TargetPlatform.linux,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: withChords
              ? CommandChordScope(
                  commands: buildPaneCommands(
                    workspace: workspace,
                    focusLeft: () => leftNode.requestFocus(),
                    focusRight: () => rightNode.requestFocus(),
                    swapFocus: () {
                      final target = workspace.swapFocus();
                      if (identical(target, right)) {
                        rightNode.requestFocus();
                      } else {
                        leftNode.requestFocus();
                      }
                    },
                  ),
                  child: panes,
                )
              : panes,
        ),
      ),
    );
  }

  Future<controller_test.FakePaneChannel> openFiveRows({
    PaneController? pane,
  }) async {
    final target = pane ?? left;
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = fiveRows();
    lanes.nextLocalChannel = channel;
    await target.openLocalHome();
    return channel;
  }

  /// Clicks a listing row, then lets the double-click window lapse so
  /// the next click on the same row is a fresh single click (D32 §6:
  /// the press selects at once; only the window needs waiting out).
  Future<void> tapRow(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
  }

  Set<int> selectedOf(PaneController pane) {
    final selected = <int>{};
    for (var i = 0; i < pane.entries.length; i++) {
      if (pane.isRowSelected(i)) selected.add(i);
    }
    return selected;
  }

  testWidgets('shift-click keeps the range when Shift is released inside '
      'the double-tap window', (tester) async {
    await openFiveRows();
    await pumpPanes(tester);

    // Plain-select the first row.
    await tapRow(tester, find.text('alpha'));
    expect(selectedOf(left), {0});

    // Shift-click m.txt, releasing Shift BEFORE the tap commits (rows
    // carry both onTap and onDoubleTap, so the single tap waits out
    // kDoubleTapTimeout): the gesture must still extend the range —
    // sampling modifiers at commit time would collapse it to a single.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('m.txt')),
    );
    await gesture.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));

    expect(selectedOf(left), {0, 1, 2, 3});
    expect(left.cursorIndex, 3);
  });

  testWidgets('a Shift pressed only after pointer-down single-selects', (
    tester,
  ) async {
    await openFiveRows();
    await pumpPanes(tester);
    await tapRow(tester, find.text('alpha'));
    expect(selectedOf(left), {0});

    // Press Shift AFTER pointer-down but before the tap commits: the
    // gesture's modifiers were captured at down, so this is a plain
    // single-select — never a range (commit-time sampling would extend).
    final lateShift = await tester.startGesture(
      tester.getCenter(find.text('m.txt')),
    );
    await lateShift.up();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(selectedOf(left), {3});
    expect(left.cursorIndex, 3);
  });

  testWidgets('a plain click single-selects the clicked row', (tester) async {
    await openFiveRows();
    await pumpPanes(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tapRow(tester, find.text('m.txt'));
    await tester.pump();

    expect(left.cursorIndex, 3);
    expect(selectedOf(left), {3});

    // A plain click on another row replaces the selection.
    await tapRow(tester, find.text('a.txt'));
    await tester.pump();
    expect(selectedOf(left), {2});
  });

  testWidgets('meta-click toggles on macOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await openFiveRows();
      await pumpPanes(tester);

      await tapRow(tester, find.text('a.txt'));
      await tester.pump();
      expect(selectedOf(left), {2});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tapRow(tester, find.text('m.txt'));
      await tester.pump();
      expect(selectedOf(left), {2, 3});

      // Meta-clicking a selected row removes it.
      await tapRow(tester, find.text('a.txt'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(selectedOf(left), {3});
      expect(left.cursorIndex, 2);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('control-click toggles on Windows and Linux', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await openFiveRows();
      await pumpPanes(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tapRow(tester, find.text('a.txt'));
      await tester.pump();
      await tapRow(tester, find.text('m.txt'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(selectedOf(left), {2, 3});

      // Control is the toggle modifier off macOS: a second control-click
      // removes the row again.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tapRow(tester, find.text('a.txt'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(selectedOf(left), {3});
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('control-click does not toggle on macOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await openFiveRows();
      await pumpPanes(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tapRow(tester, find.text('a.txt'));
      await tester.pump();
      await tapRow(tester, find.text('m.txt'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // Ctrl is not macOS's toggle modifier: each activation singles.
      expect(selectedOf(left), {3});
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('shift-click extends and shrinks the anchored range', (
    tester,
  ) async {
    await openFiveRows();
    await pumpPanes(tester);

    await tapRow(tester, find.text('alpha'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tapRow(tester, find.text('m.txt'));
    await tester.pump();
    expect(selectedOf(left), {0, 1, 2, 3});

    // Shrink back toward the anchor.
    await tapRow(tester, find.text('a.txt'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(selectedOf(left), {0, 1, 2});
    expect(left.cursorIndex, 2);
  });

  testWidgets('plain arrows single-select; shift arrows extend', (
    tester,
  ) async {
    await openFiveRows();
    await pumpPanes(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(left.cursorIndex, 0);
    expect(selectedOf(left), {0});

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(selectedOf(left), {1}, reason: 'plain movement singles');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(left.cursorIndex, 3);
    expect(selectedOf(left), {1, 2, 3});

    // Shrink back up across the anchor.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(selectedOf(left), {1, 2});
  });

  testWidgets('Home and End keep plain behavior and extend with shift', (
    tester,
  ) async {
    await openFiveRows();
    await pumpPanes(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(left.cursorIndex, 4);
    expect(selectedOf(left), {4}, reason: 'plain End singles the last row');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(left.cursorIndex, 0);
    expect(selectedOf(left), {
      0,
      1,
      2,
      3,
      4,
    }, reason: 'shift+Home spans back to the anchor at the end');

    // The anchor never moved: shift+End re-collapses onto it.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(selectedOf(left), {4});
    expect(left.cursorIndex, 4);

    // Re-anchored at the first row, shift+End spans the whole listing.
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(selectedOf(left), {0}, reason: 'plain Home singles the first row');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(selectedOf(left), {0, 1, 2, 3, 4});
    expect(left.cursorIndex, 4);
  });

  testWidgets('keyboard repeats keep extending the range', (tester) async {
    await openFiveRows();
    await pumpPanes(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(selectedOf(left), {0});

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(left.cursorIndex, 2);
    expect(selectedOf(left), {0, 1, 2});
  });

  testWidgets('selected rows and the cursor render distinct surfaces', (
    tester,
  ) async {
    await openFiveRows();
    await pumpPanes(tester);
    leftNode.requestFocus();
    await tester.pump();

    // A row's fill is its background DecoratedBox; the cursor ring is
    // the foreground one (it never shifts the row's layout).
    Iterable<BoxDecoration> rowDecorations(String name) => tester
        .widgetList<DecoratedBox>(
          find.ancestor(of: find.text(name), matching: find.byType(DecoratedBox)),
        )
        .map((box) => box.decoration)
        .whereType<BoxDecoration>();
    Color? rowSurface(String name) =>
        rowDecorations(name).map((d) => d.color).nonNulls.firstOrNull;
    bool hasCursorRing(String name) =>
        rowDecorations(name).any((d) => d.border != null);

    // alpha, omega, and a.txt are selected (the range); a.txt is the
    // cursor at the range's far end.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    // Rows sort alpha(0), omega(1), a.txt(2), m.txt(3), z.txt(4).
    final selectedSurface = rowSurface('alpha');
    expect(selectedSurface, isNotNull);
    expect(rowSurface('omega'), selectedSurface);
    // D32 §6: every selected row — the cursor's included — takes the
    // one selection fill; an unselected row paints none.
    expect(rowSurface('a.txt'), selectedSurface);
    expect(rowSurface('z.txt'), isNull);

    // The cursor's shape marker: only the cursor row carries the ring
    // (inside a multi-selection the fill alone cannot name it).
    expect(hasCursorRing('a.txt'), isTrue);
    expect(hasCursorRing('alpha'), isFalse);
    expect(hasCursorRing('omega'), isFalse);
    expect(hasCursorRing('m.txt'), isFalse);
    expect(hasCursorRing('z.txt'), isFalse);

    // A lone selected cursor row is its own marker — no ring.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(left.selectedCount, 1);
    expect(hasCursorRing('m.txt'), isFalse);
  });

  testWidgets('selected rows expose the selected semantics flag', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await openFiveRows();
      await pumpPanes(tester);
      leftNode.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      final selectedData = tester
          .getSemantics(find.bySemanticsLabel(RegExp(r'^alpha, folder, —, —$')))
          .getSemanticsData();
      expect(selectedData.flagsCollection.isSelected, ui.Tristate.isTrue);

      final unselectedData = tester
          .getSemantics(
            find.bySemanticsLabel(RegExp(r'^z\.txt, file, 10 B, —$')),
          )
          .getSemanticsData();
      expect(unselectedData.flagsCollection.isSelected, ui.Tristate.isFalse);

      // A toggled-off row keeps the cursor but is no longer selected:
      // the announced flag follows the selection, never the cursor.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tapRow(tester, find.text('a.txt'));
      await tapRow(tester, find.text('a.txt'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(left.cursorIndex, 2);
      expect(left.isRowSelected(2), isFalse);

      final toggledOff = tester
          .getSemantics(
            find.bySemanticsLabel(RegExp(r'^a\.txt, file, 10 B, —$')),
          )
          .getSemanticsData();
      expect(toggledOff.flagsCollection.isSelected, ui.Tristate.isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      semantics.dispose();
    }
  });

  testWidgets('selection is inert under the error overlay', (tester) async {
    final channel = await openFiveRows();
    await pumpPanes(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tapRow(tester, find.text('a.txt'));
    await tester.pump();
    expect(selectedOf(left), {2});

    // A same-location refresh that fails keeps the cached rows; the
    // selection stays but must be inert under the overlay.
    channel.listingFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.permissionDenied,
      operation: 'list',
      message: 'Denied',
    );
    left.refresh();
    await tester.pumpAndSettle();
    expect(left.error, isNotNull);
    expect(selectedOf(left), {
      2,
    }, reason: 'the cached selection survives the failed refresh');

    // Keys are consumed by the inert gate; taps cannot reach the rows.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('m.txt'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(left.cursorIndex, 2);
    expect(
      selectedOf(left),
      {2},
      reason:
          'the stale selection must not '
          'change while the overlay owns the pane',
    );

    // The error shield is scoped to the listing subtree: the location
    // header's ancestor menu stays a recovery path while the error
    // shows.
    channel.listingFailure = null;
    channel.listings['/home'] = [
      _entry('tester', parent: '/home', type: RemoteFileType.directory),
    ];
    await tester.tap(find.byKey(const ValueKey('pane.left.path.ancestors')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pane.left.path.ancestor.0')));
    await tester.pumpAndSettle();
    expect(left.error, isNull, reason: 'the ancestor menu navigated away');
    expect(left.location?.path, '/home');
  });

  testWidgets('selection is inert while connection-lost', (tester) async {
    final remote = controller_test.FakePaneChannel('/srv/home');
    remote.listings['/srv/home'] = [
      _entry('r1', parent: '/srv/home'),
      _entry('r2', parent: '/srv/home'),
      _entry('r3', parent: '/srv/home'),
    ];
    lanes.nextRemoteChannel = remote;
    final connecting = right.connectRemote(_bookmark('srv-1'));
    await pumpPanes(tester);
    rightNode.requestFocus();
    await tester.pump();
    await connecting;
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(selectedOf(right), {0, 1});

    lanes.emitState(
      'srv-1',
      const ServerStatus(ServerConnectionState.reconnecting),
    );
    await tester.pump();
    await tester.pump();
    expect(right.connectionLost, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(
      selectedOf(right),
      {0, 1},
      reason:
          'keys over stale rows under '
          'the loss banner must not move selection',
    );
    expect(right.cursorIndex, 1);
  });

  testWidgets('Ctrl+A selects all rows of the active pane only', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await openFiveRows();
      await openFiveRows(pane: right);
      await pumpPanes(tester, withChords: true);
      leftNode.requestFocus();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(selectedOf(left), {0, 1, 2, 3, 4});
      expect(
        selectedOf(right),
        isEmpty,
        reason: 'select-all resolves the active pane, never both',
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(selectedOf(left), isEmpty, reason: 'invert complements');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Cmd+A selects all on macOS; Cmd+Shift+I inverts', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await openFiveRows();
      await pumpPanes(tester, withChords: true);
      leftNode.requestFocus();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(selectedOf(left), {0, 1, 2, 3, 4});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(selectedOf(left), isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Ctrl+A keeps acting on the active pane when the right '
      'pane is active', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await openFiveRows();
      await openFiveRows(pane: right);
      await pumpPanes(tester, withChords: true);
      rightNode.requestFocus();
      await tester.pump();
      expect(workspace.activePane, rightStrip);

      // The chord resolves the ACTIVE pane — here the right one — from
      // the workspace, regardless of which pane last took focus.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(selectedOf(right), {0, 1, 2, 3, 4});
      expect(selectedOf(left), isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a focused TextField on a covering route suppresses '
      'select-all', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await openFiveRows();
      await pumpPanes(tester, withChords: true);
      leftNode.requestFocus();
      await tester.pump();

      // A covering route whose field owns primary focus: the field's own
      // shortcuts win and the pane's chord layer never sees Ctrl+A.
      final navContext = tester.element(find.byType(PaneView).first);
      unawaited(
        Navigator.of(navContext).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(24),
                child: TextField(
                  autofocus: true,
                  decoration: InputDecoration(labelText: 'Filter'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(leftNode.hasPrimaryFocus, isFalse);

      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(
        selectedOf(left),
        isEmpty,
        reason:
            'a focused text field owns Ctrl+A; the pane command '
            'must not fire',
      );
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.controller.selection.baseOffset, 0);
      expect(
        field.controller.selection.extentOffset,
        3,
        reason: 'the field performed its own select-all',
      );

      // Below the cover the chord works again.
      Navigator.of(navContext).pop();
      await tester.pumpAndSettle();
      leftNode.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(selectedOf(left), {0, 1, 2, 3, 4});
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
