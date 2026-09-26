import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'fake_sync_api.dart';

/// Leaves a real coordinator round waiting on the first network response.
final class _BlockedPush implements SyncApi {
  _BlockedPush(this.server);

  final FakeSyncApi server;
  final started = Completer<void>();
  final resume = Completer<void>();
  List<PushResult> extraResults = const [];

  @override
  Future<PullResponse> pull({required int since}) => server.pull(since: since);

  @override
  Future<PushResponse> push(List<EncryptedRecord> records) async {
    started.complete();
    await resume.future;
    final response = await server.push(records);
    return PushResponse(results: [...response.results, ...extraResults]);
  }
}

void main() {
  late Directory directory;
  late PersistentLocalRecordStore records;
  late BookmarkCoordinator coordinator;
  late RecordCrypto crypto;

  Bookmark bookmark(String label, {DateTime? updatedAt}) => Bookmark(
    id: 'a',
    kind: BookmarkKind.localFolder,
    label: label,
    localPath: '/example',
    sortKey: 'm',
    createdAt: DateTime.utc(2026),
    updatedAt: updatedAt ?? DateTime.utc(2026),
  );

  PersistentLocalRecordStore reopen() =>
      PersistentLocalRecordStore(path: '${directory.path}/records.json');

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('push-revision-');
    records = reopen();
    crypto = RecordCrypto(RecordCodec(List<int>.filled(32, 7)));
    coordinator = BookmarkCoordinator(
      records: records,
      bookmarks: FileBookmarkStore(path: '${directory.path}/bookmarks.json'),
      hostKeys: InMemoryHostKeyStore(),
      crypto: crypto,
      deviceId: 'device-a',
      pinVerdicts: InMemoryPinVerdictStore(),
      tripwires: InMemorySyncTripwireStore(),
      maxRounds: 1,
    );
  });

  tearDown(() => directory.delete(recursive: true));

  for (final deleted in [false, true]) {
    test(
      'accepted old push preserves a newer ${deleted ? 'delete' : 'edit'}',
      () async {
        await coordinator.onBookmarkSaved(bookmark('first'));
        final server = FakeSyncApi();
        final blocked = _BlockedPush(server);
        final round = coordinator.runRound(blocked);
        await blocked.started.future;

        if (deleted) {
          await coordinator.onBookmarkDeleted('a');
        } else {
          // The timestamps deliberately tie: identity must cover the actual
          // operation, not just the ID, author, or clock tick.
          await coordinator.onBookmarkSaved(bookmark('second'));
        }
        final replacement = (await records.dirtyRecords()).single;
        blocked.resume.complete();
        await round;

        expect((await records.dirtyRecords()).single, same(replacement));
        final persisted = (await reopen().dirtyRecords()).single;
        expect(persisted.blob, replacement.blob);
        expect(persisted.deleted, deleted);
        expect(persisted.seq, isNull);
      },
    );
  }

  test('rejected old push cannot restore over a newer edit', () async {
    final winner = await crypto.seal(
      DecryptedRecord(
        id: 'bookmark:a',
        kind: RecordKind.bookmark,
        updatedAt: DateTime.utc(2027).millisecondsSinceEpoch,
        deviceId: 'device-b',
        data: bookmark('remote').toJson(),
      ),
    );
    final server = FakeSyncApi()..seed(winner);
    await coordinator.runRound(server);
    await coordinator.onBookmarkSaved(bookmark('first'));

    final blocked = _BlockedPush(server);
    final round = coordinator.runRound(blocked);
    await blocked.started.future;
    await coordinator.onBookmarkSaved(bookmark('second'));
    final replacement = (await records.dirtyRecords()).single;
    blocked.resume.complete();
    await round;

    expect((await records.dirtyRecords()).single, same(replacement));
    expect((await reopen().dirtyRecords()).single.blob, replacement.blob);
    expect(await records.displacedRecords(), hasLength(1));
  });

  test(
    'the preserved edit converges on the next backup after reopening',
    () async {
      await coordinator.onBookmarkSaved(bookmark('first'));
      final server = FakeSyncApi();
      final blocked = _BlockedPush(server);
      final round = coordinator.runRound(blocked);
      await blocked.started.future;
      await coordinator.onBookmarkSaved(
        bookmark('second', updatedAt: DateTime.utc(2026, 2)),
      );
      blocked.resume.complete();
      await round;

      records = reopen();
      final restarted = BookmarkCoordinator(
        records: records,
        bookmarks: FileBookmarkStore(path: '${directory.path}/bookmarks.json'),
        hostKeys: InMemoryHostKeyStore(),
        crypto: crypto,
        deviceId: 'device-a',
        pinVerdicts: InMemoryPinVerdictStore(),
        tripwires: InMemorySyncTripwireStore(),
      );
      await restarted.runRound(server);

      expect(await records.dirtyRecords(), isEmpty);
      final remote = await crypto.open(server.records['bookmark:a']!);
      expect(remote.data['label'], 'second');
    },
  );

  test(
    'settlement waits for queued replacement before checking identity',
    () async {
      await coordinator.onBookmarkSaved(bookmark('first'));
      final sent = (await records.dirtyRecords()).single;
      final replacement = await crypto.seal(
        DecryptedRecord(
          id: sent.id,
          kind: RecordKind.bookmark,
          updatedAt: sent.updatedAt,
          deviceId: sent.deviceId,
          data: bookmark('second').toJson(),
        ),
      );

      // Neither call is awaited before both are enqueued. Checking identity
      // outside the write queue would see `sent` and acknowledge replacement.
      final save = records.putLocal(replacement);
      final settle = records.settlePush(
        sent,
        PushResult(id: sent.id, seq: 1, accepted: true),
      );
      await Future.wait([save, settle]);

      expect((await reopen().dirtyRecords()).single.blob, replacement.blob);
    },
  );

  test(
    'a response cannot acknowledge a record absent from its request',
    () async {
      await coordinator.onBookmarkSaved(bookmark('first'));
      final blocked = _BlockedPush(FakeSyncApi())
        ..extraResults = [
          PushResult(id: 'bookmark:other', seq: 99, accepted: true),
        ];
      final round = coordinator.runRound(blocked);
      await blocked.started.future;
      final other = await crypto.seal(
        DecryptedRecord(
          id: 'bookmark:other',
          kind: RecordKind.bookmark,
          updatedAt: DateTime.utc(2026).millisecondsSinceEpoch,
          deviceId: 'device-a',
          data: {...bookmark('other').toJson(), 'id': 'other'},
        ),
      );
      await records.putLocal(other);
      blocked.resume.complete();
      await round;

      expect((await reopen().dirtyRecords()).single.id, 'bookmark:other');
      expect((await records.getRecord('bookmark:other'))!.seq, isNull);
    },
  );
}
