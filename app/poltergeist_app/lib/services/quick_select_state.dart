import 'package:poltergeist_core/poltergeist_core.dart';

enum QuickSelectMode { add, remove }

enum QuickSelectPhase { editing, confirmed, cancelled }

/// One Quick Select preview session, independent of widgets and filesystem I/O.
///
/// The pane supplies visible, name-matchable rows and immutable keys unique
/// within that listing. Names alone are not identities. Manually selected rows
/// excluded from name matching stay in the baseline and survive both modes.
/// Invalid-UTF-8 exclusion requires the metadata tracked in docs/STATUS.md
/// item 13 before UI wiring.
/// The pane must cancel before replacing its listing or visibility policy, then
/// prune selection against the new rows; this snapshot never follows refreshes.
final class QuickSelectState<Key extends Object> {
  factory QuickSelectState.begin({
    required Map<Key, String> namesByKey,
    required Iterable<Key> selectedKeys,
  }) {
    final names = Map<Key, String>.unmodifiable(namesByKey);
    final selection = Set<Key>.unmodifiable(selectedKeys);
    return QuickSelectState._(
      names: names,
      baseline: selection,
      selectedKeys: selection,
      query: '',
      mode: QuickSelectMode.add,
      phase: QuickSelectPhase.editing,
    );
  }

  const QuickSelectState._({
    required this._names,
    required this._baseline,
    required this.selectedKeys,
    required this.query,
    required this.mode,
    required this.phase,
  });

  final Map<Key, String> _names;
  final Set<Key> _baseline;
  final Set<Key> selectedKeys;
  final String query;
  final QuickSelectMode mode;
  final QuickSelectPhase phase;

  QuickSelectState<Key> changeQuery(String value) => _preview(value, mode);

  QuickSelectState<Key> changeMode(QuickSelectMode value) =>
      _preview(query, value);

  QuickSelectState<Key> confirm() => _finish(QuickSelectPhase.confirmed);

  QuickSelectState<Key> cancel() => _finish(QuickSelectPhase.cancelled);

  QuickSelectState<Key> _preview(String query, QuickSelectMode mode) {
    if (phase != QuickSelectPhase.editing) return this;
    if (query == this.query && mode == this.mode) return this;

    // Always start from the opening selection: narrowing must undo old matches.
    final selection = Set<Key>.of(_baseline);
    if (query.isNotEmpty) {
      final matcher = QuickSelectQuery(query);
      for (final row in _names.entries) {
        if (!matcher.matches(row.value)) continue;

        switch (mode) {
          case QuickSelectMode.add:
            selection.add(row.key);
          case QuickSelectMode.remove:
            selection.remove(row.key);
        }
      }
    }

    return QuickSelectState._(
      names: _names,
      baseline: _baseline,
      selectedKeys: Set.unmodifiable(selection),
      query: query,
      mode: mode,
      phase: phase,
    );
  }

  QuickSelectState<Key> _finish(QuickSelectPhase terminalPhase) {
    // Terminal states absorb late field callbacks and repeated close actions.
    if (phase != QuickSelectPhase.editing) return this;

    return QuickSelectState._(
      names: _names,
      baseline: _baseline,
      selectedKeys: terminalPhase == QuickSelectPhase.cancelled
          ? _baseline
          : selectedKeys,
      query: query,
      mode: mode,
      phase: terminalPhase,
    );
  }
}
