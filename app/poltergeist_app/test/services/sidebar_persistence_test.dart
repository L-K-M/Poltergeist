import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final _now = DateTime.utc(2026, 10, 4);

Bookmark _remote(String id, {String? group, required String sortKey}) =>
    Bookmark(
      id: id,
      kind: BookmarkKind.remotePath,
      label: 'label-$id',
      group: group,
      server: BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: '$id.example.com',
          port: 22,
          username: 'deploy',
          authMethod: AuthMethod.agent,
        ),
      ),
      remotePath: '/srv/$id',
      sortKey: sortKey,
      createdAt: _now,
      updatedAt: _now,
    );

void main() {
  late Directory temporaryDirectory;
  late File storeFile;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'poltergeist_sidebar_persistence_test_',
    );
    storeFile = File(p.join(temporaryDirectory.path, 'bookmarks.json'));
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  List<String> flatIds(SidebarController controller) => [
    for (final section in controller.sections)
      ...section.bookmarks.map((bookmark) => bookmark.id),
  ];

  test(
    'mutations through the sidebar persist into a fresh store — the '
    'restart boundary every launch crosses (07 §3.6 criterion 1)',
    () async {
      // Seed directly at the store seam — creation is the import/
      // capture flow's write, not a sidebar verb.
      final store = FileBookmarkStore(path: storeFile.path);
      await store.upsertAll([
        _remote('a', sortKey: 'a'),
        _remote('b', sortKey: 'b'),
        _remote('c', sortKey: 'c'),
        _remote('d', sortKey: 'd'),
      ]);
      final sidebar = SidebarController(store: store);
      addTearDown(sidebar.dispose);
      await sidebar.reload();
      expect(flatIds(sidebar), ['a', 'b', 'c', 'd']);

      // The row surface's own verbs: reorder, refile into a group,
      // rename, delete — each routed through the real FileBookmarkStore.
      await sidebar.reorder('d', beforeId: 'a');
      await sidebar.moveToGroup('c', 'work');
      await sidebar.rename('b', 'Bee renamed');
      await sidebar.remove('a');

      // The on-disk document is the restart's only input — assert the
      // file itself, so a fake-shaped success cannot pass here.
      final written =
          jsonDecode(storeFile.readAsStringSync()) as Map<String, dynamic>;
      expect(written.keys.toSet(), {'version', 'bookmarks'});
      expect(written['bookmarks'], hasLength(3));

      // "Restart": a fresh store over the same file, a fresh controller
      // over that store — nothing shared with the first session.
      final restartedStore = FileBookmarkStore(path: storeFile.path);
      final restarted = SidebarController(store: restartedStore);
      addTearDown(restarted.dispose);
      await restarted.reload();

      expect(restarted.sections, hasLength(2));
      expect(restarted.sections[0].name, 'work');
      expect(
        restarted.sections[0].bookmarks.map((bookmark) => bookmark.id),
        ['c'],
      );
      expect(restarted.sections[1].name, isNull);
      expect(
        restarted.sections[1].bookmarks.map((bookmark) => bookmark.id),
        ['d', 'b'],
      );
      expect(
        restarted.bookmarks.firstWhere((bookmark) => bookmark.id == 'b').label,
        'Bee renamed',
      );
      expect(
        restarted.bookmarks.any((bookmark) => bookmark.id == 'a'),
        isFalse,
      );
    },
  );
}
