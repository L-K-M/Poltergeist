import 'dart:async';

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/quick_select_state.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
  DateTime? modified,
}) {
  return RemoteFileEntry(
    path: '/home/tester/$name',
    name: name,
    type: type,
    size: size,
    modifiedAt: modified,
  );
}

Bookmark _bookmark(String id, {String remotePath = '/'}) {
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
    remotePath: remotePath,
    sortKey: id,
    createdAt: now,
    updatedAt: now,
  );
}

/// Fixed clock so date rendering never depends on the host calendar.
DateTime _fixedClock() => DateTime(2026, 9, 15, 10);

void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController left;
  late PaneController right;
  late PaneTabsController leftStrip;
  late PaneTabsController rightStrip;
  late WorkspaceController workspace;
  late FocusNode leftNode;
  late FocusNode rightNode;

  DateTime Function() clock = _fixedClock;

  setUp(() {
    clock = _fixedClock;
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


  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: PaneView(
                  controller: left,
                  pane: leftStrip,
                  workspace: workspace,
                  focusNode: leftNode,
                  onSwapFocus: () => rightNode.requestFocus(),
                  onCancelRecovery: () => unawaited(left.cancelRecovery()),
                  clock: clock,
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
                  clock: clock,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  controller_test.FakePaneChannel localChannelWithEntries() {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry(
        'docs',
        type: RemoteFileType.directory,
        modified: DateTime(2026, 9, 10, 14, 32),
      ),
      _entry(
        'report.txt',
        size: 2048,
        modified: DateTime(2026, 9, 11, 9, 5),
      ),
      _entry('link', type: RemoteFileType.symbolicLink),
    ];
    channel.listings['/home/tester/docs'] = [_entry('nested.txt', size: 3)];
    lanes.nextLocalChannel = channel;
    return channel;
  }

  testWidgets('loss owns the overlay until a healed listing succeeds', (tester) async {
    final channel = controller_test.FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('cached.txt')];
    lanes.nextRemoteChannel = channel;
    await right.connectRemote(_bookmark('srv-1'));
    await pumpShell(tester);
    lanes.emitState('srv-1', const ServerStatus(ServerConnectionState.reconnecting));
    await tester.pump();
    expect(find.text('cached.txt'), findsOneWidget);
    expect(find.byKey(const ValueKey('pane.banner')), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('cached.txt')).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(find.byKey(const ValueKey('pane.banner'))).dy),
      reason: 'the banner must not cover the cached first row',
    );
    expect(find.byKey(const ValueKey('pane.error.retry')), findsNothing,
        reason: 'the loss error is rendered as the banner, never another overlay');

    final held = Completer<void>();
    channel.holdNext = held;
    lanes.emitState('srv-1', const ServerStatus(ServerConnectionState.connected));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final scrims = tester.widgetList<ColoredBox>(find.byType(ColoredBox))
        .where((box) => box.color.a == 0.6);
    expect(scrims, hasLength(1), reason: 'loss and loading must not stack dims');
    expect(find.byKey(const ValueKey('pane.banner')), findsOneWidget);
    channel.listingFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.permissionDenied, operation: 'list', message: 'Denied',
    );
    held.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pane.error.retry')), findsNothing);
    expect(find.byKey(const ValueKey('pane.banner.retry')), findsOneWidget);

    final healed = controller_test.FakePaneChannel('/srv/home');
    healed.listings['/srv/home'] = [_entry('fresh.txt')];
    lanes.nextRemoteChannel = healed;
    await tester.tap(find.byKey(const ValueKey('pane.banner.retry')));
    await tester.pumpAndSettle();
    expect(find.text('fresh.txt'), findsOneWidget);
    expect(find.byKey(const ValueKey('pane.banner')), findsNothing);
    expect(channel.closeCalls, 1);
  });

  testWidgets('one banner slot: lost connection outranks a notice, which '
      'outranks the save-favorite bar', (tester) async {
    final channel = controller_test.FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('cached.txt')];
    lanes.nextRemoteChannel = channel;
    await right.connectRemote(_bookmark('adhoc:one'));
    await pumpShell(tester);
    final saveBar = find.byKey(const ValueKey('saveFavorite.bar'));
    final notice = find.byKey(const ValueKey('pane.right.notice.dismiss'));
    final lost = find.byKey(const ValueKey('pane.banner'));
    expect(saveBar, findsOneWidget);

    right.notePathCopied();
    await tester.pump();
    expect(notice, findsOneWidget);
    expect(saveBar, findsNothing, reason: 'one banner at a time');

    lanes.emitState(
      'adhoc:one',
      const ServerStatus(ServerConnectionState.reconnecting),
    );
    await tester.pump();
    expect(lost, findsOneWidget);
    expect(notice, findsNothing);
    expect(saveBar, findsNothing);

    // The notice expires; the save bar keeps its slot below the loss.
    await tester.pump(const Duration(seconds: 5));
    expect(lost, findsOneWidget);
    expect(saveBar, findsNothing);
  });

  testWidgets('renders a local listing: name, kind glyph, size, mtime', (
    tester,
  ) async {
    final channel = localChannelWithEntries();
    await left.openLocalHome();
    await pumpShell(tester);

    expect(find.text('docs'), findsOneWidget);
    expect(find.text('report.txt'), findsOneWidget);
    expect(find.text('link'), findsOneWidget);
    // Directory size renders the dash (docs), and the link carries no
    // metadata at all (a size and a date dash); the file renders its size.
    expect(find.text('—'), findsNWidgets(3));
    expect(find.text('2 KB'), findsOneWidget);
    // Absolute dates render next to the rows.
    expect(find.textContaining('9/10/2026'), findsOneWidget);
    expect(find.textContaining('9/11/2026'), findsOneWidget);
    // Links carry null metadata: no date cell content beyond the dash.
    expect(channel.listCalls, ['/home/tester']);
  });

  testWidgets('rows render in natural name order, directories first',
      (tester) async {
    final channel = localChannelWithEntries();
    channel.listings['/home/tester'] = [
      _entry('file10'),
      _entry('file1'),
      _entry('file2'),
      _entry('alpha'),
    ];
    await left.openLocalHome();
    await pumpShell(tester);

    // The displayed order is the pane's accepted listing order (02 §2.3's
    // natural names), read back from the laid-out rows themselves.
    double rowY(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(rowY('alpha'), lessThan(rowY('file1')));
    expect(rowY('file1'), lessThan(rowY('file2')));
    expect(rowY('file2'), lessThan(rowY('file10')));
  });

  testWidgets('renders a remote listing through the browse-channel seam', (
    tester,
  ) async {
    final channel = controller_test.FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [
      _entry('index.html', size: 512, modified: DateTime(2026, 9, 1, 8, 0)),
    ];
    lanes.nextRemoteChannel = channel;
    await right.connectRemote(_bookmark('srv-1'));
    await pumpShell(tester);

    expect(find.text('index.html'), findsOneWidget);
    expect(find.text('512 B'), findsOneWidget);
  });

  testWidgets('empty folder renders the empty state, never blank', (
    tester,
  ) async {
    localChannelWithEntries().listings['/home/tester'] = const [];
    await left.openLocalHome();
    await pumpShell(tester);

    expect(find.text('This folder is empty.'), findsOneWidget);
  });

  testWidgets('taxonomy errors render inline with Retry over stale entries',
      (tester) async {
    final channel = localChannelWithEntries();
    await left.openLocalHome();
    await pumpShell(tester);

    left.navigate('/home/tester/gone');
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be found'), findsOneWidget);
    // The engine's diagnostic line rides under the ARB sentence.
    expect(find.textContaining('Could not list "/home/tester/gone"'),
        findsOneWidget);
    // Cached data stays visible under the error.
    expect(find.text('report.txt'), findsOneWidget);
    expect(find.byKey(const ValueKey('pane.error.retry')), findsOneWidget);

    channel.listings['/home/tester/gone'] = [_entry('back.txt')];
    await tester.tap(find.byKey(const ValueKey('pane.error.retry')));
    await tester.pumpAndSettle();
    expect(find.text('back.txt'), findsOneWidget);
    expect(find.textContaining('could not be found'), findsNothing);
  });

  testWidgets('loading stays silent before the 150 ms anti-flash grace', (
    tester,
  ) async {
    final channel = localChannelWithEntries();
    await left.openLocalHome();
    await pumpShell(tester);
    expect(find.byKey(const ValueKey('pane.left.progress')), findsNothing);

    final hold = Completer<void>();
    channel.holdNext = hold;
    channel.listings['/home/tester/docs'] = [_entry('one.txt')];
    left.navigate('/home/tester/docs');
    await tester.pump();

    // Sub-150 ms: no progress line, no dim, footer keeps its counts.
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('pane.left.progress')), findsNothing);
    expect(find.textContaining('3 items'), findsOneWidget);

    // Past the grace: progress line, dim over the old listing, footer swaps.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('pane.left.progress')), findsOneWidget);
    expect(find.textContaining('Esc cancels'), findsOneWidget);
    expect(find.textContaining('3 items'), findsNothing);

    hold.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pane.left.progress')), findsNothing);
    expect(find.textContaining('1 item'), findsOneWidget);
  });

  testWidgets('stale rows are inert before the anti-flash dim appears', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final channel = localChannelWithEntries();
      channel.listings['/elsewhere'] = [_entry('there.txt', size: 7)];
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();
      expect(
        find.semantics.byLabel(RegExp(r'^report\.txt')),
        findsOne,
        reason: 'the live listing announces its rows before the navigation',
      );

      // The listing of a different directory is held: the old rows stay
      // rendered — the §2.8 grace governs PRESENTATION, but the pane has
      // already disowned them, so row interaction is inert from t=0.
      final hold = Completer<void>();
      channel.holdNext = hold;
      left.navigate('/elsewhere');
      await tester.pump();
      expect(left.staleRows, isTrue);

      // The rows leaving the semantics tree is not silent: a polite live
      // region announces the transition from t=0, before the grace dim.
      expect(
        find.semantics.byLabel(RegExp(r'^Loading elsewhere')),
        findsOne,
        reason: 'AT hears the load start while the rows are disowned',
      );

      // t=0: Enter on a stale row and a cursor key are already inert —
      // activation cannot supersede the pending navigation.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(channel.listCalls, ['/home/tester', '/elsewhere']);
      expect(left.location, const LocalPaneLocation('/elsewhere'));
      expect(left.cursorIndex, isNull);

      // Still inside the grace: no progress line, no dim, footer keeps
      // its counts — the cached rows look exactly as before.
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('pane.left.progress')), findsNothing);
      expect(find.text('report.txt'), findsOneWidget);
      expect(find.textContaining('3 items'), findsOneWidget);
      // …but they already left the semantics tree: a reachable-but-inert
      // row would read as broken to AT activation.
      expect(
        find.semantics.byLabel(RegExp(r'^report\.txt')),
        findsNothing,
        reason: 'stale rows leave the semantics tree at issue, not when '
            'the dim appears',
      );

      // Keyboard, type-ahead, and pointer gestures over cached rows are
      // all inert: no throw, no cursor, no selection, no activation.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.tap(find.text('report.txt'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 100));

      expect(left.cursorIndex, isNull);
      expect(left.selectedCount, 0);
      expect(left.typeAheadActive, isFalse);
      expect(
        channel.listCalls,
        ['/home/tester', '/elsewhere'],
        reason: 'stale input must never issue another listing request',
      );
      expect(left.location, const LocalPaneLocation('/elsewhere'));

      // A stale double-tap cannot hijack the pending navigation either
      // (the grace may have elapsed by now — the rows stay inert under
      // the dim too).
      await tester.tap(find.text('docs'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('docs'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(channel.listCalls, ['/home/tester', '/elsewhere']);
      expect(left.location, const LocalPaneLocation('/elsewhere'));

      // Esc still cancels back to the old listing, which owns its rows
      // again: the next cursor key lands.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(left.staleRows, isFalse);
      expect(left.location, const LocalPaneLocation('/home/tester'));
      expect(find.text('report.txt'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(left.cursorIndex, 0);

      hold.complete();
      await tester.pumpAndSettle();
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a failed navigation quiets the loading announcement', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final channel = localChannelWithEntries();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      final hold = Completer<void>();
      channel.holdNext = hold;
      left.navigate('/elsewhere');
      await tester.pump();
      expect(
        find.semantics.byLabel(RegExp(r'^Loading elsewhere')),
        findsOne,
      );

      // The navigation FAILS: the error card replaces the loading state.
      // The stale rows remain disowned (staleRows stays true) but the
      // pane is no longer loading — keeping a "Loading" live region
      // would announce a load that already failed to AT users.
      channel.listingFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'list',
        message: 'Not found',
      );
      hold.complete();
      await tester.pumpAndSettle();

      expect(left.error, isNotNull);
      expect(left.staleRows, isTrue);
      expect(
        find.semantics.byLabel(RegExp(r'^Loading')),
        findsNothing,
        reason: 'a failed navigation must not keep a "Loading" '
            'announcement live under the error card',
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a re-navigation from the error state still announces', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final channel = localChannelWithEntries();
      channel.listings['/elsewhere'] = [_entry('there.txt', size: 7)];
      channel.listings['/another'] = [_entry('other.txt', size: 9)];
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      // The first navigation fails: the error card stands and the
      // announcement is quiet.
      channel.listingFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'list',
        message: 'Not found',
      );
      left.navigate('/elsewhere');
      await tester.pumpAndSettle();
      expect(left.error, isNotNull);
      expect(
        left.staleRows,
        isTrue,
        reason: 'the error path keeps the old rows disowned; the '
            'same-target retry below announces only because of this',
      );
      expect(find.semantics.byLabel(RegExp(r'^Loading')), findsNothing);

      // A fresh navigation issued straight from the error card clears
      // the error at issue, so the next flight announces normally.
      channel.listingFailure = null;
      var hold = Completer<void>();
      channel.holdNext = hold;
      left.navigate('/another');
      await tester.pump();
      expect(
        find.semantics.byLabel(RegExp(r'^Loading another')),
        findsOne,
        reason: 'a navigation issued from the error state clears the '
            'error at issue, so its announcement is not muted',
      );
      hold.complete();
      await tester.pumpAndSettle();
      expect(left.error, isNull);
      expect(find.text('other.txt'), findsOneWidget);

      // The same-target retry: a failed destination stays the
      // location, so the retry's issue skips the disown block — but
      // the error clear at issue is unconditional, so this flight
      // announces too.
      channel.listingFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'list',
        message: 'Not found',
      );
      left.navigate('/elsewhere');
      await tester.pumpAndSettle();
      expect(left.error, isNotNull);
      expect(left.location, const LocalPaneLocation('/elsewhere'));
      expect(left.staleRows, isTrue);

      channel.listingFailure = null;
      hold = Completer<void>();
      channel.holdNext = hold;
      left.navigate('/elsewhere');
      await tester.pump();
      expect(
        find.semantics.byLabel(RegExp(r'^Loading elsewhere')),
        findsOne,
        reason: 'a same-target retry announces its load even though '
            'the disown block is skipped',
      );
      hold.complete();
      await tester.pumpAndSettle();
      expect(find.text('there.txt'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('Esc cancels an in-flight navigation back to the old listing', (
    tester,
  ) async {
    final channel = localChannelWithEntries();
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    final hold = Completer<void>();
    channel.holdNext = hold;
    left.navigate('/home/tester/docs');
    await tester.pump(const Duration(milliseconds: 300));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(left.loading, isFalse);
    expect(left.location, const LocalPaneLocation('/home/tester'));
    expect(find.text('report.txt'), findsOneWidget);

    // The late engine answer must not repaint the cancelled listing.
    hold.complete();
    await tester.pumpAndSettle();
    expect(find.text('nested.txt'), findsNothing);
    expect(find.text('report.txt'), findsOneWidget);
  });

  Future<void> arrowEnterBackspaceExercise(WidgetTester tester) async {
    localChannelWithEntries();
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(left.cursorIndex, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(left.cursorIndex, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(left.cursorIndex, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    expect(left.cursorIndex, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    expect(left.cursorIndex, 0);

    // Enter opens the selected directory (Windows/Linux muscle memory).
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(left.location, const LocalPaneLocation('/home/tester/docs'));
    expect(find.text('nested.txt'), findsOneWidget);

    // Backspace goes to the parent folder on Linux/Windows.
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(left.location, const LocalPaneLocation('/home/tester'));
  }

  testWidgets('arrow keys move the cursor and Enter opens a directory', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await arrowEnterBackspaceExercise(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Enter does not open on macOS (rename-key muscle memory)', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      localChannelWithEntries();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(left.location, const LocalPaneLocation('/home/tester'));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Tab swaps pane focus from inside a listing', (tester) async {
    localChannelWithEntries();
    await left.openLocalHome();
    final rightChannel = controller_test.FakePaneChannel('/home/tester');
    rightChannel.listings['/home/tester'] = const [];
    lanes.nextLocalChannel = rightChannel;
    await right.openLocalHome();
    await pumpShell(tester);

    leftNode.requestFocus();
    await tester.pump();
    expect(workspace.activePane, leftStrip);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(workspace.activePane, rightStrip);
    expect(rightNode.hasFocus, isTrue);
  });

  testWidgets('Shift+Tab does not swap panes (reverse traversal keeps it)', (
    tester,
  ) async {
    localChannelWithEntries();
    await left.openLocalHome();
    final rightChannel = controller_test.FakePaneChannel('/home/tester');
    rightChannel.listings['/home/tester'] = const [];
    lanes.nextLocalChannel = rightChannel;
    await right.openLocalHome();
    final sentinelNode = FocusNode();
    addTearDown(sentinelNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              // A focusable region before the panes: reverse traversal
              // from the left pane must reach it, not swap to the right.
              Focus(
                focusNode: sentinelNode,
                autofocus: true,
                child: const SizedBox(height: 20, width: 20),
              ),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: PaneView(
                        controller: left,
                        pane: leftStrip,
                        workspace: workspace,
                        focusNode: leftNode,
                        onSwapFocus: () => rightNode.requestFocus(),
                        onCancelRecovery: () {},
                        clock: clock,
                      ),
                    ),
                    Expanded(
                      child: PaneView(
                        controller: right,
                        pane: rightStrip,
                        workspace: workspace,
                        focusNode: rightNode,
                        onSwapFocus: () => leftNode.requestFocus(),
                        onCancelRecovery: () {},
                        clock: clock,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    leftNode.requestFocus();
    await tester.pump();
    expect(workspace.activePane, leftStrip);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    // The pane node ignored Shift+Tab (02 §8.2 scopes only plain Tab),
    // so default reverse traversal moved focus out of the pane instead
    // of swapping to the right pane.
    expect(leftNode.hasFocus, isFalse);
    expect(sentinelNode.hasFocus, isTrue);
    expect(workspace.activePane, leftStrip);
  });

  testWidgets('Esc over an inline error retries the navigation', (
    tester,
  ) async {
    final channel = localChannelWithEntries();
    await left.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump();

    left.navigate('/home/tester/gone');
    await tester.pumpAndSettle();
    expect(left.error, isNotNull);

    // The failed path now lists successfully; Esc retries it.
    channel.listings['/home/tester/gone'] = [_entry('back.txt')];
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(left.error, isNull);
    expect(find.text('back.txt'), findsOneWidget);
  });

  testWidgets('Enter is inert on stale entries during connection-lost', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      localChannelWithEntries();
      final remoteChannel = controller_test.FakePaneChannel('/srv/home');
      remoteChannel.listings['/srv/home'] = [
        _entry('docs', type: RemoteFileType.directory),
      ];
      remoteChannel.listings['/srv/home/docs'] = [_entry('child.txt')];
      lanes.nextRemoteChannel = remoteChannel;
      await right.connectRemote(_bookmark('srv-1'));
      await pumpShell(tester);
      rightNode.requestFocus();
      await tester.pump();

      // Cursor onto the directory, then the transport drops.
      right.moveCursorBy(1);
      await tester.pump();
      lanes.emitState(
        'srv-1',
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await tester.pump();
      await tester.pump();
      expect(right.connectionLost, isTrue);

      // Enter on the highlighted stale row must not navigate: the
      // keyboard is as inert as the absorbed pointer.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(remoteChannel.listCalls, ['/srv/home']);
      expect(
        right.location,
        const RemotePaneLocation('srv-1', '/srv/home'),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('owned keys and row semantics are inert under the error overlay', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final semantics = tester.ensureSemantics();
    try {
      final channel = localChannelWithEntries();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      // A failing navigation shows the error overlay over the cached
      // listing.
      left.navigate('/home/tester/gone');
      await tester.pumpAndSettle();
      expect(left.error, isNotNull);

      // Owned keys are consumed: no cursor move, no hidden navigation.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(left.cursorIndex, isNull);
      expect(left.location, const LocalPaneLocation('/home/tester/gone'));

      // The stale rows under the overlay leave the semantics tree.
      // One extra frame: the semantics pipeline attaches to the next
      // build after the excluding flip, not the one that flipped it.
      await tester.pump();
      final excluderOfRow = tester.widget<ExcludeSemantics>(
        find.ancestor(
          of: find.text('report.txt'),
          matching: find.byType(ExcludeSemantics),
        ),
      );
      expect(excluderOfRow.excluding, isTrue,
          reason: 'the error overlay must exclude row semantics');

      // Esc still reaches the retry escape hatch (scripted to succeed
      // this time — Esc re-issues the failed navigation).
      channel.listings['/home/tester/gone'] = [_entry('back.txt')];
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(left.error, isNull,
          reason: 'Esc retried the failed navigation');
      expect(find.text('back.txt'), findsOneWidget);
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('plain Backspace falls through on macOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      localChannelWithEntries();
      await left.openLocalHome();
      var ancestorSawBackspace = false;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.backspace):
                  () => ancestorSawBackspace = true,
            },
            child: Scaffold(
              body: Row(
                children: [
                  Expanded(
                    child: PaneView(
                      controller: left,
                      pane: leftStrip,
                      workspace: workspace,
                      focusNode: leftNode,
                      onSwapFocus: () => rightNode.requestFocus(),
                      onCancelRecovery: () {},
                      clock: clock,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      leftNode.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      // Unbound on macOS (§8.3 binds Backspace only on Windows/Linux):
      // the key must reach ancestor handlers, not die at the pane.
      expect(ancestorSawBackspace, isTrue);
      expect(left.location, const LocalPaneLocation('/home/tester'));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('non-VFS faults render the ARB diagnostic, never the sentinel', (
    tester,
  ) async {
    // A local open whose seam throws a non-VFS error (no scripted
    // channel): the fault is app-side, so the diagnostic line is the
    // ARB sentence; the machine sentinel must never render.
    final lanes = controller_test.FakePaneLanes()
      ..localOpenFailure = StateError('no local browse channel scripted');
    final controller = PaneController(
      paneTabId: 'pane.left',
      lanes: lanes,
      onError: (_, _) {},
    );
    final otherPane = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final strip = testPaneStrip(controller);
    final workspace = WorkspaceController(
      left: strip,
      right: testPaneStrip(otherPane),
    );
    addTearDown(workspace.dispose);

    await controller.openLocalHome();
    expect(controller.error, isA<PaneFaultException>());

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PaneView(
            controller: controller,
            pane: strip,
            workspace: workspace,
            focusNode: leftNode,
            onSwapFocus: () {},
            onCancelRecovery: () {},
            clock: clock,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.text('The local file browser could not be opened.'),
      findsOneWidget,
    );
    expect(find.textContaining('fault:'), findsNothing);
  });

  testWidgets('every fault variant renders its ARB sentence, never the sentinel', (
    tester,
  ) async {
    // Drive each fault through its real path: a non-VFS remote open
    // failure (connectionOpen) and a non-VFS listing failure
    // (listFolder). The localOpen variant is covered above. A
    // regression back to error.message would ship the sentinel with
    // no test failing otherwise.
    final lanes = controller_test.FakePaneLanes()
      ..remoteOpenFailure = StateError('boom');
    final controller = PaneController(
      paneTabId: 'pane.left',
      lanes: lanes,
      onError: (_, _) {},
    );
    final otherPane = PaneController(paneTabId: 'pane.right', lanes: lanes);
    final strip = testPaneStrip(controller);
    final workspace = WorkspaceController(
      left: strip,
      right: testPaneStrip(otherPane),
    );
    addTearDown(workspace.dispose);

    Future<void> pumpPane() async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PaneView(
              controller: controller,
              pane: strip,
              workspace: workspace,
              focusNode: leftNode,
              onSwapFocus: () {},
              onCancelRecovery: () {},
              clock: clock,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }

    await controller.connectRemote(_bookmark('srv-9'));
    expect(controller.error, isA<PaneFaultException>());
    await pumpPane();
    expect(
      find.text('The connection to this server could not be opened.'),
      findsOneWidget,
    );

    // listFolder: a successful bind, then a listing that throws a
    // non-VFS error.
    lanes.remoteOpenFailure = null;
    final listing = controller_test.FakePaneChannel('/home/tester');
    listing.listingFailure = StateError('io exploded');
    lanes.nextLocalChannel = listing;
    await controller.openLocalHome();
    await tester.pump();
    expect(controller.error, isA<PaneFaultException>());
    await pumpPane();
    expect(find.text('This folder could not be listed.'), findsOneWidget);

    expect(find.textContaining('fault:'), findsNothing);
  });

  testWidgets('remote connect renders the connecting state until it lands', (
    tester,
  ) async {
    final open = Completer<void>();
    final channel = controller_test.FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('late.txt')];
    lanes.nextRemoteChannel = channel;
    lanes.holdRemoteOpen = open;
    final connecting = left.connectRemote(_bookmark('srv-1'));
    await pumpShell(tester);
    await tester.pump(const Duration(milliseconds: 200));

    // Past the anti-flash grace (02 §2.8): the connecting state shows.
    expect(find.text('Connecting to web.example.com…'), findsOneWidget);
    expect(find.text('late.txt'), findsNothing);

    open.complete();
    await connecting;
    await tester.pumpAndSettle();
    expect(find.text('late.txt'), findsOneWidget);
    expect(find.text('Connecting to web.example.com…'), findsNothing);
  });

  testWidgets('Esc abandons a pending remote connect before the grace', (
    tester,
  ) async {
    final open = Completer<void>();
    final channel = controller_test.FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('late.txt')];
    lanes.nextRemoteChannel = channel;
    lanes.holdRemoteOpen = open;
    final connecting = right.connectRemote(_bookmark('srv-1'));
    await pumpShell(tester);
    rightNode.requestFocus();
    await tester.pump(const Duration(milliseconds: 100));

    // Still inside the anti-flash grace (02 §2.8): no spinner, no cancel
    // affordance — but Esc must already cancel the pending bind.
    expect(right.phase, PanePhase.connectingRemote);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('pane.connect.cancel')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(right.phase, PanePhase.unbound);
    expect(right.remoteBookmark, isNull);
    expect(lanes.disconnects, ['srv-1']);

    // The late open must not repaint the cancelled pane: its orphaned
    // channel is retired without ever listing.
    open.complete();
    await connecting;
    await tester.pumpAndSettle();
    expect(channel.closeCalls, 1);
    expect(channel.listCalls, isEmpty);
    expect(find.text('late.txt'), findsNothing);
  });

  testWidgets('Esc abandons a pending remote connect past the grace', (
    tester,
  ) async {
    localChannelWithEntries();
    await left.openLocalHome();
    final open = Completer<void>();
    final channel = controller_test.FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('late.txt')];
    lanes.nextRemoteChannel = channel;
    lanes.holdRemoteOpen = open;
    final connecting = right.connectRemote(_bookmark('srv-1'));
    await pumpShell(tester);
    leftNode.requestFocus();
    await tester.pump(const Duration(milliseconds: 200));

    expect(right.phase, PanePhase.connectingRemote);
    expect(find.text('Connecting to web.example.com…'), findsOneWidget);
    expect(find.byKey(const ValueKey('pane.connect.cancel')), findsOneWidget);

    // The UNFOCUSED pane's pending bind is never cancelled by Esc.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(right.phase, PanePhase.connectingRemote);

    rightNode.requestFocus();
    await tester.pump();

    // A modified chord is not the pane's plain Esc (02 §8.2).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(right.phase, PanePhase.connectingRemote);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(right.phase, PanePhase.unbound);
    expect(right.remoteBookmark, isNull);
    // Alone on srv-1: the cancel drops the server reference.
    expect(lanes.disconnects, ['srv-1']);

    open.complete();
    await connecting;
    await tester.pumpAndSettle();
    expect(channel.closeCalls, 1);
    expect(channel.listCalls, isEmpty);
    expect(find.text('late.txt'), findsNothing);
    // The sibling's own listing is untouched by the cancel.
    expect(find.text('report.txt'), findsOneWidget);
  });

  testWidgets('the connecting Cancel action abandons the pending remote bind', (
    tester,
  ) async {
    final open = Completer<void>();
    final channel = controller_test.FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('late.txt')];
    lanes.nextRemoteChannel = channel;
    lanes.holdRemoteOpen = open;
    final connecting = right.connectRemote(_bookmark('srv-1'));
    await pumpShell(tester);
    await tester.pump(const Duration(milliseconds: 200));

    final cancel = find.byKey(const ValueKey('pane.connect.cancel'));
    expect(cancel, findsOneWidget);
    await tester.tap(cancel);
    await tester.pump();

    expect(right.phase, PanePhase.unbound);
    expect(right.remoteBookmark, isNull);
    expect(lanes.disconnects, ['srv-1']);

    open.complete();
    await connecting;
    await tester.pumpAndSettle();
    expect(channel.closeCalls, 1);
    expect(channel.listCalls, isEmpty);
    expect(find.text('late.txt'), findsNothing);
  });

  testWidgets('a held Esc repeat cannot cancel a replacement remote bind', (
    tester,
  ) async {
    final firstOpen = Completer<void>();
    lanes.holdRemoteOpen = firstOpen;
    final first = right.connectRemote(_bookmark('srv-1'));
    await pumpShell(tester);
    rightNode.requestFocus();
    await tester.pump();
    expect(right.phase, PanePhase.connectingRemote);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(right.phase, PanePhase.unbound);
    firstOpen.complete();
    await first;

    // A replacement bind owns the pane now; a key still repeating from
    // the held Esc must not cancel it.
    final secondOpen = Completer<void>();
    lanes.holdRemoteOpen = secondOpen;
    final secondChannel = controller_test.FakePaneChannel('/srv/home');
    secondChannel.listings['/srv/home'] = [_entry('second.txt')];
    lanes.nextRemoteChannel = secondChannel;
    final second = right.connectRemote(_bookmark('srv-1'));
    await tester.pump();
    expect(right.phase, PanePhase.connectingRemote);

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      right.phase,
      PanePhase.connectingRemote,
      reason: 'an Esc repeat must not cancel the replacement binding',
    );

    secondOpen.complete();
    await second;
    await tester.pumpAndSettle();
    expect(find.text('second.txt'), findsOneWidget);
  });

  testWidgets('reconnecting renders the connection-lost banner with Cancel', (
    tester,
  ) async {
    final channel = controller_test.FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [_entry('file.txt')];
    lanes.nextRemoteChannel = channel;
    await right.connectRemote(_bookmark('srv-1'));
    await pumpShell(tester);

    lanes.emitState('srv-1', const ServerStatus(ServerConnectionState.connected));
    await tester.pump();
    expect(find.textContaining('lost'), findsNothing);

    lanes.emitState(
      'srv-1',
      const ServerStatus(ServerConnectionState.reconnecting),
    );
    // Broadcast delivery lands on a microtask; the rebuild needs a frame
    // after the listener ran.
    await tester.pump();
    await tester.pump();
    expect(
      find.text('Connection to web.example.com lost — reconnecting…'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('pane.banner.cancel')), findsOneWidget);

    // Cancel drops the server reference: the watch reports the
    // disconnect and the banner clears with the state.
    await tester.tap(find.byKey(const ValueKey('pane.banner.cancel')));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pane.banner')), findsNothing);
    expect(lanes.disconnects, ['srv-1']);

    lanes.emitState(
      'srv-1',
      const ServerStatus(ServerConnectionState.connected),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('lost'), findsNothing);
  });

  testWidgets('the location header names the folder; its ancestor menu '
      'navigates, parent first', (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester/docs');
    channel.listings['/home/tester/docs'] = [_entry('deep.txt')];
    channel.listings['/home/tester'] = [_entry('shallow.txt')];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    left.navigate('/home/tester/docs');
    await pumpShell(tester);
    await tester.pump();

    final header = find.byKey(const ValueKey('pane.left.path'));
    // D32 §6: the folder name alone — ancestors live in the ▾ menu,
    // never as a segment row.
    expect(
      find.descendant(of: header, matching: find.text('docs')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.text('tester')),
      findsNothing,
    );
    expect(
      tester.widget<Text>(
        find.byKey(const ValueKey('pane.left.path.summary')),
      ).data,
      '1 item',
    );

    await tester.tap(find.byKey(const ValueKey('pane.left.path.ancestors')));
    await tester.pumpAndSettle();
    final items = [
      for (var i = 0; i < 3; i++)
        find.byKey(ValueKey('pane.left.path.ancestor.$i')),
    ];
    for (final (index, label) in ['tester', 'home', '/'].indexed) {
      expect(
        find.descendant(of: items[index], matching: find.text(label)),
        findsOneWidget,
        reason: 'Finder\'s title-menu order: parent first, root last',
      );
    }
    expect(
      tester.getTopLeft(items[0]).dy,
      lessThan(tester.getTopLeft(items[2]).dy),
    );

    await tester.tap(items[0]);
    await tester.pumpAndSettle();

    expect(left.location, const LocalPaneLocation('/home/tester'));
    expect(find.text('shallow.txt'), findsOneWidget);
  });

  testWidgets('clicking the folder name opens the path field in place', (
    tester,
  ) async {
    localChannelWithEntries();
    await left.openLocalHome();
    await pumpShell(tester);

    await tester.tap(find.byKey(const ValueKey('pane.left.path.name')));
    await tester.pump();
    await tester.pump();

    expect(left.pathFieldOpen, isTrue);
    final field = find.byKey(const ValueKey('pane.left.path.field'));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('pane.left.path')),
        matching: field,
      ),
      findsOneWidget,
      reason: 'the field swaps in inside the header',
    );
    expect(left.pathFieldSeed, '/home/tester');
  });

  testWidgets('the header summarizes the selection: files-only bytes', (
    tester,
  ) async {
    localChannelWithEntries();
    await left.openLocalHome();
    await pumpShell(tester);
    String summary() => tester
        .widget<Text>(find.byKey(const ValueKey('pane.left.path.summary')))
        .data!;

    expect(summary(), '3 items');
    // docs (a folder) + report.txt (2048 B): the folder counts toward
    // the selection but never toward the bytes.
    left.selectAll();
    await tester.pump();
    expect(summary(), '3 of 3 selected · 2 KB');

    left.setCursorIndex(0); // docs alone
    await tester.pump();
    expect(summary(), '1 of 3 selected');
  });

  testWidgets('column headers sort; Size and Date start descending', (
    tester,
  ) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('b.txt', size: 10, modified: DateTime(2026, 9, 1)),
      _entry('a.txt', size: 30, modified: DateTime(2026, 9, 3)),
      _entry('c.txt', size: 20, modified: DateTime(2026, 9, 2)),
    ];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);
    List<String> names() => [for (final e in left.entries) e.name];

    expect(names(), ['a.txt', 'b.txt', 'c.txt']);
    await tester.tap(find.byKey(const ValueKey('pane.left.column.size')));
    await tester.pump();
    expect(left.sortKey, FileSortKey.size);
    expect(left.sortDirection, FileSortDirection.descending);
    expect(names(), ['a.txt', 'c.txt', 'b.txt']);

    // A second click on the sorted column flips it.
    await tester.tap(find.byKey(const ValueKey('pane.left.column.size')));
    await tester.pump();
    expect(names(), ['b.txt', 'c.txt', 'a.txt']);

    await tester.tap(find.byKey(const ValueKey('pane.left.column.modified')));
    await tester.pump();
    expect(left.sortDirection, FileSortDirection.descending);
    expect(names(), ['a.txt', 'c.txt', 'b.txt']);

    await tester.tap(find.byKey(const ValueKey('pane.left.column.name')));
    await tester.pump();
    expect(left.sortDirection, FileSortDirection.ascending);
    expect(names(), ['a.txt', 'b.txt', 'c.txt']);
    // The rendered order follows, not just the controller.
    expect(
      tester.getTopLeft(find.text('a.txt')).dy,
      lessThan(tester.getTopLeft(find.text('c.txt')).dy),
    );
    // The header sits outside the listing: row 0 is the list's origin.
    final list = find.byType(ListView).first;
    expect(
      tester.getTopLeft(list).dy,
      greaterThanOrEqualTo(
        tester
            .getBottomLeft(find.byKey(const ValueKey('pane.left.columns')))
            .dy,
      ),
    );
  });

  testWidgets('a navigation from a scrolled listing reveals the top', (
    tester,
  ) async {
    final channel = localChannelWithEntries();
    channel.listings['/home/tester'] = List.generate(
      200,
      (i) => _entry('file-$i.txt'),
    );
    channel.listings['/home/tester/docs'] = List.generate(
      200,
      (i) => _entry('doc-$i.txt'),
    );
    await left.openLocalHome();
    await pumpShell(tester);

    // Scroll deep into the listing (controller-level: no pointer churn),
    // then navigate into a subfolder: the new listing's top must be
    // revealed, not the stale offset. The path bar also hosts a
    // ListView; the listing's is the one with the scroll controller.
    final listing = tester
        .widgetList<ListView>(find.byType(ListView))
        .firstWhere((view) => view.controller != null);
    listing.controller!.jumpTo(2000);
    await tester.pump();

    left.navigate('/home/tester/docs');
    await tester.pumpAndSettle();

    expect(find.text('doc-0.txt'), findsOneWidget);
    expect(listing.controller!.position.pixels, 0);
  });

  testWidgets('the active pane selects in the accent; the inactive one '
      'in neutral grey', (tester) async {
    localChannelWithEntries();
    await left.openLocalHome();
    final rightChannel = controller_test.FakePaneChannel('/home/tester');
    rightChannel.listings['/home/tester'] = [_entry('other.txt')];
    lanes.nextLocalChannel = rightChannel;
    await right.openLocalHome();
    await pumpShell(tester);
    leftNode.requestFocus();
    left.setCursorIndex(
      left.entries.indexWhere((entry) => entry.name == 'report.txt'),
    );
    right.setCursorIndex(0);
    await tester.pump();

    Color? rowFill(String name) {
      for (final box in tester.widgetList<DecoratedBox>(
        find.ancestor(of: find.text(name), matching: find.byType(DecoratedBox)),
      )) {
        final decoration = box.decoration;
        if (decoration is BoxDecoration && decoration.color != null) {
          return decoration.color;
        }
      }
      return null;
    }

    final chrome = PoltergeistChrome.of(
      tester.element(find.byKey(const ValueKey('pane.left.path'))),
    );
    expect(rowFill('report.txt'), chrome.selectionFill);
    expect(
      tester.widget<Text>(find.text('report.txt')).style?.color,
      chrome.onSelection,
    );
    expect(rowFill('other.txt'), chrome.inactiveSelectionFill);

    rightNode.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(workspace.activePane, rightStrip);
    expect(rowFill('other.txt'), chrome.selectionFill);
    expect(rowFill('report.txt'), chrome.inactiveSelectionFill);
  });

  testWidgets('rows announce name, size, and date to semantics', (
    tester,
  ) async {
    localChannelWithEntries();
    await left.openLocalHome();
    await pumpShell(tester);

    expect(
      find.bySemanticsLabel(
        RegExp('report.txt.*2 KB.*9/11/2026', dotAll: true),
      ),
      findsOneWidget,
    );
  });

  testWidgets('rows announce name, kind, size, and date in that order', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry(
          'docs',
          type: RemoteFileType.directory,
          modified: DateTime(2026, 9, 10, 14, 32),
        ),
        _entry(
          'report.txt',
          size: 2048,
          modified: DateTime(2026, 9, 11, 9, 5),
        ),
        _entry('link', type: RemoteFileType.symbolicLink),
        _entry('socket', type: RemoteFileType.other),
      ];
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);

      // 02 §13 / 08 §7: one merged node per row announcing the fields in
      // Name-Kind-Size-Date order — anchored field-by-field on each row's
      // own label, never substring presence in unrelated widgets.
      expect(
        find.bySemanticsLabel(RegExp(r'^docs, folder, —, 9/10/2026')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^report\.txt, file, 2 KB, 9/11/2026')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^link, symbolic link, —, —$')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^socket, item, —, —$')),
        findsOneWidget,
        reason: 'a non-file non-directory entry still announces its kind',
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^socket, file,')),
        findsNothing,
        reason: 'RemoteFileType.other must not announce as a regular file',
      );

      // The merged label replaces the children: the name is announced
      // exactly once, on the row node itself.
      expect(
        find.bySemanticsLabel(RegExp(r'report\.txt')),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a null lanes pane renders the no-engine state', (tester) async {
    final engineless = PaneController(paneTabId: 'pane.left');
    final enginelessRight = PaneController(paneTabId: 'pane.right');
    addTearDown(engineless.dispose);
    addTearDown(enginelessRight.dispose);
    final enginelessStrip = testPaneStrip(engineless);
    final enginelessWorkspace = WorkspaceController(
      left: enginelessStrip,
      right: testPaneStrip(enginelessRight),
    );
    addTearDown(enginelessWorkspace.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PaneView(
            controller: engineless,
            pane: enginelessStrip,
            workspace: enginelessWorkspace,
            focusNode: leftNode,
            onSwapFocus: () {},
            onCancelRecovery: () {},
            clock: clock,
          ),
        ),
      ),
    );

    expect(find.textContaining('Browsing is unavailable'), findsOneWidget);
  });

  group('quick select field', () {
    final field = find.byKey(const ValueKey('pane.left.quickSelect.field'));

    int rowOf(String name) => left.entries.indexWhere((e) => e.name == name);

    testWidgets('drops below the path bar, previews live, Enter keeps', (
      tester,
    ) async {
      localChannelWithEntries();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();
      expect(field, findsNothing);

      left.openQuickSelect();
      await tester.pump();

      // 02 §2.5: the field drops in below the path bar.
      expect(field, findsOneWidget);
      expect(
        tester.getTopLeft(field).dy,
        greaterThanOrEqualTo(
          tester
              .getBottomLeft(find.byKey(const ValueKey('pane.left.path')))
              .dy,
        ),
        reason: 'the field must sit below the path bar',
      );

      // The Add/Remove segmented toggle starts on Add.
      expect(
        find.byType(SegmentedButton<QuickSelectMode>),
        findsOneWidget,
      );
      expect(find.text('Add'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      expect(left.quickSelectMode, QuickSelectMode.add);

      // The field took focus on open; a fragment preview selects live.
      expect(
        tester.binding.focusManager.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>(),
        isNotNull,
        reason: 'the field must own primary focus while open',
      );
      await tester.enterText(field, '.txt');
      await tester.pump();
      expect(left.isRowSelected(rowOf('report.txt')), isTrue);
      expect(left.isRowSelected(rowOf('docs')), isFalse);

      // Enter keeps the preview, closes the field, returns focus. The
      // submission travels the text-input action channel (as the
      // embedder sends it for a single-line field), not a raw key.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(field, findsNothing);
      expect(left.quickSelectActive, isFalse);
      expect(left.isRowSelected(rowOf('report.txt')), isTrue);
      expect(leftNode.hasFocus, isTrue);
    });

    testWidgets('Esc cancels: field closes, opening selection restored', (
      tester,
    ) async {
      localChannelWithEntries();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setCursorIndex(rowOf('docs')); // the opening selection
      left.openQuickSelect();
      await tester.pump();
      await tester.enterText(field, '*');
      await tester.pump();
      expect(left.selectedCount, 3);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(field, findsNothing);
      expect(left.selectedCount, 1);
      expect(left.isRowSelected(rowOf('docs')), isTrue);
      expect(leftNode.hasFocus, isTrue);
    });

    testWidgets('the Remove segment recomputes the preview live', (
      tester,
    ) async {
      localChannelWithEntries();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.selectAll();
      left.openQuickSelect();
      await tester.pump();
      await tester.enterText(field, '.txt');
      await tester.pump();

      await tester.tap(find.text('Remove'));
      await tester.pump();

      expect(left.quickSelectMode, QuickSelectMode.remove);
      expect(left.isRowSelected(rowOf('report.txt')), isFalse);
      expect(left.isRowSelected(rowOf('docs')), isTrue);
    });

    testWidgets('listing keys stay inert while the field holds focus', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        localChannelWithEntries();
        await left.openLocalHome();
        final rightChannel =
            controller_test.FakePaneChannel('/home/tester');
        rightChannel.listings['/home/tester'] = const [];
        lanes.nextLocalChannel = rightChannel;
        await right.openLocalHome();
        await pumpShell(tester);
        leftNode.requestFocus();
        await tester.pump();

        left.openQuickSelect();
        await tester.pump();

        // 02 §8.2: every pane-owned single key is inert under a focused
        // text surface — no cursor move, no Enter-open, no Tab swap.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(left.cursorIndex, isNull);
        expect(channelStillOpen(left), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(rightNode.hasFocus, isFalse);
        expect(workspace.activePane, leftStrip);
        expect(left.quickSelectActive, isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a controller-side session end returns focus to the listing', (
      tester,
    ) async {
      final channel = localChannelWithEntries();
      channel.listings['/home/tester/docs'] = [_entry('nested.txt')];
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.openQuickSelect();
      await tester.pump();
      expect(left.quickSelectActive, isTrue);

      // Navigation ends the session controller-side (02 §2.5): the field
      // unmounts under focus, and the stranded primary focus must return
      // to the listing rather than dying at the root scope.
      left.navigate('/home/tester/docs');
      await tester.pumpAndSettle();
      expect(left.quickSelectActive, isFalse);
      expect(field, findsNothing);
      expect(leftNode.hasFocus, isTrue);
    });
  });

  group('header-owned filter (D32 §4)', () {
    testWidgets('the pane mounts no filter strip; the header query '
        'filters the rows live', (tester) async {
      localChannelWithEntries();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      // The legacy view.filter fallback opens nothing in the pane: the
      // header owns the only filter field now.
      left.openFilter();
      await tester.pump();
      expect(find.byType(TextField), findsNothing);

      left.setFilterQuery('r');
      await tester.pump();
      expect(left.entries.map((e) => e.name), ['report.txt']);
      // The rendered rows themselves change, not just the controller.
      expect(find.text('report.txt'), findsOneWidget);
      expect(find.text('docs'), findsNothing);
      expect(find.text('link'), findsNothing);
      // The location header counts the visible rows.
      expect(
        tester.widget<Text>(
          find.byKey(const ValueKey('pane.left.path.summary')),
        ).data,
        '1 item',
      );
    });

    testWidgets('Esc on the listing clears an active filter', (
      tester,
    ) async {
      localChannelWithEntries();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setFilterQuery('report');
      await tester.pump();
      expect(left.filterActive, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(left.filterActive, isFalse);
      expect(left.entries.length, 3);
    });

    testWidgets('navigation-cancel still outranks the filter tier', (
      tester,
    ) async {
      final channel = localChannelWithEntries();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setFilterQuery('report');
      await tester.pump();
      expect(left.filterActive, isTrue);

      // A held listing keeps the navigation in flight: §8.2's first Esc
      // cancels the load, never the filter.
      final hold = Completer<void>();
      channel.holdNext = hold;
      addTearDown(() {
        // A failing expect must not leave the fake's future stranded.
        if (!hold.isCompleted) hold.complete();
      });
      left.navigate('/home/tester/docs');
      await tester.pump(const Duration(milliseconds: 300));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(left.loading, isFalse);
      expect(left.filterActive, isTrue,
          reason: 'the navigation tier owns this Esc — the filter tier '
              'never sees it');
      expect(left.location, const LocalPaneLocation('/home/tester'));
      expect(left.entries.map((e) => e.name), ['report.txt']);
      hold.complete();
      await tester.pumpAndSettle();
      // The cancelled listing's late answer must never land.
      expect(left.location, const LocalPaneLocation('/home/tester'));
      expect(left.filterActive, isTrue);
      expect(left.entries.map((e) => e.name), ['report.txt']);
    });

    testWidgets('filtered-to-nothing renders the dedicated empty state', (
      tester,
    ) async {
      localChannelWithEntries();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setFilterQuery('zzz');
      await tester.pump();

      // 02 §2.7: the dedicated message and Clear affordance — never a
      // blank pane.
      expect(find.text('No items match "zzz"'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pane.left.filter.emptyClear')),
        findsOneWidget,
      );
      expect(find.text('This folder is empty.'), findsNothing,
          reason: 'the listing is not empty — the FILTER is');

      await tester.tap(
        find.byKey(const ValueKey('pane.left.filter.emptyClear')),
      );
      await tester.pump();
      expect(left.filterActive, isFalse);
      expect(left.entries.length, 3);
    });
  });
}

/// The pane stays browsable — a typing mishap must not have navigated.
bool channelStillOpen(PaneController pane) =>
    pane.location != null && pane.error == null;
