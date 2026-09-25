// D32 §9's compact posture through the real shell on a 390 × 844 phone:
// Home is the full-screen sidebar, the browser shows one pane at a time
// with 56 dp two-line rows, the A · B switcher keeps the two-pane verbs,
// selection mode carries its own bars, the inspector is a bottom sheet
// with a progress pill, and system back walks the modes in D32 §9's
// order before leaving the app.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/adaptive_shell.dart';
import 'package:poltergeist_app/ui/compact/compact_posture.dart';
import 'package:poltergeist_app/ui/compact/compact_workspace.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/sync_harness.dart';
import 'compact_harness.dart';

/// A compact key: generic so the key keeps its value's static type
/// (ValueKey equality compares runtime types too).
Finder _key<T>(T value) => find.byKey(ValueKey<T>(value));

/// Opens pane A's home through Home's "This device" row.
Future<void> _openThisDevice(WidgetTester tester) async {
  await tester.tap(find.text('This device'));
  await tester.pumpAndSettle();
}

/// TalkBack's double-tap: Android's bridge sends the focused node's tap
/// action, and a node without one (a Semantics wrapper that excludes the
/// InkWell below it) is not clickable to TalkBack, Switch Access or Voice
/// Access. [wrapper] finds the Semantics widget that owns the node.
Future<void> _semanticsTap(WidgetTester tester, Finder wrapper) async {
  final label = tester.widget<Semantics>(wrapper).properties.label!;
  final node = find.semantics.byLabel(label).evaluate().single;
  expect(
    node.getSemanticsData().hasAction(SemanticsAction.tap),
    isTrue,
    reason: '"$label" must answer a screen reader\'s activation',
  );
  node.owner!.performAction(node.id, SemanticsAction.tap);
  await tester.pump();
}

Finder _semanticsAbove(Finder target) =>
    find.ancestor(of: target, matching: find.byType(Semantics)).first;

Finder _semanticsBelow(Finder target) =>
    find.descendant(of: target, matching: find.byType(Semantics)).first;

void main() {
  group('the posture decision (D32 §3.2)', () {
    test('below 600 dp on a touch platform only', () {
      expect(
        compactPostureApplies(width: 599, platform: TargetPlatform.android),
        isTrue,
      );
      expect(
        compactPostureApplies(width: 390, platform: TargetPlatform.iOS),
        isTrue,
      );
      expect(
        compactPostureApplies(width: 600, platform: TargetPlatform.android),
        isFalse,
      );
      // A desktop window keeps its own narrow-stage behavior.
      expect(
        compactPostureApplies(width: 390, platform: TargetPlatform.linux),
        isFalse,
      );
    });
  });

  group('Home', () {
    testWidgets('is the sidebar, full screen, with search and the + FAB', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester);

      expect(_key(CompactKey.home), findsOneWidget);
      expect(find.byType(AdaptiveShell), findsNothing);
      expect(find.byType(Drawer), findsNothing);
      // Material list subheaders, as authored rather than in caps.
      for (final section in ['Devices', 'Favorites', 'Servers']) {
        expect(find.text(section), findsOneWidget);
      }
      // The phone's own files stand in for DEVICES' volumes.
      expect(find.text('This device'), findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar.home.search')), findsOneWidget);
      expect(find.byKey(const ValueKey('sidebar.home.add')), findsOneWidget);
      // The desktop rail's 30 px bottom bar gives way to the FAB.
      expect(find.byKey(const ValueKey('sidebar.bottomBar')), findsNothing);
    });

    testWidgets('the app bar switch picks the rows\' density', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);

      final appBar = find.byType(AppBar);
      expect(_key(CompactKey.homeDensity), findsOneWidget);
      expect(
        find.descendant(of: appBar, matching: _key(CompactKey.homeDensity)),
        findsOneWidget,
      );
      // Comfortable by default: the phone's Material list rows.
      final demo = find.byKey(const ValueKey('sidebar.favorite.demo'));
      expect(tester.getSize(demo).height, 56);

      await tester.tap(
        find.descendant(of: appBar, matching: find.byTooltip('Compact rows')),
      );
      await tester.pumpAndSettle();
      // Compact: the rail's one-line touch rows.
      expect(tester.getSize(demo).height, 48);

      await tester.tap(
        find.descendant(
          of: appBar,
          matching: find.byTooltip('Comfortable rows'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(demo).height, 56);
    });

    testWidgets('the search bar filters every section', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('sidebar.home.search')),
          matching: find.byType(TextField),
        ),
        'demo',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sidebar.favorite.demo')), findsOne);
      expect(find.text('Documents'), findsNothing);
      expect(find.text('backup box'), findsNothing);
    });

    testWidgets('the FAB offers only the verbs that make sense on Home', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester, serverEditor: true, sshConfigImport: true);

      await tester.tap(find.byKey(const ValueKey('sidebar.home.add')));
      await tester.pumpAndSettle();

      final sheet = find.byType(BottomSheet);
      final verbs = [
        for (final tile in tester.widgetList<ListTile>(
          find.descendant(of: sheet, matching: find.byType(ListTile)),
        ))
          (tile.key! as ValueKey<String>).value,
      ];
      expect(verbs, [
        'sidebar.add.newServer',
        'sidebar.add.quickConnect',
        'sidebar.add.importSshConfig',
        'sidebar.add.newGroup',
      ]);
      // No folder is in view on Home: the current-folder verb stays in
      // the rail and the browser.
      expect(
        find.byKey(const ValueKey('sidebar.add.currentFolder')),
        findsNothing,
      );
      expect(find.text('New Server…'), findsOneWidget);
      expect(find.text('Import from ssh config…'), findsOneWidget);
    });

    testWidgets('a server row pushes the browser on its location', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester);

      await tester.tap(find.byKey(const ValueKey('sidebar.favorite.demo')));
      await tester.pumpAndSettle();

      expect(_key(CompactKey.browser), findsOneWidget);
      // Home stays mounted under the browser, out of the way.
      expect(_key(CompactKey.home), findsNothing);
      expect(
        find.byKey(const ValueKey(CompactKey.home), skipOffstage: false),
        findsOneWidget,
      );
      expect(tester.widget<Text>(_key(CompactKey.browserTitle)).data, 'www');
      expect(
        tester.widget<Text>(_key(CompactKey.browserSubtitle)).data,
        'deploy@demo.example.com',
      );
      expect(find.text('index.html'), findsOneWidget);
    });
  });

  group('the browser', () {
    testWidgets('rows are 56 dp, two lines: name over size · date', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);

      final row = compactRow('/home/deploy/notes.txt');
      expect(tester.getSize(row).height, 56);
      expect(
        find.descendant(of: row, matching: find.textContaining('4.2 KB · ')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: compactRow('/home/deploy/Documents'),
          matching: find.textContaining('Folder · '),
        ),
        findsOneWidget,
      );
      // No desktop chrome leaks in: no column header, no tab strip.
      expect(find.byType(PaneView), findsNothing);
    });

    testWidgets('a tap opens: folders navigate, files open, nothing stays '
        'selected', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      final pane = harness.activePane(tester);

      await tester.tap(compactRow('/home/deploy/notes.txt'));
      await tester.pumpAndSettle();
      final channel = harness.engine.localChannels[2];
      expect(channel.openCalls, ['/home/deploy/notes.txt']);
      expect(pane.selectedCount, 0);
      expect(pane.cursorIndex, isNull);

      await tester.tap(compactRow('/home/deploy/Documents'));
      await tester.pumpAndSettle();
      expect(pane.location?.path, '/home/deploy/Documents');
      expect(
        tester.widget<Text>(_key(CompactKey.browserTitle)).data,
        'Documents',
      );
      expect(find.text('plan.md'), findsOneWidget);
    });

    testWidgets('breadcrumb chips navigate to an enclosing folder', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      await tester.tap(compactRow('/home/deploy/Documents'));
      await tester.pumpAndSettle();

      expect(_key((CompactKey.breadcrumb, '/home/deploy/Documents')), findsOne);
      await tester.tap(_key((CompactKey.breadcrumb, '/home/deploy')));
      await tester.pumpAndSettle();

      expect(harness.activePane(tester).location?.path, '/home/deploy');
    });

    testWidgets('pull to refresh re-lists the folder', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      final channel = harness.engine.localChannels[2];
      final before = channel.listCalls.length;

      await tester.fling(_key(CompactKey.listing), const Offset(0, 400), 1200);
      await tester.pumpAndSettle();

      expect(channel.listCalls.length, before + 1);
    });

    testWidgets('the row ⋮ opens the registry row sheet and releases its '
        'subject when dismissed', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      final pane = harness.activePane(tester);

      await tester.tap(_key((CompactKey.rowMore, '/home/deploy/notes.txt')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pane.context.file.rename')), findsOne);
      expect(find.byKey(const ValueKey('pane.context.file.getInfo')), findsOne);
      // The sheet acts on the row it was opened from.
      expect(pane.selectedEntries.single.name, 'notes.txt');

      await harness.systemBack(tester);
      expect(pane.selectedCount, 0);
      expect(pane.cursorIndex, isNull);
      expect(harness.compact(tester).selecting, isFalse);
    });

    testWidgets('⋮ in the app bar renders the registry menus', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);

      await tester.tap(_key(CompactKey.browserMore));
      await tester.pumpAndSettle();

      expect(_key(CompactKey.commandSheet), findsOneWidget);
      expect(_key((CompactKey.commandRow, 'file.newFolder')), findsOneWidget);
    });

    testWidgets('⋮ adds the shown folder to Favorites, where Home cannot', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);

      await tester.tap(_key(CompactKey.browserMore));
      await tester.pumpAndSettle();
      await tester.tap(_key(CompactKey.browserAddFavorite));
      await tester.pumpAndSettle();

      final added = harness.store.bookmarks.where(
        (bookmark) => bookmark.localPath == '/home/deploy',
      );
      expect(added, hasLength(1));
      expect(added.single.kind, BookmarkKind.localFolder);
      // Home, where the row appears, is a screen away: say it landed.
      expect(find.text('Added “deploy” to Favorites.'), findsOneWidget);

      // A second time it already is one, and says so (once the first
      // notice has timed out: snack bars queue).
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(_key(CompactKey.browserMore));
      await tester.pumpAndSettle();
      await tester.tap(_key(CompactKey.browserAddFavorite));
      await tester.pumpAndSettle();
      expect(
        harness.store.bookmarks.where((b) => b.localPath == '/home/deploy'),
        hasLength(1),
      );
      expect(find.text('“deploy” is already in Favorites.'), findsOneWidget);

      // Back on Home the favorite is a row, home-relative.
      for (var i = 0; i < 4 && harness.compact(tester).browsing; i++) {
        await harness.systemBack(tester);
      }
      expect(
        find.byKey(ValueKey('sidebar.favorite.${added.single.id}')),
        findsOneWidget,
      );
      expect(find.text('~'), findsOneWidget);
    });

    testWidgets('⋮ saves a remote folder to Favorites', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await tester.tap(find.byKey(const ValueKey('sidebar.favorite.demo')));
      await tester.pumpAndSettle();

      await tester.tap(_key(CompactKey.browserMore));
      await tester.pumpAndSettle();
      await tester.tap(_key(CompactKey.browserAddFavorite));
      await tester.pumpAndSettle();

      final saved = harness.store.bookmarks.where(
        (bookmark) => bookmark.remotePath == '/srv/www',
      );
      expect(saved, hasLength(1));
      expect(saved.single.kind, BookmarkKind.remotePath);
      expect(saved.single.label, 'www');
      expect(find.text('Added “www” to Favorites.'), findsOneWidget);
    });

    testWidgets('the filter narrows the listing and back clears it', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);

      await tester.tap(_key(CompactKey.browserFilter));
      await tester.pumpAndSettle();
      await tester.enterText(_key(CompactKey.filterField), 'pdf');
      await tester.pumpAndSettle();
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('notes.txt'), findsNothing);

      await harness.systemBack(tester);
      expect(_key(CompactKey.filterField), findsNothing);
      expect(find.text('notes.txt'), findsOneWidget);
      expect(harness.activePane(tester).filterActive, isFalse);
    });

    testWidgets('rename runs as a dialog over the controller session', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      final channel = harness.engine.localChannels[2];

      await tester.tap(_key((CompactKey.rowMore, '/home/deploy/notes.txt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pane.context.file.rename')));
      await tester.pumpAndSettle();
      expect(_key(CompactKey.renameDialog), findsOneWidget);

      await tester.enterText(_key(CompactKey.renameField), 'todo.txt');
      await tester.tap(_key(CompactKey.renameConfirm));
      await tester.pumpAndSettle();

      expect(channel.renameCalls, [
        ('/home/deploy/notes.txt', '/home/deploy/todo.txt'),
      ]);
      expect(_key(CompactKey.renameDialog), findsNothing);
      expect(_key(CompactKey.browser), findsOneWidget);
    });

    testWidgets('back out of the rename dialog cancels the session and '
        'keeps the browser', (tester) async {
      // Regression: the cancel that follows a dismissal notified the
      // still-animating dialog, which popped a second time — taking the
      // whole shell route with it.
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);

      await tester.tap(_key((CompactKey.rowMore, '/home/deploy/notes.txt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pane.context.file.rename')));
      await tester.pumpAndSettle();
      await harness.systemBack(tester);

      expect(_key(CompactKey.renameDialog), findsNothing);
      expect(_key(CompactKey.browser), findsOneWidget);
      expect(harness.activePane(tester).renameTarget, isNull);
    });
  });

  group('two panes on a phone', () {
    testWidgets('the A · B switcher flips the shown pane and keeps pane B '
        'on the layout', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      final workspace = harness.workspace(tester);
      expect(workspace.secondPaneShown, isTrue);

      await tester.tap(_key(CompactKey.paneSwitcher));
      await tester.pumpAndSettle();

      expect(identical(workspace.activePane, workspace.right), isTrue);
      expect(find.text('old.log'), findsOneWidget);
      expect(find.text('notes.txt'), findsNothing);

      await tester.tap(_key(CompactKey.paneSwitcher));
      await tester.pumpAndSettle();
      expect(identical(workspace.activePane, workspace.left), isTrue);
    });

    testWidgets('Copy to B sends the selection into the other pane', (
      tester,
    ) async {
      final harness = CompactHarness();
      harness.rightChannel.listings['/home/deploy/backups'] = const [];
      await harness.pump(tester);
      await _openThisDevice(tester);

      // Pane B into its backups folder.
      await tester.tap(_key(CompactKey.paneSwitcher));
      await tester.pumpAndSettle();
      await tester.tap(compactRow('/home/deploy/backups'));
      await tester.pumpAndSettle();
      await tester.tap(_key(CompactKey.paneSwitcher));
      await tester.pumpAndSettle();

      await tester.longPress(compactRow('/home/deploy/photo.jpg'));
      await tester.pumpAndSettle();
      expect(find.text('Copy to B'), findsOneWidget);
      await tester.tap(_key(CompactKey.actionCopy));
      // The queued copy knows no size yet: the pill's spinner is
      // indeterminate, so the frame never settles.
      await tester.pump();

      final spec = harness.queue.enqueuedSpecs.single;
      expect(spec.operation, TransferOperation.copy);
      expect(spec.rootPaths, ['/home/deploy/photo.jpg']);
      expect(spec.destinationDir, '/home/deploy/backups');
    });
  });

  group('selection', () {
    testWidgets('long-press starts it: the contextual bar and the action bar', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);

      await tester.longPress(compactRow('/home/deploy/photo.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(compactRow('/home/deploy/report.pdf'));
      await tester.pumpAndSettle();

      expect(harness.compact(tester).selecting, isTrue);
      expect(
        tester.widget<Text>(_key(CompactKey.selectionTitle)).data,
        '2 selected · 40 MB',
      );
      expect(_key(CompactKey.selectionBar), findsOneWidget);
      for (final action in [
        CompactKey.actionCopy,
        CompactKey.actionMove,
        CompactKey.actionDelete,
        CompactKey.actionMore,
      ]) {
        expect(_key(action), findsOneWidget);
      }
      // Share needs a platform share plugin (deferred in STATUS).
      expect(find.text('Share'), findsNothing);

      // Toggling the last row off ends the mode.
      await tester.tap(compactRow('/home/deploy/photo.jpg'));
      await tester.pumpAndSettle();
      await tester.tap(compactRow('/home/deploy/report.pdf'));
      await tester.pumpAndSettle();
      expect(harness.compact(tester).selecting, isFalse);
      expect(_key(CompactKey.selectionBar), findsNothing);
    });

    testWidgets('More lists the remaining selection verbs', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);

      await tester.longPress(compactRow('/home/deploy/notes.txt'));
      await tester.pumpAndSettle();
      await tester.tap(_key(CompactKey.actionMore));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('pane.context.file.rename')), findsOne);
      expect(
        find.byKey(const ValueKey('pane.context.file.duplicate')),
        findsOne,
      );
      // The bar's own verbs are not repeated behind More.
      expect(
        find.byKey(const ValueKey('pane.context.file.delete')),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey('pane.context.selection.transferToOtherPane'),
        ),
        findsNothing,
      );
    });

    testWidgets('a disabled action says why', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);

      // Both panes show the same folder: Move to B has nowhere to go.
      await tester.longPress(compactRow('/home/deploy/notes.txt'));
      await tester.pumpAndSettle();
      await tester.tap(_key(CompactKey.actionMove));
      await tester.pump();

      expect(
        find.text('Select items, and open a folder in the other pane'),
        findsOneWidget,
      );
      expect(harness.queue.enqueuedSpecs, isEmpty);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });
  });

  group('the inspector sheet', () {
    testWidgets('Get Info opens it on Info; the handle drag closes it', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      final workspace = harness.workspace(tester);
      // The posture starts with the inspector closed.
      expect(workspace.inspectorHidden, isTrue);

      await tester.tap(_key((CompactKey.rowMore, '/home/deploy/notes.txt')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pane.context.file.getInfo')));
      await tester.pumpAndSettle();

      expect(_key(CompactKey.inspectorSheet), findsOneWidget);
      expect(workspace.inspectorTab, InspectorTab.info);
      expect(find.text('notes.txt'), findsWidgets);

      await tester.drag(_key(CompactKey.inspectorHandle), const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(_key(CompactKey.inspectorSheet), findsNothing);
      expect(workspace.inspectorHidden, isTrue);
    });

    testWidgets('the progress pill shows while transfers run and opens '
        'Transfers', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      expect(_key(CompactKey.progressPill), findsNothing);

      harness.queue.addTask(
        state: TransferTaskState.running,
        rootPaths: const ['/home/deploy/site.tar.gz'],
        transferredBytes: 30,
        totalBytes: 120,
      );
      harness.queue.emitRefresh();
      await tester.pumpAndSettle();

      expect(find.text('1 transfer · 25%'), findsOneWidget);
      // New work does not throw the sheet over the listing.
      expect(_key(CompactKey.inspectorSheet), findsNothing);

      await tester.tap(_key(CompactKey.progressPill));
      await tester.pumpAndSettle();
      expect(_key(CompactKey.inspectorSheet), findsOneWidget);
      expect(harness.workspace(tester).inspectorTab, InspectorTab.transfers);
      expect(find.byKey(const ValueKey('activity.panel')), findsOneWidget);
      // The sheet shows the work; the pill steps aside.
      expect(
        tester
            .widget<IgnorePointer>(
              find
                  .ancestor(
                    of: find.byType(AnimatedSlide),
                    matching: find.byType(IgnorePointer),
                  )
                  .first,
            )
            .ignoring,
        isTrue,
      );
    });

    testWidgets('its tabs switch between Info, Transfers, and Alerts', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      final workspace = harness.workspace(tester);
      workspace.showInspector(InspectorTab.info);
      await tester.pumpAndSettle();

      await tester.tap(_key((CompactKey.inspectorTab, InspectorTab.alerts)));
      await tester.pumpAndSettle();
      expect(workspace.inspectorTab, InspectorTab.alerts);
      expect(find.byKey(const ValueKey('alerts.empty')), findsOneWidget);

      await tester.tap(_key((CompactKey.inspectorTab, InspectorTab.transfers)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('activity.panel')), findsOneWidget);
    });
  });

  group('screen-reader activation', () {
    testWidgets('the A · B switcher answers a semantics tap', (tester) async {
      final semantics = tester.ensureSemantics();
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      final workspace = harness.workspace(tester);

      await _semanticsTap(
        tester,
        _semanticsAbove(_key(CompactKey.paneSwitcher)),
      );
      await tester.pumpAndSettle();
      expect(identical(workspace.activePane, workspace.right), isTrue);
      semantics.dispose();
    });

    testWidgets('the selection bar answers a semantics tap, a disabled '
        'action with its reason', (tester) async {
      final semantics = tester.ensureSemantics();
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      await tester.longPress(compactRow('/home/deploy/notes.txt'));
      await tester.pumpAndSettle();

      // Both panes show the same folder: Move to B has nowhere to go.
      await _semanticsTap(tester, _semanticsBelow(_key(CompactKey.actionMove)));
      expect(
        find.text('Select items, and open a folder in the other pane'),
        findsOneWidget,
      );
      await tester.pumpAndSettle(const Duration(seconds: 5));

      await _semanticsTap(tester, _semanticsBelow(_key(CompactKey.actionMore)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pane.context.file.rename')), findsOne);
      semantics.dispose();
    });

    testWidgets('the progress pill and the sheet tabs answer a semantics '
        'tap', (tester) async {
      final semantics = tester.ensureSemantics();
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      final workspace = harness.workspace(tester);
      harness.queue.addTask(
        state: TransferTaskState.running,
        rootPaths: const ['/home/deploy/site.tar.gz'],
        transferredBytes: 30,
        totalBytes: 120,
      );
      harness.queue.emitRefresh();
      await tester.pumpAndSettle();

      await _semanticsTap(
        tester,
        _semanticsAbove(_key(CompactKey.progressPill)),
      );
      await tester.pumpAndSettle();
      expect(_key(CompactKey.inspectorSheet), findsOneWidget);
      expect(workspace.inspectorTab, InspectorTab.transfers);
      // The painted badge is excluded with the glyph; the tab says it.
      expect(
        find.semantics.byLabel('Transfers').evaluate().single.value,
        '1 unfinished transfer',
      );

      await _semanticsTap(
        tester,
        _semanticsAbove(_key((CompactKey.inspectorTab, InspectorTab.alerts))),
      );
      await tester.pumpAndSettle();
      expect(workspace.inspectorTab, InspectorTab.alerts);
      semantics.dispose();
    });
  });

  group('system back (D32 §9)', () {
    testWidgets('steps through selection, sheet, folder history, Home, '
        'then leaves', (tester) async {
      final harness = CompactHarness();
      final platformCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          platformCalls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await harness.pump(tester);
      await _openThisDevice(tester);
      final compact = harness.compact(tester);
      final workspace = harness.workspace(tester);
      final pane = harness.activePane(tester);

      // Folder history, the sheet, and a selection — all at once.
      await tester.tap(compactRow('/home/deploy/Documents'));
      await tester.pumpAndSettle();
      workspace.showInspector(InspectorTab.info);
      await tester.pumpAndSettle();
      await tester.longPress(compactRow('/home/deploy/Documents/plan.md'));
      await tester.pumpAndSettle();
      expect(compact.nextBackStep, CompactBackStep.clearSelection);

      await harness.systemBack(tester);
      expect(compact.selecting, isFalse);
      expect(pane.selectedCount, 0);
      expect(workspace.inspectorHidden, isFalse);
      expect(compact.nextBackStep, CompactBackStep.closeSheet);

      await harness.systemBack(tester);
      expect(workspace.inspectorHidden, isTrue);
      expect(pane.location?.path, '/home/deploy/Documents');
      expect(compact.nextBackStep, CompactBackStep.folderBack);

      await harness.systemBack(tester);
      expect(pane.location?.path, '/home/deploy');
      expect(compact.browsing, isTrue);
      expect(compact.nextBackStep, CompactBackStep.home);

      await harness.systemBack(tester);
      expect(compact.browsing, isFalse);
      expect(_key(CompactKey.home), findsOneWidget);
      // Nothing was lost on the way: the pane still shows its folder.
      expect(pane.location?.path, '/home/deploy');
      expect(compact.nextBackStep, CompactBackStep.leave);
      expect(platformCalls, isNot(contains('SystemNavigator.pop')));

      await harness.systemBack(tester);
      expect(platformCalls, contains('SystemNavigator.pop'));
    });

    testWidgets('the app bar back arrow takes the same steps', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      await tester.tap(compactRow('/home/deploy/Documents'));
      await tester.pumpAndSettle();

      await tester.tap(_key(CompactKey.browserBack));
      await tester.pumpAndSettle();
      expect(harness.activePane(tester).location?.path, '/home/deploy');

      await tester.tap(_key(CompactKey.browserBack));
      await tester.pumpAndSettle();
      expect(harness.compact(tester).browsing, isFalse);
    });

    testWidgets('a modal sheet closes before any compact step', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);

      await tester.tap(_key(CompactKey.browserMore));
      await tester.pumpAndSettle();
      expect(_key(CompactKey.commandSheet), findsOneWidget);

      await harness.systemBack(tester);
      expect(_key(CompactKey.commandSheet), findsNothing);
      expect(harness.compact(tester).browsing, isTrue);
    });
  });

  group('commands in the compact posture', () {
    testWidgets('Show Sidebar returns Home; Filter opens the browser field', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      final host = menuHost(tester);
      RegisteredCommand command(String id) =>
          host.commands.firstWhere((c) => c.id == id);

      ignoreResult(host.onRun(command('view.toggleSidebar')));
      await tester.pumpAndSettle();
      expect(harness.compact(tester).browsing, isFalse);

      ignoreResult(host.onRun(command('view.filter')));
      await tester.pumpAndSettle();
      expect(harness.compact(tester).browsing, isTrue);
      expect(_key(CompactKey.filterField), findsOneWidget);
    });

    testWidgets('Synchronize is reachable and opens the full-screen sheet', (
      tester,
    ) async {
      final scratch = Directory.systemTemp.createTempSync('pg-compact-sync-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final harness = CompactHarness();
      harness.rightChannel.listings['/home/deploy/backups'] = const [];
      await harness.pump(
        tester,
        syncEnvironment: testSyncEnvironment(scratch),
        syncTasks: SyncQueueTasks(),
      );
      await _openThisDevice(tester);
      // Pane B elsewhere, so the pair has two distinct legs.
      await tester.tap(_key(CompactKey.paneSwitcher));
      await tester.pumpAndSettle();
      await tester.tap(compactRow('/home/deploy/backups'));
      await tester.pumpAndSettle();

      await tester.tap(_key(CompactKey.browserMore));
      await tester.pumpAndSettle();
      expect(_key(CompactKey.commandSheet), findsOneWidget);
      final row = _key((CompactKey.commandRow, 'sync.synchronizePanes'));
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find.descendant(
          of: _key(CompactKey.commandSheet),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(row);
        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          if (find.byType(Dialog).evaluate().isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();

      final sheet = find.byKey(const ValueKey('sync.sheet'));
      expect(sheet, findsOneWidget);
      // Below 600 dp the sheet takes the whole screen (D32 §9).
      expect(tester.getSize(sheet), phoneSize);
    });
  });

  group('registry verbs whose desktop surface lives in the pane', () {
    RegisteredCommand command(WidgetTester tester, String id) =>
        menuHost(tester).commands.firstWhere((c) => c.id == id);

    testWidgets('Select All enters selection mode', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);

      ignoreResult(menuHost(tester).onRun(command(tester, 'edit.selectAll')));
      await tester.pumpAndSettle();

      expect(harness.compact(tester).selecting, isTrue);
      expect(
        tester.widget<Text>(_key(CompactKey.selectionTitle)).data,
        startsWith('7 selected'),
      );
    });

    testWidgets('Go to Folder is a dialog that navigates', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);

      ignoreResult(menuHost(tester).onRun(command(tester, 'go.toFolder')));
      await tester.pumpAndSettle();
      expect(_key(CompactKey.pathDialog), findsOneWidget);

      await tester.enterText(_key(CompactKey.pathField), 'Documents');
      await tester.tap(_key(CompactKey.pathGo));
      await tester.pumpAndSettle();

      expect(_key(CompactKey.pathDialog), findsNothing);
      expect(
        harness.activePane(tester).location?.path,
        '/home/deploy/Documents',
      );
    });

    testWidgets('Quick Select is a strip; Done lands in selection mode, '
        'back cancels it', (tester) async {
      final harness = CompactHarness();
      await harness.pump(tester);
      await _openThisDevice(tester);
      final pane = harness.activePane(tester);

      ignoreResult(
        menuHost(tester).onRun(command(tester, 'selection.quickSelect')),
      );
      await tester.pumpAndSettle();
      expect(_key(CompactKey.quickSelect), findsOneWidget);
      expect(harness.compact(tester).nextBackStep, CompactBackStep.closeField);

      // Back cancels an open session before anything else moves.
      await harness.systemBack(tester);
      expect(pane.quickSelectActive, isFalse);
      expect(harness.compact(tester).browsing, isTrue);

      ignoreResult(
        menuHost(tester).onRun(command(tester, 'selection.quickSelect')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(_key(CompactKey.quickSelectField), '*.txt');
      await tester.pumpAndSettle();
      await tester.enterText(_key(CompactKey.quickSelectField), 'o');
      await tester.pumpAndSettle();
      await tester.tap(_key(CompactKey.quickSelectDone));
      await tester.pumpAndSettle();

      expect(pane.quickSelectActive, isFalse);
      expect(pane.selectedCount, greaterThan(1));
      expect(harness.compact(tester).selecting, isTrue);
      expect(_key(CompactKey.selectionBar), findsOneWidget);
    });
  });

  group('tablets keep the desktop layout (D32 §9)', () {
    testWidgets('at 700 dp: the panes, the drawer sidebar, touch rows', (
      tester,
    ) async {
      final harness = CompactHarness();
      await harness.pump(tester, size: const Size(700, 1000));

      expect(find.byType(CompactWorkspace), findsNothing);
      expect(find.byType(AdaptiveShell), findsOneWidget);
      // The sidebar is below its stage width: the drawer, not the rail.
      expect(find.byKey(const ValueKey('sidebar.region')), findsNothing);
      // The inspector folds into its overlay at this width.
      expect(find.byKey(const ValueKey('inspector.overlay')), findsOneWidget);
      // Touch rows come from the chrome tokens (48 dp, not 22).
      final list = tester.widget<ListView>(
        find
            .descendant(
              of: find.byType(PaneView).first,
              matching: find.byType(ListView),
            )
            .first,
      );
      expect(list.itemExtent, 48);
    });
  });
}
