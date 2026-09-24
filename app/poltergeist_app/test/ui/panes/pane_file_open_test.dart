import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show PointerDeviceKind, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/double_click_action.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
  String parent = '/home/tester',
}) {
  return RemoteFileEntry(
    path: '$parent/$name',
    name: name,
    type: type,
    size: size,
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

void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController left;
  late PaneController right;
  late PaneTabsController leftStrip;
  late PaneTabsController rightStrip;
  late WorkspaceController workspace;
  late FocusNode leftNode;
  late FocusNode rightNode;
  late List<Object> reported;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    reported = <Object>[];
    left = PaneController(
      paneTabId: 'pane.left',
      lanes: lanes,
      onError: (error, _) => reported.add(error),
    );
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

  /// [platform] picks the row gesture model (D32 §6/§9): desktop rows
  /// select on press and open on a double-click, touch rows open on a
  /// tap. Defaults to the overridden host, else Linux.
  Future<void> pumpShell(WidgetTester tester, {TargetPlatform? platform}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform:
              platform ??
              debugDefaultTargetPlatformOverride ??
              TargetPlatform.linux,
        ),
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
          ),
        ),
      ),
    );
  }

  /// docs (a folder) plus two files, sorted directories-first then by
  /// name: docs, notes.md, report.txt.
  controller_test.FakePaneChannel localChannel() {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('docs', type: RemoteFileType.directory),
      _entry('report.txt', size: 2048),
      _entry('notes.md', size: 10),
    ];
    channel.listings['/home/tester/docs'] = const [];
    lanes.nextLocalChannel = channel;
    return channel;
  }

  /// Two presses inside the double-click window: the second is the
  /// §2.6 Open gesture, the first only selects (at pointer-down).
  Future<void> doubleTapRow(WidgetTester tester, String name) async {
    await tester.tap(find.text(name));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
  }

  testWidgets('a single press selects at once and never opens', (
    tester,
  ) async {
    final channel = localChannel();
    await left.openLocalHome();
    await pumpShell(tester);

    await tester.tap(find.text('report.txt'));
    // No double-tap recognizer to wait out: the press already selected.
    await tester.pump();
    expect(left.cursorIndex, 2);
    expect(left.isRowSelected(2), isTrue);
    await tester.pumpAndSettle();
    expect(channel.openCalls, isEmpty);

    // Past the double-click window, a second press is a fresh click.
    await tester.pump(kDoubleTapTimeout);
    await tester.tap(find.text('report.txt'));
    await tester.pumpAndSettle();
    expect(channel.openCalls, isEmpty);
  });

  /// One primary mouse click stamped at [at] — the event's own clock,
  /// which the double-click decision reads (the frame clock can lag it).
  Future<void> clickAt(WidgetTester tester, String name, Duration at) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.down(tester.getCenter(find.text(name)), timeStamp: at);
    await gesture.up(timeStamp: at + const Duration(milliseconds: 8));
    await gesture.removePointer();
  }

  testWidgets('a double-click is judged by the events\' timestamps, even '
      'when a slow frame delays the second press', (tester) async {
    final channel = localChannel();
    await left.openLocalHome();
    await pumpShell(tester);

    await clickAt(tester, 'report.txt', const Duration(seconds: 10));
    // A heavy rebuild: the frame clock runs far past the window before
    // the already-queued second press dispatches.
    await tester.pump(const Duration(milliseconds: 400));
    await clickAt(tester, 'report.txt', const Duration(milliseconds: 10060));
    await tester.pumpAndSettle();

    expect(channel.openCalls, ['/home/tester/report.txt']);
  });

  testWidgets('presses further apart than the window are two clicks, '
      'however fast the frames', (tester) async {
    final channel = localChannel();
    await left.openLocalHome();
    await pumpShell(tester);

    await clickAt(tester, 'report.txt', const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 16));
    await clickAt(tester, 'report.txt', const Duration(milliseconds: 10400));
    await tester.pumpAndSettle();

    expect(channel.openCalls, isEmpty);
    expect(left.isRowSelected(2), isTrue);
  });

  testWidgets('a double-click in the inactive pane opens there', (
    tester,
  ) async {
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = [
      _entry('archive', type: RemoteFileType.directory),
      _entry('b.txt', size: 1),
    ];
    channel.listings['/home/tester/archive'] = const [];
    lanes.nextLocalChannel = localChannel();
    await left.openLocalHome();
    lanes.nextLocalChannel = channel;
    await right.openLocalHome();
    await pumpShell(tester);
    expect(workspace.activePane, same(leftStrip));

    // The first press activates pane B (a rebuild of both panes and the
    // inspector's target), then the second lands late on the frame clock.
    await clickAt(tester, 'archive', const Duration(seconds: 20));
    await tester.pump(const Duration(milliseconds: 350));
    await clickAt(tester, 'archive', const Duration(milliseconds: 20070));
    await tester.pumpAndSettle();

    expect(workspace.activePane, same(rightStrip));
    expect(right.location?.path, '/home/tester/archive');
  });

  testWidgets('two presses on different rows are two clicks, never a '
      'double-click', (tester) async {
    final channel = localChannel();
    await left.openLocalHome();
    await pumpShell(tester);

    await tester.tap(find.text('notes.md'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('report.txt'));
    await tester.pumpAndSettle();

    expect(channel.openCalls, isEmpty);
    expect(left.cursorIndex, 2);
  });

  testWidgets('on touch platforms a tap opens (D32 §9)', (tester) async {
    final channel = localChannel();
    await left.openLocalHome();
    await pumpShell(tester, platform: TargetPlatform.android);

    await tester.tap(find.text('report.txt'));
    await tester.pumpAndSettle();
    expect(channel.openCalls, ['/home/tester/report.txt']);

    await tester.tap(find.text('docs'));
    await tester.pumpAndSettle();
    expect(left.location?.path, '/home/tester/docs');
  });

  testWidgets('a double-tap on a file row launches through the channel '
      'under the default Open', (tester) async {
    final channel = localChannel();
    await left.openLocalHome();
    await pumpShell(tester);

    await doubleTapRow(tester, 'report.txt');

    expect(channel.openCalls, ['/home/tester/report.txt']);
    // The pane stayed put — a file open is not a navigation.
    expect(left.location?.path, '/home/tester');
    expect(left.notice, isNull);
    expect(left.error, isNull);
  });

  testWidgets('a double-tap on a folder navigates under every action '
      'value', (tester) async {
    final channel = localChannel();
    await left.openLocalHome();
    await pumpShell(tester);

    for (final action in DoubleClickAction.values) {
      left.doubleClickAction = action;
      await doubleTapRow(tester, 'docs');
      expect(left.location?.path, '/home/tester/docs');
      left.goUp();
      await tester.pumpAndSettle();
    }

    expect(channel.openCalls, isEmpty);
    expect(left.notice, isNull);
  });

  testWidgets('Enter opens the cursor file on Linux', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final channel = localChannel();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.setCursorIndex(2); // report.txt (docs, notes.md sort ahead)
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(channel.openCalls, ['/home/tester/report.txt']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the deferred-action notice renders as a dismissible '
      'strip', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      localChannel();
      await left.openLocalHome();
      await pumpShell(tester);
      leftNode.requestFocus();
      await tester.pump();

      left.doubleClickAction = DoubleClickAction.edit;
      left.setCursorIndex(2); // report.txt
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(
        find.text(
          "Editing files in Poltergeist isn't available yet — the "
          'editor arrives in a later milestone.',
        ),
        findsOneWidget,
      );

      // The ✕ dismisses early (02 §10: transient or dismiss — both).
      await tester.tap(
        find.byKey(const ValueKey('pane.left.notice.dismiss')),
      );
      await tester.pumpAndSettle();
      expect(left.notice, isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the remote-unavailable notice renders on a remote file '
      'and never launches', (tester) async {
    final remote = controller_test.FakePaneChannel('/srv/home');
    remote.listings['/srv/home'] = [
      _entry('remote.txt', parent: '/srv/home'),
    ];
    lanes.nextRemoteChannel = remote;
    await left.connectRemote(_remoteBookmark());
    await pumpShell(tester);
    await tester.pumpAndSettle();

    await doubleTapRow(tester, 'remote.txt');

    expect(
      find.text(
        "Remote files can't be opened in place yet — Poltergeist will "
        'download and open them in a later milestone.',
      ),
      findsOneWidget,
    );
    expect(remote.openCalls, isEmpty);
    expect(left.error, isNull);

    // The ✕ dismisses early — and retires the auto-dismiss timer.
    await tester.tap(
      find.byKey(const ValueKey('pane.left.notice.dismiss')),
    );
    await tester.pumpAndSettle();
    expect(left.notice, isNull);
  });

  testWidgets('a launcher failure renders in the pane inline error — '
      'never a modal', (tester) async {
    localChannel().openFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.other,
      operation: 'open',
      message: 'No application is registered for this file.',
    );
    await left.openLocalHome();
    await pumpShell(tester);

    await doubleTapRow(tester, 'report.txt');

    expect(
      find.text('No application is registered for this file.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('pane.error.retry')), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(left.notice, isNull);
  });

  testWidgets('a launcher failure leaves the pane usable and retires on '
      'the next selection', (tester) async {
    localChannel().openFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.other,
      operation: 'open',
      message: 'No application is registered for this file.',
    );
    await left.openLocalHome();
    await pumpShell(tester);

    await doubleTapRow(tester, 'report.txt');
    expect(find.byKey(const ValueKey('pane.error.retry')), findsOneWidget);

    // A failed Open is about ONE file: the folder is still listed, so
    // copy, delete and the rest stay live rather than stranding the
    // user until Retry (which would only fail the same way again).
    expect(left.verbsEnabled, isTrue);

    left.setCursorIndex(left.cursorIndex! == 0 ? 1 : 0);
    await tester.pumpAndSettle();
    expect(left.error, isNull);
    expect(find.byKey(const ValueKey('pane.error.retry')), findsNothing);
  });

  testWidgets('an untyped launcher failure renders the authored fault '
      'line', (tester) async {
    localChannel().openFailure = StateError('spawn failed');
    await left.openLocalHome();
    await pumpShell(tester);

    await doubleTapRow(tester, 'report.txt');

    expect(find.text('The file could not be opened.'), findsOneWidget);
    expect(find.byKey(const ValueKey('pane.error.retry')), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    // The opaque error also reports through the pane's error sink —
    // the same non-VFS route as every other untyped pane failure.
    expect(reported.single, isA<StateError>());
  });
}
