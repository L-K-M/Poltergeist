// Contract tests for the keyed LRU preview cache (06 §5.3): temp-plus-
// rename commits, recency-true eviction, startup sweep, cap enforcement,
// launch-boundary executable list, and clear-cache accounting.

import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late PreviewCache cache;

  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('poltergeist-pc-');
    tempDir = Directory(temp.resolveSymbolicLinksSync());
    cache = PreviewCache(directory: Directory('${tempDir.path}/cache'));
    await cache.open();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> commitEntry(
    String key,
    List<int> bytes, {
    String extension = 'txt',
  }) async {
    final slot = await cache.prepare(key, extension: extension);
    await slot.tempFile.writeAsBytes(bytes);
    return slot.commit();
  }

  test('prepare/commit lands a keyed file atomically', () async {
    final key = previewCacheKey('srv', '/a.txt', null, 3);
    final file = await commitEntry(key, [1, 2, 3]);
    expect(file.existsSync(), isTrue);
    expect(file.path, endsWith('$key.txt'));
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect(cache.totalBytes, 3);
    expect(cache.keys, [key]);
  });

  test('lookup hits and refreshes LRU order', () async {
    final a = previewCacheKey('s', '/a', null, 1);
    final b = previewCacheKey('s', '/b', null, 1);
    final c = previewCacheKey('s', '/c', null, 1);
    await commitEntry(a, [1]);
    await commitEntry(b, [2]);
    await commitEntry(c, [3]);
    expect(cache.keys, [a, b, c]);
    // A hit moves the entry to the tail.
    expect(await cache.lookup(a), isNotNull);
    expect(cache.keys, [b, c, a]);
    // A miss is null and does not disturb the order.
    expect(await cache.lookup('nope'), isNull);
    expect(cache.keys, [b, c, a]);
  });

  test('lookup drops an index entry whose file vanished', () async {
    final key = previewCacheKey('s', '/gone', null, 1);
    final file = await commitEntry(key, [1]);
    await file.delete();
    expect(await cache.lookup(key), isNull);
    expect(cache.keys, isEmpty);
  });

  test('prepare refuses an already-committed key', () async {
    final key = previewCacheKey('s', '/dup', null, 1);
    await commitEntry(key, [1]);
    expect(
      () => cache.prepare(key, extension: 'txt'),
      throwsStateError,
    );
  });

  test('abort discards the temp without touching the index', () async {
    final key = previewCacheKey('s', '/aborted', null, 1);
    final slot = await cache.prepare(key, extension: 'txt');
    await slot.tempFile.writeAsBytes([9]);
    await slot.abort();
    expect(slot.tempFile.existsSync(), isFalse);
    expect(cache.totalBytes, 0);
    expect(await cache.lookup(key), isNull);
  });

  test('evicts LRU-first when a commit crosses the cap', () async {
    cache.capacityBytes = 3;
    final a = previewCacheKey('s', '/a', null, 2);
    final b = previewCacheKey('s', '/b', null, 2);
    await commitEntry(a, [1, 1]);
    await commitEntry(b, [2, 2]);
    // b's commit pushed totalBytes to 4 > 3: a (the LRU head) evicts.
    expect(await cache.lookup(a), isNull);
    expect(File('${cache.directory.path}/$a.txt').existsSync(), isFalse);
    expect(await cache.lookup(b), isNotNull);
    expect(cache.totalBytes, 2);
  });

  test('an over-cap completion is dropped after eviction', () async {
    cache.capacityBytes = 2;
    final big = previewCacheKey('s', '/big', null, null);
    final file = await commitEntry(big, [1, 2, 3]);
    // Cannot ever fit — the commit drops it.
    expect(file.existsSync(), isFalse);
    expect(cache.keys, isEmpty);
    expect(cache.totalBytes, 0);
  });

  test('canAccommodate gates the pre-queue refusal', () {
    cache.capacityBytes = 10;
    expect(cache.canAccommodate(10), isTrue);
    expect(cache.canAccommodate(11), isFalse);
  });

  test('lowering the cap evicts on the next enforce', () async {
    final a = previewCacheKey('s', '/a', null, 3);
    final b = previewCacheKey('s', '/b', null, 3);
    await commitEntry(a, [1, 1, 1]);
    await commitEntry(b, [2, 2, 2]);
    cache.capacityBytes = 3;
    await cache.enforce();
    expect(await cache.lookup(a), isNull);
    expect(await cache.lookup(b), isNotNull);
  });

  test('an unlink failure leaves the entry indexed and over budget', () async {
    final key = previewCacheKey('s', '/held', null, 5);
    final file = await commitEntry(key, [1, 2, 3, 4, 5]);
    // Simulate a still-open file the OS refuses to unlink: rename the
    // file out from under the index so delete() fails with notFound —
    // the entry must stay indexed (the bytes are still counted).
    final hidden = File('${tempDir.path}/held-aside');
    await file.rename(hidden.path);
    cache.capacityBytes = 0;
    await cache.enforce();
    expect(cache.keys, [key], reason: 'failed unlink keeps the entry');
    expect(cache.totalBytes, 5);
    // Restore and retry: the next pass succeeds.
    await hidden.rename(file.path);
    await cache.enforce();
    expect(cache.keys, isEmpty);
    expect(cache.totalBytes, 0);
  });

  test('index survives a reopen with LRU order intact', () async {
    final a = previewCacheKey('s', '/a', null, 1);
    final b = previewCacheKey('s', '/b', null, 1);
    await commitEntry(a, [1]);
    await commitEntry(b, [2]);
    await cache.lookup(a); // refresh a to the tail

    final reopened = PreviewCache(directory: cache.directory);
    await reopened.open();
    expect(reopened.keys, [b, a]);
    expect(await reopened.lookup(a), isNotNull);
  });

  test('open sweeps stale temps and unindexed files', () async {
    final dir = cache.directory;
    await File('${dir.path}/tmp-deadbeef.part').writeAsBytes([1]);
    await File('${dir.path}/orphan.txt').writeAsBytes([2]);
    final live = previewCacheKey('s', '/live', null, 1);
    await commitEntry(live, [3]);

    final reopened = PreviewCache(directory: dir);
    await reopened.open();
    expect(File('${dir.path}/tmp-deadbeef.part').existsSync(), isFalse);
    expect(File('${dir.path}/orphan.txt').existsSync(), isFalse);
    expect(await reopened.lookup(live), isNotNull);
  });

  test('a corrupt index rebuilds empty and sweeps the orphans', () async {
    final key = previewCacheKey('s', '/x', null, 1);
    await commitEntry(key, [1]);
    await File(
      '${cache.directory.path}/index.json',
    ).writeAsString('not json{');

    final reopened = PreviewCache(directory: cache.directory);
    await reopened.open();
    expect(reopened.keys, isEmpty);
    // The orphaned data file is swept too — the rebuilt index is truth.
    expect(
      File('${cache.directory.path}/$key.txt').existsSync(),
      isFalse,
    );
  });

  test('clear deletes everything and reports reclaimed bytes', () async {
    await commitEntry(previewCacheKey('s', '/a', null, 2), [1, 1]);
    await commitEntry(previewCacheKey('s', '/b', null, 3), [2, 2, 2]);
    expect(await cache.clear(), 5);
    expect(cache.totalBytes, 0);
    expect(cache.keys, isEmpty);
    final leftovers = await cache.directory
        .list()
        .where((e) => e is File)
        .toList();
    expect(
      leftovers.map((e) => e.uri.pathSegments.last),
      everyElement('index.json'),
    );
  });

  test('executable extensions are kept — the cache is never executed', () async {
    // 06 §5.3: `.bat`/`.exe` pass the charset rule and stay on the cache
    // name (Quick Look keys type off it); the launch-boundary blocklist
    // lives in previewWindowsExecutableExtensions, not the write path.
    final key = previewCacheKey('s', '/setup.exe', null, 1);
    final file = await commitEntry(key, [1], extension: 'exe');
    expect(file.path, endsWith('$key.exe'));
  });

  test('unsafe extensions drop from the committed name', () async {
    // An "extension" carrying characters illegal in local filenames
    // (or overlong) never reaches disk — the name falls back to the
    // bare hash, which content sniffing serves.
    final key = previewCacheKey('s', '/x', null, 1);
    final file = await commitEntry(key, [1], extension: 'a b');
    expect(file.path, endsWith('${Platform.pathSeparator}$key'));
    final overlong = await commitEntry(
      previewCacheKey('s', '/y', null, 1),
      [1],
      extension: 'a' * 17,
    );
    expect(overlong.path, isNot(contains('.')));
  });
}
