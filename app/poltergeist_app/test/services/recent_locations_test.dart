import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/recent_locations.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  late Directory temporaryDirectory;
  late File settingsFile;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_recents_test_',
    );
    settingsFile = File(p.join(temporaryDirectory.path, 'settings.json'));
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  RecentLocationsStore store({void Function(Object, StackTrace)? onError}) =>
      RecentLocationsStore(
        store: SettingsStore(path: settingsFile.path),
        saveDelay: Duration.zero,
        onError: onError,
      );

  Bookmark remoteBookmark(String id) => Bookmark(
    id: id,
    kind: BookmarkKind.remotePath,
    label: 'label-$id',
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: '$id.example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.agent,
      ),
    ),
    remotePath: '/srv/$id',
    sortKey: 'mm',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  test('records newest-first and dedupes by location', () async {
    final recents = store();
    recents.recordLocation(const LocalPaneLocation('/tmp/one'));
    recents.recordLocation(const LocalPaneLocation('/tmp/two'));
    recents.recordLocation(const LocalPaneLocation('/tmp/one'));

    expect(recents.entries.map((e) => e.path).toList(), [
      '/tmp/one',
      '/tmp/two',
    ]);
    expect(recents.entries.first.label, 'one');
  });

  test('remote recents key on server + path, not path alone', () {
    final recents = store();
    final bookmark = remoteBookmark('alpha');
    recents.recordLocation(
      const RemotePaneLocation('alpha', '/srv/web'),
      remoteBookmark: bookmark,
    );
    recents.recordLocation(
      const RemotePaneLocation('beta', '/srv/web'),
      remoteBookmark: remoteBookmark('beta'),
    );
    recents.recordLocation(
      const RemotePaneLocation('alpha', '/srv/web'),
      remoteBookmark: bookmark,
    );

    expect(recents.entries.length, 2);
    expect(recents.entries.first.serverId, 'alpha');
    expect(recents.entries.first.remoteBookmark?.label, 'label-alpha');
  });

  test('the list truncates at maxEntries', () {
    final recents = store();
    for (var i = 0; i < RecentLocationsStore.maxEntries + 10; i++) {
      recents.recordLocation(LocalPaneLocation('/tmp/dir$i'));
    }
    expect(recents.entries.length, RecentLocationsStore.maxEntries);
    expect(recents.entries.last.path, '/tmp/dir10');
  });

  test('persists through flush and reloads in order', () async {
    final recents = store();
    recents.recordLocation(const LocalPaneLocation('/tmp/one'));
    recents.recordLocation(
      const RemotePaneLocation('alpha', '/srv/web'),
      remoteBookmark: remoteBookmark('alpha'),
    );
    await recents.flush();

    final reloaded = store();
    await reloaded.load();
    expect(reloaded.entries.length, 2);
    expect(reloaded.entries.first.isRemote, isTrue);
    expect(reloaded.entries.first.path, '/srv/web');
    expect(reloaded.entries.first.remoteBookmark?.id, 'alpha');
    expect(reloaded.entries.last.path, '/tmp/one');
  });

  test('a malformed document reports and loads empty', () async {
    await settingsFile.writeAsString(
      '{"${RecentLocationsStore.settingsKey}": {"version": 99}}',
    );
    final errors = <Object>[];
    final recents = store(onError: (error, _) => errors.add(error));
    await recents.load();
    expect(recents.entries, isEmpty);
    expect(errors, isNotEmpty);
  });

  test('a malformed entry drops out; valid siblings survive', () async {
    await settingsFile.writeAsString(
      '{"${RecentLocationsStore.settingsKey}": {"version": 1, "entries": '
      '[{"label": 42}, '
      '{"label": "one", "path": "/tmp/one"}]}}',
    );
    final errors = <Object>[];
    final recents = store(onError: (error, _) => errors.add(error));
    await recents.load();
    expect(recents.entries.single.path, '/tmp/one');
    expect(errors, isNotEmpty);
  });
}
