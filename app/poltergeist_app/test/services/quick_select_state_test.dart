import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/quick_select_state.dart';

const _names = {1: 'report.txt', 2: 'report.csv', 3: 'notes.txt', 4: 'archive'};

QuickSelectState<int> _begin() =>
    QuickSelectState.begin(namesByKey: _names, selectedKeys: const [3, 4]);

void main() {
  test('starts open in Add mode with an unchanged selection', () {
    final state = _begin();

    expect(state.phase, QuickSelectPhase.editing);
    expect(state.mode, QuickSelectMode.add);
    expect(state.query, isEmpty);
    expect(state.selectedKeys, {3, 4});
  });

  test('narrowing Add recomputes from the opening selection', () {
    final initial = _begin();
    final broad = initial.changeQuery('report');
    final narrow = broad.changeQuery('*.csv');

    expect(broad.selectedKeys, {1, 2, 3, 4});
    expect(narrow.selectedKeys, {2, 3, 4});
    expect(initial.selectedKeys, {3, 4});
    expect(narrow.changeQuery('').selectedKeys, {3, 4});
    expect(narrow.changeQuery('missing').selectedKeys, {3, 4});
  });

  test('narrowing Remove restores previously matched baseline rows', () {
    final state = _begin().changeMode(QuickSelectMode.remove);
    final broad = state.changeQuery('*');
    final narrow = broad.changeQuery('*.txt');

    expect(broad.selectedKeys, isEmpty);
    expect(narrow.selectedKeys, {4});
    expect(narrow.changeQuery('missing').selectedKeys, {3, 4});
    expect(narrow.changeQuery('').selectedKeys, {3, 4});
  });

  test('mode changes use the baseline and retain the query', () {
    final added = _begin().changeQuery('*.txt');
    final removed = added.changeMode(QuickSelectMode.remove);
    final addedAgain = removed.changeMode(QuickSelectMode.add);

    expect(added.selectedKeys, {1, 3, 4});
    expect(removed.selectedKeys, {4});
    expect(removed.query, '*.txt');
    expect(addedAgain.selectedKeys, {1, 3, 4});
  });

  test('cancel restores exactly the selection before multiple previews', () {
    final state = _begin()
        .changeQuery('report')
        .changeMode(QuickSelectMode.remove)
        .changeQuery('*')
        .cancel();

    expect(state.phase, QuickSelectPhase.cancelled);
    expect(state.selectedKeys, {3, 4});
  });

  test('confirm retains the last preview', () {
    final preview = _begin().changeQuery('*.csv');
    final state = preview.confirm();

    expect(state.phase, QuickSelectPhase.confirmed);
    expect(state.selectedKeys, {2, 3, 4});
    expect(preview.phase, QuickSelectPhase.editing);
  });

  test('terminal states ignore late edits and repeated close actions', () {
    final preview = _begin().changeQuery('report');
    for (final state in [preview.confirm(), preview.cancel()]) {
      expect(state.changeQuery('*'), same(state));
      expect(state.changeMode(QuickSelectMode.remove), same(state));
      expect(state.confirm(), same(state));
      expect(state.cancel(), same(state));
    }
  });

  test('snapshots caller data and exposes only immutable selections', () {
    final names = Map<int, String>.of(_names);
    final selection = [3, 4];
    final state = QuickSelectState.begin(
      namesByKey: names,
      selectedKeys: selection,
    );
    names[1] = 'changed';
    names.clear();
    selection.clear();

    final preview = state.changeQuery('report');
    expect(preview.selectedKeys, {1, 2, 3, 4});
    expect(preview.cancel().selectedKeys, {3, 4});
    for (final snapshot in [
      state,
      preview,
      preview.confirm(),
      preview.cancel(),
    ]) {
      expect(() => snapshot.selectedKeys.clear(), throwsUnsupportedError);
    }
  });

  test('distinct row keys survive identical decoded names', () {
    final state = QuickSelectState.begin(
      namesByKey: const {1: 'same', 2: 'same'},
      selectedKeys: const [1],
    );

    expect(state.changeQuery('same').selectedKeys, {1, 2});
    expect(
      state.changeMode(QuickSelectMode.remove).changeQuery('same').selectedKeys,
      isEmpty,
    );
  });

  test('matching uses names, never the spelling of row keys', () {
    final state = QuickSelectState.begin(
      namesByKey: const {'/report/notes.txt': 'notes.txt'},
      selectedKeys: const <String>[],
    );

    expect(state.changeQuery('report').selectedKeys, isEmpty);
    expect(state.changeQuery('*.TXT').selectedKeys, {'/report/notes.txt'});
  });

  test('only supplied eligible rows can become selected', () {
    final state = QuickSelectState.begin(
      namesByKey: const {1: 'visible', 2: '.revealed', 3: '\uFFFD-valid'},
      selectedKeys: const <int>[],
    );

    expect(state.changeQuery('*').selectedKeys, {1, 2, 3});
    expect(state.changeQuery('\uFFFD').selectedKeys, {3});
  });

  test('preserves manually selected rows excluded from name matching', () {
    // Row 99 models a flagged name: selectable manually, never by its name.
    final state = QuickSelectState.begin(
      namesByKey: _names,
      selectedKeys: const [3, 99],
    );
    final added = state.changeQuery('*');
    final removed = added.changeMode(QuickSelectMode.remove);

    expect(added.selectedKeys, {1, 2, 3, 4, 99});
    expect(added.confirm().selectedKeys, {1, 2, 3, 4, 99});
    expect(removed.selectedKeys, {99});
    expect(removed.confirm().selectedKeys, {99});
    expect(added.cancel().selectedKeys, {3, 99});
    expect(removed.cancel().selectedKeys, {3, 99});
    expect(removed.changeQuery('').selectedKeys, {3, 99});
  });

  test('an empty listing permits previews and either close action', () {
    final state = QuickSelectState<int>.begin(
      namesByKey: const {},
      selectedKeys: const [],
    ).changeQuery('*');

    expect(state.selectedKeys, isEmpty);
    expect(state.confirm().selectedKeys, isEmpty);
    expect(state.cancel().selectedKeys, isEmpty);
  });
}
