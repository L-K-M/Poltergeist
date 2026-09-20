// Editor-over-checkout integration (06 §3/§4.2, M7): the full shell
// path — a remote pane's `file.editBuiltIn` command riding the managed
// checkout pipeline, saving through the atomic saver, and uploading
// through the composed queue — against a scripted remote endpoint.
// The conflict arm exercises 06 §3.4's escalation: a remote that moved
// under the open checkout blocks the upload at the preflight stat and
// the dialog decides — never a silent write, never a bypass of the
// SHA-256 gate.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/app_transfer_queue.dart';
import 'package:poltergeist_app/services/checkout_session.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/ui/built_in_text_editor.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';

/// The remote path the harness seeds — the file the editor tests open.
const remoteConfigPath = '/srv/www/config.txt';

/// A second seeded file — lets a test stack one editor route over
/// another to exercise the buried-editor reveal.
const remoteNotesPath = '/srv/www/notes.txt';
final _now = DateTime.utc(2026, 9, 12);

Bookmark _bookmark() => Bookmark(
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

RemoteFileEntry _listing() => RemoteFileEntry(
  path: remoteConfigPath,
  name: 'config.txt',
  type: RemoteFileType.file,
  size: utf8.encode('one\ntwo\n').length,
  modifiedAt: DateTime.utc(2026, 1, 1),
  mode: 0x1a4, // 0644
);

RemoteFileEntry _notesListing() => RemoteFileEntry(
  path: remoteNotesPath,
  name: 'notes.txt',
  type: RemoteFileType.file,
  size: utf8.encode('notes\n').length,
  modifiedAt: DateTime.utc(2026, 1, 1),
  mode: 0x1a4, // 0644
);

/// One scripted remote file: the bytes a later stat/download/upload
/// pair must agree on, with the metadata `sameRemoteSnapshot`
/// compares.
final class _RemoteFile {
  _RemoteFile({
    required this.bytes,
    required this.modifiedAt,
    required this.mode,
  });
  final List<int> bytes;
  final DateTime modifiedAt;
  final int? mode;
}

/// The remote endpoint behind the checkout hop (03 §4.3's leased
/// channel): in-memory files, a streamed download into the pipe's
/// sink, and an upload applying the adapter's CAS — `expectedTarget`
/// compares snapshot metadata AND the streamed content digest, so a
/// remote that only metadata-matches still refuses.
final class FakeEditorRemoteFs implements RemoteFileSystem {
  final _files = <String, _RemoteFile>{};
  final uploadCalls = <String>[];
  final downloadCalls = <String>[];
  final statCalls = <String>[];

  void seed(String path, List<int> bytes, {DateTime? modifiedAt}) {
    _files[path] = _RemoteFile(
      bytes: bytes,
      modifiedAt: modifiedAt ?? DateTime.utc(2026, 1, 1),
      mode: 0x1a4,
    );
  }

  List<int>? bytes(String path) => _files[path]?.bytes;

  RemoteFileEntry _entryOf(String path, String operation) {
    final file = _files[path];
    if (file == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: operation,
        path: path,
        message: 'No such file.',
      );
    }
    return RemoteFileEntry(
      path: path,
      name: remoteBasename(path),
      type: RemoteFileType.file,
      size: file.bytes.length,
      modifiedAt: file.modifiedAt,
      mode: file.mode,
    );
  }

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) {
    statCalls.add(path);
    return Future.value(_entryOf(path, 'stat'));
  }

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    downloadCalls.add(path);
    cancellation?.throwIfCancelled();
    final file = _files[path];
    if (file == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'download',
        path: path,
        message: 'No such file.',
      );
    }
    destination.add(file.bytes);
    onProgress?.call(file.bytes.length, file.bytes.length);
    final entry = _entryOf(path, 'download');
    return RemoteFileEntry(
      path: entry.path,
      name: entry.name,
      type: entry.type,
      size: entry.size,
      modifiedAt: entry.modifiedAt,
      mode: entry.mode,
      contentSha256: computeHash
          ? sha256.convert(file.bytes).toString()
          : null,
    );
  }

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    uploadCalls.add(path);
    cancellation?.throwIfCancelled();
    final expected = expectedTarget;
    if (expected != null) {
      final file = _files[path];
      // Séance's `_matchesExpectedTarget` (D2): snapshot metadata first,
      // then the streamed content digest when the expected snapshot
      // carries one — the checkout's remoteSnapshot always does.
      final digestMatches =
          expected.contentSha256 == null ||
          (file != null &&
              sha256.convert(file.bytes).toString() ==
                  expected.contentSha256);
      final matches =
          file != null &&
          file.bytes.length == expected.size &&
          file.modifiedAt == expected.modifiedAt &&
          file.mode == expected.mode &&
          digestMatches;
      if (!matches) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'upload',
          path: path,
          message: '"${remoteBasename(path)}" changed on the server.',
        );
      }
    }
    final collected = <int>[];
    await for (final chunk in content) {
      cancellation?.throwIfCancelled();
      collected.addAll(chunk);
      onProgress?.call(collected.length, length);
    }
    final written = DateTime.utc(2026, 2, 2);
    _files[path] = _RemoteFile(
      bytes: collected,
      modifiedAt: written,
      mode: preserveMode ?? _files[path]?.mode,
    );
    return RemoteFileEntry(
      path: path,
      name: remoteBasename(path),
      type: RemoteFileType.file,
      size: collected.length,
      modifiedAt: written,
      mode: _files[path]!.mode,
      contentSha256: computeHash
          ? sha256.convert(collected).toString()
          : null,
    );
  }

  // The managed hops only ever reach stat/download/upload — the rest
  // of the VFS answers unsupported honestly rather than pretending.
  @override
  Future<String> canonicalize(String path) => Future.value(path);
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) =>
      Future.value(const []);
  @override
  Future<void> setMode(String path, int permissions) => Future.value();
  @override
  Future<void> setTimes(
    String path, {
    DateTime? accessedAt,
    DateTime? modifiedAt,
  }) => Future.value();
  @override
  Future<void> setOwner(String path, {int? uid, int? gid}) =>
      Future.value();
  @override
  Future<String> readSymbolicLink(String path) =>
      Future.error(UnsupportedError('readSymbolicLink'));
  @override
  Future<void> createSymbolicLink(String linkPath, String targetPath) =>
      Future.error(UnsupportedError('createSymbolicLink'));
  @override
  Future<void> createDirectory(String path) =>
      Future.error(UnsupportedError('createDirectory'));
  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) => Future.error(UnsupportedError('rename'));
  @override
  Future<void> delete(RemoteFileEntry entry) =>
      Future.error(UnsupportedError('delete'));
}

/// The queue's connection seam (03 §4.3): leases the scripted remote
/// to transfer workers; browse channels are the engine's business, not
/// this fake's.
final class FakeEditorConnections implements ConnectionManager {
  FakeEditorConnections(this.fs);

  final RemoteFileSystem fs;
  final leaseCalls = <String>[];

  @override
  Future<TransferChannelLease> leaseTransferChannel(String serverId) {
    leaseCalls.add(serverId);
    return Future.value(_FakeLease(fs));
  }

  @override
  Future<PaneChannel> openBrowseChannel(
    String serverId, {
    required String paneTabId,
  }) => Future.error(UnsupportedError('openBrowseChannel'));

  @override
  Stream<ServerStatus> watchServer(String serverId) => Stream.value(
    const ServerStatus(ServerConnectionState.connected),
  );

  @override
  Stream<ConnectLogLine> get connectLog => const Stream.empty();

  @override
  Future<Set<String>> connectedServerIds() => Future.value(const {'b1'});

  @override
  Future<void> disconnectServer(String serverId) => Future.value();

  @override
  Future<void> removeBookmark(String serverId) => Future.value();
}

final class _FakeLease implements TransferChannelLease {
  _FakeLease(this.fs);

  @override
  final RemoteFileSystem fs;
  var releaseCalls = 0;

  @override
  Future<void> release() async {
    releaseCalls++;
  }

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {}
}

/// The wired harness: a scripted remote endpoint, the composed queue
/// over it, the checkout session, and the engine session whose browse
/// channel lists /srv/www — everything the shell needs to run the real
/// §4.2 open path.
final class EditorCheckoutHarness {
  EditorCheckoutHarness._();

  late final Directory supportDir;
  late final FakeEditorRemoteFs fs;
  late final FakeEditorConnections connections;
  late final TransferQueue queue;
  late final CheckoutSession checkout;
  late final EngineSession engine;
  late final FakeBookmarkStore bookmarks;
  late final session_test.FakeAppEngine appEngine;
  final navigatorKey = GlobalKey<NavigatorState>();

  static Future<EditorCheckoutHarness> open() async {
    final harness = EditorCheckoutHarness._();
    harness.supportDir = await Directory.systemTemp.createTemp(
      'pg-editor-checkout-',
    );
    harness.fs = FakeEditorRemoteFs()
      ..seed(remoteConfigPath, utf8.encode('one\ntwo\n'))
      ..seed(remoteNotesPath, utf8.encode('notes\n'));
    harness.connections = FakeEditorConnections(harness.fs);
    harness.queue = TransferQueue(connections: harness.connections);
    harness.checkout = (await startCheckoutSession(
      supportDirectoryPath: harness.supportDir.path,
      queue: harness.queue,
      connections: harness.connections,
    ))!;
    harness.bookmarks = FakeBookmarkStore();
    final channel = session_test.FakeAppBrowseChannel(homePath: '/srv')
      ..listings['/srv/www'] = [_listing(), _notesListing()];
    harness.appEngine = session_test.FakeAppEngine()..channel = channel;
    harness.engine = (await startEngineSession(
      supportDirectoryPath: harness.supportDir.path,
      bookmarks: harness.bookmarks,
      navigatorKey: harness.navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (_) async => harness.appEngine,
    ))!;
    return harness;
  }

  Future<void> close() async {
    await checkout.shutdown();
    await engine.shutdown();
    appEngine.close();
    await queue.dispose();
    if (await supportDir.exists()) {
      await supportDir.delete(recursive: true);
    }
  }
}

/// Polls the real event loop until [finder] mounts — every wait in
/// this file rides real I/O (channel opens, checkout downloads, disk
/// saves), so fake-zone frame counts would flake.
Future<void> pollFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(finder.evaluate(), isNotEmpty, reason: 'timed out: $finder');
}

/// The restored remote tab's live pane (pane.left — the second pane is
/// hidden in the seeded session).
PaneController leftPane(WidgetTester tester) {
  for (final element in find.byType(PaneTabsView).evaluate()) {
    final view = element.widget as PaneTabsView;
    if (view.tabs.paneId == sessionLeftPaneId) {
      return view.tabs.activeTabController!;
    }
  }
  fail('left pane not mounted');
}

late EditorCheckoutHarness harness;

/// Mounts the shell with a session-restored remote tab (the live pane
/// a remote file row can be edited from) and the real seams: engine
/// lanes → the scripted browse channel, the checkout session → the
/// composed queue, the activity panel → the same queue. [boundaryKey]
/// marks the capture surface — the editor's pushed route lands inside
/// it, so boundary grabs cover the editor too.
Future<void> mountEditorShell(
  WidgetTester tester,
  EditorCheckoutHarness harness, {
  Key? boundaryKey,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  Widget app = MaterialApp(
    theme: theme,
    debugShowCheckedModeBanner: false,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    navigatorKey: harness.navigatorKey,
    home: WorkspaceShell(
      bookmarks: harness.bookmarks,
      engineSession: harness.engine,
      transferQueue: TransferQueueAdapter(harness.queue),
      checkoutSession: harness.checkout,
      // Keep the completed row: the default auto-clear would evict
      // the finished upload before the assertion reads the panel.
      autoClearCompletedTransfers: false,
      restoredSession: SessionState(
        activePaneId: sessionLeftPaneId,
        // One pane keeps every PaneTabsView lookup unambiguous; the
        // panel stays open so upload-on-save renders as a row.
        secondPaneHidden: true,
        activityPanelHidden: false,
        panes: [
          SessionPaneState(
            paneId: sessionLeftPaneId,
            activeTab: 0,
            nextTabOrdinal: 2,
            tabs: [
              SessionTabState.remote(
                serverId: 'b1',
                path: '/srv/www',
                bookmark: _bookmark(),
                listing: [_listing(), _notesListing()],
              ),
            ],
          ),
        ],
      ),
    ),
  );
  if (boundaryKey != null) {
    app = RepaintBoundary(key: boundaryKey, child: app);
  }
  await tester.pumpWidget(app);
  // The restored tab's cached listing renders as stale rows at once —
  // the live bind is what unlocks the verbs (and the command's
  // enablement), so the wait is on the binding, not the row text.
  for (var i = 0; i < 80; i++) {
    await tester.pump();
    if (leftPane(tester).verbsEnabled) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('remote tab did not bind in time');
}

/// Opens the cursor row through the registered File-menu command —
/// `file.editBuiltIn`'s production path from menu item to checkout.
Future<void> openEditorViaCommand(
  WidgetTester tester,
  EditorCheckoutHarness harness, {
  String fileName = 'config.txt',
}) async {
  final pane = leftPane(tester);
  final cursor = pane.entries.indexWhere((e) => e.name == fileName);
  expect(cursor, isNonNegative);
  pane.setCursorIndex(cursor);
  await tester.pump();

  final l10n = AppLocalizations.of(
    tester.element(find.byType(MenuBar)),
  );
  await tester.tap(find.text(l10n.menuFile));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(
    find.widgetWithText(MenuItemButton, l10n.fileEditBuiltInLabel),
  );
  // The route push follows the real checkout download — poll until
  // the editor mounts, then until its disk load finishes.
  await pollFor(tester, find.byType(BuiltInTextEditorScreen));
  for (var i = 0; i < 80; i++) {
    await tester.pump();
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(
    find.byType(CircularProgressIndicator),
    findsNothing,
    reason: 'editor load did not finish',
  );
  // The slide-in transition runs on the fake clock — real-async waits
  // leave the page mid-slide and its AppBar actions off-screen.
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() async {
    harness = await EditorCheckoutHarness.open();
  });

  tearDown(() async {
    await harness.close();
  });

  testWidgets(
    'a remote file opens through file.editBuiltIn, edits, and '
    'save-and-upload rides the composed queue',
    (tester) async {
      await tester.runAsync(() async {
        await mountEditorShell(tester, harness);
        await openEditorViaCommand(tester, harness);

        // The checkout's local bytes are the remote's — the editor's
        // real disk load landed them in the field.
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          'one\ntwo\n',
        );
        // The remote route carries the upload action (06 §4.2).
        expect(find.byTooltip('Save and upload'), findsOneWidget);
        // The record landed in the session — the download task is the
        // first queue row.
        expect(
          harness.checkout.checkoutFor('b1', remoteConfigPath),
          isNotNull,
        );
        expect(harness.fs.downloadCalls, [remoteConfigPath]);

        await tester.enterText(find.byType(TextField), 'remote edit\n');
        await tester.pump();
        await tester.tap(find.byTooltip('Save and upload'));
        await pollFor(tester, find.text('Saved and uploaded.'));
        await tester.pump(const Duration(milliseconds: 300));

        // The upload went through the queue's CAS hop exactly once —
        // the remote now holds the edited bytes.
        expect(harness.fs.uploadCalls, [remoteConfigPath]);
        expect(
          utf8.decode(harness.fs.bytes(remoteConfigPath)!),
          'remote edit\n',
        );

        // Upload-on-save is panel-visible (02 §6): the managed upload
        // task completed on the same queue the panel mirrors.
        final uploads = harness.queue.tasks.where(
          (task) =>
              task.spec.managedCheckout?.direction ==
                  ManagedCheckoutDirection.upload &&
              task.state == TransferTaskState.completed,
        );
        expect(uploads, hasLength(1));

        // Upload-on-save is panel-visible (02 §6): back on the shell,
        // the completed upload row lists under the activity panel. The
        // row is lazily built, so the read has to happen after the
        // editor route pops — offstage lists have no viewport.
        await tester.binding.handlePopRoute();
        await pollFor(
          tester,
          find.descendant(
            of: find.byKey(const ValueKey('activity.panel')),
            matching: find.text('config.txt'),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
      });
    },
  );

  testWidgets(
    'a remote change under the open checkout blocks the upload at the '
    'conflict dialog — cancel writes nothing',
    (tester) async {
      await tester.runAsync(() async {
        await mountEditorShell(tester, harness);
        await openEditorViaCommand(tester, harness);

        // The server moved after the checkout — a different mtime AND
        // content, so both the metadata preflight and the CAS digest
        // would refuse.
        harness.fs.seed(
          remoteConfigPath,
          utf8.encode('server rewrite\n'),
          modifiedAt: DateTime.utc(2026, 3, 3),
        );
        await tester.enterText(find.byType(TextField), 'local edit\n');
        await tester.pump();
        await tester.tap(find.byTooltip('Save and upload'));
        await pollFor(tester, find.text('Remote file changed'));
        await tester.pump(const Duration(milliseconds: 300));

        // 06 §3.4's escalation dialog names the file and its server —
        // safe default first (02 §10).
        expect(
          find.textContaining(
            '“config.txt” changed (or was deleted) on web.example.com',
          ),
          findsOneWidget,
        );
        // The save preflight refused before the queue hop — the fake
        // never saw an upload.
        expect(harness.fs.uploadCalls, isEmpty);

        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await pollFor(tester, find.text('Saved locally; not uploaded.'));
        await tester.pump(const Duration(milliseconds: 300));

        // Cancel writes nothing: the remote keeps the server's rewrite
        // and no upload task ever reached the queue.
        expect(
          utf8.decode(harness.fs.bytes(remoteConfigPath)!),
          'server rewrite\n',
        );
        expect(harness.fs.uploadCalls, isEmpty);
        expect(
          harness.queue.tasks.where(
            (task) =>
                task.spec.managedCheckout?.direction ==
                ManagedCheckoutDirection.upload,
          ),
          isEmpty,
        );
        // The local copy kept its edit — the save itself succeeded.
        final record = harness.checkout.checkoutFor('b1', remoteConfigPath)!;
        expect(
          await harness.checkout.localFile(record).readAsString(),
          'local edit\n',
        );
      });
    },
  );

  testWidgets(
    'the conflict dialog\'s overwrite retries with CAS waived and '
    'commits the edit',
    (tester) async {
      await tester.runAsync(() async {
        await mountEditorShell(tester, harness);
        await openEditorViaCommand(tester, harness);

        harness.fs.seed(
          remoteConfigPath,
          utf8.encode('server rewrite\n'),
          modifiedAt: DateTime.utc(2026, 3, 3),
        );
        await tester.enterText(find.byType(TextField), 'local edit\n');
        await tester.pump();
        await tester.tap(find.byTooltip('Save and upload'));
        await pollFor(tester, find.text('Remote file changed'));

        await tester.tap(
          find.widgetWithText(FilledButton, 'Overwrite Remote Version'),
        );
        await pollFor(tester, find.text('Saved and uploaded.'));
        await tester.pump(const Duration(milliseconds: 300));

        expect(harness.fs.uploadCalls, [remoteConfigPath]);
        expect(
          utf8.decode(harness.fs.bytes(remoteConfigPath)!),
          'local edit\n',
        );
      });
    },
  );

  testWidgets(
    're-opening a buried editor reveals it through the covering '
    'editor\'s discard guard, never a force pop',
    (tester) async {
      await tester.runAsync(() async {
        await mountEditorShell(tester, harness);
        await openEditorViaCommand(tester, harness, fileName: 'config.txt');

        // The pushed editor covers the shell, so a second open can't
        // come from the menu — drive the pane's editor seam directly
        // (the same entry point the command resolves to).
        final pane = leftPane(tester);
        final notes = pane.entries.firstWhere((e) => e.name == 'notes.txt');
        unawaited(pane.editInBuiltInEditor(notes));
        for (var i = 0; i < 80; i++) {
          await tester.pump();
          if (find
                  .byType(BuiltInTextEditorScreen, skipOffstage: false)
                  .evaluate()
                  .length ==
              2) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        for (var i = 0; i < 80; i++) {
          await tester.pump();
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await tester.pump(const Duration(milliseconds: 400));

        // Both editors stay in the tree (the covered route keeps its
        // state) — address the covering one's field by its document.
        Finder fieldWith(String text) => find.byWidgetPredicate(
          (w) => w is TextField && w.controller?.text == text,
        );

        // Dirty the covering editor — its PopScope must arbitrate the
        // reveal, not be stepped over by a forceful popUntil.
        await tester.enterText(fieldWith('notes\n'), 'unsaved notes\n');
        await tester.pump();

        final config = pane.entries.firstWhere(
          (e) => e.name == 'config.txt',
        );
        unawaited(pane.editInBuiltInEditor(config));
        await pollFor(tester, find.text('Discard unsaved changes?'));

        // Keep editing declines the reveal — the covering editor stays.
        await tester.tap(find.widgetWithText(TextButton, 'Keep editing'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(fieldWith('unsaved notes\n'), findsOneWidget);

        // Re-invoke, then Discard: the covering editor pops and the
        // buried one surfaces with its own document.
        unawaited(pane.editInBuiltInEditor(config));
        await pollFor(tester, find.text('Discard unsaved changes?'));
        await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
        for (var i = 0; i < 40; i++) {
          await tester.pump();
          if (fieldWith('one\ntwo\n').evaluate().isNotEmpty &&
              fieldWith('unsaved notes\n').evaluate().isEmpty) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await tester.pump(const Duration(milliseconds: 400));
        expect(fieldWith('one\ntwo\n'), findsOneWidget);
      });
    },
  );
}
