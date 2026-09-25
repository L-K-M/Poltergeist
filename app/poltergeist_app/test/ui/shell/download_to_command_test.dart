// File ▸ Download To… (02-UX's promise until drag-out ships, and the
// fallback where remote items cannot be dragged out): pick a local
// folder, enqueue an ordinary download of the remote selection there.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_drop.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_app_transfer_queue.dart';
import '../../support/test_panes.dart';

Bookmark _server(String id) {
  final now = DateTime.utc(2026, 9, 20);
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: id,
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: '$id.example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/',
    sortKey: id,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController pane;
  late WorkspaceController workspace;
  late FakeAppTransferQueue queue;
  late List<String> pickerTitles;
  String? picked;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    pane = PaneController(paneTabId: 'pane.left', lanes: lanes);
    workspace = WorkspaceController(
      left: testPaneStrip(pane),
      right: testPaneStrip(
        PaneController(paneTabId: 'pane.right', lanes: lanes),
      ),
    );
    queue = FakeAppTransferQueue();
    pickerTitles = [];
    picked = '/Users/me/Downloads';
  });

  tearDown(() => workspace.dispose());

  Future<void> bindRemote() async {
    lanes.nextRemoteChannel = controller_test.FakePaneChannel('/srv')
      ..listings['/srv'] = const [
        RemoteFileEntry(
          path: '/srv/site',
          name: 'site',
          type: RemoteFileType.directory,
        ),
        RemoteFileEntry(
          path: '/srv/a.txt',
          name: 'a.txt',
          type: RemoteFileType.file,
          size: 3,
        ),
      ];
    await pane.connectRemote(_server('srv-1'), initialPath: '/srv');
  }

  Future<void> bindLocal() async {
    lanes.nextLocalChannel = controller_test.FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = const [
        RemoteFileEntry(
          path: '/home/tester/a.txt',
          name: 'a.txt',
          type: RemoteFileType.file,
          size: 3,
        ),
      ];
    await pane.openLocalHome();
  }

  List<RegisteredCommand> commands({
    bool withQueue = true,
    bool withPicker = true,
  }) => buildShellCommands(
    workspace: workspace,
    dropDelegate: () => withQueue ? PaneDropDelegate(queue: queue) : null,
    openConnect: () {},
    allCommands: () => const [],
    openUrl: (_) async {},
    fileOps: () => null,
    reportFailure: (_) {},
    locationLabel: (_) => '',
    pickDirectory: withPicker
        ? (title) async {
            pickerTitles.add(title);
            return picked;
          }
        : null,
  );

  RegisteredCommand downloadTo({bool withQueue = true}) => commands(
    withQueue: withQueue,
  ).singleWhere((command) => command.id == kFileDownloadToCommandId);

  Future<BuildContext> host(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    return tester.element(find.byType(Scaffold));
  }

  testWidgets('downloads the remote selection into the picked folder', (
    tester,
  ) async {
    await bindRemote();
    final context = await host(tester);
    // Directories sort first: site, a.txt.
    pane.setCursorIndex(0);
    pane.setCursorIndex(1, update: SelectionUpdate.toggle);
    final command = downloadTo();
    expect(command.label(AppLocalizations.of(context)), 'Download To…');
    expect(command.enabled(), isTrue);

    await command.run(context);

    expect(pickerTitles, ['Download To']);
    final spec = queue.enqueuedSpecs.single;
    expect(spec.source, const ServerFsLocation('srv-1'));
    expect(spec.destination, const LocalFsLocation());
    expect(spec.rootPaths, ['/srv/site', '/srv/a.txt']);
    expect(spec.destinationDir, '/Users/me/Downloads');
    expect(spec.operation, TransferOperation.copy);
    // The settings matrix's download bucket, like a drop.
    expect(spec.policy.files, ConflictResolution.ask);
  });

  testWidgets('the cursor row counts when nothing is selected', (tester) async {
    await bindRemote();
    final context = await host(tester);
    pane.setCursorIndex(1);
    await downloadTo().run(context);
    expect(queue.enqueuedSpecs.single.rootPaths, ['/srv/a.txt']);
  });

  testWidgets('a cancelled picker enqueues nothing', (tester) async {
    await bindRemote();
    final context = await host(tester);
    pane.setCursorIndex(1);
    picked = null;
    await downloadTo().run(context);
    expect(pickerTitles, hasLength(1));
    expect(queue.enqueuedSpecs, isEmpty);
  });

  testWidgets('needs a remote selection and a queue', (tester) async {
    await bindLocal();
    await host(tester);
    pane.setCursorIndex(0);
    expect(downloadTo().enabled(), isFalse);
    expect(
      downloadTo().disabledReason!(
        AppLocalizations.of(tester.element(find.byType(Scaffold))),
      ),
      'Select items on a server',
    );
  });

  testWidgets('is disabled without a queue', (tester) async {
    await bindRemote();
    await host(tester);
    pane.setCursorIndex(1);
    expect(downloadTo(withQueue: false).enabled(), isFalse);
  });

  test('registers only where a folder picker exists', () {
    expect(
      commands(
        withPicker: false,
      ).where((command) => command.id == kFileDownloadToCommandId),
      isEmpty,
    );
  });
}
