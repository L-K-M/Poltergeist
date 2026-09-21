// External-editor-over-checkout integration (06 §3.3/§4.1/§4.2, M7):
// the shell path for registry-resolved opens — the remote Open verb
// through `effectiveDefaultFor`, explicit Open With ▸ choices riding an
// uncapped managed checkout, the `Other…` pick/remember flow, and the
// watch → dirty → prompt → CAS-guarded-upload loop — against the same
// scripted remote endpoint the built-in-editor suite uses. Runs on any
// desktop host: the fake editor definition follows
// `currentEditorHostPlatform`. Menu-driving tests assume the
// Windows/Linux MenuBar backend, like the sibling suite's. Every body
// rides `runAsync` — the checkout watcher's debounce is a real Timer
// the fake zone would never fire.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/app_transfer_queue.dart';
import 'package:poltergeist_app/services/editor_registry_controller.dart';
import 'package:poltergeist_app/services/external_file_opener.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import 'built_in_editor_checkout_test.dart';

/// The over-cap remote files: `big.bin` carries a known size (the
/// early-refusal arm), `mystery.bin` hides it (the stream-abort arm).
const remoteBigPath = '/srv/www/big.bin';
const remoteMysteryPath = '/srv/www/mystery.bin';

final _now = DateTime.utc(2026, 9, 12);

Bookmark serverBookmark() => Bookmark(
  id: 'b1',
  kind: BookmarkKind.remotePath,
  label: 'web.example.com',
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: 'web.example.com',
      port: 22,
      username: 'deploy',
      authMethod: AuthMethod.password,
      secretRef: 'secret-b1',
    ),
  ),
  remotePath: '/srv/www',
  sortKey: 'b1',
  createdAt: _now,
  updatedAt: _now,
);

RemoteFileEntry _bigListing() => RemoteFileEntry(
  path: remoteBigPath,
  name: 'big.bin',
  type: RemoteFileType.file,
  size: builtInEditorMaximumBytes + 1,
  modifiedAt: _now,
  mode: 0x1a4,
);

RemoteFileEntry _mysteryListing() => RemoteFileEntry(
  path: remoteMysteryPath,
  name: 'mystery.bin',
  type: RemoteFileType.file,
  modifiedAt: _now,
  mode: 0x1a4,
);

/// Records the OS-default launches the opener seam would hand to
/// `open`/`xdg-open`/`explorer.exe`.
final class _RecordingSystemOpener implements LocalFileOpener {
  final opens = <String>[];

  @override
  Future<void> open(String path) async => opens.add(path);
}

/// The `Process` the fake launcher returns — the opener only awaits the
/// spawn, so the members stay unused.
final class _FakeProcess implements Process {
  @override
  Future<int> get exitCode => Future.value(0);
  @override
  int get pid => 0;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
  @override
  IOSink get stdin => throw UnimplementedError('unused in tests');
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
}

/// The scripted launcher/picker seams behind one [ExternalFileOpener]:
/// `launches` records configured-editor launches (bundle id on macOS,
/// executable path elsewhere) with the opened path; `systemOpens`
/// records OS-default opens; `pickCalls` records picker invocations and
/// [pickedExecutablePath] scripts its answer (the macOS pick rides the
/// channel mock — [pickedApplication] — instead).
final class OpenerSeams {
  final launches = <(String target, String path)>[];
  final systemOpener = _RecordingSystemOpener();
  final pickCalls = <(EditorHostPlatform, String)>[];

  /// What the host pick answers: an executable path on Windows/Linux,
  /// a channel map on macOS, null = the user cancelled.
  String? pickedExecutablePath;
  Object? pickedApplication;

  late final ExternalFileOpener opener = ExternalFileOpener(
    systemOpener: systemOpener,
    processStarter: (executable, arguments) async {
      launches.add((executable, arguments.single));
      return _FakeProcess();
    },
    executablePicker: (platform, title) async {
      pickCalls.add((platform, title));
      return pickedExecutablePath;
    },
  );

  /// Answers the `poltergeist/files` channel — only macOS reaches it.
  Future<Object?> onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'pickApplication':
        return pickedApplication;
      case 'openWithApplication':
        launches.add((
          call.arguments['bundleIdentifier'] as String,
          call.arguments['path'] as String,
        ));
    }
    return null;
  }

  /// The host-platform definition a registered editor needs to be
  /// launchable (and §4.1-compatible) on this machine.
  ExternalEditorDefinition editor({
    String id = 'editor.fake',
    String displayName = 'Fake Editor',
    List<String> acceptedExtensions = const [],
  }) => ExternalEditorDefinition(
    id: id,
    displayName: displayName,
    platform: currentEditorHostPlatform!,
    launchTarget: currentEditorHostPlatform == EditorHostPlatform.macos
        ? 'com.poltergeist.test.fake'
        : pickedExecutablePath!,
    acceptedExtensions: acceptedExtensions,
  );
}

late EditorCheckoutHarness harness;
late Directory scratchDir;
late SettingsStore settingsStore;
late EditorRegistryController registry;
late OpenerSeams seams;

/// Resolves l10n off the shell's root Scaffold — `.first` because a
/// dialog/route can mount its own Scaffold later in the overlay.
AppLocalizations l10nOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first));

/// The cursor's row — finds the entry by name on the live left pane.
RemoteFileEntry cursorEntry(WidgetTester tester, String name) {
  final pane = leftPane(tester);
  final index = pane.entries.indexWhere((entry) => entry.name == name);
  expect(index, isNonNegative, reason: '$name not listed');
  pane.setCursorIndex(index);
  return pane.entries[index];
}

/// Polls the real event loop until [condition] holds — every wait in
/// this file rides real I/O (channel opens, checkout downloads, disk
/// watches), so fake-zone frame counts would flake.
Future<void> pollUntil(
  WidgetTester tester,
  bool Function() condition, {
  String? reason,
}) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue, reason: reason ?? 'timed out');
}

/// Waits for the managed checkout of [remotePath] to materialize —
/// the download runs through the real queue, so the record lands a few
/// event-loop turns after the launch.
Future<ManagedRemoteFile> checkoutOf(
  WidgetTester tester,
  String remotePath,
) async {
  ManagedRemoteFile? record;
  await pollUntil(
    tester,
    () => (record = harness.checkout.copiesFor('b1')[remotePath]) != null,
    reason: 'no checkout record for $remotePath',
  );
  return record!;
}

/// Waits for the §3.3 dirty-prompt toast for [name] — the watcher's
/// real 600 ms debounce runs first.
Future<void> pollForDirtyPrompt(WidgetTester tester, String name) =>
    pollFor(tester, find.textContaining('“$name” changed locally'));

void main() {
  setUp(() async {
    harness = await EditorCheckoutHarness.open();
    // The §3.3 prompt's connected gate reads the bookmark-derived
    // connection list — seed it before the shell mounts.
    harness.bookmarks.bookmarks = [serverBookmark()];
    harness.fs.seed(
      remoteBigPath,
      // Flat bytes, not a boxed List<int> — 4 MiB per seed per test.
      Uint8List(builtInEditorMaximumBytes + 1)
        ..fillRange(0, builtInEditorMaximumBytes + 1, 0x41),
    );
    harness.fs.seed(
      remoteMysteryPath,
      Uint8List(builtInEditorMaximumBytes + 64)
        ..fillRange(0, builtInEditorMaximumBytes + 64, 0x42),
    );
    scratchDir = await Directory.systemTemp.createTemp(
      'pg-external-editor-test-',
    );
    seams = OpenerSeams();
    // A launchable POSIX executable (the Linux editor target and the
    // picked-executable answer); Windows/macOS never read its bits —
    // the former only needs the .exe name, the latter rides the
    // channel.
    final fakeExecutable = File(
      p.join(
        scratchDir.path,
        Platform.isWindows ? 'fake-editor.exe' : 'fake-editor',
      ),
    );
    await fakeExecutable.writeAsString('# fake editor\n');
    if (!Platform.isWindows) {
      await Process.run('chmod', ['0755', fakeExecutable.path]);
    }
    seams.pickedExecutablePath = fakeExecutable.path;
    seams.pickedApplication = {
      'displayName': 'Picked Editor',
      'bundleIdentifier': 'com.poltergeist.test.picked',
    };
    settingsStore = SettingsStore(
      path: p.join(scratchDir.path, 'settings.json'),
    );
    registry = EditorRegistryController(store: settingsStore);
    await registry.load();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          ExternalFileOpener.channel,
          seams.onMethodCall,
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ExternalFileOpener.channel, null);
    await harness.close();
    if (await scratchDir.exists()) {
      await scratchDir.delete(recursive: true);
    }
  });

  group('remote Open resolution (06 §4.2)', () {
    testWidgets(
      'the per-extension binding launches its editor on a managed checkout',
      (tester) async {
        await tester.runAsync(() async {
          final editor = seams.editor(acceptedExtensions: ['txt']);
          await registry.register(editor);
          await registry.setExtensionDefault('txt', editor.id);
          await mountEditorShell(
            tester,
            harness,
            editorRegistry: registry,
            externalOpener: seams.opener,
          );

          await leftPane(
            tester,
          ).openEntry(cursorEntry(tester, 'config.txt'));
          final record = await checkoutOf(tester, remoteConfigPath);
          await pollUntil(
            tester,
            () => seams.launches.isNotEmpty,
            reason: 'editor never launched',
          );

          expect(seams.launches.single.$1, editor.launchTarget);
          expect(
            seams.launches.single.$2,
            harness.checkout.localFile(record).path,
          );
        });
      },
    );

    testWidgets(
      'the global default editor wins when no extension binding applies',
      (tester) async {
        await tester.runAsync(() async {
          final editor = seams.editor();
          await registry.register(editor);
          await registry.setDefault(editor.id);
          await mountEditorShell(
            tester,
            harness,
            editorRegistry: registry,
            externalOpener: seams.opener,
          );

          await leftPane(
            tester,
          ).openEntry(cursorEntry(tester, 'config.txt'));
          await checkoutOf(tester, remoteConfigPath);
          await pollUntil(
            tester,
            () => seams.launches.isNotEmpty,
            reason: 'editor never launched',
          );
          expect(seams.launches.single.$1, editor.launchTarget);
        });
      },
    );

    testWidgets(
      'the system default OS-opens the managed copy — never the remote path',
      (tester) async {
        await tester.runAsync(() async {
          await mountEditorShell(
            tester,
            harness,
            editorRegistry: registry,
            externalOpener: seams.opener,
          );

          await leftPane(
            tester,
          ).openEntry(cursorEntry(tester, 'config.txt'));
          final record = await checkoutOf(tester, remoteConfigPath);
          await pollUntil(
            tester,
            () => seams.systemOpener.opens.isNotEmpty,
            reason: 'system opener never fired',
          );
          expect(
            seams.systemOpener.opens.single,
            harness.checkout.localFile(record).path,
          );
        });
      },
    );

    testWidgets(
      'an explicit Open With checks out UNCAPPED — the 4 MiB cap binds '
      'the built-in editor only',
      (tester) async {
        await tester.runAsync(() async {
          final editor = seams.editor();
          await registry.register(editor);
          await mountEditorShell(
            tester,
            harness,
            editorRegistry: registry,
            externalOpener: seams.opener,
            extraEntries: [_bigListing()],
          );

          final pane = leftPane(tester);
          await pane.openInExternalEditor(
            cursorEntry(tester, 'big.bin'),
            editorId: editor.id,
          );
          final record = await checkoutOf(tester, remoteBigPath);
          await pollUntil(
            tester,
            () => seams.launches.isNotEmpty,
            reason: 'editor never launched',
          );
          expect(
            seams.launches.single.$2,
            harness.checkout.localFile(record).path,
          );
        });
      },
    );

    testWidgets(
      'the explicit built-in over a KNOWN over-cap size refuses with '
      'the Open With router — no download spent',
      (tester) async {
        await tester.runAsync(() async {
          await mountEditorShell(
            tester,
            harness,
            editorRegistry: registry,
            externalOpener: seams.opener,
            extraEntries: [_bigListing()],
          );

          final downloadsBefore = harness.fs.downloadCalls.length;
          final pane = leftPane(tester);
          await pane.editInBuiltInEditor(cursorEntry(tester, 'big.bin'));

          await pollFor(tester, find.textContaining('editor limit'));
          // The toast's Open With action — the toolbar carries another
          // Open With affordance, so assert at least one button.
          expect(
            find.widgetWithText(TextButton, 'Open With'),
            findsWidgets,
          );
          // The known-size refusal happens before the download starts.
          expect(harness.fs.downloadCalls.length, downloadsBefore);
          expect(
            harness.checkout.copiesFor('b1').containsKey(remoteBigPath),
            isFalse,
          );
        });
      },
    );

    testWidgets(
      'an unknown-size over-cap Open re-resolves through the system '
      'default — the download was already spent',
      (tester) async {
        await tester.runAsync(() async {
          await mountEditorShell(
            tester,
            harness,
            editorRegistry: registry,
            externalOpener: seams.opener,
            extraEntries: [_mysteryListing()],
          );

          await leftPane(
            tester,
          ).openEntry(cursorEntry(tester, 'mystery.bin'));
          final record = await checkoutOf(tester, remoteMysteryPath);
          await pollUntil(
            tester,
            () => seams.systemOpener.opens.isNotEmpty,
            reason: 'system opener never fired',
          );
          expect(
            seams.systemOpener.opens.single,
            harness.checkout.localFile(record).path,
          );
        });
      },
    );
  });

  group('local rows (06 §4.2)', () {
    late Directory localDir;

    setUp(() async {
      localDir = await scratchDir.createTemp('local-pane-');
      await File(
        p.join(localDir.path, 'notes.txt'),
      ).writeAsString('local\n');
    });

    RemoteFileEntry localEntry() => RemoteFileEntry(
      path: p.join(localDir.path, 'notes.txt'),
      name: 'notes.txt',
      type: RemoteFileType.file,
      size: 6,
      modifiedAt: _now,
    );

    /// A shell whose single restored tab browses [localDir] — the local
    /// pane binds through the engine's scripted local channel.
    Future<void> mountLocalShell(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      harness.appEngine.localChannels.add(
        session_test.FakeAppBrowseChannel(homePath: localDir.path)
          ..listings[localDir.path] = [localEntry()],
      );
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          navigatorKey: harness.navigatorKey,
          home: WorkspaceShell(
            bookmarks: harness.bookmarks,
            engineSession: harness.engine,
            transferQueue: TransferQueueAdapter(harness.queue),
            checkoutSession: harness.checkout,
            editorRegistry: registry,
            externalOpener: seams.opener,
            restoredSession: SessionState(
              activePaneId: sessionLeftPaneId,
              secondPaneHidden: true,
              panes: [
                SessionPaneState(
                  paneId: sessionLeftPaneId,
                  activeTab: 0,
                  nextTabOrdinal: 2,
                  tabs: [SessionTabState.local(path: localDir.path)],
                ),
              ],
            ),
          ),
        ),
      );
      await pollUntil(
        tester,
        () => leftPane(tester).verbsEnabled,
        reason: 'local tab did not bind in time',
      );
    }

    testWidgets(
      'a configured editor launches detached on the local file — '
      'never a checkout',
      (tester) async {
        await tester.runAsync(() async {
          final editor = seams.editor();
          await registry.register(editor);
          await mountLocalShell(tester);

          final pane = leftPane(tester);
          await pane.openInExternalEditor(
            cursorEntry(tester, 'notes.txt'),
            editorId: editor.id,
          );
          await pollUntil(
            tester,
            () => seams.launches.isNotEmpty,
            reason: 'editor never launched',
          );

          expect(seams.launches.single.$1, editor.launchTarget);
          expect(
            seams.launches.single.$2,
            p.join(localDir.path, 'notes.txt'),
          );
          // Local files never enter the managed store.
          expect(harness.checkout.records, isEmpty);
        });
      },
    );

    testWidgets(
      'the System default row hands the local file to the pane channel',
      (tester) async {
        await tester.runAsync(() async {
          await mountLocalShell(tester);
          final channel = harness.appEngine.localChannels.single;

          final pane = leftPane(tester);
          await pane.openInSystemDefaultApp(
            cursorEntry(tester, 'notes.txt'),
          );
          await pollUntil(
            tester,
            () => channel.openCalls.isNotEmpty,
            reason: 'pane channel open never arrived',
          );

          expect(
            channel.openCalls,
            contains(p.join(localDir.path, 'notes.txt')),
          );
        });
      },
    );
  });

  group('upload-on-save loop (06 §3.3/§3.4)', () {
    /// Opens config.txt through the fake editor and writes [contents]
    /// into the managed copy — the watcher/debounce/reconcile chain
    /// turns it into the dirty prompt.
    Future<ManagedRemoteFile> openAndEdit(
      WidgetTester tester, {
      String contents = 'changed\n',
    }) async {
      final editor = seams.editor();
      await registry.register(editor);
      await registry.setDefault(editor.id);
      await mountEditorShell(
        tester,
        harness,
        editorRegistry: registry,
        externalOpener: seams.opener,
      );
      await leftPane(
        tester,
      ).openEntry(cursorEntry(tester, 'config.txt'));
      final record = await checkoutOf(tester, remoteConfigPath);
      await pollUntil(
        tester,
        () => seams.launches.isNotEmpty,
        reason: 'editor never launched',
      );

      final file = harness.checkout.localFile(record);
      await file.writeAsString(contents);
      await pollForDirtyPrompt(tester, 'config.txt');
      return record;
    }

    testWidgets(
      'an external write prompts once and Upload enqueues through the '
      'composed queue',
      (tester) async {
        await tester.runAsync(() async {
          await openAndEdit(tester);
          expect(
            find.widgetWithText(TextButton, 'Upload'),
            findsOneWidget,
          );

          await tester.tap(find.widgetWithText(TextButton, 'Upload'));
          await pollUntil(
            tester,
            () => harness.fs.uploadCalls.contains(remoteConfigPath),
            reason: 'upload never reached the remote',
          );
          expect(
            utf8.decode(harness.fs.bytes(remoteConfigPath)!),
            'changed\n',
          );
          await pollFor(tester, find.text('Uploaded config.txt'));

          // 07 §3.8's criterion-3 wording: the upload is visible in the
          // activity panel — the managed-upload task completed on the
          // same queue the panel mirrors, and its row lists there.
          expect(
            harness.queue.tasks.where(
              (task) =>
                  task.spec.managedCheckout?.direction ==
                      ManagedCheckoutDirection.upload &&
                  task.state == TransferTaskState.completed,
            ),
            hasLength(1),
          );
          await pollFor(
            tester,
            find.descendant(
              of: find.byKey(const ValueKey('activity.panel')),
              matching: find.text('config.txt'),
            ),
          );

          // Clean again — the prompted set released the record.
          final record = harness.checkout.copiesFor(
            'b1',
          )[remoteConfigPath];
          expect(record?.dirty, isFalse);
        });
      },
    );

    testWidgets(
      'a remote change under the dirty copy conflicts — Cancel keeps '
      'the remote, no upload lands',
      (tester) async {
        await tester.runAsync(() async {
          await openAndEdit(tester);
          // The remote moved after the checkout's snapshot: the CAS
          // preflight must refuse.
          harness.fs.seed(
            remoteConfigPath,
            utf8.encode('remote moved\n'),
            modifiedAt: DateTime.utc(2026, 3, 3),
          );

          await tester.tap(find.widgetWithText(TextButton, 'Upload'));
          await pollFor(tester, find.text('Remote file changed'));
          await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
          await pollUntil(
            tester,
            () => find.text('Remote file changed').evaluate().isEmpty,
            reason: 'conflict dialog never closed',
          );

          // One preflight stat, zero uploads; the remote keeps its bytes.
          expect(
            harness.fs.statCalls.where((path) => path == remoteConfigPath),
            hasLength(1),
          );
          expect(
            harness.fs.uploadCalls,
            isNot(contains(remoteConfigPath)),
          );
          expect(
            utf8.decode(harness.fs.bytes(remoteConfigPath)!),
            'remote moved\n',
          );
        });
      },
    );

    testWidgets(
      'the conflict dialog’s Overwrite drops CAS and lands the save',
      (tester) async {
        await tester.runAsync(() async {
          await openAndEdit(tester);
          harness.fs.seed(
            remoteConfigPath,
            utf8.encode('remote moved\n'),
            modifiedAt: DateTime.utc(2026, 3, 3),
          );

          await tester.tap(find.widgetWithText(TextButton, 'Upload'));
          await pollFor(tester, find.text('Remote file changed'));
          await tester.tap(
            find.widgetWithText(FilledButton, 'Overwrite Remote Version'),
          );
          await pollUntil(
            tester,
            () => harness.fs.uploadCalls.contains(remoteConfigPath),
            reason: 'overwrite upload never reached the remote',
          );
          expect(
            utf8.decode(harness.fs.bytes(remoteConfigPath)!),
            'changed\n',
          );
        });
      },
    );

    testWidgets(
      'an atomic-replace save (write-temp, rename-over) still marks '
      'the checkout dirty',
      (tester) async {
        await tester.runAsync(() async {
          final editor = seams.editor();
          await registry.register(editor);
          await registry.setDefault(editor.id);
          await mountEditorShell(
            tester,
            harness,
            editorRegistry: registry,
            externalOpener: seams.opener,
          );
          await leftPane(
            tester,
          ).openEntry(cursorEntry(tester, 'config.txt'));
          final record = await checkoutOf(tester, remoteConfigPath);
          await pollUntil(
            tester,
            () => seams.launches.isNotEmpty,
            reason: 'editor never launched',
          );

          final file = harness.checkout.localFile(record);
          final temp = File('${file.path}.save-tmp');
          await temp.writeAsString('atomic\n');
          if (Platform.isWindows) {
            // Rename-over-existing is a POSIX atomic; Windows tests take
            // the two-step path — the directory watch fires either way.
            await file.delete();
          }
          await temp.rename(file.path);

          await pollForDirtyPrompt(tester, 'config.txt');
          expect(
            find.widgetWithText(TextButton, 'Upload'),
            findsOneWidget,
          );
        });
      },
    );
  });

  group('Open With ▸ menu and remember-choice (06 §4.1)', () {
    Future<void> openWithSubmenu(WidgetTester tester) async {
      final l10n = l10nOf(tester);
      await tester.tap(find.text(l10n.menuFile));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Scoped to the open File menu — the toolbar carries another
      // Open With label.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('menu.file')),
          matching: find.text(l10n.fileOpenWithLabel),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets(
      'the File menu renders the submenu rows for the cursor file',
      (tester) async {
        await tester.runAsync(() async {
          final editor = seams.editor(acceptedExtensions: ['txt']);
          await registry.register(editor);
          await mountEditorShell(
            tester,
            harness,
            editorRegistry: registry,
            externalOpener: seams.opener,
          );
          cursorEntry(tester, 'config.txt');
          await tester.pump();
          final l10n = l10nOf(tester);

          await openWithSubmenu(tester);

          expect(find.text(l10n.openWithBuiltInLabel), findsOneWidget);
          expect(find.text('Fake Editor'), findsOneWidget);
          expect(
            find.text(l10n.openWithSystemDefaultLabel),
            findsOneWidget,
          );
          expect(find.text(l10n.openWithOtherLabel), findsOneWidget);
          expect(find.text(l10n.openWithConfigureLabel), findsOneWidget);
        });
      },
    );

    testWidgets(
      'Other… picks an application, remembers the binding, and opens '
      'through it',
      (tester) async {
        await tester.runAsync(() async {
          await mountEditorShell(
            tester,
            harness,
            editorRegistry: registry,
            externalOpener: seams.opener,
          );
          cursorEntry(tester, 'config.txt');
          await tester.pump();
          final l10n = l10nOf(tester);

          await openWithSubmenu(tester);
          await tester.tap(
            find.widgetWithText(MenuItemButton, l10n.openWithOtherLabel),
          );
          await pollFor(
            tester,
            find.textContaining('Open “config.txt” with'),
          );

          // The pick already ran — the prompt now asks about remembering.
          if (currentEditorHostPlatform == EditorHostPlatform.macos) {
            // macOS picks through the channel, not the picker seam.
            expect(seams.pickCalls, isEmpty);
          } else {
            expect(seams.pickCalls, hasLength(1));
          }
          final picked = registry.registry.editors.single;
          expect(
            picked.displayName,
            currentEditorHostPlatform == EditorHostPlatform.macos
                ? 'Picked Editor'
                : 'fake-editor',
          );

          // Remember the binding, then Open.
          await tester.tap(find.byKey(const ValueKey('openWith.remember')));
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('openWith.confirm')));
          final record = await checkoutOf(tester, remoteConfigPath);
          await pollUntil(
            tester,
            () => seams.launches.isNotEmpty,
            reason: 'editor never launched',
          );

          expect(registry.registry.extensionDefaults['txt'], picked.id);
          expect(
            seams.launches.single.$2,
            harness.checkout.localFile(record).path,
          );
        });
      },
    );

    testWidgets(
      'cancelling the remember-choice aborts the launch entirely',
      (tester) async {
        await tester.runAsync(() async {
          await mountEditorShell(
            tester,
            harness,
            editorRegistry: registry,
            externalOpener: seams.opener,
          );
          cursorEntry(tester, 'config.txt');
          await tester.pump();
          final l10n = l10nOf(tester);

          await openWithSubmenu(tester);
          await tester.tap(
            find.widgetWithText(MenuItemButton, l10n.openWithOtherLabel),
          );
          await pollFor(
            tester,
            find.byKey(const ValueKey('openWith.confirm')),
          );
          await tester.tap(
            find.widgetWithText(TextButton, l10n.openWithCancel),
          );
          await tester.pump(const Duration(milliseconds: 400));

          expect(seams.launches, isEmpty);
          expect(registry.registry.extensionDefaults, isEmpty);
          // The pick itself registered — the cancel only aborts the open.
          expect(registry.registry.editors, hasLength(1));
        });
      },
    );
  });
}
