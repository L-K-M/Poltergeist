/// Fractional sort keys for manual bookmark ordering (04 §2.5).
///
/// Keys are nonempty strings over `a`–`z` ordered lexicographically, with the
/// record `id` as the deterministic tiebreaker — `sortKeyBetween` is
/// deterministic, so two devices inserting between the same neighbors mint
/// identical keys and a reorder only ever rewrites the moved record (LWW
/// leaves the neighbors untouched).
///
/// The all-`a` strings (`a`, `aa`, …) are reserved as the unreachable lower
/// bound and are never minted: that is what makes head insertion total —
/// `before == null` takes the midpoint between that implicit floor and the
/// current first key, so a key strictly before the first always exists
/// (`b` → `am`, `am` → `ag`, `ag` → `ad`, descending toward but never
/// reaching the floor). `after == null` appends past the last key.
library;

import 'package:seance_core/seance_core.dart' show Bookmark;

const int _a = 0x61; // 'a'
const int _z = 0x7a; // 'z'

/// The alphabet bound used when `after` is absent or exhausted — the top of
/// the `a`–`z` space itself, so an empty store's first mint is `m` and head
/// insertion descends `b` → `am` → `ag` exactly as 04 §2.5 writes it out.
const int _ceiling = _z;

/// Thrown by [sortKeyBetween] when no key in the alphabet sorts strictly
/// between the two neighbors — e.g. `am` and `ama`, where every extension
/// of the shorter key is already ≥ the longer one. Callers treat this as a
/// re-keying trigger (the store re-mints the overflowing item at the tail),
/// never as a decode or write failure.
final class SortKeySpaceExhaustedException implements Exception {
  const SortKeySpaceExhaustedException(this.before, this.after);

  final String? before;
  final String? after;

  @override
  String toString() =>
      'No sortKey exists between ${before ?? 'the floor'} '
      'and ${after ?? 'the ceiling'}';
}

/// Whether [key] has the shape of a minted key: nonempty, `a`–`z` only, and
/// not one of the reserved all-`a` floor strings. Stored keys failing this
/// are interim mints (`sortKey: <uuid>` from the pre-M5 writers) or foreign
/// data; the store re-keys them deterministically rather than letting them
/// break [sortKeyBetween] later.
bool isValidSortKey(String key) {
  if (key.isEmpty) return false;
  var allA = true;
  for (var i = 0; i < key.length; i++) {
    final unit = key.codeUnitAt(i);
    if (unit < _a || unit > _z) return false;
    if (unit != _a) allA = false;
  }
  return !allA;
}

/// The 04 §2.5 ordering: lexicographic `sortKey`, then record `id` as the
/// deterministic tiebreaker so equal keys resolve identically on every
/// device instead of reshuffling across sync rounds.
int compareBookmarkSortKeys(Bookmark a, Bookmark b) {
  final byKey = a.sortKey.compareTo(b.sortKey);
  if (byKey != 0) return byKey;
  return a.id.compareTo(b.id);
}

/// Mints a key sorting strictly between [before] and [after]. Either bound
/// may be null: `before == null` is the all-`a` floor (head insertion),
/// `after == null` the `z` ceiling (tail append).
///
/// Midpoint rule: where the neighbors differ by more than one alphabet
/// position the midpoint char mints the key; otherwise the lower neighbor's
/// char is kept and the next position descends — `append m` when the upper
/// bound runs out (the plan's worked example: `b` → `am`, `am` → `ag`).
///
/// Throws [ArgumentError] on a malformed key (empty or outside `a`–`z`) or
/// an inverted range (`before > after` — a caller bug), and
/// [SortKeySpaceExhaustedException] when no key sorts strictly between the
/// bounds: equal keys — reachable after an LWW merge of two devices'
/// identical deterministic mints, not a caller bug — `after` equal to
/// `before` followed only by `a`s, or an all-`a` [after] at the floor.
String sortKeyBetween(String? before, String? after) {
  if (before != null && !_isAlphabetKey(before)) {
    throw ArgumentError.value(before, 'before', 'not an a–z sortKey');
  }
  if (after != null && !_isAlphabetKey(after)) {
    throw ArgumentError.value(after, 'after', 'not an a–z sortKey');
  }
  if (before != null && after != null) {
    final cmp = before.compareTo(after);
    if (cmp > 0) {
      throw ArgumentError(
        'sortKeyBetween requires before < after: $before vs $after',
      );
    }
    if (cmp == 0) {
      // Duplicate keys are a legitimate post-merge state (two devices
      // minting the same key between the same neighbors): report
      // exhaustion so callers run their re-keying recovery instead of
      // seeing a caller-error ArgumentError they cannot recover from.
      throw SortKeySpaceExhaustedException(before, after);
    }
  }

  final out = StringBuffer();
  var i = 0;
  while (true) {
    // An exhausted `before` behaves as its own `a`-continuation (any
    // extension still sorts after it); an absent or exhausted `after`
    // is the `z` ceiling.
    final lo = (before != null && i < before.length)
        ? before.codeUnitAt(i)
        : _a;
    final hi = (after != null && i < after.length)
        ? after.codeUnitAt(i)
        : _ceiling;
    final gap = hi - lo;
    if (gap > 1) {
      out.writeCharCode(lo + gap ~/ 2);
      break;
    }
    // No room at this position: keep the lower bound's char and descend
    // (the `append m`-equivalent for the ceiling lands on the next loop).
    out.writeCharCode(lo);
    i++;
  }

  final result = out.toString();
  if ((before != null && result.compareTo(before) <= 0) ||
      (after != null && result.compareTo(after) >= 0)) {
    throw SortKeySpaceExhaustedException(before, after);
  }
  return result;
}

bool _isAlphabetKey(String key) {
  if (key.isEmpty) return false;
  for (var i = 0; i < key.length; i++) {
    final unit = key.codeUnitAt(i);
    if (unit < _a || unit > _z) return false;
  }
  return true;
}
