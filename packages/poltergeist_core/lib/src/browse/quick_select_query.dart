import 'unicode_simple_fold.dart';

const _wildcard = '*';

/// A compiled basename query for Quick Select (02 §2.5).
///
/// Uses Unicode 17 simple case folding without normalization or accent removal.
/// Only `*` is special: its presence switches literal substring matching to a
/// whole-name glob. Caller supplies eligible names; this cannot identify the
/// invalid-UTF-8 entries that 02 §13 excludes from by-name selection.
/// An empty query matches nothing.
final class QuickSelectQuery {
  QuickSelectQuery(String query)
    : _segments = List.unmodifiable(simpleCaseFold(query).split(_wildcard));

  final List<String> _segments;

  /// Matches the supplied basename without reading or interpreting a path.
  bool matches(String name) {
    final first = _segments.first;
    if (_segments.length == 1 && first.isEmpty) return false;

    final folded = simpleCaseFold(name);
    if (_segments.length == 1) return folded.contains(first);

    final last = _segments.last;
    final suffixStart = folded.length - last.length;
    if (!folded.startsWith(first) ||
        !folded.endsWith(last) ||
        first.length > suffixStart) {
      return false;
    }

    // Reserve the anchored suffix. Earlier occurrences cannot consume it, and
    // choosing each interior segment's first match leaves the most room later.
    var offset = first.length;
    for (var index = 1; index < _segments.length - 1; index++) {
      final segment = _segments[index];
      if (segment.isEmpty) continue;

      final found = folded.indexOf(segment, offset);
      if (found < 0 || found + segment.length > suffixStart) return false;

      offset = found + segment.length;
    }

    return true;
  }
}
