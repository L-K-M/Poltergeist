import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/application_error_reporter.dart';
import 'package:poltergeist_app/services/sidebar_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_bookmark_store.dart';

final _now = DateTime.utc(2026, 10, 1);

Bookmark _remote(
  String id, {
  String? group,
  String? sortKey,
}) => Bookmark(
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
  // Minted keys are a–z only (04 §2.5); 'mm' ties resolve on the id
  // tiebreaker — the deterministic order the store itself uses.
  sortKey: sortKey ?? 'mm',
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  late FakeBookmarkStore store;
  late List<Object> errors;
  late List<String> changed;
  late List<String> removed;
  late List<Set<String>> collapsedWrites;

  SidebarController buildController({Set<String> collapsed = const {}}) =>
      SidebarController(
        store: store,
        initiallyCollapsed: collapsed,
        errors: ApplicationErrorReporter(sink: (error, _) => errors.add(error)),
        onBookmarksChanged: () => changed.add('change'),
        onBookmarkRemoved: removed.add,
        onCollapsedChanged: collapsedWrites.add,
      );

  setUp(() {
    store = FakeBookmarkStore();
    errors = [];
    changed = [];
    removed = [];
    collapsedWrites = [];
  });

  test('reload publishes the store sections in group order', () async {
    store.bookmarks = [
      _remote('b', group: 'Beta'),
      _remote('u'),
      _remote('a', group: 'alpha'),
    ];
    final controller = buildController();
    addTearDown(controller.dispose);

    await controller.reload();

    expect(controller.load, SidebarLoad.ready);
    expect(controller.sections.map((section) => section.name), [
      'alpha',
      'Beta',
      null,
    ]);
    expect(
      controller.bookmarks.map((bookmark) => bookmark.id),
      ['a', 'b', 'u'],
    );
    // The explicit reload fires the re-derive edge exactly once.
    expect(changed, ['change']);
  });

  test('a store save reloads the sections and forwards the edge', () async {
    store.bookmarks = [_remote('b')];
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.reload();
    changed.clear();

    await store.save(_remote('n', group: 'new'));
    // Drain the change → reload pipeline however it is scheduled.
    await pumpEventQueue();

    expect(changed, ['change']);
    expect(controller.sections.map((section) => section.name), ['new', null]);
  });

  test('toggleCollapsed reports the full key set through the seam',
      () async {
    store.bookmarks = [_remote('a', group: 'alpha')];
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.reload();
    final key = controller.sections.single.key;

    controller.toggleCollapsed(key);
    expect(controller.isCollapsed(key), isTrue);
    expect(collapsedWrites, [
      {key},
    ]);

    controller.toggleCollapsed(key);
    expect(controller.isCollapsed(key), isFalse);
    expect(collapsedWrites.last, isEmpty);
  });

  test('seeded collapse state applies and a failed sink keeps the toggle',
      () async {
    store.bookmarks = [_remote('a', group: 'alpha')];
    // A pre-D32 set: the bare group key migrates into the fav: namespace.
    final controller = buildController(collapsed: {'alpha'});
    addTearDown(controller.dispose);
    await controller.reload();

    expect(
      controller.isCollapsed(
        SidebarCollapseKeys.favoriteGroup(controller.sections.single.key),
      ),
      isTrue,
    );

    // A throwing persist seam is reported, not fatal — the in-memory
    // toggle already landed.
    final throwing = SidebarController(
      store: store,
      onCollapsedChanged: (_) => throw StateError('disk full'),
      errors: ApplicationErrorReporter(sink: (error, _) => errors.add(error)),
    );
    addTearDown(throwing.dispose);
    await throwing.reload();
    throwing.toggleCollapsed(throwing.sections.single.key);
    expect(errors, hasLength(1));
    expect(throwing.isCollapsed(throwing.sections.single.key), isTrue);
  });

  test('rename saves the new label through the store', () async {
    store.bookmarks = [_remote('a')];
    store.now = () => _now.add(const Duration(minutes: 5));
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.reload();

    final saved = await controller.rename('a', 'renamed');
    expect(saved.label, 'renamed');
    expect(store.bookmarks.single.label, 'renamed');
    // The file store stamps updatedAt on every local edit; the fake
    // mirrors it, so the stamp lands on the injected clock.
    expect(
      store.bookmarks.single.updatedAt,
      _now.add(const Duration(minutes: 5)),
    );
  });

  test('rename on an unknown id throws without touching the store',
      () async {
    final controller = buildController();
    addTearDown(controller.dispose);

    await expectLater(
      controller.rename('missing', 'x'),
      throwsArgumentError,
    );
    expect(store.bookmarks, isEmpty);
  });

  test('remove deletes the record, then forwards the cascade id',
      () async {
    store.bookmarks = [_remote('a'), _remote('b')];
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.reload();

    expect(await controller.remove('a'), isTrue);
    expect(store.bookmarks.map((bookmark) => bookmark.id), ['b']);
    // Delete first, cascade second: the forwarded id must already be
    // absent from the store when the seam fires.
    expect(removed, ['a']);

    expect(await controller.remove('missing'), isFalse);
    expect(removed, hasLength(1));
  });

  test('moveToGroup refiles and drop appends at the group tail', () async {
    store.bookmarks = [
      _remote('a', sortKey: 'm'),
      _remote('b', group: 'work', sortKey: 'n'),
      _remote('c', group: 'work', sortKey: 'o'),
    ];
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.reload();

    await controller.moveToGroup('a', 'work');
    await pumpEventQueue();
    expect(store.bookmarks.firstWhere((b) => b.id == 'a').group, 'work');
    // A drop with no named neighbors appends after the group's tail.
    expect(
      compareBookmarkSortKeys(
        store.bookmarks.firstWhere((b) => b.id == 'a'),
        store.bookmarks.firstWhere((b) => b.id == 'c'),
      ) >
          0,
      isTrue,
    );
  });

  test('reorder positions between the named neighbors', () async {
    store.bookmarks = [
      _remote('a', sortKey: 'm'),
      _remote('b', sortKey: 'o'),
      _remote('c', sortKey: 'q'),
    ];
    final controller = buildController();
    addTearDown(controller.dispose);
    await controller.reload();

    // beforeId names the member the moved row lands after: 'c' between
    // 'a' and 'b'.
    await controller.reorder('c', beforeId: 'a');
    await pumpEventQueue();
    expect(
      controller.bookmarks.map((bookmark) => bookmark.id),
      ['a', 'c', 'b'],
    );
  });

  test('a failed load flips the state and reports once', () async {
    store.failure = StateError('unreadable');
    final controller = buildController();
    addTearDown(controller.dispose);

    await controller.reload();

    expect(controller.load, SidebarLoad.failed);
    expect(controller.sections, isEmpty);
    expect(errors, hasLength(1));
    // A failed load has no bookmark truth to forward.
    expect(changed, isEmpty);
  });

  test('a superseded reload drops its stale result', () async {
    store.bookmarks = [_remote('a')];
    final gate = Completer<void>();
    store.gate = gate;
    final controller = buildController();
    addTearDown(controller.dispose);

    final parked = controller.reload();
    // A second load supersedes the parked one: after the gate releases,
    // the stale snapshot must not overwrite the fresher read.
    store.bookmarks = [_remote('a'), _remote('b')];
    store.gate = null;
    final fresh = controller.reload();
    gate.complete();
    await parked;
    await fresh;

    expect(controller.bookmarks, hasLength(2));
  });

  group('collapse keys', () {
    test('every surface namespaces its keys', () {
      expect(
        SidebarCollapseKeys.section(SidebarSection.devices),
        'sec:devices',
      );
      expect(SidebarCollapseKeys.favoriteGroup('work'), 'fav:work');
      expect(SidebarCollapseKeys.serverGroup('work'), 'srv:work');
    });

    test('the migration maps every legacy key and is idempotent', () {
      final migrated = SidebarCollapseKeys.migrate({
        'work', // a favorite group's bare key
        '', // the old ungrouped "Favorites" header
        'sidebar.connections', // a section that no longer exists
        'sidebar.catalog', // the Séance-servers section → SERVERS
        'sidebar.catalog.prod', // a catalog group
        'sec:devices', // already namespaced
      });
      expect(migrated, {'fav:work', 'sec:servers', 'srv:prod', 'sec:devices'});
      expect(SidebarCollapseKeys.migrate(migrated), migrated);
    });
  });

  group('density', () {
    test('rows start comfortable unless seeded, and a change persists', () {
      final writes = <SidebarDensity>[];
      final controller = SidebarController(
        store: store,
        onDensityChanged: writes.add,
      );
      addTearDown(controller.dispose);
      var notified = 0;
      controller.addListener(() => notified++);

      expect(controller.density, SidebarDensity.comfortable);

      controller.setDensity(SidebarDensity.compact);
      expect(controller.density, SidebarDensity.compact);
      expect(writes, [SidebarDensity.compact]);
      expect(notified, 1);

      // The same choice again is no change: nothing to repaint or save.
      controller.setDensity(SidebarDensity.compact);
      expect(writes, hasLength(1));
      expect(notified, 1);

      final seeded = SidebarController(
        store: store,
        density: SidebarDensity.compact,
      );
      addTearDown(seeded.dispose);
      expect(seeded.density, SidebarDensity.compact);
    });

    test('a failed save reports and keeps the choice', () {
      final controller = SidebarController(
        store: store,
        onDensityChanged: (_) => throw StateError('disk full'),
        errors: ApplicationErrorReporter(sink: (error, _) => errors.add(error)),
      );
      addTearDown(controller.dispose);

      controller.setDensity(SidebarDensity.compact);
      expect(errors, hasLength(1));
      expect(controller.density, SidebarDensity.compact);
    });
  });

  group('pins', () {
    test('a pin toggles on and off and reports the full set', () {
      final writes = <Set<String>>[];
      final controller = SidebarController(
        store: store,
        initiallyPinned: {'seeded'},
        onPinnedChanged: writes.add,
      );
      addTearDown(controller.dispose);
      var notified = 0;
      controller.addListener(() => notified++);

      expect(controller.isPinned('seeded'), isTrue);
      expect(controller.isPinned('s1'), isFalse);

      controller.togglePinned('s1');
      expect(controller.pinnedServers, {'seeded', 's1'});
      expect(writes, [
        {'seeded', 's1'},
      ]);
      controller.togglePinned('seeded');
      expect(controller.isPinned('seeded'), isFalse);
      expect(writes.last, {'s1'});
      expect(notified, 2);
    });

    test('a failed save reports and keeps the pin', () {
      final controller = SidebarController(
        store: store,
        onPinnedChanged: (_) => throw StateError('disk full'),
        errors: ApplicationErrorReporter(sink: (error, _) => errors.add(error)),
      );
      addTearDown(controller.dispose);

      controller.togglePinned('s1');
      expect(errors, hasLength(1));
      expect(controller.isPinned('s1'), isTrue);
    });
  });

  group('filter', () {
    test('a request opens the field and leaves focus to take once', () {
      final controller = buildController();
      addTearDown(controller.dispose);
      expect(controller.filterOpen, isFalse);
      expect(controller.takeFilterFocus(), isFalse);

      controller.requestFilter();
      expect(controller.filterOpen, isTrue);
      expect(controller.takeFilterFocus(), isTrue);
      expect(controller.takeFilterFocus(), isFalse);
    });

    test('dismiss clears a live query first, then closes', () {
      final controller = buildController();
      addTearDown(controller.dispose);
      controller
        ..requestFilter()
        ..setFilterQuery('web');

      controller.dismissFilter();
      expect(controller.filterQuery, isEmpty);
      expect(controller.filterOpen, isTrue);

      controller.dismissFilter();
      expect(controller.filterOpen, isFalse);
    });
  });

  group('pending groups', () {
    test(
      'a new group waits in memory and retires once it has a member',
      () async {
        store.bookmarks = [_remote('a')];
        final controller = buildController();
        addTearDown(controller.dispose);
        await controller.reload();

        controller
          ..addPendingGroup('Clients')
          // Case-insensitive duplicates and blanks are ignored.
          ..addPendingGroup('clients')
          ..addPendingGroup('  ');
        expect(controller.pendingGroups, ['Clients']);

        await controller.moveToGroup('a', 'Clients');
        await pumpEventQueue();
        expect(controller.pendingGroups, isEmpty);
      },
    );

    test('an existing group is never re-created as pending', () async {
      store.bookmarks = [_remote('a', group: 'Ops')];
      final controller = buildController();
      addTearDown(controller.dispose);
      await controller.reload();

      controller.addPendingGroup('ops');
      expect(controller.pendingGroups, isEmpty);
    });
  });

  group('adding', () {
    test(
      'local folders land in order, labelled, and never duplicated',
      () async {
        store.bookmarks = [
          Bookmark(
            id: 'docs',
            kind: BookmarkKind.localFolder,
            label: 'Docs',
            localPath: '/home/me/Documents',
            sortKey: 'mm',
            createdAt: _now,
            updatedAt: _now,
          ),
        ];
        final controller = buildController();
        addTearDown(controller.dispose);
        await controller.reload();

        final added = await controller.addLocalFolders([
          '/home/me/Desktop',
          '/home/me/Documents',
          '/home/me/Downloads',
        ], labelOf: (path) => path.split('/').last);
        await pumpEventQueue();

        expect(
          [for (final b in added) b.localPath],
          ['/home/me/Desktop', '/home/me/Downloads'],
        );
        expect([for (final b in added) b.label], ['Desktop', 'Downloads']);
        expect(added.every((b) => b.kind == BookmarkKind.localFolder), isTrue);
        // Store order follows the ask: Desktop before Downloads, both after
        // the existing favorite (the ungrouped tail).
        expect(
          [for (final b in controller.bookmarks) b.id],
          ['docs', added[0].id, added[1].id],
        );
      },
    );

    test('a remote location saves the endpoint under a fresh id', () async {
      final controller = buildController();
      addTearDown(controller.dispose);
      final live = Bookmark(
        id: 'adhoc:1',
        kind: BookmarkKind.remotePath,
        label: 'demo@host',
        server: BookmarkServerRef(
          identity: EmbeddedHostIdentity(
            host: 'host',
            port: 2222,
            username: 'demo',
            authMethod: AuthMethod.password,
          ),
        ),
        remotePath: '/',
        sortKey: 'adhoc:1',
        createdAt: _now,
        updatedAt: _now,
      );

      final saved = await controller.saveRemoteLocation(
        live: live,
        path: '/var/www',
        label: 'web root',
      );

      expect(saved.id, isNot(live.id));
      expect(saved.server?.identity?.port, 2222);
      expect(saved.remotePath, '/var/www');
      expect(saved.label, 'web root');
      expect(store.bookmarks.single.id, saved.id);
    });
  });
}
