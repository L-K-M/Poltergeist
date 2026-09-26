/// How one row activation updates the selection — 02 §2.5's gesture family.
enum SelectionUpdate {
  /// A plain click: the selection becomes exactly this row.
  single,

  /// A control/command click: toggles this row, keeping the others.
  toggle,

  /// A shift click or shift-arrow extension: the selection becomes the
  /// contiguous span between the anchor and this row.
  range,
}

/// Immutable pane-row selection state, independent of widgets and I/O.
///
/// The pane supplies the ordered visible row keys; keys are opaque immutable
/// identities (never decoded names or indices), unique within a listing.
/// Every transition copies its inputs and exposes only unmodifiable
/// snapshots, so a returned state never changes under the caller.
///
/// Cursor and anchor are tracked as identities, so reordering or replacing
/// rows can never move the selection onto a different row: [withRows] prunes
/// missing keys, and a pruned cursor or anchor becomes null (the pane re-seeds
/// on the next interaction, like the existing cursor convention).
///
/// Anchor semantics (standard file-manager behavior, pinned by tests):
/// the anchor is the last non-range activation's row, or a cursor adopted
/// by a range when pruning removed the explicit one; [SelectionUpdate.range]
/// always preserves it while extending or shrinking the span, and recomputes
/// the whole selection from it. A range with no anchor adopts the cursor as
/// the anchor, so a sequence of ranges keeps one stable endpoint even after
/// row replacement pruned the explicit anchor (an adopted anchor then behaves
/// exactly like an explicit one); with neither cursor nor anchor, it
/// degenerates to a single selection of the target.
///
/// Quick Select hands its confirmed or restored selection over through
/// [withSelectedKeys] — on the same listing, per that session's contract;
/// row replacement afterwards goes through [withRows], which prunes.
final class SelectionState<Key extends Object> {
  /// Starts a selection over [rows] (the caller's ordered visible rows).
  /// Throws [ArgumentError] on duplicate row identities or selected keys
  /// that are not rows.
  factory SelectionState.begin({
    required Iterable<Key> rows,
    Iterable<Key> selectedKeys = const [],
  }) {
    final rowList = List<Key>.of(rows);
    _rejectDuplicates(rowList);

    final selection = Set<Key>.of(selectedKeys);
    final rowSet = rowList.toSet();
    for (final key in selection) {
      if (!rowSet.contains(key)) {
        throw ArgumentError.value(key, 'selectedKeys', 'not a visible row');
      }
    }
    return SelectionState._(rows: rowList, selection: selection);
  }

  // Not const: fields come from runtime collections, and the memoized
  // snapshots below need deferred initialization.
  SelectionState._({
    required this._rows,
    required this._selection,
    this.cursorKey,
    this.anchorKey,
  });

  final List<Key> _rows;
  final Set<Key> _selection;
  final Key? cursorKey;
  final Key? anchorKey;

  // Memoized unmodifiable snapshots: one copy per state, not per access —
  // widgets read these on every build once pane wiring adopts the model.
  /// The ordered visible rows, unmodifiable (one snapshot per state).
  late final List<Key> rows = List.unmodifiable(_rows);

  /// The selected row identities, unmodifiable (one snapshot per state).
  late final Set<Key> selectedKeys = Set.unmodifiable(_selection);

  /// Applies one row activation (click, toggle, or range extension).
  /// Throws [ArgumentError] if [key] is not a visible row.
  SelectionState<Key> activate(Key key, SelectionUpdate update) {
    final index = _indexOf(key);

    switch (update) {
      case SelectionUpdate.single:
        if (cursorKey == key &&
            anchorKey == key &&
            _selection.length == 1 &&
            _selection.contains(key)) {
          return this;
        }
        return SelectionState._(
          rows: _rows,
          selection: {key},
          cursorKey: key,
          anchorKey: key,
        );

      case SelectionUpdate.toggle:
        final selection = Set<Key>.of(_selection);
        if (!selection.remove(key)) selection.add(key);
        return SelectionState._(
          rows: _rows,
          selection: selection,
          cursorKey: key,
          anchorKey: key,
        );

      case SelectionUpdate.range:
        // No anchor yet: extend from the cursor; with neither, select.
        final fallback = anchorKey ?? cursorKey;
        if (fallback == null) {
          return SelectionState._(
            rows: _rows,
            selection: {key},
            cursorKey: key,
            anchorKey: key,
          );
        }

        final anchorIndex = _indexOf(fallback);
        final span = _rows.sublist(
          anchorIndex < index ? anchorIndex : index,
          anchorIndex < index ? index + 1 : anchorIndex + 1,
        );
        // The adopted cursor becomes the recorded anchor so the next range
        // extends or shrinks around the same endpoint, never a moved cursor.
        return SelectionState._(
          rows: _rows,
          selection: Set<Key>.of(span),
          cursorKey: key,
          anchorKey: fallback,
        );
    }
  }

  /// Selects every visible row; the cursor and anchor keep their positions.
  SelectionState<Key> selectAll() {
    if (_selection.length == _rows.length) return this;

    return SelectionState._(
      rows: _rows,
      selection: Set<Key>.of(_rows),
      cursorKey: cursorKey,
      anchorKey: anchorKey,
    );
  }

  /// Replaces the selection with its complement among the visible rows;
  /// the cursor and anchor keep their positions.
  SelectionState<Key> invert() {
    final selection = _rows.where((row) => !_selection.contains(row)).toSet();
    // The complement equals the selection only when there are no rows.
    if (_rows.isEmpty) {
      return this;
    }

    return SelectionState._(
      rows: _rows,
      selection: selection,
      cursorKey: cursorKey,
      anchorKey: anchorKey,
    );
  }

  /// Adopts a selected-key snapshot from outside this model (e.g. Quick
  /// Select's confirmed or restored selection). Every key must be a visible
  /// row — applying a session's result belongs to the listing it was opened
  /// on, per that session's contract; use [withRows] afterwards to prune.
  /// The cursor and anchor keep their positions.
  /// Throws [ArgumentError] on unknown keys.
  SelectionState<Key> withSelectedKeys(Iterable<Key> selectedKeys) {
    final selection = Set<Key>.of(selectedKeys);
    final rowSet = _rows.toSet();
    for (final key in selection) {
      if (!rowSet.contains(key)) {
        throw ArgumentError.value(key, 'selectedKeys', 'not a visible row');
      }
    }

    return SelectionState._(
      rows: _rows,
      selection: selection,
      cursorKey: cursorKey,
      anchorKey: anchorKey,
    );
  }

  /// Replaces the ordered visible rows (navigation, sort, filter, or hidden
  /// policy change). Selection, cursor, and anchor keep their surviving
  /// identities; keys missing from [rows] are pruned, never re-targeted by
  /// index. Throws [ArgumentError] on duplicate row identities.
  SelectionState<Key> withRows(Iterable<Key> rows) {
    final rowList = List<Key>.of(rows);
    _rejectDuplicates(rowList);

    return _withRows(rowList, rowList.toSet());
  }

  SelectionState<Key> _withRows(List<Key> rowList, Set<Key> present) {
    return SelectionState._(
      rows: rowList,
      selection: _selection.where(present.contains).toSet(),
      cursorKey: cursorKey != null && present.contains(cursorKey)
          ? cursorKey
          : null,
      anchorKey: anchorKey != null && present.contains(anchorKey)
          ? anchorKey
          : null,
    );
  }

  bool _sameSelection(SelectionState<Key> other) =>
      cursorKey == other.cursorKey &&
      anchorKey == other.anchorKey &&
      _selection.length == other._selection.length &&
      _selection.containsAll(other._selection);

  // Duplicate identities would make ranges and toggles ambiguous.
  static void _rejectDuplicates(List<Object?> rows) {
    if (rows.length != rows.toSet().length) {
      throw ArgumentError.value(rows, 'rows', 'duplicate row identities');
    }
  }

  int _indexOf(Key key) {
    final index = _rows.indexOf(key);
    if (index < 0) {
      throw ArgumentError.value(key, 'key', 'not a visible row');
    }
    return index;
  }
}

/// Bounded, immutable selection history for one listing owner. Navigation
/// starts a new history; a cancelled navigation can restore this value with
/// its selection snapshot. Neither rows changing nor previews record steps.
final class SelectionHistory<Key extends Object> {
  const SelectionHistory.empty() : _undo = const [], _redo = const [];

  const SelectionHistory._(this._undo, this._redo);

  static const _limit = 100;
  final List<SelectionState<Key>> _undo;
  final List<SelectionState<Key>> _redo;

  bool canUndo(SelectionState<Key> current) =>
      _undo.any((state) => !state._sameSelection(current));

  bool canRedo(SelectionState<Key> current) =>
      _redo.any((state) => !state._sameSelection(current));

  /// Records a user change, preserving redo for true no-ops (including a
  /// repeated range gesture that constructs an equivalent state).
  SelectionHistory<Key> record(
    SelectionState<Key> before,
    SelectionState<Key> after,
  ) {
    if (before._sameSelection(after)) return this;
    return SelectionHistory._(_push(_undo, before), const []);
  }

  ({SelectionHistory<Key> history, SelectionState<Key> selection})? undo(
    SelectionState<Key> current,
  ) {
    final index = _undo.lastIndexWhere((s) => !s._sameSelection(current));
    if (index < 0) return null;
    return (
      history: SelectionHistory._(
        _undo.sublist(0, index),
        _push(_redo, current),
      ),
      selection: _undo[index],
    );
  }

  ({SelectionHistory<Key> history, SelectionState<Key> selection})? redo(
    SelectionState<Key> current,
  ) {
    final index = _redo.lastIndexWhere((s) => !s._sameSelection(current));
    if (index < 0) return null;
    return (
      history: SelectionHistory._(
        _push(_undo, current),
        _redo.sublist(0, index),
      ),
      selection: _redo[index],
    );
  }

  /// Prunes every step immediately so a disappeared row cannot reappear in
  /// an old selection later. All states share one new row list and presence
  /// set during pruning, keeping large directory refreshes bounded.
  SelectionHistory<Key> withRows(Iterable<Key> rows) {
    if (_undo.isEmpty && _redo.isEmpty) return this;
    final rowList = List<Key>.of(rows);
    final present = rowList.toSet();
    return SelectionHistory._(
      [for (final state in _undo) state._withRows(rowList, present)],
      [for (final state in _redo) state._withRows(rowList, present)],
    );
  }

  static List<SelectionState<Key>> _push<Key extends Object>(
    List<SelectionState<Key>> stack,
    SelectionState<Key> state,
  ) => [...stack.skip(stack.length >= _limit ? 1 : 0), state];
}
