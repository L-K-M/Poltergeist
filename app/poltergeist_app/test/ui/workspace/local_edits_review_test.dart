// 06 §3.7 / M7 criterion-2: process death → relaunch → the resume
// surface. The durable halves — record restore, reconcileAll marking
// the dead session's edits dirty, watcher reattach — are covered in
// checkout_manager_test.dart and checkout_session_test.dart; this file
// covers the UI the exit criterion names: the persistent pane banner,
// the review dialog's rows and verbs (including the offline gate and
// the never-uploadable recovered payloads), and the remotePath
// favorite's `Local Edits…` entry. Every body rides `runAsync` like
// the sibling suites — the checkout pipeline runs real I/O.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/external_file_opener.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'built_in_editor_checkout_test.dart';
import 'external_editor_checkout_test.dart';

RemoteFileEntry _configEntry() => RemoteFileEntry(
  path: remoteConfigPath,
  name: 'config.txt',
  type: RemoteFileType.file,
  size: utf8.encode('one\ntwo\n').length,
  modifiedAt: DateTime.utc(2026, 1, 1),
  mode: 0x1a4,
);

/// Simulates process death: the session releases the store lock and
/// watchers; the support dir — index and payloads — survives for the
/// relaunched process. Everything else the first process owned dies too.
Future<void> killProcess(EditorCheckoutHarness harness) async {
  await harness.checkout.shutdown();
  await harness.engine.shutdown();
  harness.appEngine.close();
  await harness.queue.dispose();
}

/// Checks out config.txt on the "first process" and dirties its local
/// copy — the edit the relaunch must surface. Returns the support dir
/// the relaunched harness reopens.
Future<String> dirtyCheckoutThenDie() async {
  final first = await EditorCheckoutHarness.open();
  final record = await first.checkout.checkout(
    serverId: 'b1',
    entry: _configEntry(),
  );
  await first.checkout.localFile(record).writeAsString('edited offline\n');
  final supportDir = first.supportDir.path;
  await killProcess(first);
  return supportDir;
}

/// The relaunched process over the dead one's support dir — the store
/// load reconciles the dirty edit before the shell mounts.
Future<EditorCheckoutHarness> relaunch(String supportDir) =>
    EditorCheckoutHarness.open(supportDirectoryPath: supportDir);

/// The dialog's Upload button for a row — null `onPressed` means the
/// offline gate held (06 §3.7's "Connect to upload").
TextButton? uploadButton(WidgetTester tester) {
  final dialog = find.byType(AlertDialog);
  expect(dialog, findsOneWidget);
  final button = find.descendant(
    of: dialog,
    matching: find.widgetWithText(TextButton, 'Upload'),
  );
  if (button.evaluate().isEmpty) return null;
  return tester.widget<TextButton>(button.first);
}

/// One dialog row's action button by label (Open/Upload/Discard…).
Finder dialogButton(String label) => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.widgetWithText(TextButton, label),
);

void main() {
  // Nullable so a body that fails before `relaunch` never leaves
  // tearDown throwing LateInitializationError over the real failure —
  // or double-closing a previous test's harness.
  EditorCheckoutHarness? harness;

  tearDown(() async {
    await harness?.close();
    harness = null;
  });

  group('06 §3.7 resume surface', () {
    testWidgets(
      'a relaunch with a dirty checkout shows the banner; Review… lists '
      'the copy and its Upload commits through the queue',
      (tester) async {
        await tester.runAsync(() async {
          final supportDir = await dirtyCheckoutThenDie();
          harness = await relaunch(supportDir);
          harness!.bookmarks.bookmarks = [serverBookmark()];
          await mountEditorShell(tester, harness!);

          // The persistent banner — not the 12 s toast — is what a
          // previous session's edit is owed (§3.7's resume offer).
          await pollFor(
            tester,
            find.text("1 file has local edits that aren't on the server yet."),
          );
          await tester.tap(find.byKey(const ValueKey('localEdits.review')));
          await tester.pump();
          await pollFor(tester, find.byType(AlertDialog));

          // The row names the remote path it was checked out from and
          // carries the honest badge — never silent, never auto-uploading.
          expect(dialogButton('Open'), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('config.txt'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Modified locally'),
            ),
            findsOneWidget,
          );

          // Upload may sit disabled until the connection status lands —
          // poll rather than asserting on the first frame.
          await pollUntil(
            tester,
            () => uploadButton(tester)?.onPressed != null,
            reason: 'Upload never enabled for a connected server',
          );
          await tester.tap(dialogButton('Upload'));
          await pollUntil(
            tester,
            () => harness!.queue.tasks.any(
              (task) =>
                  task.spec.managedCheckout?.direction ==
                      ManagedCheckoutDirection.upload &&
                  task.state == TransferTaskState.completed,
            ),
            reason: 'no completed upload task for $remoteConfigPath',
          );
          expect(
            utf8.decode(harness!.fs.bytes(remoteConfigPath)!),
            'edited offline\n',
          );
          // Resolved edits leave the surface — banner and row both gone.
          await pollUntil(
            tester,
            () => find
                .text("1 file has local edits that aren't on the server yet.")
                .evaluate()
                .isEmpty,
            reason: 'banner persisted after the upload committed',
          );
          await pollFor(
            tester,
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('No local edits for this server.'),
            ),
          );
        });
      },
    );

    testWidgets('the dialog stays reachable offline: Upload disabled, Open and '
        'Discard… live', (tester) async {
      await tester.runAsync(() async {
        final supportDir = await dirtyCheckoutThenDie();
        harness = await relaunch(supportDir);
        // No bookmark in the store → the connection list holds no
        // 'b1' row → _serverConnected reports false: the offline
        // posture §3.7 pins (banner still shows, Upload disables,
        // Open/Discard stay reachable).
        await mountEditorShell(tester, harness!);

        await pollFor(
          tester,
          find.text("1 file has local edits that aren't on the server yet."),
        );
        await tester.tap(find.byKey(const ValueKey('localEdits.review')));
        await tester.pump();
        await pollFor(tester, find.byType(AlertDialog));

        // §3.7's posture pins a visible-but-disabled Upload — an absent
        // button would be a different (failing) surface.
        expect(dialogButton('Upload'), findsOneWidget);
        expect(uploadButton(tester)?.onPressed, isNull);
        expect(
          tester.widget<TextButton>(dialogButton('Open')).onPressed,
          isNotNull,
        );
        expect(
          tester.widget<TextButton>(dialogButton('Discard…')).onPressed,
          isNotNull,
        );
        // And nothing silently uploaded while disconnected.
        expect(
          harness!.queue.tasks.where(
            (t) =>
                t.spec.managedCheckout?.direction ==
                ManagedCheckoutDirection.upload,
          ),
          isEmpty,
        );
      });
    });

    testWidgets('Discard… confirms, then deletes the copy and its record — the '
        'banner clears', (tester) async {
      await tester.runAsync(() async {
        final supportDir = await dirtyCheckoutThenDie();
        harness = await relaunch(supportDir);
        harness!.bookmarks.bookmarks = [serverBookmark()];
        await mountEditorShell(tester, harness!);
        final record = harness!.checkout.copiesFor('b1')[remoteConfigPath]!;
        final local = harness!.checkout.localFile(record);
        expect(await local.exists(), isTrue);

        await pollFor(
          tester,
          find.text("1 file has local edits that aren't on the server yet."),
        );
        await tester.tap(find.byKey(const ValueKey('localEdits.review')));
        await tester.pump();
        await pollFor(tester, find.byType(AlertDialog));

        await tester.tap(dialogButton('Discard…'));
        await tester.pump();
        await pollFor(
          tester,
          find.text('Any changes not uploaded to the server are deleted.'),
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
        await pollUntil(
          tester,
          () => harness!.checkout.copiesFor('b1').isEmpty,
          reason: 'discarded record still listed',
        );
        expect(await local.exists(), isFalse);
        // The remote was never touched — discard is a local verb.
        expect(harness!.fs.uploadCalls, isEmpty);
        await pollUntil(
          tester,
          () => find
              .text("1 file has local edits that aren't on the server yet.")
              .evaluate()
              .isEmpty,
          reason: 'banner persisted after the discard',
        );
      });
    });

    testWidgets(
      'a preserved recordless payload lists under Recovered files; its '
      'Discard… drops the file and, last, the dir',
      (tester) async {
        await tester.runAsync(() async {
          final supportDir = await dirtyCheckoutThenDie();
          // A crashed/dropped record's dir kept its payload — the file
          // plus the sibling backup an external editor left beside it.
          final recoveredDir = Directory(
            p.join(supportDir, 'checkouts', 'recovered00'),
          );
          await recoveredDir.create(recursive: true);
          await File(
            p.join(recoveredDir.path, 'edit.txt'),
          ).writeAsString('payload\n');
          await File(
            p.join(recoveredDir.path, '.edit.txt.swp'),
          ).writeAsString('swap\n');
          harness = await relaunch(supportDir);
          harness!.bookmarks.bookmarks = [serverBookmark()];
          await mountEditorShell(tester, harness!);

          await pollFor(
            tester,
            find.text("1 file has local edits that aren't on the server yet."),
          );
          await tester.tap(find.byKey(const ValueKey('localEdits.review')));
          await tester.pump();
          await pollFor(tester, find.text('Recovered files'));

          expect(
            find.text(
              'Recovered files can\'t upload from here — upload the file '
              'through a pane when you\'re done.',
            ),
            findsOneWidget,
          );
          // Both payload names list; neither carries an Upload verb —
          // the only Upload in the dialog is the record row's.
          expect(find.text('edit.txt'), findsOneWidget);
          expect(find.text('.edit.txt.swp'), findsOneWidget);
          expect(dialogButton('Upload'), findsOneWidget);
          expect(dialogButton('Discard…'), findsNWidgets(3));
          expect(dialogButton('Open'), findsNWidgets(3));

          // Discard the plaintext: the sibling survives — an editor's
          // backup is data until its own row is discarded.
          final editRow = find.ancestor(
            of: find.text('edit.txt'),
            matching: find.byType(Row),
          );
          await tester.tap(
            find.descendant(
              of: editRow.first,
              matching: find.widgetWithText(TextButton, 'Discard…'),
            ),
          );
          await tester.pump();
          await pollFor(
            tester,
            find.text('Any changes not uploaded to the server are deleted.'),
          );
          await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
          await pollUntil(
            tester,
            () => find.text('edit.txt').evaluate().isEmpty,
            reason: 'discarded payload row still listed',
          );
          expect(
            await File(p.join(recoveredDir.path, 'edit.txt')).exists(),
            isFalse,
          );
          expect(await recoveredDir.exists(), isTrue);
          expect(find.text('.edit.txt.swp'), findsOneWidget);

          // The last payload file's discard deletes the dir itself
          // (06 §3.7) — the store's markers go with it.
          final swpRow = find.ancestor(
            of: find.text('.edit.txt.swp'),
            matching: find.byType(Row),
          );
          await tester.tap(
            find.descendant(
              of: swpRow.first,
              matching: find.widgetWithText(TextButton, 'Discard…'),
            ),
          );
          await tester.pump();
          await pollFor(
            tester,
            find.text('Any changes not uploaded to the server are deleted.'),
          );
          await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
          await pollUntil(
            tester,
            () => find.text('.edit.txt.swp').evaluate().isEmpty,
            reason: 'last payload row still listed after discard',
          );
          expect(await recoveredDir.exists(), isFalse);
        });
      },
    );

    testWidgets('a remotePath favorite offers Local Edits… — the server-scoped '
        'review entry independent of any pane', (tester) async {
      await tester.runAsync(() async {
        final supportDir = await dirtyCheckoutThenDie();
        harness = await relaunch(supportDir);
        harness!.bookmarks.bookmarks = [serverBookmark()];
        await mountEditorShell(tester, harness!);
        await pollFor(
          tester,
          find.text("1 file has local edits that aren't on the server yet."),
        );

        // The favorite row's context menu carries the item; tapping it
        // opens the same server-scoped dialog. Keyed on the favorite
        // row — the Connections section lists the same label.
        await pollFor(
          tester,
          find.byKey(const ValueKey('sidebar.favorite.b1')),
        );
        await tester.tap(
          find.byKey(const ValueKey('sidebar.favorite.b1')),
          buttons: kSecondaryButton,
        );
        await tester.pump();
        await pollFor(
          tester,
          find.byKey(const ValueKey('sidebar.menu.localEdits')),
        );
        await tester.tap(find.byKey(const ValueKey('sidebar.menu.localEdits')));
        await tester.pump();
        await pollFor(tester, find.byType(AlertDialog));
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('config.txt'),
          ),
          findsOneWidget,
        );
      });
    });

    testWidgets(
      'a clean relaunch shows no banner — the surface is edit-scoped, '
      'not a relaunch ritual',
      (tester) async {
        await tester.runAsync(() async {
          final first = await EditorCheckoutHarness.open();
          await first.checkout.checkout(serverId: 'b1', entry: _configEntry());
          final supportDir = first.supportDir.path;
          await killProcess(first);
          harness = await relaunch(supportDir);
          harness!.bookmarks.bookmarks = [serverBookmark()];
          await mountEditorShell(tester, harness!);
          await pollUntil(
            tester,
            () => harness!.checkout.copiesFor('b1').isNotEmpty,
            reason: 'relaunched store never restored the clean record',
          );
          // Give the banner a beat to (not) appear — the reconcile is
          // synchronous with the restore, so a settled pump is honest.
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            find.textContaining("local edits that aren't on the server yet"),
            findsNothing,
          );
        });
      },
    );

    testWidgets(
      "the row's Open never OS-launches a program type (06 §5.3)",
      (tester) async {
        await tester.runAsync(() async {
          debugEditorHostPlatform = () => EditorHostPlatform.windows;
          addTearDown(() => debugEditorHostPlatform = null);
          const remotePath = '/srv/www/payload.hta';
          final first = await EditorCheckoutHarness.open();
          first.fs.seed(remotePath, utf8.encode('<script></script>\n'));
          final record = await first.checkout.checkout(
            serverId: 'b1',
            entry: RemoteFileEntry(
              path: remotePath,
              name: 'payload.hta',
              type: RemoteFileType.file,
              size: 18,
              modifiedAt: DateTime.utc(2026, 1, 1),
              mode: 0x1a4,
            ),
          );
          await first.checkout.localFile(record).writeAsString('edited\n');
          final supportDir = first.supportDir.path;
          await killProcess(first);
          harness = await relaunch(supportDir);
          final seams = OpenerSeams();
          await mountEditorShell(
            tester,
            harness!,
            externalOpener: seams.opener,
          );

          await tester.tap(find.byKey(const ValueKey('localEdits.review')));
          await tester.pump();
          await pollFor(tester, find.byType(AlertDialog));
          await tester.tap(dialogButton('Open'));
          await pollFor(
            tester,
            find.text(l10nOf(tester).fileOpenProgramRefused('payload.hta')),
          );

          expect(seams.systemOpener.opens, isEmpty);
        });
      },
    );
  });
}
