// The shell's delete and duplicate commands end to end (02 §10, D15):
// the registered command, the confirmation dialog, and PaneFileOps over
// a scripted queue — the path a menu, the chord layer, or a header
// button takes. What reaches the queue is the assertion: the dialog's
// final wording and the enqueued disposition must never disagree.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_file_ops.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart'
    show FakePaneChannel, FakePaneLanes;
import '../../support/fake_app_transfer_queue.dart';
import '../../support/test_panes.dart';

RemoteFileEntry _entry(String dir, String name) => RemoteFileEntry(
  path: '$dir/$name',
  name: name,
  type: RemoteFileType.file,
  size: 10,
);

Bookmark _server() {
  final now = DateTime.utc(2026, 9, 12);
  return Bookmark(
    id: 'srv-1',
    kind: BookmarkKind.remotePath,
    label: 'prod-web',
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'prod-web.example.com',
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

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakePaneLanes lanes;
  late PaneController left;
  late PaneController right;
  late WorkspaceController workspace;
  late FakeAppTransferQueue queue;
  late List<Object> failures;
  late List<RegisteredCommand> commands;

  setUp(() {
    lanes = FakePaneLanes();
    left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    workspace = WorkspaceController(
      left: testPaneStrip(left),
      right: testPaneStrip(right),
    );
    queue = FakeAppTransferQueue();
    failures = [];
    final ops = PaneFileOps(queue);
    commands = buildShellCommands(
      workspace: workspace,
      dropDelegate: () => null,
      openConnect: () {},
      allCommands: () => const [],
      openUrl: (_) async {},
      fileOps: () => ops,
      reportFailure: failures.add,
      locationLabel: (_) => 'prod-web',
    );
  });

  tearDown(() async {
    workspace.dispose();
    await queue.close();
  });

  RegisteredCommand command(String id) =>
      commands.singleWhere((command) => command.id == id);

  /// Binds the left (active) pane to the remote '/srv/home' listing
  /// a.txt and b.txt.
  Future<void> bindRemote() async {
    final channel = FakePaneChannel('/srv/home');
    channel.listings['/srv/home'] = [
      _entry('/srv/home', 'a.txt'),
      _entry('/srv/home', 'b.txt'),
    ];
    lanes.nextRemoteChannel = channel;
    await left.connectRemote(_server());
    await _settle();
  }

  /// Pumps a host and runs [id] with its context, the way the shell's
  /// runner does; the dialog, if any, is left showing.
  Future<void> run(WidgetTester tester, String id) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    unawaited(command(id).run(context));
    await tester.pumpAndSettle();
  }

  DeleteConfirmation optedIn(DeleteDisposition effective) => DeleteConfirmation(
    source: const ServerFsLocation('srv-1'),
    rootPaths: const ['/srv/home/a.txt'],
    names: const ['a.txt'],
    effectiveDisposition: effective,
    quantified: true,
    remoteTrashOptIn: true,
    trashUnavailable: false,
    totalItems: 1,
    totalBytes: 10,
  );

  group('the dialog\'s final choice decides the disposition', () {
    testWidgets('Delete Permanently, then checking the server trash box, '
        'moves to the server trash', (tester) async {
      await tester.runAsync(bindRemote);
      left.setCursorIndex(0);
      queue.deleteConfirmation = optedIn(DeleteDisposition.permanent);

      await run(tester, kFileDeletePermanentlyCommandId);
      expect(find.text('Delete “a.txt” from prod-web?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delete.serverTrash')));
      await tester.pumpAndSettle();
      expect(
        find.text('Move “a.txt” to .poltergeist-trash/ on prod-web?'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('delete.confirm')));
      await tester.pumpAndSettle();

      expect(failures, isEmpty);
      final request = queue.enqueuedDeletes.single;
      expect(request.disposition, DeleteDisposition.trash);
    });

    testWidgets('Delete, then unchecking the pre-checked box, deletes '
        'permanently', (tester) async {
      await tester.runAsync(bindRemote);
      left.setCursorIndex(0);
      queue.deleteConfirmation = optedIn(DeleteDisposition.trash);

      await run(tester, kFileDeleteCommandId);
      await tester.tap(find.byKey(const ValueKey('delete.serverTrash')));
      await tester.pumpAndSettle();
      expect(find.text('Delete “a.txt” from prod-web?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delete.confirm')));
      await tester.pumpAndSettle();

      final request = queue.enqueuedDeletes.single;
      expect(request.disposition, DeleteDisposition.permanent);
      expect(request.confirmed, isTrue);
    });

    testWidgets('Delete Permanently left unchecked deletes permanently', (
      tester,
    ) async {
      await tester.runAsync(bindRemote);
      left.setCursorIndex(0);
      queue.deleteConfirmation = optedIn(DeleteDisposition.permanent);

      await run(tester, kFileDeletePermanentlyCommandId);
      await tester.tap(find.byKey(const ValueKey('delete.confirm')));
      await tester.pumpAndSettle();

      expect(
        queue.enqueuedDeletes.single.disposition,
        DeleteDisposition.permanent,
      );
    });
  });

  group('a cursor row alone is not a selection', () {
    testWidgets('Delete, Delete Permanently and Duplicate are disabled once '
        'the only selected row is toggled off', (tester) async {
      await tester.runAsync(bindRemote);
      left.setCursorIndex(0);
      expect(command(kFileDeleteCommandId).enabled(), isTrue);
      expect(command(kFileDuplicateCommandId).enabled(), isTrue);

      // Ctrl-click the selected row: the cursor stays on it, but
      // nothing is selected, and that is what the verbs act on.
      left.setCursorIndex(0, update: SelectionUpdate.toggle);
      expect(left.selectedEntries, isEmpty);
      expect(left.cursorIndex, 0);

      for (final id in [
        kFileDeleteCommandId,
        kFileDeletePermanentlyCommandId,
        kFileDuplicateCommandId,
      ]) {
        expect(command(id).enabled(), isFalse, reason: id);
      }
      expect(queue.prepareDeleteCalls, isEmpty);
      expect(queue.enqueuedSpecs, isEmpty);
    });
  });

  group('the delete keys act only from a pane listing', () {
    late FocusNode listing;
    late FocusNode sidebarRow;
    late FocusNode field;

    setUp(() {
      listing = FocusNode();
      sidebarRow = FocusNode();
      field = FocusNode();
    });

    tearDown(() {
      listing.dispose();
      sidebarRow.dispose();
      field.dispose();
    });

    /// The shell's shape in miniature: one chord scope over the left
    /// pane's listing, a focusable sidebar row, and a text field. The
    /// left pane is bound locally with a.txt selected.
    Future<void> pumpShell(WidgetTester tester, TargetPlatform platform) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final channel = FakePaneChannel('/home/tester');
        channel.listings['/home/tester'] = [
          _entry('/home/tester', 'a.txt'),
          _entry('/home/tester', 'b.txt'),
        ];
        lanes.nextLocalChannel = channel;
        await left.openLocalHome();
        await _settle();
      });
      left.setCursorIndex(0);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CommandChordScope(
              commands: commands,
              child: Row(
                children: [
                  SizedBox(
                    width: 200,
                    child: Column(
                      children: [
                        Focus(
                          focusNode: sidebarRow,
                          child: const Text('Favorites row'),
                        ),
                        TextField(focusNode: field),
                      ],
                    ),
                  ),
                  Expanded(
                    child: PaneView(
                      controller: left,
                      pane: workspace.left,
                      workspace: workspace,
                      focusNode: listing,
                      onSwapFocus: () {},
                      onCancelRecovery: () {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> press(
      WidgetTester tester,
      FocusNode focus,
      LogicalKeyboardKey key, {
      List<LogicalKeyboardKey> modifiers = const [],
    }) async {
      focus.requestFocus();
      await tester.pump();
      for (final modifier in modifiers) {
        await tester.sendKeyDownEvent(modifier);
      }
      await tester.sendKeyEvent(key);
      for (final modifier in modifiers.reversed) {
        await tester.sendKeyUpEvent(modifier);
      }
      await tester.pumpAndSettle();
    }

    testWidgets('Delete and Shift+Delete off macOS', (tester) async {
      await pumpShell(tester, TargetPlatform.linux);

      await press(tester, sidebarRow, LogicalKeyboardKey.delete);
      await press(
        tester,
        sidebarRow,
        LogicalKeyboardKey.delete,
        modifiers: [LogicalKeyboardKey.shiftLeft],
      );
      await press(tester, field, LogicalKeyboardKey.delete);
      expect(queue.prepareDeleteCalls, isEmpty);
      expect(find.byKey(const ValueKey('delete.dialog')), findsNothing);

      await press(tester, listing, LogicalKeyboardKey.delete);
      expect(
        queue.enqueuedDeletes.single.disposition,
        DeleteDisposition.trash,
      );
      expect(queue.enqueuedDeletes.single.rootPaths, ['/home/tester/a.txt']);
    });

    testWidgets('Cmd-Backspace and Opt-Cmd-Backspace on macOS', (
      tester,
    ) async {
      await pumpShell(tester, TargetPlatform.macOS);

      await press(
        tester,
        sidebarRow,
        LogicalKeyboardKey.backspace,
        modifiers: [LogicalKeyboardKey.metaLeft],
      );
      await press(
        tester,
        sidebarRow,
        LogicalKeyboardKey.backspace,
        modifiers: [LogicalKeyboardKey.altLeft, LogicalKeyboardKey.metaLeft],
      );
      await press(
        tester,
        field,
        LogicalKeyboardKey.backspace,
        modifiers: [LogicalKeyboardKey.altLeft, LogicalKeyboardKey.metaLeft],
      );
      expect(queue.prepareDeleteCalls, isEmpty);
      expect(find.byKey(const ValueKey('delete.dialog')), findsNothing);

      await press(
        tester,
        listing,
        LogicalKeyboardKey.backspace,
        modifiers: [LogicalKeyboardKey.metaLeft],
      );
      expect(
        queue.enqueuedDeletes.single.disposition,
        DeleteDisposition.trash,
      );
    });
  });
}
