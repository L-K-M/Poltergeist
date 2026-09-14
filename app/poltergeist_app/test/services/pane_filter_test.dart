import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/view_preferences.dart';

import 'pane_controller_test.dart' show FakePaneLanes, FakePaneChannel;

RemoteFileEntry _entry(
  String name, {
  RemoteFileType type = RemoteFileType.file,
}) {
  return RemoteFileEntry(path: '/home/tester/$name', name: name, type: type);
}

Bookmark _remoteBookmark() {
  final now = DateTime.utc(2026, 9, 12);
  return Bookmark(
    id: 'srv-1',
    kind: BookmarkKind.remotePath,
    label: 'web.example.com',
    server: BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 22,
        username: 'tester',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/srv/home',
    sortKey: 'k',
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  /// The controller's opens resolve at navigation issue; the fake's
  /// listings answer one microtask later, so tests settle before
  /// asserting on listing state.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<PaneController> browsing(
    FakePaneLanes lanes,
    List<RemoteFileEntry> entries,
  ) async {
    final channel = FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = entries;
    lanes.nextLocalChannel = channel;
    final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    await controller.openLocalHome();
    await settle();
    expect(controller.phase, PanePhase.browsing);
    return controller;
  }

  group('filter (02 §2.5)', () {
    test('apply narrows the visible listing; clear restores it', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('docs', type: RemoteFileType.directory),
        _entry('report.txt'),
        _entry('notes.txt'),
        _entry('photo.png'),
      ]);

      controller.openFilter();
      expect(controller.filterFieldOpen, isTrue);
      expect(controller.filterActive, isFalse);

      controller.changeFilterQuery('txt');
      expect(controller.filterQuery, 'txt');
      expect(controller.filterActive, isTrue);
      expect(
        controller.entries.map((e) => e.name),
        ['notes.txt', 'report.txt'],
      );
      expect(controller.unfilteredCount, 4);

      controller.clearFilter();
      expect(controller.filterFieldOpen, isFalse);
      expect(controller.filterActive, isFalse);
      expect(controller.entries.length, 4);
      controller.dispose();
    });

    test('matching is case-insensitive substring without diacritic '
        'folding', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('Étude.doc'),
        _entry('README.md'),
        _entry('report.txt'),
      ]);

      controller.openFilter();
      controller.changeFilterQuery('README');
      expect(controller.entries.map((e) => e.name), ['README.md']);

      // 'et' must NOT reach 'Étude' — the type-ahead fold is a different
      // matcher on purpose (02 §2.5 specifies plain substring).
      controller.changeFilterQuery('et');
      expect(controller.entries.map((e) => e.name), isEmpty);
      expect(controller.filterActive, isTrue,
          reason: 'an active filter may hide every row — §2.7 covers it');

      controller.changeFilterQuery('ét');
      expect(controller.entries.map((e) => e.name), ['Étude.doc']);
      controller.dispose();
    });

    test('the strip reports visible-of-total while active', () async {
      final lanes = FakePaneLanes();
      final entries = [
        for (var i = 0; i < 10; i++) _entry('match$i.txt'),
        for (var i = 0; i < 20; i++) _entry('other$i.bin'),
      ];
      final controller = await browsing(lanes, entries);

      controller.openFilter();
      controller.changeFilterQuery('match');
      expect(controller.entries.length, 10);
      expect(controller.unfilteredCount, 30);
      controller.dispose();
    });

    test('open requires verbs; the field gate blocks stray edits',
        () async {
      final unbound = PaneController(paneTabId: 'pane.left');
      unbound.openFilter();
      expect(unbound.filterFieldOpen, isFalse);
      unbound.changeFilterQuery('x');
      expect(unbound.filterQuery, '');
      unbound.dispose();

      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [_entry('a.txt')]);
      // A query change with the strip closed is a no-op — only the field
      // edits the query.
      controller.changeFilterQuery('a');
      expect(controller.filterActive, isFalse);

      controller.openFilter();
      final generation = controller.filterFocusGeneration;
      controller.openFilter();
      expect(
        controller.filterFocusGeneration,
        greaterThan(generation),
        reason: 're-invoking view.filter re-requests field focus even '
            'while the strip is already mounted',
      );
      controller.dispose();
    });

    test('a filter edit ends Quick Select BEFORE the baseline prunes '
        'against the filtered rows', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('alpha.txt'),
        _entry('beta.txt'),
        _entry('gamma.png'),
      ]);

      // Baseline: only gamma.png selected. Quick Select previews '*'.
      controller.setCursorIndex(2);
      controller.openQuickSelect();
      controller.changeQuickSelectQuery('*');
      expect(controller.selectedCount, 3);

      controller.openFilter();
      controller.changeFilterQuery('txt');
      expect(controller.quickSelectActive, isFalse,
          reason: 'the row-set replacement ends the session first');
      // The restored baseline (gamma.png) then prunes against the
      // filtered rows — it must not survive as a hidden selection.
      expect(controller.selectedCount, 0);
      expect(controller.entries.length, 2);
      controller.dispose();
    });

    test('type-ahead matches the FILTERED listing', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('beta.txt'),
        _entry('gamma.png'),
      ]);

      controller.openFilter();
      controller.changeFilterQuery('txt');
      expect(controller.entries.map((e) => e.name), ['beta.txt']);

      controller.typeAhead('b');
      expect(controller.entries[controller.cursorIndex!].name, 'beta.txt');

      controller.clearTypeAhead();
      controller.typeAhead('g');
      expect(
        controller.entries[controller.cursorIndex!].name,
        'beta.txt',
        reason: 'gamma.png is filtered out — no match keeps the cursor '
            'on the last hit, it does not reach the hidden row',
      );
      controller.dispose();
    });

    test('a filter edit drops the pending type-ahead buffer', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('beta.txt'),
        _entry('bonus.txt'),
      ]);

      controller.typeAhead('b');
      expect(controller.typeAheadActive, isTrue);

      controller.openFilter();
      controller.changeFilterQuery('bon');
      expect(controller.typeAheadBuffer, '',
          reason: 'the buffer matched rows that no longer stand');
      controller.dispose();
    });

    test('the filter survives navigation and refresh within the binding',
        () async {
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('sub', type: RemoteFileType.directory),
        _entry('report.txt'),
      ];
      channel.listings['/home/tester/sub'] = [
        _entry('nested.txt'),
        _entry('photo.png'),
      ];
      lanes.nextLocalChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
      );
      await controller.openLocalHome();
      await settle();

      controller.openFilter();
      controller.changeFilterQuery('txt');

      controller.navigate('/home/tester/sub');
      await settle();
      expect(controller.filterQuery, 'txt');
      expect(
        controller.entries.map((e) => e.name),
        ['nested.txt'],
        reason: 'the query reapplies to the newly accepted listing',
      );

      controller.refresh();
      await settle();
      expect(controller.filterActive, isTrue);
      expect(controller.entries.map((e) => e.name), ['nested.txt']);
      controller.dispose();
    });

    test('Esc-cancel of a navigation restores the pre-filter listing and '
        're-applies the query', () async {
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/home/tester');
      channel.listings['/home/tester'] = [
        _entry('sub', type: RemoteFileType.directory),
        _entry('report.txt'),
        _entry('photo.png'),
      ];
      lanes.nextLocalChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.left',
        lanes: lanes,
      );
      await controller.openLocalHome();
      await settle();

      controller.openFilter();
      controller.changeFilterQuery('txt');
      expect(controller.entries.map((e) => e.name), ['report.txt']);

      // A held listing keeps the navigation in flight; Esc cancels it
      // (the navigation tier outranks the filter tier in §8.2) and the
      // restored snapshot re-applies the still-active query.
      final hold = Completer<void>();
      channel.holdNext = hold;
      controller.navigate('/home/tester/sub');
      controller.cancelNavigation();
      expect(controller.loading, isFalse);
      expect(controller.filterQuery, 'txt');
      expect(controller.entries.map((e) => e.name), ['report.txt']);
      hold.complete();
      await settle();
      controller.dispose();
    });

    test('a replaced binding drops the filter with its listing', () async {
      final lanes = FakePaneLanes();
      final controller = await browsing(lanes, [
        _entry('alpha.txt'),
        _entry('gamma.png'),
      ]);

      controller.openFilter();
      controller.changeFilterQuery('zzz');
      expect(controller.entries, isEmpty);

      // A fresh bind replaces the browsing session wholesale.
      final next = FakePaneChannel('/home/tester');
      next.listings['/home/tester'] = [
        _entry('alpha.txt'),
        _entry('gamma.png'),
      ];
      lanes.nextLocalChannel = next;
      await controller.openLocalHome();
      await settle();

      expect(controller.filterQuery, '');
      expect(controller.filterFieldOpen, isFalse);
      expect(controller.entries.length, 2,
          reason: 'a stale query must not hide a fresh listing — that '
              'reads as data loss');
      controller.dispose();
    });

    test('a remote detach drops the filter with the binding', () async {
      final lanes = FakePaneLanes();
      final channel = FakePaneChannel('/srv/home');
      channel.listings['/srv/home'] = [
        _entry('index.html'),
        _entry('notes.txt'),
      ];
      lanes.nextRemoteChannel = channel;
      final controller = PaneController(
        paneTabId: 'pane.right',
        lanes: lanes,
      );
      await controller.connectRemote(_remoteBookmark());
      await settle();
      expect(controller.phase, PanePhase.browsing);

      controller.openFilter();
      controller.changeFilterQuery('index');
      expect(controller.entries.map((e) => e.name), ['index.html']);

      await controller.detachRemote();
      await settle();
      expect(controller.filterQuery, '');
      expect(controller.filterFieldOpen, isFalse);
      expect(controller.entries, isEmpty);
      controller.dispose();
    });

    test('filter state never reaches a persistence surface', () {
      // 02 §2.5: per-tab and transient — not ViewPreferences, not §3
      // workspace snapshots, not session restore. The pin is the
      // persisted key set itself: a new persisted field (a filter among
      // them) must trip this test.
      expect(
        ViewPreferences().toJson().keys.toSet(),
        {
          'mode',
          'density',
          'directories',
          'hiddenFiles',
          'dates',
          'sortKey',
          'sortDirection',
          'columns',
          'columnWidths',
        },
        reason: 'the §2.5 filter is transient by construction — any new '
            'persisted key must be a deliberate, reviewed addition',
      );
    });
  });
}
