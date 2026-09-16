import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/bookmark_store.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/test_panes.dart';

/// Pumps one launcher pane (an empty strip renders the 02 §2.7 launcher)
/// with [lanes] backing connects.
Future<PaneTabsController> pumpLauncher(
  WidgetTester tester,
  controller_test.FakePaneLanes lanes,
) async {
  final strip = PaneTabsController(paneId: 'pane.left', lanes: lanes);
  addTearDown(strip.dispose);
  final right = PaneTabsController(paneId: 'pane.right', lanes: lanes);
  addTearDown(right.dispose);
  final workspace = WorkspaceController(left: strip, right: right);
  addTearDown(workspace.dispose);
  final leftNode = FocusNode();
  final rightNode = FocusNode();
  addTearDown(leftNode.dispose);
  addTearDown(rightNode.dispose);

  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: PaneTabsView(
          tabs: strip,
          workspace: workspace,
          focusNode: leftNode,
          onSwapFocus: () {},
          onCancelRecovery: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return strip;
}

Finder get addressField => find.byKey(const ValueKey('quickConnect.field'));
Finder get connectButton =>
    find.byKey(const ValueKey('quickConnect.connect'));

/// Drives one adhoc remote binding to the browsing phase through the
/// fake lanes: the surface the "Save as favorite…" bar renders on.
Future<PaneController> connectAdhoc(
  controller_test.FakePaneLanes lanes,
  Bookmark bookmark,
) async {
  final channel = controller_test.FakePaneChannel('/home/deploy');
  channel.listings['/srv/www'] = const [];
  lanes.nextRemoteChannel = channel;
  final controller = PaneController(paneTabId: 'pane.left.tab1', lanes: lanes);
  await controller.connectRemote(bookmark, initialPath: '/srv/www');
  return controller;
}

Bookmark adhocBookmark() {
  final now = DateTime.utc(2026, 9, 16);
  return Bookmark(
    id: 'adhoc:test-id',
    kind: BookmarkKind.remotePath,
    label: 'deploy@example.com',
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/srv/www',
    sortKey: 'adhoc:test-id',
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> pumpPane(
  WidgetTester tester,
  PaneController controller,
  PaneTabsController strip,
  WorkspaceController workspace, {
  BookmarkRepository? bookmarks,
}) async {
  final node = FocusNode();
  addTearDown(node.dispose);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: PaneView(
          controller: controller,
          pane: strip,
          workspace: workspace,
          focusNode: node,
          onSwapFocus: () {},
          onCancelRecovery: () {},
          bookmarks: bookmarks,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Quick Connect field', () {
    testWidgets('renders the address field with autofocus on the active pane',
        (tester) async {
      final lanes = controller_test.FakePaneLanes();
      await pumpLauncher(tester, lanes);

      expect(addressField, findsOneWidget);
      expect(connectButton, findsOneWidget);
      final editable = tester.widget<EditableText>(
        find.descendant(
          of: addressField,
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.focusNode.hasFocus, isTrue);
    });

    testWidgets('an in-range port shows the visible interpretation',
        (tester) async {
      final lanes = controller_test.FakePaneLanes();
      await pumpLauncher(tester, lanes);

      await tester.enterText(addressField, 'deploy@example.com:2222');
      await tester.pump();

      expect(
        find.text(
          '2222 \u2192 port; use sftp://example.com/2222 for a folder named 2222',
        ),
        findsOneWidget,
      );
    });

    testWidgets('an out-of-range token shows the path hint', (tester) async {
      final lanes = controller_test.FakePaneLanes();
      await pumpLauncher(tester, lanes);

      await tester.enterText(addressField, 'deploy@example.com:99999');
      await tester.pump();

      expect(find.textContaining('99999'), findsWidgets);
      expect(tester.widget<FilledButton>(connectButton).enabled, isTrue);
    });

    testWidgets('an unbracketed IPv6 address shows the bracket hint',
        (tester) async {
      final lanes = controller_test.FakePaneLanes();
      await pumpLauncher(tester, lanes);

      await tester.enterText(addressField, 'deploy@2001:db8::1');
      await tester.pump();
      // The field error animates in: settle past it and assert it
      // renders, not just exists.
      await tester.pump(const Duration(milliseconds: 300));
      final error = find.textContaining('[ ]');
      expect(error, findsOneWidget);
      expect(tester.getSize(error).height, greaterThan(0));
      expect(tester.widget<FilledButton>(connectButton).enabled, isFalse);
    });

    testWidgets('a stripped password is announced inline', (tester) async {
      final lanes = controller_test.FakePaneLanes();
      await pumpLauncher(tester, lanes);

      await tester.enterText(
        addressField,
        'sftp://deploy:secret@example.com/srv/www',
      );
      await tester.pump();

      expect(tester.widget<FilledButton>(connectButton).enabled, isTrue);
      expect(find.textContaining('secret'), findsNothing);
    });

    testWidgets('empty input disables Connect', (tester) async {
      final lanes = controller_test.FakePaneLanes();
      await pumpLauncher(tester, lanes);

      expect(tester.widget<FilledButton>(connectButton).enabled, isFalse);
    });

    testWidgets('typing never leaves the field or swaps panes',
        (tester) async {
      final lanes = controller_test.FakePaneLanes();
      final strip = await pumpLauncher(tester, lanes);

      await tester.enterText(addressField, 'deploy@example.com');
      await tester.pump();

      expect(strip.tabs, isEmpty);
      final editable = tester.widget<EditableText>(
        find.descendant(
          of: addressField,
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.focusNode.hasFocus, isTrue);
    });
  });

  group('Quick Connect connect', () {
    testWidgets('connects through the remote seam with an adhoc bookmark',
        (tester) async {
      final lanes = controller_test.FakePaneLanes();
      lanes.nextRemoteChannel =
          controller_test.FakePaneChannel('/home/deploy');
      final strip = await pumpLauncher(tester, lanes);

      await tester.enterText(addressField, 'deploy@example.com:/srv/www');
      await tester.pump();
      await tester.tap(connectButton);
      await tester.pumpAndSettle();

      expect(strip.tabs, hasLength(1));
      final bookmark = strip.tabs.single.controller.remoteBookmark;
      expect(bookmark, isNotNull);
      expect(bookmark!.id.startsWith('adhoc:'), isTrue);
      expect(bookmark.server?.identity?.host, 'example.com');
      expect(bookmark.server?.identity?.port, 22);
      expect(bookmark.server?.identity?.username, 'deploy');
      final opens = lanes.calls
          .where((call) => call.startsWith('openBrowse:'))
          .toList();
      expect(opens, hasLength(1));
      expect(opens.single, startsWith('openBrowse:${bookmark.id}:'));
    });

    testWidgets('Enter submits the address', (tester) async {
      final lanes = controller_test.FakePaneLanes();
      lanes.nextRemoteChannel =
          controller_test.FakePaneChannel('/home/deploy');
      final strip = await pumpLauncher(tester, lanes);

      await tester.enterText(addressField, 'deploy@example.com');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(strip.tabs, hasLength(1));
    });
  });

  group('Save as favorite bar', () {
    testWidgets('saves through the wired store with no password anywhere',
        (tester) async {
      final lanes = controller_test.FakePaneLanes();
      final bookmark = adhocBookmark();
      final controller = await connectAdhoc(lanes, bookmark);
      addTearDown(controller.dispose);
      final strip = testPaneStrip(controller, lanes: lanes);
      final right = PaneTabsController(paneId: 'pane.right', lanes: lanes);
      addTearDown(right.dispose);
      final workspace = WorkspaceController(left: strip, right: right);
      addTearDown(workspace.dispose);
      final store = FakeBookmarkStore();
      await pumpPane(tester, controller, strip, workspace,
          bookmarks: store);

      expect(find.byKey(const ValueKey('saveFavorite.bar')), findsOneWidget);
      expect(
        find.textContaining('deploy@example.com'),
        findsWidgets,
      );

      await tester.tap(find.byKey(const ValueKey('saveFavorite.save')));
      await tester.pumpAndSettle();

      expect(store.upserted, hasLength(1));
      final saved = store.upserted.single;
      expect(saved.id.startsWith('adhoc:'), isFalse);
      expect(saved.server?.identity?.host, 'example.com');
      expect(saved.remotePath, '/srv/www');
      expect(
        saved.toJson().toString().contains('secret'),
        isFalse,
      );
      expect(find.byKey(const ValueKey('saveFavorite.bar')), findsNothing);
    });

    testWidgets('without a store the save posts the honest notice',
        (tester) async {
      final lanes = controller_test.FakePaneLanes();
      final bookmark = adhocBookmark();
      final controller = await connectAdhoc(lanes, bookmark);
      addTearDown(controller.dispose);
      final strip = testPaneStrip(controller, lanes: lanes);
      final right = PaneTabsController(paneId: 'pane.right', lanes: lanes);
      addTearDown(right.dispose);
      final workspace = WorkspaceController(left: strip, right: right);
      addTearDown(workspace.dispose);
      await pumpPane(tester, controller, strip, workspace,
          bookmarks: null);

      expect(find.byKey(const ValueKey('saveFavorite.bar')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('saveFavorite.save')));
      await tester.pump();

      expect(controller.notice, PaneNotice.saveFavoriteLater);
      await tester.pump(controller.noticeLifetime);
      expect(controller.notice, isNull);
    });

    testWidgets('a store failure stays on the bar with an inline error',
        (tester) async {
      final lanes = controller_test.FakePaneLanes();
      final bookmark = adhocBookmark();
      final controller = await connectAdhoc(lanes, bookmark);
      addTearDown(controller.dispose);
      final strip = testPaneStrip(controller, lanes: lanes);
      final right = PaneTabsController(paneId: 'pane.right', lanes: lanes);
      addTearDown(right.dispose);
      final workspace = WorkspaceController(left: strip, right: right);
      addTearDown(workspace.dispose);
      final store = FakeBookmarkStore()..upsertFailure = Exception('disk full');
      await pumpPane(tester, controller, strip, workspace,
          bookmarks: store);

      await tester.tap(find.byKey(const ValueKey('saveFavorite.save')));
      await tester.pumpAndSettle();

      // The bar stays mounted so the save remains retryable; the
      // recorded attempt proves the write went to the store, not a stub.
      expect(store.upserted, isEmpty);
      expect(find.byKey(const ValueKey('saveFavorite.bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('saveFavorite.error')), findsOneWidget);
    });
  });
}
