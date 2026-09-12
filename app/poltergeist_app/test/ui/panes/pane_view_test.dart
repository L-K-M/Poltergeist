import 'dart:async';

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;

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
  late WorkspaceController workspace;
  late FocusNode leftNode;
  late FocusNode rightNode;

  DateTime Function() clock = _fixedClock;

  setUp(() {
    clock = _fixedClock;
    lanes = controller_test.FakePaneLanes();
    left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    workspace = WorkspaceController(left: left, right: right);
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
    expect(workspace.activePane, left);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(workspace.activePane, right);
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
    expect(workspace.activePane, left);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    // The pane node ignored Shift+Tab (02 §8.2 scopes only plain Tab),
    // so default reverse traversal moved focus out of the pane instead
    // of swapping to the right pane.
    expect(leftNode.hasFocus, isFalse);
    expect(sentinelNode.hasFocus, isTrue);
    expect(workspace.activePane, left);
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

    expect(find.text('Connecting to web.example.com…'), findsOneWidget);
    expect(find.text('late.txt'), findsNothing);

    open.complete();
    await connecting;
    await tester.pumpAndSettle();
    expect(find.text('late.txt'), findsOneWidget);
    expect(find.text('Connecting to web.example.com…'), findsNothing);
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

  testWidgets('path bar segments navigate to their ancestor', (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester/docs');
    channel.listings['/home/tester/docs'] = [_entry('deep.txt')];
    channel.listings['/home/tester'] = [_entry('shallow.txt')];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    left.navigate('/home/tester/docs');
    await pumpShell(tester);
    await tester.pump();

    expect(find.text('home'), findsOneWidget);
    expect(find.text('tester'), findsOneWidget);
    expect(find.text('docs'), findsOneWidget);
    // Root first, deepest last (02 §2.1's ancestor order).
    final offsets = [
      tester.getTopLeft(find.text('/')).dx,
      tester.getTopLeft(find.text('home')).dx,
      tester.getTopLeft(find.text('tester')).dx,
      tester.getTopLeft(find.text('docs')).dx,
    ];
    expect(
      offsets,
      equals(offsets.toList()..sort()),
      reason: 'path segments render root → deepest, left to right',
    );

    await tester.tap(find.text('tester'));
    await tester.pumpAndSettle();

    expect(left.location, const LocalPaneLocation('/home/tester'));
    expect(find.text('shallow.txt'), findsOneWidget);
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

  testWidgets('the focused pane path renders in the accent color', (
    tester,
  ) async {
    localChannelWithEntries();
    await left.openLocalHome();
    final rightChannel = controller_test.FakePaneChannel('/home/tester');
    rightChannel.listings['/home/tester'] = const [];
    lanes.nextLocalChannel = rightChannel;
    await right.openLocalHome();
    await pumpShell(tester);

    Text pathSegment(String pane, String label) => tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(ValueKey('pane.$pane.path')),
            matching: find.text(label),
          )
          .first,
    );
    final accent = Theme.of(
      tester.element(find.byKey(const ValueKey('pane.left.path'))),
    ).colorScheme.primary;
    expect(pathSegment('left', 'tester').style?.color, accent);

    rightNode.requestFocus();
    await tester.pump();
    expect(pathSegment('right', 'tester').style?.color, accent);
    // The left pane lost focus: its segments dropped to the variant tone.
    expect(pathSegment('left', 'tester').style?.color, isNot(accent));
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

  testWidgets('a null lanes pane renders the no-engine state', (tester) async {
    final engineless = PaneController(paneTabId: 'pane.left');
    final enginelessRight = PaneController(paneTabId: 'pane.right');
    addTearDown(engineless.dispose);
    addTearDown(enginelessRight.dispose);
    final enginelessWorkspace = WorkspaceController(
      left: engineless,
      right: enginelessRight,
    );
    addTearDown(enginelessWorkspace.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PaneView(
            controller: engineless,
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
}
