import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/folder_size.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_pane_channel.dart';

RemoteFileEntry _entry(
  String path,
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
}) {
  return RemoteFileEntry(path: path, name: name, type: type, size: size);
}

void main() {
  test('sums file sizes recursively and counts every entry', () async {
    final channel = FakePaneChannel('/root');
    channel.listings['/root'] = [
      _entry('/root/a.txt', 'a.txt', size: 10),
      _entry('/root/sub', 'sub', type: RemoteFileType.directory),
      _entry('/root/b.txt', 'b.txt', size: 5),
    ];
    channel.listings['/root/sub'] = [
      _entry('/root/sub/c.txt', 'c.txt', size: 7),
      _entry('/root/sub/deep', 'deep', type: RemoteFileType.directory),
    ];
    channel.listings['/root/sub/deep'] = [
      _entry('/root/sub/deep/d.txt', 'd.txt', size: 3),
    ];

    final result = await measureFolderSize(
      channel,
      '/root',
      cancellation: RemoteTransferCancellation(),
    );

    expect(result.status, FolderSizeStatus.done);
    expect(result.targetPath, '/root');
    // 10 + 5 + 7 + 3 — directories contribute no size of their own.
    expect(result.bytes, 25);
    // a, sub, b, c, deep, d — six entries across three listings.
    expect(result.entries, 6);
    expect(result.unmeasured, 0);
    expect(result.unreadable, 0);
  });

  test('reports live progress after each listing lands', () async {
    final channel = FakePaneChannel('/root');
    channel.listings['/root'] = [
      _entry('/root/sub', 'sub', type: RemoteFileType.directory),
      _entry('/root/a.txt', 'a.txt', size: 4),
    ];
    channel.listings['/root/sub'] = [
      _entry('/root/sub/b.txt', 'b.txt', size: 6),
    ];

    final progress = <FolderSizeProgress>[];
    final result = await measureFolderSize(
      channel,
      '/root',
      cancellation: RemoteTransferCancellation(),
      onProgress: progress.add,
    );

    expect(result.status, FolderSizeStatus.done);
    // One callback per listing: root first, then the subdirectory.
    expect(progress.length, 2);
    expect(progress.first.entries, 2);
    expect(progress.first.bytes, 4);
    expect(progress.last.entries, 3);
    expect(progress.last.bytes, 10);
    expect(
      progress,
      everyElement(
        predicate<FolderSizeProgress>(
          (p) => p.status == FolderSizeStatus.running,
        ),
      ),
    );
  });

  test('a refused nested listing counts unreadable and continues', () async {
    final channel = FakePaneChannel('/root');
    channel.listings['/root'] = [
      _entry('/root/open', 'open', type: RemoteFileType.directory),
      _entry('/root/shut', 'shut', type: RemoteFileType.directory),
      _entry('/root/a.txt', 'a.txt', size: 2),
    ];
    channel.listings['/root/open'] = [
      _entry('/root/open/b.txt', 'b.txt', size: 3),
    ];
    // '/root/shut' stays unscripted — the fake refuses it.

    final result = await measureFolderSize(
      channel,
      '/root',
      cancellation: RemoteTransferCancellation(),
    );

    expect(result.status, FolderSizeStatus.done);
    expect(result.bytes, 5);
    expect(result.unreadable, 1);
    expect(result.unmeasured, 0);
  });

  test('the ROOT listing refusal fails the walk outright', () async {
    final channel = FakePaneChannel('/root');
    // No scripted listing — the root itself refuses.

    final result = await measureFolderSize(
      channel,
      '/root',
      cancellation: RemoteTransferCancellation(),
    );

    expect(result.status, FolderSizeStatus.failed);
    expect(result.error, isA<RemoteFileException>());
    expect(result.bytes, 0);
    expect(result.entries, 0);
  });

  test('sizeless entries count toward unmeasured, not the byte total',
      () async {
    final channel = FakePaneChannel('/root');
    channel.listings['/root'] = [
      _entry('/root/a.txt', 'a.txt', size: 8),
      _entry('/root/mystery', 'mystery'),
      _entry('/root/link', 'link', type: RemoteFileType.symbolicLink),
    ];

    final result = await measureFolderSize(
      channel,
      '/root',
      cancellation: RemoteTransferCancellation(),
    );

    expect(result.status, FolderSizeStatus.done);
    expect(result.bytes, 8);
    expect(result.entries, 3);
    // 'mystery' (no size) and 'link' (no size, never followed).
    expect(result.unmeasured, 2);
    // The link was counted but never listed.
    expect(channel.listCalls, ['/root']);
  });

  test('cancellation stops the walk and reports the partial counters',
      () async {
    final channel = FakePaneChannel('/root');
    channel.listings['/root'] = [
      _entry('/root/a.txt', 'a.txt', size: 4),
      _entry('/root/sub', 'sub', type: RemoteFileType.directory),
    ];
    channel.listings['/root/sub'] = [
      _entry('/root/sub/b.txt', 'b.txt', size: 6),
    ];
    final cancellation = RemoteTransferCancellation();

    final result = await measureFolderSize(
      channel,
      '/root',
      cancellation: cancellation,
      onProgress: (progress) {
        // Cancel after the root listing lands: the subdirectory is
        // still queued but never listed.
        cancellation.cancel();
      },
    );

    expect(result.status, FolderSizeStatus.cancelled);
    expect(result.bytes, 4);
    expect(result.entries, 2);
    expect(channel.listCalls, ['/root']);
  });

  test('echoed dot segments and cyclic listings cannot recurse', () async {
    final channel = FakePaneChannel('/root');
    channel.listings['/root'] = [
      _entry('/root', '.', type: RemoteFileType.directory),
      _entry('/root', '..', type: RemoteFileType.directory),
      // A server returning the parent path inside itself would loop a
      // naive walk; the visited set stops it.
      _entry('/root', 'loop', type: RemoteFileType.directory),
      _entry('/root/a.txt', 'a.txt', size: 1),
    ];

    final result = await measureFolderSize(
      channel,
      '/root',
      cancellation: RemoteTransferCancellation(),
    );

    expect(result.status, FolderSizeStatus.done);
    // '.' and '..' are skipped before counting; 'loop' resolves to
    // /root which is already visited, so only the root listing ran.
    expect(result.entries, 2);
    expect(result.bytes, 1);
    expect(channel.listCalls, ['/root']);
  });

  test('a directory echoed with a trailing separator is walked once',
      () async {
    final channel = FakePaneChannel('/root');
    channel.listings['/root'] = [
      // The server spells the child WITH a trailing separator...
      _entry('/root/sub/', 'sub', type: RemoteFileType.directory),
    ];
    channel.listings['/root/sub/'] = [
      // ...then echoes the same directory without it — a spelling
      // cycle the dedupe key must collapse (the unkeyed spelling is
      // never listed; the channel has no entry for it).
      _entry('/root/sub', 'sub', type: RemoteFileType.directory),
      _entry('/root/sub/f.txt', 'f.txt', size: 5),
    ];

    final result = await measureFolderSize(
      channel,
      '/root',
      cancellation: RemoteTransferCancellation(),
    );

    expect(result.status, FolderSizeStatus.done);
    expect(result.bytes, 5);
    expect(result.unreadable, 0);
    // '/root/sub' must never be listed — the dedupe key collapsed it.
    expect(channel.listCalls, ['/root', '/root/sub/']);
  });

  test('a POSIX directory literally named with a trailing backslash '
      'is not deduped against its unslashed sibling', () async {
    final channel = FakePaneChannel('/root');
    channel.listings['/root'] = [
      // On POSIX 'sub\' and 'sub' are distinct names — the dedupe key
      // must not merge them (separator-hood of '\' is Windows-only).
      _entry('/root/sub', 'sub', type: RemoteFileType.directory),
      _entry(r'/root/sub\', r'sub\', type: RemoteFileType.directory),
    ];
    channel.listings['/root/sub'] = const [];
    channel.listings[r'/root/sub\'] = [
      _entry(r'/root/sub\/f.txt', 'f.txt', size: 3),
    ];

    final result = await measureFolderSize(
      channel,
      '/root',
      cancellation: RemoteTransferCancellation(),
    );

    expect(result.status, FolderSizeStatus.done);
    expect(result.bytes, 3);
    expect(channel.listCalls,
        containsAll(<String>['/root/sub', r'/root/sub\']));
  });

  test('a mixed-separator Windows spelling still dedupes', () async {
    final channel = FakePaneChannel('C:/root');
    channel.listings['C:/root'] = [
      _entry(r'C:/root/sub\', 'sub', type: RemoteFileType.directory),
    ];
    channel.listings[r'C:/root/sub\'] = [
      // The same directory echoed under the unslashed spelling — the
      // drive-letter prefix keeps '\' a separator despite the '/'.
      _entry('C:/root/sub', 'sub', type: RemoteFileType.directory),
      _entry('C:/root/sub/f.txt', 'f.txt', size: 2),
    ];

    final result = await measureFolderSize(
      channel,
      'C:/root',
      cancellation: RemoteTransferCancellation(),
    );

    expect(result.status, FolderSizeStatus.done);
    expect(result.bytes, 2);
    expect(channel.listCalls, ['C:/root', r'C:/root/sub\']);
  });

  test('a POSIX relative name starting with a drive-like prefix keeps '
      'its trailing backslash', () async {
    final channel = FakePaneChannel('/root');
    channel.listings['/root'] = [
      // A server spelling children RELATIVE to the listing can return
      // 'C:notes' and 'C:notes\' — distinct POSIX names that only a
      // colon+separator drive match must not merge.
      _entry('C:notes', 'C:notes', type: RemoteFileType.directory),
      _entry(r'C:notes\', r'C:notes\', type: RemoteFileType.directory),
    ];
    channel.listings['C:notes'] = const [];
    channel.listings[r'C:notes\'] = [
      _entry(r'C:notes\/f.txt', 'f.txt', size: 1),
    ];

    final result = await measureFolderSize(
      channel,
      '/root',
      cancellation: RemoteTransferCancellation(),
    );

    expect(result.status, FolderSizeStatus.done);
    expect(result.bytes, 1);
    expect(channel.listCalls,
        containsAll(<String>['C:notes', r'C:notes\']));
  });

  test('an untyped nested fault propagates — only typed refusals '
      'degrade to unreadable', () async {
    final channel = _FaultyChannel('/root');
    channel.listings['/root'] = [
      _entry('/root/bad', 'bad', type: RemoteFileType.directory),
      _entry('/root/a.txt', 'a.txt', size: 2),
    ];

    // A non-RemoteFileException means the seam itself broke — the walk
    // fails loudly through the caller rather than silently skipping a
    // subtree on a dying channel.
    await expectLater(
      measureFolderSize(
        channel,
        '/root',
        cancellation: RemoteTransferCancellation(),
      ),
      throwsA(isA<StateError>()),
    );
  });
}

/// A channel whose unscripted paths throw an untyped fault instead of a
/// RemoteFileException — the walker's nested-refusal accounting must not
/// depend on the exception's type.
final class _FaultyChannel extends FakePaneChannel {
  _FaultyChannel(super.homePath);

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    listCalls.add(path);
    final entries = listings[path];
    if (entries == null) throw StateError('unscripted listing: $path');
    return entries;
  }
}
