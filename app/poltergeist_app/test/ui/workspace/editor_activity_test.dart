import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/workspace_windows/workspace_windows.dart';

import '../../services/workspace_windows_test.dart' show FakeWindowHost;
import 'built_in_editor_checkout_test.dart';
import 'external_editor_checkout_test.dart' show serverBookmark;

void main() {
  testWidgets('an active editor does not suppress checkout upload prompts', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final harness = await EditorCheckoutHarness.open();
      final windows = WorkspaceWindows(
        host: FakeWindowHost(),
        quitApplication: () async {},
        afterFrame: () async {},
      );
      try {
        harness.bookmarks.bookmarks = [serverBookmark()];
        await windows.start();
        await mountEditorShell(tester, harness, window: windows.windows.single);
        await pollFor(tester, find.text('config.txt'));
        final entry = leftPane(
          tester,
        ).entries.firstWhere((entry) => entry.path == remoteConfigPath);
        final record = await harness.checkout.checkout(
          serverId: 'b1',
          entry: entry,
        );
        await windows.openEditor(
          key: 'local:/other.txt',
          builder: (_) => const SizedBox(),
        );
        expect(windows.activeWindow!.isEditor, isTrue);
        await harness.checkout.localFile(record).writeAsString('changed\n');
        await harness.checkout.reconcile(record);
        await pollFor(
          tester,
          find.textContaining('“config.txt” changed locally'),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        windows.dispose();
        await harness.close();
      }
    });
  });
}
