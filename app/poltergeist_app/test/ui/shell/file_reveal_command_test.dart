import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/file_manager_reveal.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

/// D32 §11's file.reveal: when no file manager can be started, the
/// command says so instead of silently doing nothing.
void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController left;
  late WorkspaceController workspace;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    workspace = WorkspaceController(
      left: testPaneStrip(left),
      right: testPaneStrip(
        PaneController(paneTabId: 'pane.right', lanes: lanes),
      ),
    );
    final channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = const [
      RemoteFileEntry(
        path: '/home/tester/a.txt',
        name: 'a.txt',
        type: RemoteFileType.file,
        size: 10,
      ),
    ];
    lanes.nextLocalChannel = channel;
  });

  tearDown(() => workspace.dispose());

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    await left.openLocalHome();
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    left.setCursorIndex(0);
    expect(left.selectedEntries.single.name, 'a.txt');
    return context;
  }

  RegisteredCommand reveal(FileManagerRevealer revealer) => buildShellCommands(
    workspace: workspace,
    dropDelegate: () => null,
    openConnect: () {},
    allCommands: () => const [],
    openUrl: (_) async {},
    fileOps: () => null,
    reportFailure: (_) {},
    locationLabel: (_) => 'this computer',
    revealer: revealer,
  ).singleWhere((command) => command.id == kFileRevealCommandId);

  testWidgets('a reveal nothing could start says so', (tester) async {
    final context = await pumpHost(tester);
    final command = reveal(
      FileManagerRevealer(
        operatingSystem: 'linux',
        run: (executable, arguments) async =>
            throw ProcessException(executable, arguments, 'not found', 2),
      ),
    );

    await command.run(context);
    await tester.pump();

    expect(
      find.text('“a.txt” could not be shown in the file manager.'),
      findsOneWidget,
    );
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('a successful reveal stays quiet', (tester) async {
    final context = await pumpHost(tester);
    final launched = <String>[];
    final command = reveal(
      FileManagerRevealer(
        operatingSystem: 'linux',
        run: (executable, arguments) async {
          launched.add(executable);
          return 0;
        },
      ),
    );

    await command.run(context);
    await tester.pump();

    expect(launched, ['dbus-send']);
    expect(find.textContaining('could not be shown'), findsNothing);
  });
}
