import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

// 04 §2.5's ordering contract: fractional sortKeys over `a`–`z`, the all-`a`
// strings reserved as the unreachable lower bound, `sortKeyBetween` minting
// strictly-between keys so a reorder only ever rewrites the moved record.
// The comparator's id tiebreak keeps same-key pairs in one stable order on
// every device.
Bookmark _bookmark(String id, String sortKey) => Bookmark(
      id: id,
      kind: BookmarkKind.localFolder,
      label: id,
      localPath: '/tmp/$id',
      sortKey: sortKey,
      createdAt: DateTime.utc(2026, 9, 19, 8),
      updatedAt: DateTime.utc(2026, 9, 19, 8),
    );

void main() {
  group('sortKeyBetween', () {
    test('mints the middle key for an empty space', () {
      expect(sortKeyBetween(null, null), 'm');
    });

    test('mints the documented head-insertion sequence', () {
      // The plan's worked example (04 §2.5): descending toward — never
      // reaching — the all-`a` floor.
      expect(sortKeyBetween(null, 'b'), 'am');
      expect(sortKeyBetween(null, 'am'), 'ag');
      expect(sortKeyBetween(null, 'ag'), 'ad');
    });

    test('mints strictly-between keys for adjacent and spread neighbors', () {
      expect(sortKeyBetween('a', 'c'), 'b');
      expect(sortKeyBetween('m', 'n'), 'mm');
      expect(sortKeyBetween('am', 'an'), 'amm');
      expect(sortKeyBetween('g', 's'), 'm');
    });

    test('appends past the last key for tail insertion', () {
      final key = sortKeyBetween('hm', null);
      expect(key.compareTo('hm') > 0, isTrue);

      // Tail insertion stays possible past 'z' too — the key extends
      // instead of colliding.
      final pastZ = sortKeyBetween('z', null);
      expect(pastZ.compareTo('z') > 0, isTrue);
      expect(pastZ.startsWith('z'), isTrue);
    });

    test('repeated head insertion stays ordered and never reaches the floor',
        () {
      var head = sortKeyBetween(null, null);
      final keys = <String>[head];
      for (var i = 0; i < 200; i++) {
        head = sortKeyBetween(null, head);
        expect(head.compareTo(keys.last) < 0, isTrue);
        expect(isValidSortKey(head), isTrue);
        keys.add(head);
      }
      expect(keys.toSet(), hasLength(keys.length));
    });

    test('repeated tail insertion stays ordered', () {
      var tail = sortKeyBetween(null, null);
      final keys = <String>[tail];
      for (var i = 0; i < 200; i++) {
        tail = sortKeyBetween(tail, null);
        expect(tail.compareTo(keys.last) > 0, isTrue);
        expect(isValidSortKey(tail), isTrue);
        keys.add(tail);
      }
      expect(keys.toSet(), hasLength(keys.length));
    });

    test('a key between the same neighbors is deterministic', () {
      // 04 §2.5: two devices inserting between the same neighbors mint
      // identical keys, so sync never fights over the collision.
      expect(sortKeyBetween('ag', 'am'), sortKeyBetween('ag', 'am'));
    });

    test('rejects an inverted range as a caller error', () {
      expect(() => sortKeyBetween('b', 'a'), throwsArgumentError);
    });

    test('reports equal keys as exhaustion — a reachable post-merge state',
        () {
      // Two devices minting the same key between the same neighbors is the
      // documented collision, so a pair of duplicate keys is not a caller
      // bug: callers run their re-keying recovery on exhaustion.
      expect(
        () => sortKeyBetween('m', 'm'),
        throwsA(isA<SortKeySpaceExhaustedException>()),
      );
      expect(
        () => sortKeyBetween('am', 'am'),
        throwsA(isA<SortKeySpaceExhaustedException>()),
      );
    });

    test('rejects keys outside the a–z alphabet', () {
      expect(() => sortKeyBetween('x1', null), throwsArgumentError);
      expect(() => sortKeyBetween('m', 'x1'), throwsArgumentError);
      expect(() => sortKeyBetween('a-b', null), throwsArgumentError);
      expect(() => sortKeyBetween('M', null), throwsArgumentError);
      expect(() => sortKeyBetween('', null), throwsArgumentError);
    });

    test('throws when no mintable key exists between the neighbors', () {
      // `ama` is the immediate successor of `am` in this alphabet — every
      // extension of `am` is ≥ `ama`, so nothing fits between them.
      expect(
        () => sortKeyBetween('am', 'ama'),
        throwsA(isA<SortKeySpaceExhaustedException>()),
      );
      // Nothing mintable sorts before an all-`a` key either.
      expect(
        () => sortKeyBetween(null, 'aa'),
        throwsA(isA<SortKeySpaceExhaustedException>()),
      );
    });
  });

  group('isValidSortKey', () {
    test('accepts minted-shape keys', () {
      for (final key in ['m', 'am', 'ag', 'q', 'zzzm']) {
        expect(isValidSortKey(key), isTrue, reason: key);
      }
    });

    test('rejects the reserved all-a floor strings', () {
      for (final key in ['a', 'aa', 'aaaa']) {
        expect(isValidSortKey(key), isFalse, reason: key);
      }
    });

    test('rejects empty and non-alphabet keys', () {
      for (final key in ['', 'x1', 'a-b', 'M', 'm m', '0']) {
        expect(isValidSortKey(key), isFalse, reason: key);
      }
    });
  });

  group('compareBookmarkSortKeys', () {
    test('orders by sortKey first', () {
      final a = _bookmark('z', 'am');
      final b = _bookmark('a', 'z');
      expect(compareBookmarkSortKeys(a, b) < 0, isTrue);
      expect(compareBookmarkSortKeys(b, a) > 0, isTrue);
    });

    test('breaks sortKey ties by id — the cross-device stable order', () {
      // 04 §2.5's comparator rule: equal keys resolve by record id so two
      // devices render the same order instead of reshuffling per round.
      final a = _bookmark('aaa', 'm');
      final b = _bookmark('bbb', 'm');
      expect(compareBookmarkSortKeys(a, b) < 0, isTrue);
      expect(compareBookmarkSortKeys(b, a) > 0, isTrue);
      expect(compareBookmarkSortKeys(a, a), 0);
    });
  });
}
