import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/quick_select_state.dart';
import 'package:poltergeist_app/services/selection_state.dart';

const _rows = [1, 2, 3, 4, 5];

SelectionState<int> _begin({Iterable<int> rows = _rows, Iterable<int> selected = const []}) =>
    SelectionState.begin(rows: rows, selectedKeys: selected);

void main() {
  test('starts with copied, immutable rows and selection', () {
    final rows = List<int>.of(_rows);
    final selected = [2, 3];
    final state = _begin(rows: rows, selected: selected);
    rows.clear();
    selected.clear();

    expect(state.rows, _rows);
    expect(state.selectedKeys, {2, 3});
    expect(state.cursorKey, isNull);
    expect(state.anchorKey, isNull);
    expect(() => state.rows.clear(), throwsUnsupportedError);
    expect(() => state.selectedKeys.clear(), throwsUnsupportedError);
  });

  test('an empty listing accepts wholesale transitions and rejects targets', () {
    final state = _begin(rows: const []);

    expect(state.selectAll().selectedKeys, isEmpty);
    expect(state.invert().selectedKeys, isEmpty);
    expect(state.withRows(const [1, 2]).selectedKeys, isEmpty);
    expect(() => state.activate(1, SelectionUpdate.single),
        throwsArgumentError);
  });

  test('a single-row listing selects, toggles, and ranges onto itself', () {
    final state = _begin(rows: const [7]);

    final single = state.activate(7, SelectionUpdate.single);
    expect(single.selectedKeys, {7});
    expect(single.cursorKey, 7);
    expect(single.anchorKey, 7);
    expect(single.activate(7, SelectionUpdate.range).selectedKeys, {7});
    expect(single.activate(7, SelectionUpdate.toggle).selectedKeys, isEmpty);
    expect(single.activate(7, SelectionUpdate.toggle).cursorKey, 7);
  });

  test('single selection moves cursor and anchor and drops the rest', () {
    final state = _begin(selected: const [1, 5]).activate(3, SelectionUpdate.single);

    expect(state.selectedKeys, {3});
    expect(state.cursorKey, 3);
    expect(state.anchorKey, 3);
  });

  test('toggle adds and removes without touching other rows', () {
    final on = _begin(selected: const [2]).activate(4, SelectionUpdate.toggle);
    expect(on.selectedKeys, {2, 4});
    expect(on.cursorKey, 4);
    expect(on.anchorKey, 4);

    final off = on.activate(2, SelectionUpdate.toggle);
    expect(off.selectedKeys, {4});
    expect(off.cursorKey, 2);
    expect(off.anchorKey, 2);
  });

  test('range keeps the anchor while extending and shrinking, both directions', () {
    // Forward: anchor 2, extend to 4, shrink to 3, extend past to 5.
    final forward = _begin(selected: const [2]).activate(2, SelectionUpdate.single);
    final extended = forward.activate(4, SelectionUpdate.range);
    final shrunk = extended.activate(3, SelectionUpdate.range);
    final regrown = shrunk.activate(5, SelectionUpdate.range);

    expect(extended.selectedKeys, {2, 3, 4});
    expect(extended.anchorKey, 2);
    expect(shrunk.selectedKeys, {2, 3});
    expect(shrunk.anchorKey, 2);
    expect(regrown.selectedKeys, {2, 3, 4, 5});
    expect(regrown.anchorKey, 2);
    expect(regrown.cursorKey, 5);

    // Backward: anchor 4, target before it.
    final backward = _begin().activate(4, SelectionUpdate.single)
        .activate(2, SelectionUpdate.range);
    expect(backward.selectedKeys, {2, 3, 4});
    expect(backward.cursorKey, 2);
    expect(backward.anchorKey, 4);
  });

  test('range replaces a discontiguous selection with the span', () {
    final state = _begin(selected: const [1, 5]).activate(3, SelectionUpdate.single)
        .activate(5, SelectionUpdate.range);

    // A shift-click recomputes from the anchor; row 1 does not survive.
    expect(state.selectedKeys, {3, 4, 5});
    expect(state.anchorKey, 3);
  });

  test('range without an anchor adopts the cursor, then degenerates to single', () {
    // Cursor without anchor: an anchored range whose anchor row disappears.
    final cursorOnly = _begin()
        .activate(2, SelectionUpdate.single)
        .activate(5, SelectionUpdate.range)
        .withRows(const [1, 3, 4, 5]);
    expect(cursorOnly.cursorKey, 5);
    expect(cursorOnly.anchorKey, isNull);

    final fromCursor = cursorOnly.activate(3, SelectionUpdate.range);
    expect(fromCursor.selectedKeys, {3, 4, 5});
    expect(fromCursor.cursorKey, 3);
    expect(fromCursor.anchorKey, 5);

    // No anchor and no cursor: the range degenerates to the target row.
    final fromNothing = _begin().activate(4, SelectionUpdate.range);
    expect(fromNothing.selectedKeys, {4});
    expect(fromNothing.cursorKey, 4);
    expect(fromNothing.anchorKey, 4);
  });

  test('an adopted anchor stays stable across repeated ranges', () {
    // Regression (supervisor probe): the first range after anchor pruning
    // must keep one stable endpoint for the whole range sequence — the
    // adopted cursor, not whichever row the cursor last moved to.
    final cursorOnly = _begin()
        .activate(2, SelectionUpdate.single)
        .activate(5, SelectionUpdate.range)
        .withRows(const [1, 3, 4, 5]);

    final extended = cursorOnly.activate(3, SelectionUpdate.range);
    final shrunk = extended.activate(4, SelectionUpdate.range);
    final regrown = shrunk.activate(3, SelectionUpdate.range);
    final backward = regrown.activate(5, SelectionUpdate.range);

    expect(extended.selectedKeys, {3, 4, 5});
    expect(shrunk.selectedKeys, {4, 5});
    expect(regrown.selectedKeys, {3, 4, 5});
    expect(backward.selectedKeys, {5});
    for (final state in [extended, shrunk, regrown, backward]) {
      expect(state.anchorKey, 5);
    }
  });

  test('a no-move range still adopts the cursor as anchor', () {
    final cursorOnly = _begin()
        .activate(2, SelectionUpdate.single)
        .activate(5, SelectionUpdate.range)
        .withRows(const [1, 3, 4, 5]);

    // A range onto the cursor's own row degenerates to that row, but the
    // cursor is still adopted: the next range extends from it.
    final noMove = cursorOnly.activate(5, SelectionUpdate.range);
    expect(noMove.selectedKeys, {5});
    expect(noMove.anchorKey, 5);
    expect(noMove.activate(3, SelectionUpdate.range).selectedKeys, {3, 4, 5});
  });

  test('pruning an adopted anchor drops it like an explicit one', () {
    final adopted = _begin()
        .activate(2, SelectionUpdate.single)
        .activate(5, SelectionUpdate.range)
        .withRows(const [1, 3, 4, 5])
        .activate(3, SelectionUpdate.range)
        .withRows(const [1, 3, 4]);

    // Anchor 5 and cursor 3 both survived; a second pruning of the anchor
    // leaves the cursor alone again, ready to adopt on the next range.
    expect(adopted.selectedKeys, {3, 4});
    expect(adopted.cursorKey, 3);
    expect(adopted.anchorKey, isNull);
    expect(adopted.activate(4, SelectionUpdate.range).selectedKeys, {3, 4});

    final prunedCursor = adopted.withRows(const [1, 4]);
    expect(prunedCursor.cursorKey, isNull);
    expect(prunedCursor.activate(4, SelectionUpdate.range).selectedKeys, {4});
  });

  test('select all and invert complement within rows, keeping position', () {
    final state = _begin(selected: const [2, 4]).activate(2, SelectionUpdate.single)
        .activate(4, SelectionUpdate.toggle);

    final all = state.selectAll();
    expect(all.selectedKeys, {1, 2, 3, 4, 5});
    expect(all.cursorKey, 4);
    expect(all.anchorKey, 4);

    final inverted = all.invert();
    expect(inverted.selectedKeys, isEmpty);
    expect(inverted.cursorKey, 4);
    expect(inverted.anchorKey, 4);
    expect(inverted.invert().selectedKeys, {1, 2, 3, 4, 5});

    expect(state.invert().selectedKeys, {1, 3, 5});
    expect(all.selectAll(), same(all));
  });

  test('reordering rows keeps selected identities, never index-following', () {
    final state = _begin(selected: const [1, 3]).activate(3, SelectionUpdate.single);

    final reordered = state.withRows(const [5, 4, 3, 2, 1]);
    expect(reordered.selectedKeys, {3});
    expect(reordered.cursorKey, 3);
    expect(reordered.anchorKey, 3);

    // A range on the reordered list spans the new order's indices.
    expect(reordered.activate(1, SelectionUpdate.range).selectedKeys, {3, 2, 1});
  });

  test('row replacement prunes selection, cursor, and anchor', () {
    // Toggle keeps row 2 selected while moving cursor and anchor to row 4.
    final state = _begin(selected: const [2, 4]).activate(4, SelectionUpdate.toggle);

    final pruned = state.withRows(const [1, 2, 3]);
    expect(pruned.selectedKeys, {2});
    expect(pruned.cursorKey, isNull);
    expect(pruned.anchorKey, isNull);
  });

  test('equal display names never alias distinct keys', () {
    // Keys are opaque identities; the model never sees display names, so
    // two rows rendered with the same name stay independently selectable.
    const sameName = '/a/report.txt';
    const otherSameName = '/b/report.txt';
    final state = SelectionState<String>.begin(
      rows: const [sameName, otherSameName],
      selectedKeys: const [sameName],
    );

    expect(state.selectedKeys, {sameName});
    final toggled = state.activate(otherSameName, SelectionUpdate.toggle);
    expect(toggled.selectedKeys, {sameName, otherSameName});
    expect(toggled.activate(sameName, SelectionUpdate.toggle).selectedKeys,
        {otherSameName});
  });

  test('duplicate row identities are rejected at begin and at replacement', () {
    expect(() => SelectionState<int>.begin(rows: const [1, 1]),
        throwsArgumentError);
    expect(() => _begin().withRows(const [3, 3]), throwsArgumentError);
  });

  test('unknown targets and snapshot keys are rejected explicitly', () {
    final state = _begin(selected: const [2]);

    expect(() => state.activate(9, SelectionUpdate.single), throwsArgumentError);
    expect(() => state.activate(9, SelectionUpdate.toggle), throwsArgumentError);
    expect(() => state.activate(9, SelectionUpdate.range), throwsArgumentError);
    expect(() => state.withSelectedKeys(const [2, 9]), throwsArgumentError);
    expect(() => SelectionState.begin(rows: _rows, selectedKeys: const [9]),
        throwsArgumentError);
  });

  test('withSelectedKeys copies the snapshot and keeps the cursor', () {
    final keys = [1, 4];
    final state = _begin(selected: const [2]).activate(2, SelectionUpdate.single)
        .withSelectedKeys(keys);
    keys.clear();

    expect(state.selectedKeys, {1, 4});
    expect(state.cursorKey, 2);
    expect(state.anchorKey, 2);
  });

  test('QuickSelectState confirmed and cancelled selections apply as snapshots', () {
    const names = {1: 'report.txt', 2: 'report.csv', 3: 'notes.txt'};
    final session = QuickSelectState<int>.begin(
      namesByKey: names,
      selectedKeys: const [3],
    );

    final confirmed = _begin(selected: const [3])
        .withSelectedKeys(session.changeQuery('report').confirm().selectedKeys);
    expect(confirmed.selectedKeys, {1, 2, 3});

    final cancelled = _begin(selected: const [3])
        .withSelectedKeys(session.changeQuery('report').cancel().selectedKeys);
    expect(cancelled.selectedKeys, {3});

    // The session's contract: cancel before replacing rows, then prune.
    expect(cancelled.withRows(const [1, 2]).selectedKeys, isEmpty);
    expect(confirmed.withRows(const [3]).selectedKeys, {3});
  });
}
