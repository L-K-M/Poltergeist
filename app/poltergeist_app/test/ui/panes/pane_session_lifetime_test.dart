import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart';
import '../../support/fake_bookmark_store.dart';

Bookmark _bookmark(String id) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: id,
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: '$id.example.com',
      port: 22,
      username: 'tester',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/',
  sortKey: id,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

RemoteFileEntry _entry(String name) =>
    RemoteFileEntry(name: name, path: '/home/$name', type: RemoteFileType.file);

// Separate pending opens expose cross-pane prompt and channel ownership.
class _PromptEngine extends FakeAppEngine {
  final pending = <String, Completer<AppBrowseChannel>>{};
  final channels = <String, FakeAppBrowseChannel>{};

  @override
  Future<AppBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  }) {
    openCalls.add((serverId: serverId, paneTabId: paneTabId, config: config));
    final result = pending[serverId] = Completer<AppBrowseChannel>();
    promptsController.add(
      EnginePromptEvent(
        promptId: serverId,
        kind: EnginePromptKind.hostKeyFirstUse,
        data: HostKeyPromptData(
          host: config.host,
          port: config.port,
          keyType: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:$serverId',
        ),
      ),
    );
    return result.future;
  }

  @override
  void replyPrompt(String promptId, EnginePromptKind kind, PromptReply reply) {
    super.replyPrompt(promptId, kind, reply);
    final result = pending.remove(promptId)!;
    if (reply is HostKeyPromptReply && reply.accepted) {
      result.complete(channels[promptId]!);
      return;
    }
    result.completeError(
      const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'connect',
        message: 'Trust declined.',
      ),
    );
  }
}

class _HeldChannel extends FakeAppBrowseChannel {
  final listing = Completer<List<RemoteFileEntry>>();

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) {
    listCalls.add(path);
    return listing.future;
  }
}

void main() {
  Future<EngineSession> start(
    FakeAppEngine engine,
    GlobalKey<NavigatorState> key,
  ) async {
    final directory = Directory.systemTemp.createTempSync('pane-session-');
    addTearDown(() => directory.deleteSync(recursive: true));
    addTearDown(engine.close);
    final session = await startEngineSession(
      supportDirectoryPath: directory.path,
      bookmarks: FakeBookmarkStore(),
      navigatorKey: key,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (_) async => engine,
    );
    // A future completed inside fake async cannot be awaited by real teardown.
    // Each test awaits shutdown and checks release before leaving that zone.
    addTearDown(() => unawaited(session!.shutdown()));
    return session!;
  }

  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets(
    'both pane connects share FIFO prompts and independent teardown',
    (tester) async {
      size(tester);
      final engine = _PromptEngine();
      engine.localChannels.addAll([
        FakeAppBrowseChannel(),
        FakeAppBrowseChannel(),
      ]);
      for (final id in ['left', 'right']) {
        engine.channels[id] = FakeAppBrowseChannel(homePath: '/home')
          ..listings['/home'] = [_entry('$id.txt')];
      }
      final key = GlobalKey<NavigatorState>();
      final session = await start(engine, key);
      await tester.pumpWidget(
        PoltergeistApp(engineSession: session, navigatorKey: key),
      );
      await tester.pump();
      final panes = tester.widgetList<PaneView>(find.byType(PaneView)).toList();
      final left = panes[0].controller;
      final right = panes[1].controller;
      final connecting = Future.wait([
        left.connectRemote(_bookmark('left')),
        right.connectRemote(_bookmark('right')),
      ]);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 300));
      expect(engine.openCalls, hasLength(2));
      expect(engine.pending.keys, unorderedEquals(['left', 'right']));
      expect(find.text('Unknown host key'), findsOneWidget);
      expect(find.textContaining('SHA256:left'), findsOneWidget);
      expect(find.textContaining('SHA256:right'), findsNothing);

      await tester.tap(find.text('Trust and connect'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(engine.replies.map((reply) => reply.$1), ['left']);
      expect(find.textContaining('SHA256:right'), findsOneWidget);
      await tester.tap(find.text('Trust and connect'));
      await tester.pumpAndSettle();
      await connecting;
      expect(find.text('left.txt'), findsOneWidget);
      expect(find.text('right.txt'), findsOneWidget);
      expect(engine.replies.map((reply) => reply.$1), ['left', 'right']);

      await left.detachRemote();
      right.refresh();
      await tester.pump();
      expect(engine.channels['left']!.closeCalls, 1);
      expect(engine.channels['right']!.closeCalls, 0);
      expect(engine.channels['right']!.listCalls, ['/home', '/home']);
      expect(engine.disconnectIds, isEmpty);
      expect(find.text('right.txt'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await session.shutdown();
      await session.shutdown();
      expect(engine.channels['right']!.closeCalls, 1);
      expect(engine.localChannels.map((channel) => channel.closeCalls), [1, 1]);
      expect(engine.shutdownCalls, 1);
      expect(engine.pending, isEmpty);
    },
  );

  testWidgets('a replaced session cannot repaint from its delayed listing', (
    tester,
  ) async {
    size(tester);
    final key = GlobalKey<NavigatorState>();
    final held = _HeldChannel();
    addTearDown(() {
      if (!held.listing.isCompleted) held.listing.complete([]);
    });
    final oldEngine = FakeAppEngine()
      ..localChannels.addAll([held, FakeAppBrowseChannel()]);
    final oldSession = await start(oldEngine, key);
    await tester.pumpWidget(
      PoltergeistApp(engineSession: oldSession, navigatorKey: key),
    );
    await tester.pump();
    expect(held.listCalls, hasLength(1));
    expect(held.listing.isCompleted, isFalse);

    final replacement = FakeAppEngine();
    for (final name in ['new-left.txt', 'new-right.txt']) {
      replacement.localChannels.add(
        FakeAppBrowseChannel(homePath: '/home')
          ..listings['/home'] = [_entry(name)],
      );
    }
    final newSession = await start(replacement, key);
    await tester.pumpWidget(
      PoltergeistApp(engineSession: newSession, navigatorKey: key),
    );
    await tester.pumpAndSettle();
    expect(held.closeCalls, 1);
    held.listing.complete([_entry('stale.txt')]);
    await tester.pumpAndSettle();
    expect(find.text('stale.txt'), findsNothing);
    expect(find.text('new-left.txt'), findsOneWidget);
    expect(find.text('new-right.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await oldSession.shutdown();
    await newSession.shutdown();
    expect(oldEngine.shutdownCalls, 1);
    expect(replacement.shutdownCalls, 1);
    expect(replacement.localChannels.map((channel) => channel.closeCalls), [
      1,
      1,
    ]);
  });
}
