import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/info_panel.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
  int? uid,
  int? gid,
  int? mode,
  DateTime? modified,
  DateTime? accessed,
  String root = '/home/tester',
}) {
  return RemoteFileEntry(
    path: '$root/$name',
    name: name,
    type: type,
    size: size,
    uid: uid,
    gid: gid,
    mode: mode,
    accessedAt: accessed,
    modifiedAt: modified,
  );
}

Bookmark _remoteBookmark() {
  final now = DateTime.utc(2026, 9, 12);
  return Bookmark(
    id: 'srv-1',
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
    sortKey: 'k',
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
                  clock: _fixedClock,
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
                  clock: _fixedClock,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Finder inPanel(Finder matching) =>
      find.descendant(of: find.byType(InfoPanel), matching: matching);

  testWidgets('renders the target\'s metadata: name, kind, size, dates, '
      'permissions, owner, and full path', (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry(
        'report.txt',
        size: 2048,
        uid: 501,
        gid: 20,
        mode: 0x81A4, // regular file, 0644
        modified: DateTime(2026, 9, 11, 9, 5),
        accessed: DateTime(2026, 9, 14, 18, 40),
      ),
    ];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setCursorIndex(0);
    leftStrip.toggleInfoPanel();
    await tester.pumpAndSettle();

    expect(find.byType(InfoPanel), findsOneWidget);
    expect(inPanel(find.text('report.txt')), findsOneWidget);
    expect(inPanel(find.text('Kind')), findsOneWidget);
    expect(inPanel(find.text('file')), findsOneWidget);
    expect(inPanel(find.text('Size')), findsOneWidget);
    expect(inPanel(find.text('2 KB')), findsOneWidget);
    expect(inPanel(find.text('Modified')), findsOneWidget);
    expect(inPanel(find.textContaining('9/11/2026')), findsOneWidget);
    expect(inPanel(find.text('Accessed')), findsOneWidget);
    // The accessed stamp is the day before the fixed clock — the
    // relative "Yesterday" form, not an absolute date.
    expect(inPanel(find.textContaining('Yesterday')), findsOneWidget);
    expect(inPanel(find.text('Permissions')), findsOneWidget);
    expect(inPanel(find.text('rw-r--r-- (0644)')), findsOneWidget);
    expect(inPanel(find.text('Owner')), findsOneWidget);
    expect(inPanel(find.text('501')), findsOneWidget);
    expect(inPanel(find.text('Group')), findsOneWidget);
    expect(inPanel(find.text('20')), findsOneWidget);
    expect(inPanel(find.text('Path')), findsOneWidget);
    expect(
      inPanel(find.text('/home/tester/report.txt')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('infoPanel.copyPath')),
      findsOneWidget,
    );
  });

  testWidgets('a remote target renders its server-side uid/gid/mode',
      (tester) async {
    final channel = controller_test.FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [
      _entry(
        'deploy.sh',
        size: 512,
        uid: 0,
        gid: 0,
        mode: 0x81ED, // regular file, 0755
        modified: DateTime(2026, 9, 10),
        root: '/srv/home',
      ),
    ];
    lanes.nextRemoteChannel = channel;
    await right.connectRemote(_remoteBookmark());
    await pumpShell(tester);

    right.setCursorIndex(0);
    rightStrip.toggleInfoPanel();
    await tester.pumpAndSettle();

    expect(find.byType(InfoPanel), findsOneWidget);
    expect(inPanel(find.text('deploy.sh')), findsOneWidget);
    expect(inPanel(find.text('rwxr-xr-x (0755)')), findsOneWidget);
    expect(inPanel(find.text('0')), findsNWidgets(2));
    expect(
      inPanel(find.text('/srv/home/deploy.sh')),
      findsOneWidget,
    );
  });

  testWidgets('retargets as the cursor moves and counts a '
      'multi-selection', (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('a.txt', size: 1),
      _entry('b.txt', size: 2),
      _entry('c.txt', size: 3),
    ];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setCursorIndex(0);
    leftStrip.toggleInfoPanel();
    await tester.pumpAndSettle();
    expect(inPanel(find.text('a.txt')), findsOneWidget);

    left.setCursorIndex(2);
    await tester.pump();
    expect(inPanel(find.text('c.txt')), findsOneWidget);
    expect(inPanel(find.text('a.txt')), findsNothing);

    // A range selection keeps the cursor row primary and adds the
    // count line (02 §2.6's "primary + count" multi-selection form).
    left.setCursorIndex(0);
    left.setCursorIndex(2, update: SelectionUpdate.range);
    await tester.pump();
    expect(inPanel(find.text('c.txt')), findsOneWidget);
    expect(inPanel(find.text('3 items selected')), findsOneWidget);
  });

  testWidgets('shows the empty state with no selection', (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('a.txt')];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    leftStrip.toggleInfoPanel();
    await tester.pumpAndSettle();

    expect(find.byType(InfoPanel), findsOneWidget);
    expect(
      inPanel(find.text('Select an item to inspect it.')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('infoPanel.calculateSize')),
      findsNothing,
    );
  });

  testWidgets('stays non-modal: row taps reach the listing and retarget '
      'the open panel', (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('a.txt', size: 1),
      _entry('b.txt', size: 2),
    ];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setCursorIndex(0);
    leftStrip.toggleInfoPanel();
    await tester.pumpAndSettle();
    expect(inPanel(find.text('a.txt')), findsOneWidget);

    // The panel is a right-edge overlay — a tap on a row's left side
    // still reaches the listing and moves the cursor. The name text
    // sits in an Expanded, so tap its left edge (its center can land
    // under the 280px panel).
    await tester.tapAt(tester.getTopLeft(find.text('b.txt')) +
        const Offset(10, 5));
    // Rows carry onDoubleTap, so the single tap commits only after the
    // double-tap window elapses.
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect(left.cursorIndex, 1);
    expect(inPanel(find.text('b.txt')), findsOneWidget);

    // Release the focus the pointer-down bounced to the listing —
    // disposing a still-focused node at teardown schedules an update
    // on the binding's already-dead FocusManager.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
  });

  testWidgets('Esc closes the panel at its §8.2 slot, above the '
      'unfocused filter', (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('a.txt'),
      _entry('b.txt'),
    ];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    // An active-but-unfocused filter sits BELOW the panel in the Esc
    // order (02 §8.2): the first Esc closes the inspector, the second
    // clears the filter.
    left.openFilter();
    left.changeFilterQuery('a');
    left.setCursorIndex(0);
    leftStrip.toggleInfoPanel();
    // Let the field's one-shot focus claim land, then move focus back
    // to the listing — the state under test is an UNFOCUSED filter.
    await tester.pumpAndSettle();
    leftNode.requestFocus();
    await tester.pump();
    expect(find.byType(InfoPanel), findsOneWidget);
    expect(left.filterActive, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(InfoPanel), findsNothing);
    expect(left.filterActive, isTrue,
        reason: 'the panel owns the first Esc; the filter survives it');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(left.filterActive, isFalse);
    expect(left.filterFieldOpen, isFalse);

    // Release the pane's primary focus before teardown — disposing a
    // still-focused node schedules an update on the binding's already-
    // dead FocusManager.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
  });

  testWidgets('Esc order: an error retry outranks the panel close',
      (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('a.txt')];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setCursorIndex(0);
    leftStrip.toggleInfoPanel();
    await tester.pumpAndSettle();
    expect(find.byType(InfoPanel), findsOneWidget);

    // Drive the pane into its error state with the panel open — the
    // retry tier sits ABOVE the panel's close slot (02 §8.2).
    channel.listingFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.other,
      operation: 'list',
      path: '/home/tester',
      message: 'listing refused',
    );
    left.refresh();
    await tester.pumpAndSettle();
    expect(left.error, isNotNull);
    expect(find.byType(InfoPanel), findsOneWidget);

    // First Esc retries the failed operation (cleared fault → the
    // retry re-lists cleanly); the inspector must survive it.
    channel.listingFailure = null;
    leftNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(left.error, isNull);
    expect(find.byType(InfoPanel), findsOneWidget,
        reason: 'error-retry owns the first Esc; the panel stays open');

    // The next Esc reaches the panel's own slot.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(InfoPanel), findsNothing);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
  });

  testWidgets('Esc pressed while a panel control holds focus still runs '
      'the tier chain', (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('docs', type: RemoteFileType.directory),
    ];
    channel.listings['/home/tester/docs'] = [
      _entry('inner.txt', size: 4, root: '/home/tester/docs'),
    ];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setCursorIndex(0);
    leftStrip.toggleInfoPanel();
    await tester.pumpAndSettle();

    // Tapping Calculate starts the walk AND leaves the button focused —
    // Esc from inside the panel must reach the shared tier chain. The
    // listing is held so the walk is still in flight when Esc lands.
    final held = Completer<void>();
    channel.holdNext = held;
    await tester.tap(find.byKey(const ValueKey('infoPanel.calculateSize')));
    await tester.pump();
    expect(left.folderSizeInFlight, isTrue);

    // Focus the Cancel control itself — a tap doesn't move primary
    // focus in tests, so request the button's own node. Esc from
    // inside the panel must still run the pane's shared tier chain.
    final cancelFinder = find.byKey(const ValueKey('infoPanel.cancelSize'));
    final controlFocus = Focus.of(
      tester.element(
        find.descendant(of: cancelFinder, matching: find.byType(Text)),
      ),
    );
    controlFocus.requestFocus();
    await tester.pump();
    expect(controlFocus.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(InfoPanel), findsNothing);
    expect(left.folderSizeInFlight, isFalse,
        reason: 'the close cancels the walk it owned');
    // Release the held listing so the retired walk can settle — its
    // late answer must be dropped by the session-token check.
    held.complete();
    await tester.pumpAndSettle();
    expect(left.folderSize, isNull);
  });

  testWidgets('the ✕ closes the panel and focus returns to the listing',
      (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('a.txt')];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setCursorIndex(0);
    leftStrip.toggleInfoPanel();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('infoPanel.close')));
    await tester.pumpAndSettle();
    expect(find.byType(InfoPanel), findsNothing);
    expect(leftStrip.infoPanelOpen, isFalse);
    // The unmounted button strands primary focus; the pane's close
    // bookkeeping returns it so the next Esc still works.
    expect(leftNode.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    // Idle pane: Esc falls through (ignored) — nothing crashes, nothing
    // else consumed it.
    expect(find.byType(InfoPanel), findsNothing);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
  });

  testWidgets('copy path writes the clipboard and posts the notice',
      (tester) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (message) async {
        if (message.method == 'Clipboard.setData') {
          clipboardText = (message.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('a.txt', size: 3)];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setCursorIndex(0);
    leftStrip.toggleInfoPanel();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('infoPanel.copyPath')));
    await tester.pump();

    expect(clipboardText, '/home/tester/a.txt');
    expect(find.text('Path copied to clipboard.'), findsOneWidget);

    // The notice's auto-dismiss timer must not outlive the test.
    left.dismissNotice();
    await tester.pump();
  });

  testWidgets('folder size computes on demand with progress and lands '
      'the settled total', (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('docs', type: RemoteFileType.directory),
    ];
    channel.listings['/home/tester/docs'] = [
      _entry('inner.txt', size: 4, root: '/home/tester/docs'),
      _entry(
        'deep',
        type: RemoteFileType.directory,
        root: '/home/tester/docs',
      ),
    ];
    channel.listings['/home/tester/docs/deep'] = [
      _entry('d.txt', size: 8, root: '/home/tester/docs/deep'),
    ];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setCursorIndex(0);
    leftStrip.toggleInfoPanel();
    await tester.pumpAndSettle();

    // The folder's size starts unevaluated — nothing measures until
    // the Calculate affordance fires (02 §2.6's on-demand rule).
    expect(inPanel(find.text('—')), findsWidgets);
    expect(channel.listCalls, isNot(contains('/home/tester/docs')));
    await tester.tap(find.byKey(const ValueKey('infoPanel.calculateSize')));
    await tester.pumpAndSettle();

    // The walk listed the folder and its child, then landed the total —
    // 12 B across 3 entries (inner.txt, deep, d.txt: directories count
    // as items too).
    expect(channel.listCalls, contains('/home/tester/docs'));
    expect(channel.listCalls, contains('/home/tester/docs/deep'));
    expect(inPanel(find.text('12 B — 3 items')), findsOneWidget);
    expect(left.folderSizeInFlight, isFalse);
  });

  testWidgets('folder size shows live progress and Cancel returns the '
      'affordance', (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('docs', type: RemoteFileType.directory),
    ];
    channel.listings['/home/tester/docs'] = [
      _entry('inner.txt', size: 4, root: '/home/tester/docs'),
    ];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setCursorIndex(0);
    leftStrip.toggleInfoPanel();
    await tester.pumpAndSettle();

    // Hold the walk's listing so progress is observable.
    final held = Completer<void>();
    channel.holdNext = held;
    await tester.tap(find.byKey(const ValueKey('infoPanel.calculateSize')));
    await tester.pump();

    expect(inPanel(find.textContaining('so far')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('infoPanel.cancelSize')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('infoPanel.cancelSize')));
    await tester.pump();
    expect(left.folderSizeInFlight, isFalse);
    expect(
      find.byKey(const ValueKey('infoPanel.calculateSize')),
      findsOneWidget,
    );
    // Release the held listing — the cancelled walk's late answer must
    // not resurrect the session.
    held.complete();
    await tester.pumpAndSettle();
    expect(left.folderSize, isNull);
  });

  testWidgets('a settled folder measure for another target never '
      'displays on retarget', (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('docs', type: RemoteFileType.directory),
      _entry('other', type: RemoteFileType.directory),
    ];
    channel.listings['/home/tester/docs'] = [
      _entry('inner.txt', size: 4, root: '/home/tester/docs'),
    ];
    channel.listings['/home/tester/other'] = const [];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setCursorIndex(0);
    leftStrip.toggleInfoPanel();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('infoPanel.calculateSize')));
    await tester.pumpAndSettle();
    expect(inPanel(find.text('4 B — 1 item')), findsOneWidget);

    // Retarget to the second folder: its Size row must not wear the
    // first folder's settled total.
    left.setCursorIndex(1);
    await tester.pump();
    expect(inPanel(find.text('other')), findsOneWidget);
    expect(inPanel(find.text('4 B — 1 item')), findsNothing);
    expect(
      find.byKey(const ValueKey('infoPanel.calculateSize')),
      findsOneWidget,
    );
  });

  testWidgets('an in-flight folder measure for another target never '
      'displays on retarget', (tester) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('docs', type: RemoteFileType.directory),
      _entry('other', type: RemoteFileType.directory),
    ];
    channel.listings['/home/tester/docs'] = [
      _entry('inner.txt', size: 4, root: '/home/tester/docs'),
    ];
    channel.listings['/home/tester/other'] = const [];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setCursorIndex(0);
    leftStrip.toggleInfoPanel();
    await tester.pumpAndSettle();

    // Hold the first walk's listing, then retarget mid-flight: the new
    // target shows Calculate, never the in-flight progress of 'docs'.
    final held = Completer<void>();
    channel.holdNext = held;
    await tester.tap(find.byKey(const ValueKey('infoPanel.calculateSize')));
    await tester.pump();
    expect(left.folderSizeInFlight, isTrue);

    left.setCursorIndex(1);
    await tester.pump();
    expect(inPanel(find.text('other')), findsOneWidget);
    expect(inPanel(find.textContaining('so far')), findsNothing);
    expect(
      find.byKey(const ValueKey('infoPanel.calculateSize')),
      findsOneWidget,
    );

    // The superseded-for-display walk still runs (a retarget back
    // rejoins it) — release it and let its result land on 'docs',
    // never on 'other'.
    held.complete();
    await tester.pumpAndSettle();
    expect(inPanel(find.text('4 B — 1 item')), findsNothing);
    expect(left.folderSize?.targetPath, '/home/tester/docs');
    expect(left.folderSizeInFlight, isFalse);
  });
}
