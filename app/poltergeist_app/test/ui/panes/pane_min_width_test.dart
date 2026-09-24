import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/layout/pane_allocation.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/test_panes.dart';

/// D32 §3.1: panes never get narrower than [minPaneWidth], and a pane at
/// exactly that width lays out without an overflow — tab bar, location
/// header, column header, rows, empty states, and every banner.
void main() {
  RemoteFileEntry entry(String name, {bool dir = false, int? size}) =>
      RemoteFileEntry(
        path: '/srv/www/$name',
        name: name,
        type: dir ? RemoteFileType.directory : RemoteFileType.file,
        size: size,
        modifiedAt: DateTime(2026, 9, 14, 9, 30),
      );

  Bookmark adhoc() {
    final now = DateTime.utc(2026, 9, 16);
    return Bookmark(
      id: 'adhoc:min-width',
      kind: BookmarkKind.remotePath,
      label: 'deploy@a-rather-long-host-name.example.com:2222',
      server: BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: 'a-rather-long-host-name.example.com',
          port: 2222,
          username: 'deploy',
          authMethod: AuthMethod.password,
        ),
      ),
      remotePath: '/srv/www',
      sortKey: 'adhoc:min-width',
      createdAt: now,
      updatedAt: now,
    );
  }

  Future<
    (
      PaneController,
      controller_test.FakePaneLanes,
      controller_test.FakePaneChannel,
    )
  >
  pump(
    WidgetTester tester, {
    required List<RemoteFileEntry> rows,
    double width = minPaneWidth,
  }) async {
    final lanes = controller_test.FakePaneLanes();
    final channel = controller_test.FakePaneChannel('/srv/www')
      ..listings['/srv/www'] = rows;
    lanes.nextRemoteChannel = channel;
    final controller = PaneController(
      paneTabId: 'pane.left.tab1',
      lanes: lanes,
    );
    final strip = testPaneStrip(controller, lanes: lanes);
    final right = PaneTabsController(paneId: 'pane.right', lanes: lanes);
    final workspace = WorkspaceController(left: strip, right: right);
    addTearDown(workspace.dispose);
    final node = FocusNode();
    addTearDown(node.dispose);
    await controller.connectRemote(adhoc(), initialPath: '/srv/www');

    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPoltergeistTheme(
          Brightness.light,
          platform: TargetPlatform.linux,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              key: const ValueKey('pane.frame'),
              width: width,
              height: 700,
              child: PaneTabsView(
                tabs: strip,
                workspace: workspace,
                focusNode: node,
                onSwapFocus: () {},
                onCancelRecovery: () {},
                bookmarks: FakeBookmarkStore(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller, lanes, channel);
  }

  testWidgets('a listing with long names, sizes and dates fits', (
    tester,
  ) async {
    final (controller, _, _) = await pump(
      tester,
      rows: [
        entry('a-folder-with-a-long-descriptive-name', dir: true),
        entry('quarterly-report-final-final-v3.pdf', size: 123456789),
        entry('x.txt', size: 12),
      ],
    );
    expect(tester.takeException(), isNull);

    // A selection summary replaces the item count in the header.
    controller.setCursorIndex(1);
    controller.selectAll();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a full tab strip fits', (tester) async {
    await pump(tester, rows: [entry('x.txt', size: 1)]);
    final strip = tester.widget<PaneTabsView>(find.byType(PaneTabsView)).tabs;
    for (var i = 0; i < 4; i++) {
      strip.newTab(target: NewTabTarget.launcher);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'tab ${i + 2}');
    }
    // Back on the bound tab with the strip full.
    strip.activateTab(strip.tabs.first);
    await tester.pumpAndSettle();
    expect(find.text('x.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rename editor keeps the name column at min width', (
    tester,
  ) async {
    final (controller, _, _) = await pump(
      tester,
      rows: [
        entry('untitled folder (2)', dir: true),
        entry('x.txt', size: 1),
      ],
    );
    controller.setCursorIndex(0);
    controller.startRename();
    await tester.pumpAndSettle();
    // The editor spans the name the row shows (the Size column is
    // folded away at this width), not a column the row does not have.
    final box = tester.getRect(
      find.byKey(const ValueKey('pane.left.tab1.rename.box')),
    );
    final frame = tester.getRect(find.byKey(const ValueKey('pane.frame')));
    // 12 px gap + the 116 px date column + the 10 px end inset.
    final nameColumnEnd = frame.right - (12 + 116 + 10);
    expect(box.width, greaterThan(60));
    expect(box.right, lessThanOrEqualTo(nameColumnEnd + 0.5));
    // A name longer than the column shows its start, not its tail.
    final editable = find.descendant(
      of: find.byKey(const ValueKey('pane.left.tab1.rename.field')),
      matching: find.byType(EditableText),
    );
    expect(
      tester.state<EditableTextState>(editable).renderEditable.offset.pixels,
      0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty folder fits', (tester) async {
    await pump(tester, rows: const []);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a notice and the lost-connection banner fit', (tester) async {
    final (controller, lanes, _) = await pump(
      tester,
      rows: [entry('x.txt', size: 1)],
    );
    controller.notePathCopied();
    await tester.pump();
    expect(tester.takeException(), isNull);

    lanes.emitState(
      'adhoc:min-width',
      const ServerStatus(ServerConnectionState.reconnecting),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump(controller.noticeLifetime);
  });

  testWidgets('the loading spinner and a failed listing fit', (tester) async {
    final (controller, _, channel) = await pump(
      tester,
      rows: [entry('x.txt', size: 1)],
    );
    // Past the anti-flash grace the header carries spinner + cancel.
    final hold = Completer<void>();
    channel.holdNext = hold;
    controller.refresh();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(
      find.byKey(const ValueKey('pane.left.tab1.progress')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    hold.complete();
    await tester.pumpAndSettle();

    channel.listingFailure = const RemoteFileException(
      kind: RemoteFileErrorKind.permissionDenied,
      operation: 'list',
      message: 'Permission denied',
    );
    controller.refresh();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('the pane splitter never takes pane B under the minimum', () {
    for (final width in [
      // The narrowest two-pane region: pane B hides below 600.
      600.0,
      900.0,
      1600.0,
    ]) {
      for (final ratio in [0.0, 0.01, 0.5, 0.99, 1.0, 4.0]) {
        final allocation = allocatePanes(
          width: width,
          ratio: ratio,
          secondPaneIntent: SecondPaneIntent.shown,
        );
        expect(
          allocation.secondaryWidth,
          greaterThanOrEqualTo(minPaneWidth),
          reason: '$width @ $ratio',
        );
        expect(
          allocation.primaryWidth,
          greaterThanOrEqualTo(minPaneWidth),
          reason: '$width @ $ratio',
        );
      }
    }
  });
}
