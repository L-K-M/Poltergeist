// The bridged lease's app-side config answers (AppServerConfigSource)
// and the sync environment's remote endpoints over it: bookmark →
// embedded identity, catalog reference → pulled config, Quick Connect
// ids → null (the engine reuses its browse-open config), and a sync
// endpoint leasing under its registered id and releasing on demand.

import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/server_config_source.dart';
import 'package:poltergeist_app/services/sync_environment.dart';
import 'package:poltergeist_app/services/sync_state_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

final _now = DateTime.utc(2026, 9, 24);

Bookmark _bookmark(String id, BookmarkServerRef server) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: 'label-$id',
  server: server,
  sortKey: 'm',
  createdAt: _now,
  updatedAt: _now,
);

const _identity = EmbeddedHostIdentity(
  host: 'web.example.com',
  port: 2222,
  username: 'deploy',
  authMethod: AuthMethod.password,
  secretRef: 'secret-1',
);

final class _Bookmarks implements BookmarkRepository {
  _Bookmarks(this.bookmarks);

  final List<Bookmark> bookmarks;

  @override
  Future<List<Bookmark>> load() async => bookmarks;

  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {}
}

final class _Connections implements ConnectionManager {
  final leases = <String>[];
  int released = 0;

  @override
  Future<TransferChannelLease> leaseTransferChannel(String serverId) async {
    leases.add(serverId);
    return _Lease(() => released++);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final class _Lease implements TransferChannelLease {
  _Lease(this._onRelease);

  final void Function() _onRelease;

  @override
  RemoteFileSystem get fs => _Canonical();

  @override
  Future<void> release() async => _onRelease();

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {}
}

final class _Canonical implements RemoteFileSystem {
  @override
  Future<String> canonicalize(String path) async => '/canonical$path';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  group('AppServerConfigSource', () {
    test('an embedded-identity bookmark dials its identity', () async {
      final source = AppServerConfigSource(
        bookmarks: _Bookmarks([
          _bookmark('b1', const BookmarkServerRef(identity: _identity)),
        ]),
      );
      final config = await source.configFor('b1');
      expect(config?.id, 'b1');
      expect(config?.host, 'web.example.com');
      expect(config?.port, 2222);
      expect(config?.username, 'deploy');
      expect(config?.secretRef, 'secret-1');
    });

    test('a catalog reference resolves through the pulled catalog', () async {
      final pulled = ServerConfig(
        id: 'cfg-9',
        label: 'pulled',
        host: 'pulled.example.com',
        username: 'ops',
        createdAt: 0,
        updatedAt: 0,
      );
      final source = AppServerConfigSource(
        bookmarks: _Bookmarks([
          _bookmark('b2', const BookmarkServerRef(serverConfigId: 'cfg-9')),
        ]),
      );
      // The catalog binds late, like main.dart's composition.
      source.catalogLookup = (id) => id == 'cfg-9' ? pulled : null;
      expect((await source.configFor('b2'))?.host, 'pulled.example.com');
    });

    test('a catalog miss without an identity refuses typed', () async {
      final source = AppServerConfigSource(
        bookmarks: _Bookmarks([
          _bookmark('b3', const BookmarkServerRef(serverConfigId: 'gone')),
        ]),
        catalogLookup: (_) => null,
      );
      await expectLater(
        source.configFor('b3'),
        throwsA(
          isA<RemoteFileException>()
              .having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)
              .having((e) => e.message, 'message', contains('label-b3')),
        ),
      );
    });

    test('a jump-routed catalog server refuses the lease typed', () async {
      // A transfer, checkout, preview, or sync run restored after a
      // relaunch leases without a pane: the pinned opener would dial the
      // host directly, around the bastion (X-05).
      const pulled = ServerConfig(
        id: 'cfg-db',
        label: 'db',
        host: 'db.internal',
        username: 'ops',
        jumpHostId: 'bastion',
        createdAt: 0,
        updatedAt: 0,
      );
      final source = AppServerConfigSource(
        bookmarks: _Bookmarks([
          _bookmark('b4', const BookmarkServerRef(serverConfigId: 'cfg-db')),
        ]),
        catalogLookup: (id) => id == 'cfg-db' ? pulled : null,
      );
      final endpoint = source.registerEndpoint(
        const BookmarkServerRef(serverConfigId: 'cfg-db'),
      );
      final refusal = isA<RemoteFileException>()
          .having((e) => e.kind, 'kind', RemoteFileErrorKind.unsupported)
          .having(
            (e) => e.message,
            'message',
            lookupAppLocalizations(
              const Locale('en'),
            ).connectionJumpHostUnsupported,
          );
      await expectLater(source.configFor('b4'), throwsA(refusal));
      await expectLater(source.configFor(endpoint), throwsA(refusal));
    });

    test('an unknown id (Quick Connect) answers null', () async {
      final source = AppServerConfigSource(bookmarks: _Bookmarks(const []));
      expect(await source.configFor('adhoc:1234'), isNull);
    });

    test('registrations win and endpoints share one id per server', () async {
      final source = AppServerConfigSource(bookmarks: _Bookmarks(const []));
      final first = source.registerEndpoint(
        const BookmarkServerRef(identity: _identity),
      );
      final second = source.registerEndpoint(
        const BookmarkServerRef(identity: _identity),
      );
      expect(first, second);
      final config = await source.configFor(first);
      expect(config?.host, 'web.example.com');
      expect(config?.id, first);
    });
  });

  group('SyncEnvironment remote endpoints', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('sync-env-'));
    tearDown(() => temp.deleteSync(recursive: true));

    SyncEnvironment environment({ConnectionManager? connections}) =>
        SyncEnvironment(
          states: FileSyncStateStore(Directory('${temp.path}/state')),
          syncRunsDirectory: '${temp.path}/runs',
          deviceId: () async => 'device',
          connections: connections,
          serverConfigs: AppServerConfigSource(bookmarks: _Bookmarks(const [])),
        );

    const remote = RemoteEndpoint(
      server: BookmarkServerRef(identity: _identity),
      path: '/srv',
    );

    test('without the engine bridge a remote endpoint refuses typed', () {
      final env = environment();
      expect(env.endpointAvailable(remote), isFalse);
      expect(
        () => env.fileSystemFor(remote),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.unsupported,
          ),
        ),
      );
    });

    test('with the bridge it leases on demand and releases', () async {
      final connections = _Connections();
      final env = environment(connections: connections);
      expect(env.endpointAvailable(remote), isTrue);
      final fs = env.fileSystemFor(remote);
      // One shared filesystem per server.
      expect(identical(fs, env.fileSystemFor(remote)), isTrue);
      expect(await fs.canonicalize('/srv'), '/canonical/srv');
      expect(connections.leases, ['sync-endpoint:deploy@web.example.com:2222']);
      await env.releaseRemoteLeases();
      expect(connections.released, 1);
      // The next call leases again.
      await fs.canonicalize('/srv');
      expect(connections.leases, hasLength(2));
      await env.releaseRemoteLeases();
    });
  });
}
