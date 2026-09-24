// LeasedRemoteFileSystem: sync's lease-on-demand VFS over one server —
// one shared lease across concurrent calls, explicit release with
// re-lease on the next call, the idle backstop, and the disconnected
// rule that drops a dead lease so the retry re-leases.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import '../transfer/transfer_fakes.dart';

void main() {
  late FakeTreeFileSystem remote;
  late FakeQueueConnectionManager connections;

  setUp(() {
    remote = FakeTreeFileSystem()..addFile('/srv/a.txt', [1, 2, 3]);
    connections = FakeQueueConnectionManager({'srv': remote});
  });

  test('concurrent calls share one lease; release returns it', () async {
    final fs = LeasedRemoteFileSystem(connections, 'srv', idleRelease: null);
    final results = await Future.wait([
      fs.stat('/srv/a.txt'),
      fs.listDirectory('/srv'),
      fs.canonicalize('/srv'),
    ]);
    expect(results, hasLength(3));
    expect(connections.leaseCalls, 1);
    expect(fs.holdsLease, isTrue);
    await fs.release();
    expect(fs.holdsLease, isFalse);
    expect(connections.totalReleased, 1);
    // The next call leases again.
    await fs.stat('/srv/a.txt');
    expect(connections.leaseCalls, 2);
    await fs.release();
    await fs.release();
    expect(connections.totalReleased, 2);
  });

  test('a disconnected failure drops the lease; the retry re-leases', () async {
    final fs = LeasedRemoteFileSystem(connections, 'srv', idleRelease: null);
    var failOnce = true;
    remote.statFailure = (_) {
      if (!failOnce) return null;
      failOnce = false;
      return const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'stat',
        message: 'gone',
      );
    };
    await expectLater(
      fs.stat('/srv/a.txt'),
      throwsA(isA<RemoteFileException>()),
    );
    await pump();
    expect(fs.holdsLease, isFalse);
    expect(connections.totalReleased, 1);
    expect((await fs.stat('/srv/a.txt')).size, 3);
    expect(connections.leaseCalls, 2);
    await fs.release();
  });

  test('other failures keep the lease', () async {
    final fs = LeasedRemoteFileSystem(connections, 'srv', idleRelease: null);
    await expectLater(
      fs.stat('/srv/missing'),
      throwsA(isA<RemoteFileException>()),
    );
    expect(fs.holdsLease, isTrue);
    expect(connections.totalReleased, 0);
    await fs.release();
  });

  test('a failed lease is not cached', () async {
    connections.leaseFailure = (_) => const RemoteFileException(
      kind: RemoteFileErrorKind.disconnected,
      operation: 'lease transfer channel',
      message: 'offline',
    );
    final fs = LeasedRemoteFileSystem(connections, 'srv', idleRelease: null);
    await expectLater(
      fs.stat('/srv/a.txt'),
      throwsA(isA<RemoteFileException>()),
    );
    expect(fs.holdsLease, isFalse);
    connections.leaseFailure = null;
    expect((await fs.stat('/srv/a.txt')).size, 3);
    await fs.release();
  });

  test('an idle lease returns on its own after the backstop', () {
    fakeAsync((time) {
      final fs = LeasedRemoteFileSystem(
        connections,
        'srv',
        idleRelease: const Duration(seconds: 30),
      );
      unawaited(fs.stat('/srv/a.txt'));
      time.flushMicrotasks();
      expect(fs.holdsLease, isTrue);
      time.elapse(const Duration(seconds: 29));
      expect(fs.holdsLease, isTrue);
      time.elapse(const Duration(seconds: 2));
      time.flushMicrotasks();
      expect(fs.holdsLease, isFalse);
      expect(connections.totalReleased, 1);
    });
  });

  test('a digest rides the lease', () async {
    final fs = LeasedRemoteFileSystem(connections, 'srv', idleRelease: null);
    final entry = await remoteContentDigest(fs, '/srv/a.txt');
    expect(entry.contentSha256, isNotNull);
    await fs.release();
  });
}
