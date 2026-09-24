import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/connection_status_controller.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart' as controller_test;

Bookmark _adhoc(String id) {
  final now = DateTime.utc(2026, 9, 24);
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: 'demo@127.0.0.1:2222',
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: '127.0.0.1',
        port: 2222,
        username: 'demo',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/',
    sortKey: 'k',
    createdAt: now,
    updatedAt: now,
  );
}

ConnectionServer _saved(String id, ServerConnectionState state) =>
    ConnectionServer(
      serverId: id,
      label: 'web',
      host: 'web.example.com',
      port: 22,
      username: 'tester',
      status: ServerStatus(state),
    );

void main() {
  test('a saved server missing from the catalog is never vouched for by '
      'a tab', () async {
    final lanes = controller_test.FakePaneLanes();
    lanes.nextRemoteChannel = controller_test.FakePaneChannel('/srv');
    final pane = PaneController(paneTabId: 'pane.left', lanes: lanes);
    addTearDown(pane.dispose);
    await pane.connectRemote(_adhoc('b1'));
    lanes.emitState('b1', const ServerStatus(ServerConnectionState.connected));
    await Future<void>.delayed(Duration.zero);

    expect(serverConnectedNow('b1', catalog: const [], panes: [pane]), isFalse);
  });

  test('a saved server answers from the catalog', () {
    expect(
      serverConnectedNow(
        'srv-1',
        catalog: [_saved('srv-1', ServerConnectionState.connected)],
        panes: const [],
      ),
      isTrue,
    );
    expect(
      serverConnectedNow(
        'srv-1',
        catalog: [_saved('srv-1', ServerConnectionState.disconnected)],
        panes: const [],
      ),
      isFalse,
    );
  });

  test('a Quick Connect server answers from the tab bound to it', () async {
    final lanes = controller_test.FakePaneLanes();
    lanes.nextRemoteChannel = controller_test.FakePaneChannel('/home/demo');
    final pane = PaneController(paneTabId: 'pane.left', lanes: lanes);
    addTearDown(pane.dispose);
    const id = 'adhoc:8d41b075';

    await pane.connectRemote(_adhoc(id));
    expect(
      serverConnectedNow(id, catalog: const [], panes: [pane]),
      isFalse,
      reason: 'no status reported yet',
    );

    lanes.emitState(id, const ServerStatus(ServerConnectionState.connected));
    await Future<void>.delayed(Duration.zero);
    expect(serverConnectedNow(id, catalog: const [], panes: [pane]), isTrue);
    expect(
      serverConnectedNow('adhoc:other', catalog: const [], panes: [pane]),
      isFalse,
    );
  });
}
