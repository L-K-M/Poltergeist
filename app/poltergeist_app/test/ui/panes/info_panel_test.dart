import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
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

  /// Esc presses the panel routed out of itself — the inspector's
  /// handler in the shell.
  late List<KeyEvent> routedEscapes;

  /// Mounts both panes beside the D32 inspector's Info column: the
  /// panel follows the ACTIVE tab, exactly as the inspector mounts it.
  Future<void> pumpShell(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    routedEscapes = [];

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
              SizedBox(
                width: 280,
                child: ListenableBuilder(
                  listenable: workspace,
                  builder: (context, _) {
                    final controller = workspace.activeTabController;
                    if (controller == null) return const SizedBox.shrink();
                    return ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) => SingleChildScrollView(
                        child: InfoPanel(
                          controller: controller,
                          clock: _fixedClock,
                          onEscape: (event) {
                            routedEscapes.add(event);
                            return KeyEventResult.handled;
                          },
                        ),
                      ),
                    );
                  },
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
    // The D28 editor: the symbolic preview, the octal field seeded
    // with the listed mode, and the rwx grid — the read-only combined
    // line only renders for targets the editor cannot touch.
    expect(inPanel(find.text('rw-r--r--')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('infoPanel.octalField')),
          )
          .controller
          ?.text,
      '0644',
    );
    expect(
      find.byKey(const ValueKey('infoPanel.permCell.owner.read')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('infoPanel.applyPermissions')),
      findsOneWidget,
    );
    // 'Owner'/'Group' render twice — the metadata row label and the
    // permission grid's class row.
    expect(inPanel(find.text('Owner')), findsNWidgets(2));
    expect(inPanel(find.text('501')), findsOneWidget);
    expect(inPanel(find.text('Group')), findsNWidgets(2));
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

    // The inspector follows the ACTIVE pane's tab.
    workspace.setActivePane(rightStrip);
    right.setCursorIndex(0);
    await tester.pumpAndSettle();

    expect(find.byType(InfoPanel), findsOneWidget);
    expect(inPanel(find.text('deploy.sh')), findsOneWidget);
    expect(inPanel(find.text('rwxr-xr-x')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('infoPanel.octalField')),
          )
          .controller
          ?.text,
      '0755',
    );
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

  testWidgets('a row press retargets the panel at pointer-down', (
    tester,
  ) async {
    // Desktop pointer semantics (D32 §6): select on press, no wait.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('a.txt', size: 1),
        _entry('b.txt', size: 2),
      ];
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);

      left.setCursorIndex(0);
      await tester.pumpAndSettle();
      expect(inPanel(find.text('a.txt')), findsOneWidget);

      await tester.tap(find.text('b.txt'));
      await tester.pump();
      expect(left.cursorIndex, 1);
      expect(inPanel(find.text('b.txt')), findsOneWidget);

      // Let the double-click window lapse, then release the focus the
      // press bounced to the listing — disposing a still-focused node
      // at teardown schedules an update on the binding's already-dead
      // FocusManager.
      await tester.pump(kDoubleTapTimeout);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the listing\'s Esc has no panel tier: the inspector owns '
      'the panel, so the first Esc clears an unfocused filter', (
    tester,
  ) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('a.txt'),
      _entry('b.txt'),
    ];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setFilterQuery('a');
    left.setCursorIndex(0);
    await tester.pumpAndSettle();
    leftNode.requestFocus();
    await tester.pump();
    expect(find.byType(InfoPanel), findsOneWidget);
    expect(left.filterActive, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(left.filterActive, isFalse);
    expect(find.byType(InfoPanel), findsOneWidget,
        reason: 'the pane never hides the inspector\'s panel');
    expect(routedEscapes, isEmpty);

    // Release the pane's primary focus before teardown — disposing a
    // still-focused node schedules an update on the binding's already-
    // dead FocusManager.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
  });

  testWidgets('Esc pressed while a panel control holds focus routes to '
      'the inspector', (tester) async {
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
    await tester.pumpAndSettle();

    // Tapping Calculate starts the walk. The listing is held so the
    // walk is still in flight when Esc lands.
    final held = Completer<void>();
    channel.holdNext = held;
    await tester.tap(find.byKey(const ValueKey('infoPanel.calculateSize')));
    await tester.pump();
    expect(left.folderSizeInFlight, isTrue);

    // Focus the Cancel control itself — a tap doesn't move primary
    // focus in tests, so request the button's own node.
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
    await tester.pump();
    expect(routedEscapes, hasLength(1),
        reason: 'the panel hands Esc to its host, never swallows it');

    held.complete();
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
  });

  testWidgets('the panel carries no close affordance of its own', (
    tester,
  ) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [_entry('a.txt')];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await pumpShell(tester);

    left.setCursorIndex(0);
    await tester.pumpAndSettle();
    expect(inPanel(find.text('a.txt')), findsOneWidget);
    expect(inPanel(find.byIcon(Icons.close)), findsNothing,
        reason: 'the inspector column owns visibility (D32 §3)');
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

  group('permissions editor (02 §2.6, D28)', () {
    Finder octalField() =>
        find.byKey(const ValueKey('infoPanel.octalField'));

    String octalText(WidgetTester tester) =>
        tester.widget<TextField>(octalField()).controller!.text;

    bool cellValue(WidgetTester tester, String row, String column) =>
        tester
            .widget<Checkbox>(
              find.byKey(ValueKey('infoPanel.permCell.$row.$column')),
            )
            .value!;

    testWidgets('the octal field and the rwx grid stay in sync both '
        'ways, and Apply issues the chmod', (tester) async {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('report.txt', size: 2048, mode: 0x81A4),
      ];
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);

      left.setCursorIndex(0);
      await tester.pumpAndSettle();

      // Checkbox → field: toggling others-write re-seeds the octal.
      await tester.tap(
        find.byKey(const ValueKey('infoPanel.permCell.others.write')),
      );
      await tester.pump();
      expect(octalText(tester), '0646');
      expect(cellValue(tester, 'others', 'write'), isTrue);

      // Field → checkboxes: a typed value moves the grid.
      await tester.enterText(octalField(), '0600');
      await tester.pump();
      expect(cellValue(tester, 'others', 'write'), isFalse);
      expect(cellValue(tester, 'owner', 'read'), isTrue);
      expect(cellValue(tester, 'owner', 'write'), isTrue);
      expect(cellValue(tester, 'others', 'read'), isFalse);
      expect(inPanel(find.text('rw-------')), findsOneWidget);

      // Apply writes the draft's exact mode through the channel.
      await tester.ensureVisible(
        find.byKey(const ValueKey('infoPanel.applyPermissions')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('infoPanel.applyPermissions')),
      );
      await tester.pumpAndSettle();
      expect(
        channel.permissionsCalls,
        [('/home/tester/report.txt', 0x180)],
      );
    });

    testWidgets('invalid octal shows the inline error and blocks the '
        'chmod', (tester) async {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('report.txt', size: 2048, mode: 0x81A4),
      ];
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);

      left.setCursorIndex(0);
      await tester.pumpAndSettle();

      await tester.ensureVisible(octalField());
      await tester.pump();
      await tester.enterText(octalField(), '8888');
      await tester.pump();

      expect(
        inPanel(find.text('Use four octal digits (0000–7777).')),
        findsOneWidget,
      );
      final apply = tester.widget<TextButton>(
        find.byKey(const ValueKey('infoPanel.applyPermissions')),
      );
      expect(apply.onPressed, isNull);
      expect(channel.permissionsCalls, isEmpty);
    });

    testWidgets('a typed refusal renders inline under the editor',
        (tester) async {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('report.txt', size: 2048, mode: 0x81A4),
      ];
      channel.permissionsFailure = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'setMode',
        message: 'denied',
      );
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);

      left.setCursorIndex(0);
      await tester.pumpAndSettle();

      await tester.ensureVisible(octalField());
      await tester.pump();
      await tester.enterText(octalField(), '0600');
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('infoPanel.applyPermissions')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('infoPanel.applyPermissions')),
      );
      await tester.pumpAndSettle();

      expect(
        inPanel(
          find.text('Permission denied — you may not own this item.'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a symbolic-link target renders the display row with '
        'its read-only reason', (tester) async {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry(
          'link',
          type: RemoteFileType.symbolicLink,
          mode: 0xA1FF,
        ),
      ];
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);

      left.setCursorIndex(0);
      await tester.pumpAndSettle();

      expect(inPanel(find.text('rwxrwxrwx (0777)')), findsOneWidget);
      expect(
        inPanel(
          find.text("A symbolic link's permissions can't be changed."),
        ),
        findsOneWidget,
      );
      expect(octalField(), findsNothing);
    });

    testWidgets('a flagged name renders the display row with its '
        'read-only reason', (tester) async {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('bad\uFFFDname', mode: 0x81A4),
      ];
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);

      left.setCursorIndex(0);
      await tester.pumpAndSettle();

      expect(
        inPanel(
          find.text(
            "The name is not valid UTF-8 — it can't be sent to the "
            'server.',
          ),
        ),
        findsOneWidget,
      );
      expect(octalField(), findsNothing);
    });

    testWidgets('Esc in the octal field reverts a pending draft, then '
        'routes out once clean', (tester) async {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('report.txt', size: 2048, mode: 0x81A4),
      ];
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);

      left.setCursorIndex(0);
      await tester.pumpAndSettle();

      await tester.tap(octalField());
      await tester.pump();
      await tester.enterText(octalField(), '0600');
      await tester.pump();

      // First Esc reverts the draft in place — never a commit.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(octalText(tester), '0644');
      expect(find.byType(InfoPanel), findsOneWidget);
      expect(channel.permissionsCalls, isEmpty);

      // A clean field's Esc falls through to the inspector's handler.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(routedEscapes, hasLength(1));

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
    });

    testWidgets('apply to enclosed asks with the counted copy, then '
        'writes the tree', (tester) async {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
      ];
      channel.listings['/home/tester/docs'] = [
        _entry('a.txt', size: 4, mode: 0x81A4, root: '/home/tester/docs'),
        _entry('b.txt', size: 8, mode: 0x81A4, root: '/home/tester/docs'),
      ];
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);

      left.setCursorIndex(0);
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const ValueKey('infoPanel.applyEnclosed')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('infoPanel.applyEnclosed')),
      );
      await tester.pumpAndSettle();

      // The counted confirmation: the mode and the quantified reach.
      expect(find.text('Apply to enclosed items?'), findsOneWidget);
      expect(
        find.text('Apply 0755 to “docs” and the 2 items inside it?'),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('infoPanel.enclosedConfirm')),
      );
      await tester.pumpAndSettle();

      expect(channel.permissionsCalls, [
        ('/home/tester/docs/a.txt', 0x1ED),
        ('/home/tester/docs/b.txt', 0x1ED),
        ('/home/tester/docs', 0x1ED),
      ]);
      expect(inPanel(find.text('3 items changed')), findsOneWidget);
    });

    testWidgets('declining the enclosed confirmation touches nothing',
        (tester) async {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
      ];
      channel.listings['/home/tester/docs'] = [
        _entry('a.txt', size: 4, mode: 0x81A4, root: '/home/tester/docs'),
      ];
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);

      left.setCursorIndex(0);
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const ValueKey('infoPanel.applyEnclosed')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('infoPanel.applyEnclosed')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Apply to enclosed items?'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('infoPanel.enclosedDecline')),
      );
      await tester.pumpAndSettle();

      expect(channel.permissionsCalls, isEmpty);
      expect(left.enclosedApply, isNull);
    });

    testWidgets('the enclosed confirmation ignores a scrim tap and '
        'answers declined on system back', (tester) async {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('docs', type: RemoteFileType.directory, mode: 0x41ED),
      ];
      channel.listings['/home/tester/docs'] = [
        _entry('a.txt', size: 4, mode: 0x81A4, root: '/home/tester/docs'),
      ];
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);

      left.setCursorIndex(0);
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const ValueKey('infoPanel.applyEnclosed')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('infoPanel.applyEnclosed')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Apply to enclosed items?'), findsOneWidget);

      // The barrier is non-dismissible — a scrim tap must not close
      // the dialog (an unlatched dismissal would race _settle into a
      // second pop of the route beneath).
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Apply to enclosed items?'), findsOneWidget);

      // System back answers declined through the dialog's own latch —
      // once, never twice.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Apply to enclosed items?'), findsNothing);
      expect(channel.permissionsCalls, isEmpty);
      expect(left.enclosedApply, isNull);
      expect(find.byType(InfoPanel), findsOneWidget);
    });

    testWidgets('Esc in the octal field while a write is in flight '
        'never reverts the draft', (tester) async {
      final channel = controller_test.FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('report.txt', size: 2048, mode: 0x81A4),
      ];
      lanes.nextLocalChannel = channel;
      await left.openLocalHome();
      await pumpShell(tester);

      left.setCursorIndex(0);
      await tester.pumpAndSettle();

      await tester.tap(octalField());
      await tester.pump();
      await tester.enterText(octalField(), '0700');
      await tester.pump();

      // Park the write mid-flight, then Esc: the field is disabled, so
      // its revert tier ignores the key — the draft stands.
      final held = Completer<void>();
      channel.heldPermissions = held;
      unawaited(left.applyPermissions());
      await tester.pump();
      expect(left.permissionsEdit?.applying, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(octalText(tester), '0700');
      expect(left.permissionsEdit?.mode, 0x1C0);

      held.complete();
      await tester.pump();
      expect(channel.permissionsCalls, [
        ('/home/tester/report.txt', 0x1C0),
      ]);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
    });
  });
}
