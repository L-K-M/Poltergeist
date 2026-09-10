import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/bookmark_store.dart';
import 'package:poltergeist_app/services/connection_state_bridge.dart';
import 'package:poltergeist_app/services/connection_status_controller.dart';
import 'package:poltergeist_app/ui/connections/connections_command.dart';
import 'package:poltergeist_app/ui/connections/connections_view.dart';
import 'package:poltergeist_app/ui/probe_status_dot.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/fake_bookmark_store.dart';
import '../../support/fake_connection_state_bridge.dart';

final _now = DateTime.utc(2026, 9, 10, 12);

final _commandButton = find.byKey(
  const ValueKey('command.$kConnectionsCommandId'),
);

Bookmark _server(
  String id, {
  String label = 'web',
  String host = 'web.example.com',
  int port = 2222,
  String username = 'deploy',
}) {
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: label,
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: host,
        port: port,
        username: username,
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/',
    sortKey: id,
    createdAt: _now,
    updatedAt: _now,
  );
}

Bookmark _localFolder(String id) {
  return Bookmark(
    id: id,
    kind: BookmarkKind.localFolder,
    label: 'home',
    localPath: '/home/tester',
    sortKey: id,
    createdAt: _now,
    updatedAt: _now,
  );
}

/// A store whose read fails until healed: the surface must report it inline
/// with a retry, never render an empty page as if the app held no server.
class _UnreadableStore implements BookmarkRepository {
  _UnreadableStore([this.bookmarks = const []]);

  final List<Bookmark> bookmarks;
  bool readable = false;

  @override
  Future<List<Bookmark>> load() async {
    if (!readable) throw const FileSystemException('unreadable');
    return List.unmodifiable(bookmarks);
  }

  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {}
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late FakeBookmarkStore store;
  late FakeConnectionStateBridge bridge;

  setUp(() {
    store = FakeBookmarkStore();
    bridge = FakeConnectionStateBridge();
  });

  tearDown(() async {
    await bridge.close();
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    BookmarkRepository? bookmarks,
    ConnectionStateBridge? engine,
  }) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      PoltergeistApp(bookmarks: bookmarks ?? store, connectionEngine: engine),
    );
    await tester.pump();
  }

  Future<void> openConnections(WidgetTester tester) async {
    await tester.tap(_commandButton);
    await tester.pumpAndSettle();
  }

  /// Pumps the surface on its own, so the review seam — which no production
  /// composition can supply yet — is testable.
  Future<ConnectionStatusController> pumpView(
    WidgetTester tester, {
    void Function(ConnectionServer server)? onReviewBlocked,
  }) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = ConnectionStatusController(
      bookmarks: store,
      bridge: bridge,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ConnectionsView(controller, onReviewBlocked: onReviewBlocked),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  group('command registration', () {
    testWidgets('registers with a bookmark store, not without one', (
      tester,
    ) async {
      await tester.pumpWidget(const PoltergeistApp());
      await tester.pump();
      expect(_commandButton, findsNothing);

      await pumpApp(tester);

      expect(_commandButton, findsOneWidget);
      expect(find.text(l10n.connectionsTitle), findsOneWidget);
    });

    testWidgets('opens the surface from the toolbar', (tester) async {
      store.bookmarks = [_server('a')];
      await pumpApp(tester);

      await openConnections(tester);

      expect(find.byType(ConnectionsView), findsOneWidget);
      expect(find.byKey(const ValueKey('connection.a')), findsOneWidget);
    });

    testWidgets('the session ends when the route pops', (tester) async {
      store.bookmarks = [_server('a')];
      await pumpApp(tester);

      await openConnections(tester);
      expect(find.byType(ConnectionsView), findsOneWidget);

      // The pushed route covers the shell, so the toolbar is not in the tree
      // while it is open; popping restores it and the command must be
      // enabled again (run() stays pending for the whole session).
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();

      expect(find.byType(ConnectionsView), findsNothing);
      expect(tester.widget<TextButton>(_commandButton).onPressed, isNotNull);
    });
  });

  group('the list', () {
    testWidgets('renders the store\'s servers with their endpoints', (
      tester,
    ) async {
      store.bookmarks = [
        _server('a', label: 'alpha'),
        _localFolder('local'),
        _server('b', label: 'beta', host: 'beta.example.com', port: 22),
      ];
      await pumpApp(tester);

      await openConnections(tester);

      expect(find.text('alpha'), findsOneWidget);
      expect(find.text('deploy@web.example.com:2222'), findsOneWidget);
      expect(find.text('beta'), findsOneWidget);
      expect(find.text('deploy@beta.example.com:22'), findsOneWidget);
      // A local folder names no server, so it is not a connection row.
      expect(find.text('home'), findsNothing);
    });

    testWidgets('an empty store renders the empty state', (tester) async {
      await pumpApp(tester);

      await openConnections(tester);

      expect(find.text(l10n.connectionsEmpty), findsOneWidget);
      expect(find.byKey(const ValueKey('connection.a')), findsNothing);
    });

    testWidgets('without an engine every row reads not connected', (
      tester,
    ) async {
      store.bookmarks = [_server('a'), _server('b')];
      await pumpApp(tester);

      await openConnections(tester);

      // No production engine exists yet (STATUS item 3): the honest reading
      // is that the app holds no transport, never a guessed failure.
      expect(find.text(l10n.connectionStateNotConnected), findsNWidgets(2));
      expect(find.text(l10n.connectionFailedTitle), findsNothing);
      expect(find.byType(ProbeStatusDot), findsNothing);
    });

    testWidgets('an unreadable store reports inline and retries', (
      tester,
    ) async {
      final unreadable = _UnreadableStore([_server('a', label: 'alpha')]);
      await pumpApp(tester, bookmarks: unreadable);

      await openConnections(tester);

      expect(find.text(l10n.connectionsLoadFailed), findsOneWidget);
      expect(find.text(l10n.connectionsEmpty), findsNothing);
      // The read failure is also reported through the app's error sink, not
      // only rendered.
      expect(tester.takeException(), isA<FileSystemException>());

      unreadable.readable = true;
      await tester.tap(find.byKey(const ValueKey('connections-retry')));
      await tester.pumpAndSettle();

      // The retry really re-read: the row the healed store holds renders.
      expect(find.text(l10n.connectionsLoadFailed), findsNothing);
      expect(find.text('alpha'), findsOneWidget);
      expect(find.text(l10n.connectionStateNotConnected), findsOneWidget);
    });
  });

  group('live connection state', () {
    testWidgets('tracks the engine\'s state per row', (tester) async {
      store.bookmarks = [_server('a'), _server('b', label: 'beta')];
      await pumpView(tester);

      bridge.emitStatus(
        'a',
        const ServerStatus(ServerConnectionState.connecting),
      );
      await tester.pump();

      final rowA = find.byKey(const ValueKey('connection.a'));
      expect(
        find.descendant(
          of: rowA,
          matching: find.text(l10n.connectionStateConnecting),
        ),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      bridge.emitStatus(
        'a',
        const ServerStatus(ServerConnectionState.connected),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: rowA,
          matching: find.text(l10n.connectionStateConnected),
        ),
        findsOneWidget,
      );
      // The sibling never connected: it keeps the honest default.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('connection.b')),
          matching: find.text(l10n.connectionStateNotConnected),
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders the state-associated failure one-liner', (
      tester,
    ) async {
      store.bookmarks = [_server('a')];
      await pumpView(tester);

      bridge.emitStatus(
        'a',
        const ServerStatus(
          ServerConnectionState.disconnected,
          detail: 'Authentication failed for deploy@web.example.com:2222.',
        ),
      );
      await tester.pump();

      final row = find.byKey(const ValueKey('connection.a'));
      expect(
        find.descendant(
          of: row,
          matching: find.text(
            'Authentication failed for deploy@web.example.com:2222.',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text(l10n.connectionFailedTitle),
        ),
        findsOneWidget,
      );
    });

    testWidgets('makes a block explicit without a review seam', (tester) async {
      store.bookmarks = [_server('a')];
      await pumpView(tester);

      bridge.emitStatus(
        'a',
        const ServerStatus(
          ServerConnectionState.blocked,
          detail: 'Host key changed for web.example.com:2222.',
        ),
      );
      await tester.pump();

      final row = find.byKey(const ValueKey('connection.a'));
      expect(
        find.descendant(
          of: row,
          matching: find.text(l10n.connectionBlockedTitle),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text('Host key changed for web.example.com:2222.'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text(l10n.connectionsBlockedWarning),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.gpp_bad), findsOneWidget);
      // No composition can start a connect yet, so there is no review to
      // offer: the warning names the path instead of a dead button.
      expect(find.byKey(const ValueKey('connection.review.a')), findsNothing);
    });

    testWidgets('offers the review through the existing prompt path', (
      tester,
    ) async {
      store.bookmarks = [_server('a')];
      final reviewed = <ConnectionServer>[];
      await pumpView(tester, onReviewBlocked: reviewed.add);

      bridge.emitStatus(
        'a',
        const ServerStatus(
          ServerConnectionState.blocked,
          detail: 'Host key changed for web.example.com:2222.',
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('connection.review.a')));
      await tester.pump();

      expect(reviewed, hasLength(1));
      expect(reviewed.single.serverId, 'a');
      expect(find.text(l10n.connectionsReviewHostKey), findsOneWidget);
    });

    testWidgets('attributes a pane-scoped recovery failure', (tester) async {
      store.bookmarks = [_server('a')];
      await pumpView(tester);
      bridge.emitStatus(
        'a',
        const ServerStatus(ServerConnectionState.connected),
      );

      bridge.emitRecovery('a', paneTabId: 'left');
      await tester.pump();

      final row = find.byKey(const ValueKey('connection.a'));
      expect(
        find.descendant(
          of: row,
          matching: find.text(
            l10n.connectionsPaneFailure(
              'left',
              'Could not resolve the home directory.',
            ),
          ),
        ),
        findsOneWidget,
      );
      // The pool is still up: attribution must not fake a state change.
      expect(
        find.descendant(
          of: row,
          matching: find.text(l10n.connectionStateConnected),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a pool-level failure renders once, as the detail', (
      tester,
    ) async {
      store.bookmarks = [_server('a')];
      await pumpView(tester);

      bridge.emitRecovery('a', message: 'Connection recovery failed.');
      bridge.emitStatus(
        'a',
        const ServerStatus(
          ServerConnectionState.disconnected,
          detail: 'Connection recovery failed.',
        ),
      );
      await tester.pump();

      final row = find.byKey(const ValueKey('connection.a'));
      expect(
        find.descendant(
          of: row,
          matching: find.text('Connection recovery failed.'),
        ),
        findsOneWidget,
      );
    });
  });
}
