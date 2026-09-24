import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_tabs_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_app/ui/panes/quick_connect_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/test_panes.dart';

/// Pumps one launcher pane (an empty strip renders the 02 §2.7 launcher)
/// with [lanes] backing connects.
Future<PaneTabsController> pumpLauncher(
  WidgetTester tester,
  controller_test.FakePaneLanes lanes, {
  VoidCallback? onImportSshConfig,
}) async {
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
          onImportSshConfig: onImportSshConfig,
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

Bookmark adhocBookmark({
  String id = 'adhoc:test-id',
  String label = 'deploy@example.com',
}) {
  final now = DateTime.utc(2026, 9, 16);
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: label,
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/srv/www',
    sortKey: id,
    createdAt: now,
    updatedAt: now,
  );
}

Future<void> pumpPane(
  WidgetTester tester,
  PaneController controller,
  PaneTabsController strip,
  WorkspaceController workspace, {
  BookmarkStore? bookmarks,
  ThemeData? theme,
}) async {
  final node = FocusNode();
  addTearDown(node.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
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

    testWidgets('the address field takes no autocorrect or suggestions',
        (tester) async {
      final lanes = controller_test.FakePaneLanes();
      await pumpLauncher(tester, lanes);

      final field = tester.widget<TextField>(addressField);
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(field.keyboardType, TextInputType.url);
    });

    testWidgets('the ssh_config offer invokes its callback', (tester) async {
      final lanes = controller_test.FakePaneLanes();
      var taps = 0;
      await pumpLauncher(tester, lanes, onImportSshConfig: () => taps++);

      final offer = find.byKey(const ValueKey('quickConnect.importSshConfig'));
      expect(offer, findsOneWidget);
      await tester.tap(offer);
      expect(taps, 1);
    });

    testWidgets('no import seam mounts no offer', (tester) async {
      final lanes = controller_test.FakePaneLanes();
      await pumpLauncher(tester, lanes);
      // Guard against a vacuous pass: the launcher itself must be up.
      expect(find.byType(TextField), findsWidgets);
      expect(
        find.byKey(const ValueKey('quickConnect.importSshConfig')),
        findsNothing,
      );
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

  group('Quick Connect prefill (D32 §6)', () {
    Future<void> pumpForm(
      WidgetTester tester,
      Map<String, String> environment,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: QuickConnectView(
              focusNode: node,
              environment: environment,
              onConnect: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    test('USER wins, USERNAME is the Windows fallback, none means blank',
        () {
      expect(quickConnectUserPrefill({'USER': 'lkm'}), 'lkm@');
      expect(quickConnectUserPrefill({'USERNAME': 'Lukas'}), 'Lukas@');
      expect(
        quickConnectUserPrefill({'USER': 'a', 'USERNAME': 'b'}),
        'a@',
      );
      expect(quickConnectUserPrefill(const {}), '');
    });

    testWidgets('the field starts at "\$USER@" with the host helper and '
        'no error', (tester) async {
      await pumpForm(tester, {'USER': 'demo'});

      final field = tester.widget<TextField>(addressField);
      expect(field.controller?.text, 'demo@');
      expect(
        field.controller?.selection,
        const TextSelection.collapsed(offset: 5),
        reason: 'typing appends the host',
      );
      expect(find.text('host[:port]'), findsOneWidget);
      // A bare user@ is not an address yet — but it is not an error.
      expect(field.decoration?.errorText, isNull);
      expect(tester.widget<FilledButton>(connectButton).enabled, isFalse);

      await tester.enterText(addressField, 'demo@example.com');
      await tester.pump();
      expect(find.text('host[:port]'), findsNothing);
      expect(tester.widget<FilledButton>(connectButton).enabled, isTrue);
    });

    testWidgets('no user in the environment keeps the field blank', (
      tester,
    ) async {
      await pumpForm(tester, const {});
      expect(tester.widget<TextField>(addressField).controller?.text, '');
      expect(find.text('host[:port]'), findsNothing);
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

  group('Not saved banner (02 §2.7, D32 §6)', () {
    Future<(PaneController, WorkspaceController)> rig(
      WidgetTester tester, {
      BookmarkStore? store,
      bool withStore = true,
    }) async {
      final lanes = controller_test.FakePaneLanes();
      final controller = await connectAdhoc(lanes, adhocBookmark());
      addTearDown(controller.dispose);
      final strip = testPaneStrip(controller, lanes: lanes);
      final right = PaneTabsController(paneId: 'pane.right', lanes: lanes);
      addTearDown(right.dispose);
      final workspace = WorkspaceController(left: strip, right: right);
      addTearDown(workspace.dispose);
      await pumpPane(
        tester,
        controller,
        strip,
        workspace,
        bookmarks: withStore ? store ?? FakeBookmarkStore() : null,
        // The desktop chrome the banner is drawn for (D32's 22 px rows).
        theme: buildPoltergeistTheme(
          Brightness.light,
          platform: TargetPlatform.linux,
        ),
      );
      return (controller, workspace);
    }

    final bar = find.byKey(const ValueKey('saveFavorite.bar'));

    testWidgets('is one slim line naming the live endpoint', (tester) async {
      await rig(tester);
      expect(bar, findsOneWidget);
      expect(find.text('Not saved · deploy@example.com'), findsOneWidget);
      expect(find.text('Save to Servers…'), findsOneWidget);
      // One line, not a form: no field until the name prompt opens.
      expect(tester.getSize(bar).height, lessThanOrEqualTo(32));
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('Save to Servers… runs the sidebar\'s prompt and saves '
        'with no password anywhere', (tester) async {
      final store = FakeBookmarkStore();
      await rig(tester, store: store);

      await tester.tap(find.byKey(const ValueKey('saveFavorite.save')));
      await tester.pumpAndSettle();
      // The sidebar's name prompt, prefilled with the endpoint.
      expect(find.text('Save to Servers'), findsOneWidget);
      final field = tester.widget<TextFormField>(
        find.byKey(const ValueKey('saveFavorite.name')),
      );
      expect(field.initialValue, 'deploy@example.com');

      await tester.tap(find.byKey(const ValueKey('saveFavorite.confirm')));
      await tester.pumpAndSettle();

      expect(store.bookmarks, hasLength(1));
      final saved = store.bookmarks.single;
      expect(saved.id.startsWith('adhoc:'), isFalse);
      expect(saved.label, 'deploy@example.com');
      expect(saved.server?.identity?.host, 'example.com');
      expect(saved.remotePath, '/srv/www');
      expect(saved.toJson().toString().contains('secret'), isFalse);
      expect(bar, findsNothing);
    });

    testWidgets('cancelling the prompt saves nothing and keeps the banner', (
      tester,
    ) async {
      final store = FakeBookmarkStore();
      await rig(tester, store: store);
      await tester.tap(find.byKey(const ValueKey('saveFavorite.save')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.bookmarks, isEmpty);
      expect(bar, findsOneWidget);
    });

    testWidgets('leaves once the endpoint is saved from anywhere, the '
        'sidebar included', (tester) async {
      final store = FakeBookmarkStore();
      await rig(tester, store: store);
      expect(bar, findsOneWidget);

      // The rail's "Save to Servers…" writes the same endpoint.
      await tester.runAsync(
        () => store.save(
          adhocBookmark(id: 'saved-1', label: 'deploy'),
        ),
      );
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
    });

    testWidgets('an endpoint already saved shows no banner at all', (
      tester,
    ) async {
      final store = FakeBookmarkStore([
        adhocBookmark(id: 'saved-1', label: 'deploy'),
      ]);
      await rig(tester, store: store);
      expect(bar, findsNothing);
    });

    testWidgets('× dismisses it for this tab', (tester) async {
      final (controller, _) = await rig(tester);
      await tester.tap(find.byKey(const ValueKey('saveFavorite.dismiss')));
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
      expect(controller.unsavedBannerDismissed, isTrue);

      // A later rebuild (a refresh, a notice) does not bring it back.
      controller.notePathCopied();
      await tester.pump();
      await tester.pump(controller.noticeLifetime);
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
    });

    testWidgets('without a store the save posts the honest notice', (
      tester,
    ) async {
      final (controller, _) = await rig(tester, withStore: false);
      expect(bar, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('saveFavorite.save')));
      await tester.pump();

      expect(controller.notice, PaneNotice.saveFavoriteLater);
      await tester.pump(controller.noticeLifetime);
      expect(controller.notice, isNull);
    });

    testWidgets('a store failure stays on the banner with the error in its '
        'line', (tester) async {
      final store = FakeBookmarkStore()..saveFailure = Exception('disk full');
      await rig(tester, store: store);

      await tester.tap(find.byKey(const ValueKey('saveFavorite.save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('saveFavorite.confirm')));
      await tester.pumpAndSettle();

      // The banner stays so the save remains retryable; the empty store
      // proves the write went to the store, not a stub.
      expect(store.bookmarks, isEmpty);
      expect(bar, findsOneWidget);
      expect(find.byKey(const ValueKey('saveFavorite.error')), findsOneWidget);
    });

    testWidgets('the banner never overflows a narrow pane', (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await rig(tester);
      expect(bar, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
