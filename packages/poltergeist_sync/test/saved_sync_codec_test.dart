@TestOn('vm')
library;

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

void main() {
  const identity = EmbeddedHostIdentity(
    host: 'web.example.com',
    port: 22,
    username: 'deploy',
    authMethod: AuthMethod.agent,
  );

  SyncPair richPair() => SyncPair(
    id: 'fav-42',
    name: 'Blog -> webserver',
    left: const LocalEndpoint('/home/me/blog'),
    right: const RemoteEndpoint(
      server: BookmarkServerRef(identity: identity),
      path: '/var/www/blog',
    ),
    rules: const SyncRuleSet(
      direction: SyncDirection.leftToRight,
      deletions: DeletionPolicy.trash,
      backups: BackupPolicy.trash,
      comparison: ComparisonMode.sizeAndMtime,
      mtimeToleranceSecs: 4,
      acceptedTimeShifts: [3600],
      conflictDefault: ConflictDefault.newerWins,
      excludeGlobs: ['.git/', 'node_modules/'],
      includeHidden: false,
      trashPathRight: '/var/trash',
      maxDelete: 77,
      deleteFractionWarn: 0.25,
      preserveMtime: false,
      transferConcurrency: 2,
    ),
  );

  group('SyncPair ↔ SavedSyncSpec (04 §2.1)', () {
    test('a full ruleset round-trips through the spec', () {
      final original = richPair();
      final spec = savedSyncSpecFromPair(original);
      final decoded = syncPairFromSavedSync(
        spec,
        id: original.id,
        name: original.name,
      );

      expect(decoded.id, original.id);
      expect(decoded.name, original.name);
      expect(decoded.left, isA<LocalEndpoint>());
      expect((decoded.left as LocalEndpoint).path, '/home/me/blog');
      final right = decoded.right as RemoteEndpoint;
      expect(right.path, '/var/www/blog');
      expect(right.server.identity?.host, 'web.example.com');
      expect(decoded.rules, original.rules);
      expect(decoded.rules.excludeGlobs, ['.git/', 'node_modules/']);
    });

    test('ignoreRules land in the spec field, not the rules map', () {
      final spec = savedSyncSpecFromPair(richPair());
      expect(spec.ignoreRules, ['.git/', 'node_modules/']);
      expect(spec.rules, isNot(contains('excludeGlobs')));
      // And the raw JSON shape carries them too — the synced record
      // itself, not just the in-memory spec.
      expect(spec.toJson()['ignoreRules'], ['.git/', 'node_modules/']);
    });

    test('a missing rules map decodes to the default ruleset', () {
      final spec = SavedSyncSpec(
        source: const BookmarkLocation(path: '/l'),
        destination: const BookmarkLocation(path: '/r'),
      );
      final pair = syncPairFromSavedSync(spec, id: 'x', name: 'n');
      expect(pair.rules, const SyncRuleSet());
    });

    test('the spec survives a JSON round-trip through Bookmark', () {
      final original = richPair();
      final bookmark = bookmarkFromSyncPair(
        original,
        group: 'Sites',
        sortKey: 'blog',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      expect(bookmark.kind, BookmarkKind.savedSync);
      expect(bookmark.id, original.id);
      expect(bookmark.label, original.name);

      final decoded = Bookmark.fromJson(
        bookmark.toJson(),
        recordId: 'bookmark:${bookmark.id}',
      );
      final restored = syncPairFromBookmark(decoded);
      expect(restored, isNotNull);
      expect(restored!.rules, original.rules);
      expect((restored.right as RemoteEndpoint).path, '/var/www/blog');
    });

    test('non-savedSync bookmarks decode to null, never a fake pair', () {
      final bookmark = Bookmark(
        id: 'b-1',
        kind: BookmarkKind.localFolder,
        label: 'Docs',
        localPath: '/home/me/docs',
        sortKey: 'docs',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );
      expect(syncPairFromBookmark(bookmark), isNull);
    });

    test('a bidirectional pair refuses deletions on decode', () {
      final spec = SavedSyncSpec(
        source: const BookmarkLocation(path: '/l'),
        destination: const BookmarkLocation(path: '/r'),
        rules: const {
          'direction': 'bidirectional',
          'deletions': 'trash',
        },
      );
      expect(
        () => syncPairFromSavedSync(spec, id: 'x', name: 'n'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
