import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/atomic_file.dart';
import 'package:poltergeist_app/services/bookmark_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final _fixedNow = DateTime.utc(2026, 9, 8, 12);

class _FakeSource implements SshConfigFileSource {
  _FakeSource(this.files);

  final Map<String, String> files;

  @override
  Future<String?> readText(String path) async => files[path];

  @override
  Future<List<String>?> listLexical(String directory) async => null;
}

Bookmark _bookmark(String id, {String? label}) {
  return Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: label ?? id,
    server: BookmarkServerRef(
      identity: const EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 2222,
        username: 'deploy',
        authMethod: AuthMethod.privateKey,
        identityFilePath: '~/.ssh/id_ed25519',
      ),
    ),
    remotePath: '/',
    sortKey: id,
    createdAt: _fixedNow,
    updatedAt: _fixedNow,
  );
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('poltergeist-bookmarks');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String pathIn(String name) => '${dir.path}${Platform.pathSeparator}$name';

  test('persists and reloads bookmarks across instances', () async {
    final path = pathIn('bookmarks.json');
    final store = FileBookmarkStore(path: path);
    await store.upsertAll([_bookmark('a')]);

    final reloaded = FileBookmarkStore(path: path);
    final bookmarks = await reloaded.load();

    expect(bookmarks, hasLength(1));
    final identity = bookmarks.single.server!.identity!;
    expect(bookmarks.single.id, 'a');
    expect(bookmarks.single.label, 'a');
    expect(identity.host, 'web.example.com');
    expect(identity.port, 2222);
    expect(identity.username, 'deploy');
    // Reference-style key auth: the path travels verbatim, never key bytes.
    expect(identity.authMethod, AuthMethod.privateKey);
    expect(identity.identityFilePath, '~/.ssh/id_ed25519');
  });

  test('updates a bookmark whose id already exists', () async {
    final path = pathIn('bookmarks.json');
    final store = FileBookmarkStore(path: path);
    await store.upsertAll([_bookmark('a', label: 'first')]);
    await store.upsertAll([_bookmark('a', label: 'second')]);

    final reloaded = await FileBookmarkStore(path: path).load();

    expect(reloaded, hasLength(1));
    expect(reloaded.single.label, 'second');
  });

  test('quarantines a corrupt file and starts empty', () async {
    final path = pathIn('bookmarks.json');
    File(path).writeAsStringSync('{not valid json');

    final store = FileBookmarkStore(path: path);

    expect(await store.load(), isEmpty);
    final quarantined = dir
        .listSync()
        .where((entity) => entity.path.contains('.corrupt-'));
    expect(quarantined, hasLength(1));
  });

  test('preserves undecodable records verbatim on the next write', () async {
    final path = pathIn('bookmarks.json');
    // A record from a newer Poltergeist (unknown kind) plus a valid one:
    // the unknown kind must survive a local re-save untouched (04 §2.1's
    // skip-and-preserve).
    final future = <String, dynamic>{
      'id': 'future',
      'kind': 'fromTheFuture',
      'label': 'later',
      'sortKey': 'f',
      'createdAt': '2026-09-08T12:00:00.000Z',
      'updatedAt': '2026-09-08T12:00:00.000Z',
    };
    File(path).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'bookmarks': [future, _bookmark('a').toJson()],
      }),
    );

    final store = FileBookmarkStore(path: path);
    expect((await store.load()).map((bookmark) => bookmark.id), ['a']);

    await store.upsertAll([_bookmark('b')]);

    final written = jsonDecode(File(path).readAsStringSync()) as Map;
    final records = (written['bookmarks'] as List).cast<Map>();
    expect(
      records.any((record) => record['id'] == 'future' && record['kind'] == 'fromTheFuture'),
      isTrue,
      reason: 'an unknown-kind record must be re-emitted verbatim',
    );
    expect(records.map((record) => record['id']), containsAll(['a', 'b']));
  });

  test('serializes concurrent writes so neither bookmark is lost', () async {
    final path = pathIn('bookmarks.json');
    final gate = Completer<void>();
    var writes = 0;
    final store = FileBookmarkStore(
      path: path,
      atomicWriter: (file, contents) async {
        writes++;
        if (writes == 1) await gate.future;
        await writeStringAtomically(file, contents);
      },
    );

    final first = store.upsertAll([_bookmark('a')]);
    final second = store.upsertAll([_bookmark('b')]);
    gate.complete();
    await Future.wait([first, second]);

    final reloaded = await FileBookmarkStore(path: path).load();
    expect(reloaded.map((bookmark) => bookmark.id).toSet(), {'a', 'b'});
  });

  test('persists rows built by the ssh_config import service', () async {
    const home = '/home/tester';
    const configPath = '$home/.ssh/config';
    const config = '''
Host web
  HostName web.example.com
  Port 2222
  User deploy
  IdentityFile ~/.ssh/id_ed25519
''';
    var next = 0;
    final service = SshConfigImportService(
      homeDirectory: home,
      source: _FakeSource({configPath: config}),
      mintId: () => 'row-${next++}',
    );

    final path = pathIn('bookmarks.json');
    final store = FileBookmarkStore(path: path);
    final preview = await service.loadPreview(
      configPath: configPath,
      existingBookmarks: await store.load(),
    );
    await store.upsertAll([
      for (final row in preview.rows) row.toBookmark(now: _fixedNow),
    ]);

    final reloaded = await FileBookmarkStore(path: path).load();
    expect(reloaded, hasLength(1));
    final identity = reloaded.single.server!.identity!;
    expect(identity.host, 'web.example.com');
    expect(identity.port, 2222);
    expect(identity.username, 'deploy');
    expect(identity.authMethod, AuthMethod.privateKey);
    expect(identity.identityFilePath, '~/.ssh/id_ed25519');
  });
}
