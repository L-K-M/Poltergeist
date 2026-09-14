import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart' as controller_test;

RemoteFileEntry _entry(String name, {String parent = '/home/tester'}) {
  return RemoteFileEntry(
    path: '$parent/$name',
    name: name,
    type: RemoteFileType.file,
  );
}

void main() {
  /// The controller's opens resolve at navigation issue; the fake's
  /// listings answer one microtask later, so tests settle before
  /// asserting on listing state.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  late controller_test.FakePaneLanes lanes;
  late controller_test.FakePaneChannel channel;
  late PaneController controller;

  PaneController openWithListing(List<RemoteFileEntry> entries) {
    channel = controller_test.FakePaneChannel('/home/tester');
    channel.listings['/home/tester'] = entries;
    lanes.nextLocalChannel = channel;
    return PaneController(paneTabId: 'pane.left', lanes: lanes);
  }

  Future<void> openHome(PaneController controller) async {
    await controller.openLocalHome();
    await settle();
  }

  setUp(() {
    lanes = controller_test.FakePaneLanes();
  });

  tearDown(() {
    controller.dispose();
  });

  Set<int> selectedIndices(PaneController controller) {
    final selected = <int>{};
    for (var i = 0; i < controller.entries.length; i++) {
      if (controller.isRowSelected(i)) selected.add(i);
    }
    return selected;
  }

  group('row activation', () {
    test('plain activation single-selects and moves the cursor', () async {
      controller = openWithListing([_entry('a'), _entry('b'), _entry('c')]);
      await openHome(controller);

      controller.setCursorIndex(1);
      expect(controller.cursorIndex, 1);
      expect(selectedIndices(controller), {1});
      expect(controller.selectedCount, 1);

      // A plain activation elsewhere replaces the selection.
      controller.setCursorIndex(2);
      expect(selectedIndices(controller), {2});
    });

    test('toggle adds and removes without disturbing the rest', () async {
      controller = openWithListing([
        _entry('a'),
        _entry('b'),
        _entry('c'),
        _entry('d'),
      ]);
      await openHome(controller);

      controller.setCursorIndex(0);
      controller.setCursorIndex(2, update: SelectionUpdate.toggle);
      expect(selectedIndices(controller), {0, 2});

      // Toggling a selected row off keeps the others.
      controller.setCursorIndex(0, update: SelectionUpdate.toggle);
      expect(selectedIndices(controller), {2});
      // The cursor still lands on the toggled row.
      expect(controller.cursorIndex, 0);
    });

    test('range grows and shrinks around the stable anchor', () async {
      controller = openWithListing([
        _entry('a'),
        _entry('b'),
        _entry('c'),
        _entry('d'),
        _entry('e'),
      ]);
      await openHome(controller);

      controller.setCursorIndex(1);
      controller.setCursorIndex(3, update: SelectionUpdate.range);
      expect(selectedIndices(controller), {1, 2, 3});

      // Grow.
      controller.setCursorIndex(4, update: SelectionUpdate.range);
      expect(selectedIndices(controller), {1, 2, 3, 4});

      // Shrink.
      controller.setCursorIndex(2, update: SelectionUpdate.range);
      expect(selectedIndices(controller), {1, 2});

      // Cross the anchor: the span recomputes from it, never unions.
      controller.setCursorIndex(0, update: SelectionUpdate.range);
      expect(selectedIndices(controller), {0, 1});
    });

    test('a backward range spans anchor down to target', () async {
      controller = openWithListing([
        _entry('a'),
        _entry('b'),
        _entry('c'),
        _entry('d'),
      ]);
      await openHome(controller);

      controller.setCursorIndex(3);
      controller.setCursorIndex(1, update: SelectionUpdate.range);
      expect(selectedIndices(controller), {1, 2, 3});
      expect(controller.cursorIndex, 1);
    });

    test('select-all and invert act on the visible rows', () async {
      controller = openWithListing([_entry('a'), _entry('b'), _entry('c')]);
      await openHome(controller);

      controller.selectAll();
      expect(selectedIndices(controller), {0, 1, 2});
      expect(
        controller.cursorIndex,
        isNull,
        reason: 'select-all keeps the cursor where it was',
      );

      controller.invertSelection();
      expect(selectedIndices(controller), isEmpty);

      controller.invertSelection();
      expect(selectedIndices(controller), {0, 1, 2});
    });

    test('select-all and invert on an empty listing are no-ops', () async {
      controller = openWithListing(const []);
      await openHome(controller);

      controller.selectAll();
      controller.invertSelection();
      expect(controller.selectedCount, 0);
      expect(controller.cursorIndex, isNull);
    });
  });

  group('cursor movement', () {
    test('plain movement single-selects the target row', () async {
      controller = openWithListing([_entry('a'), _entry('b'), _entry('c')]);
      await openHome(controller);

      controller.moveCursorBy(1);
      expect(controller.cursorIndex, 0);
      expect(selectedIndices(controller), {0});
    });

    test('shift movement extends the anchored range', () async {
      controller = openWithListing([
        _entry('a'),
        _entry('b'),
        _entry('c'),
        _entry('d'),
      ]);
      await openHome(controller);

      controller.moveCursorBy(1);
      controller.moveCursorBy(1, update: SelectionUpdate.range);
      controller.moveCursorBy(1, update: SelectionUpdate.range);
      expect(selectedIndices(controller), {0, 1, 2});

      controller.moveCursorBy(-2, update: SelectionUpdate.range);
      expect(selectedIndices(controller), {0});
      expect(controller.cursorIndex, 0);
    });

    test('a range with no anchor adopts the cursor, keeping one stable '
        'endpoint across pruning', () async {
      controller = openWithListing([
        _entry('a'),
        _entry('b'),
        _entry('c'),
        _entry('d'),
        _entry('e'),
        _entry('f'),
      ]);
      await openHome(controller);

      // The first range degenerates to a single selection with the
      // row as its explicit anchor (no prior cursor existed).
      controller.setCursorIndex(1, update: SelectionUpdate.range);
      controller.setCursorIndex(4, update: SelectionUpdate.range);
      expect(selectedIndices(controller), {1, 2, 3, 4});

      // A same-location refresh drops the anchor row b; survivors keep
      // their selection, and the pruned anchor leaves the cursor (e) as
      // the next range's adopted anchor — one stable endpoint (#107's
      // invariant), never a re-derived moving cursor.
      channel.listings['/home/tester'] = [
        _entry('a'),
        _entry('c'),
        _entry('d'),
        _entry('e'),
        _entry('f'),
      ];
      controller.refresh();
      await settle();

      // Listing is now a(0), c(1), d(2), e(3), f(4).
      expect(selectedIndices(controller), {
        1,
        2,
        3,
      }, reason: 'c, d, e survive by identity');

      controller.setCursorIndex(2, update: SelectionUpdate.range);
      expect(
        selectedIndices(controller),
        {2, 3},
        reason:
            'the adopted anchor (e, index 3) holds; a cursor-move '
            're-derivation would also give {2, 3} here, but the next '
            'extension proves the endpoint',
      );

      controller.setCursorIndex(1, update: SelectionUpdate.range);
      expect(selectedIndices(controller), {
        1,
        2,
        3,
      }, reason: 'still anchored at e — the endpoint never moved');
    });
  });

  group('listing replacement', () {
    test('same-location refresh prunes and keeps surviving identities '
        'across a reorder', () async {
      controller = openWithListing([_entry('a'), _entry('b'), _entry('c')]);
      await openHome(controller);

      controller.setCursorIndex(0);
      controller.setCursorIndex(1, update: SelectionUpdate.range);
      expect(selectedIndices(controller), {0, 1});

      // b vanished; a and c swapped order. Surviving identities keep
      // their selection regardless of position.
      channel.listings['/home/tester'] = [
        _entry('c'),
        _entry('a'),
        _entry('d'),
      ];
      controller.refresh();
      await settle();

      expect(controller.entries.map((e) => e.name).toList(), [
        'a',
        'c',
        'd',
      ], reason: 'directories-first natural order still applies');
      expect(selectedIndices(controller), {
        controller.entries.indexWhere((e) => e.name == 'a'),
      }, reason: 'a stays selected by identity; the pruned b is gone');
      expect(controller.selectedCount, 1);
    });

    test('navigation to a new location resets the selection', () async {
      controller = openWithListing([_entry('a'), _entry('b')]);
      channel.listings['/home/tester/docs'] = [_entry('nested')];
      await openHome(controller);

      controller.setCursorIndex(0);
      controller.setCursorIndex(1, update: SelectionUpdate.range);
      expect(controller.selectedCount, 2);

      controller.navigate('/home/tester/docs');
      await settle();

      expect(controller.selectedCount, 0);
      expect(controller.cursorIndex, isNull);
      expect(selectedIndices(controller), isEmpty);
    });

    test('cancelNavigation restores the selection with the snapshot', () async {
      controller = openWithListing([_entry('a'), _entry('b'), _entry('c')]);
      channel.listings['/home/tester/docs'] = [_entry('nested')];
      await openHome(controller);

      controller.setCursorIndex(2);
      expect(selectedIndices(controller), {2});

      final hold = _holdCompleter();
      channel.holdNext = hold;
      controller.navigate('/home/tester/docs');
      await settle();

      // Mid-flight: the old entries stay visible, selection reset.
      expect(controller.selectedCount, 0);

      controller.cancelNavigation();
      expect(selectedIndices(controller), {2});
      expect(controller.cursorIndex, 2);

      hold.complete();
      await settle();
      expect(selectedIndices(controller), {
        2,
      }, reason: 'the late answer is dropped, not applied');
      expect(controller.entries.map((e) => e.name), ['a', 'b', 'c']);
    });

    test(
      'detaching a remote binding clears selection with the listing',
      () async {
        final remote = controller_test.FakePaneChannel('/srv/home');
        remote.listings['/srv/home'] = [
          _entry('r1', parent: '/srv/home'),
          _entry('r2', parent: '/srv/home'),
        ];
        lanes.nextRemoteChannel = remote;
        controller = PaneController(paneTabId: 'pane.right', lanes: lanes);
        await controller.connectRemote(_bookmark('srv-1'));
        await settle();

        controller.setCursorIndex(0);
        expect(controller.selectedCount, 1);

        await controller.detachRemote();
        expect(controller.selectedCount, 0);
        expect(controller.cursorIndex, isNull);
      },
    );
  });

  test(
    'recovery keeps cached selection until a healed listing prunes it',
    () async {
      final remote = controller_test.FakePaneChannel('/srv/home');
      remote.listings['/srv/home'] = [
        _entry('r1', parent: '/srv/home'),
        _entry('r2', parent: '/srv/home'),
        _entry('r3', parent: '/srv/home'),
      ];
      lanes.nextRemoteChannel = remote;
      controller = PaneController(paneTabId: 'pane.right', lanes: lanes);
      await controller.connectRemote(_bookmark('srv-1'));
      await settle();

      controller.setCursorIndex(0);
      controller.setCursorIndex(2, update: SelectionUpdate.range);
      expect(controller.selectedCount, 3);

      lanes.emitState(
        'srv-1',
        const ServerStatus(ServerConnectionState.reconnecting),
      );
      await settle();
      expect(controller.connectionLost, isTrue);
      // The cached rows keep their selection under the loss banner.
      expect(controller.selectedCount, 3);

      // The healed listing drops r2; survivors keep their selection.
      remote.listings['/srv/home'] = [
        _entry('r1', parent: '/srv/home'),
        _entry('r3', parent: '/srv/home'),
      ];
      lanes.emitState(
        'srv-1',
        const ServerStatus(ServerConnectionState.connected),
      );
      await settle();

      expect(controller.connectionLost, isFalse);
      expect(controller.selectedCount, 2);
      expect(controller.entries.map((e) => e.name), ['r1', 'r3']);
    },
  );
}

Bookmark _bookmark(String id) {
  final now = DateTime.utc(2026, 9, 12);
  return Bookmark(
    id: id,
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
    remotePath: '/',
    sortKey: 'k',
    createdAt: now,
    updatedAt: now,
  );
}

/// A completer the fake listing parks on, released by the test.
Completer<void> _holdCompleter() => Completer<void>();
