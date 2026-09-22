/// Quick Open's fuzzy match (02 §8.4): a subsequence match with
/// word-boundary and run bonuses. Deterministic — equal scores keep
/// the source order so section ordering stays stable.
library;

/// Scores [query] against [candidate], or returns null when the query
/// is not a subsequence. Higher is better; an empty query matches
/// everything at score 0.
int? quickOpenScore(String query, String candidate) {
  if (query.isEmpty) return 0;
  final q = query.toLowerCase();
  final c = candidate.toLowerCase();
  var score = 0;
  var qi = 0;
  var lastMatch = -2; // -2 = no run yet; -1 can never be consecutive
  for (var ci = 0; ci < c.length && qi < q.length; ci++) {
    if (c.codeUnitAt(ci) != q.codeUnitAt(qi)) continue;
    score += 1;
    // Word boundary: start of string, after a separator, or a
    // camelCase hump — the chars users actually type to reach a row.
    // The probe reads the ORIGINAL candidate (camelCase needs the case
    // that toLowerCase erased), so it only applies when lowercasing
    // didn't drift the length — e.g. U+0130 lowercases to two chars,
    // which would misalign ci against candidate.
    if (ci == 0 ||
        (candidate.length == c.length && _isBoundary(candidate, ci))) {
      score += 8;
    }
    if (lastMatch == ci - 1) score += 4; // consecutive run
    lastMatch = ci;
    qi++;
  }
  if (qi < q.length) return null;
  // Shorter candidates rank tighter matches ahead.
  return score - c.length ~/ 16;
}

/// The separator/camel rule above: space, punctuation, and path
/// separators all start a new word, as does an uppercase letter
/// following a lowercase one.
bool _isBoundary(String candidate, int index) {
  final prev = candidate.codeUnitAt(index - 1);
  final ch = candidate.codeUnitAt(index);
  const separators = ' -_./\\:;()[]{}';
  if (separators.contains(String.fromCharCode(prev))) return true;
  final prevLower = prev >= 0x61 && prev <= 0x7a;
  final chUpper = ch >= 0x41 && ch <= 0x5a;
  return prevLower && chUpper;
}

/// Filters and ranks [items] by [textOf], returning the matched rows
/// best-first with ties in source order.
List<T> quickOpenFilter<T>(
  String query,
  Iterable<T> items,
  String Function(T item) textOf,
) {
  if (query.isEmpty) return items.toList(growable: false);
  final scored = <(int, int, T)>[];
  var index = 0;
  for (final item in items) {
    final score = quickOpenScore(query, textOf(item));
    if (score != null) scored.add((score, index, item));
    index++;
  }
  scored.sort((a, b) {
    final byScore = b.$1.compareTo(a.$1);
    return byScore != 0 ? byScore : a.$2.compareTo(b.$2);
  });
  return [for (final entry in scored) entry.$3];
}
