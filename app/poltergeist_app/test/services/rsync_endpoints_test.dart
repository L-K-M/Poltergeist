// resolveRsyncEndpoints coverage (05 §2.1's app-side seam): embedded
// identities resolve directly, shared-mode serverConfigId refs resolve
// through the injected catalog lookup, unresolvable refs return null —
// and connection-shape flags (identity file, jump host) carry through
// so the exporter's notes fire.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/rsync_endpoints.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../support/sync_harness.dart';

ServerConfig _config(
  String id, {
  String? identityFilePath,
  String? jumpHostId,
}) => ServerConfig(
  id: id,
  label: id,
  host: 'srv.example.com',
  port: 2222,
  username: 'deploy',
  authMethod: AuthMethod.privateKey,
  identityFilePath: identityFilePath,
  jumpHostId: jumpHostId,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  test('local/local resolves both sides with the host OS tag', () {
    final pair = testSyncPair();
    final resolved = resolveRsyncEndpoints(pair, localOsName: 'linux');
    expect(resolved, isNotNull);
    expect(resolved!.left, isA<ResolvedLocalEndpoint>());
    expect(resolved.left.path, '/left');
    expect(resolved.left.os, SyncEndpointOs.posix);
  });

  test('a Windows host tags the local side windows', () {
    final pair = testSyncPair();
    final resolved = resolveRsyncEndpoints(pair, localOsName: 'windows');
    expect(resolved!.left.os, SyncEndpointOs.windows);
  });

  test('embedded identity resolves without a catalog', () {
    final pair = SyncPair(
      id: 'p',
      name: 'p',
      left: const LocalEndpoint('/l'),
      right: const RemoteEndpoint(
        server: BookmarkServerRef(
          identity: EmbeddedHostIdentity(
            host: 'example.com',
            port: 2222,
            username: 'deploy',
            authMethod: AuthMethod.privateKey,
            identityFilePath: '~/.ssh/deploy_key',
          ),
        ),
        path: '/srv/site',
      ),
      rules: const SyncRuleSet(),
    );
    final resolved = resolveRsyncEndpoints(pair, localOsName: 'linux');
    final remote = resolved!.right as ResolvedRemoteEndpoint;
    expect(remote.host, 'example.com');
    expect(remote.port, 2222);
    expect(remote.user, 'deploy');
    expect(remote.path, '/srv/site');
    expect(
      remote.connectionShape,
      contains(SyncConnectionFlag.identityFile),
    );
  });

  test('serverConfigId resolves through the injected catalog lookup', () {
    final pair = SyncPair(
      id: 'p',
      name: 'p',
      left: const LocalEndpoint('/l'),
      right: const RemoteEndpoint(
        server: BookmarkServerRef(serverConfigId: 'srv-1'),
        path: '/srv/site',
      ),
      rules: const SyncRuleSet(),
    );
    final resolved = resolveRsyncEndpoints(
      pair,
      serverConfig: (id) =>
          id == 'srv-1' ? _config(id, jumpHostId: 'srv-bastion') : null,
      localOsName: 'linux',
    );
    final remote = resolved!.right as ResolvedRemoteEndpoint;
    expect(remote.host, 'srv.example.com');
    expect(remote.connectionShape, contains(SyncConnectionFlag.jumpHost));
  });

  test('an unknown serverConfigId returns null, not a wrong host', () {
    final pair = SyncPair(
      id: 'p',
      name: 'p',
      left: const LocalEndpoint('/l'),
      right: const RemoteEndpoint(
        server: BookmarkServerRef(serverConfigId: 'srv-missing'),
        path: '/srv/site',
      ),
      rules: const SyncRuleSet(),
    );
    expect(
      resolveRsyncEndpoints(
        pair,
        serverConfig: (_) => null,
        localOsName: 'linux',
      ),
      isNull,
    );
    // No lookup bound at all — same refusal.
    expect(
      resolveRsyncEndpoints(pair, localOsName: 'linux'),
      isNull,
    );
  });
}
