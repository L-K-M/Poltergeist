import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/listing_filter.dart';

void main() {
  group('ListingFilter (02 §2.5)', () {
    test('matches a plain case-insensitive substring', () {
      final filter = ListingFilter('rep');
      expect(filter.matches('report.txt'), isTrue);
      expect(filter.matches('the.REPair.md'), isTrue);
      expect(filter.matches('notes.txt'), isFalse);
    });

    test('case folds both directions', () {
      expect(ListingFilter('TODO').matches('todo.txt'), isTrue);
      expect(ListingFilter('todo').matches('TODO.TXT'), isTrue);
    });

    test('does NOT fold diacritics — the spec separates Filter from '
        'type-ahead', () {
      // 02 §2.5 says "case-insensitive substring" for Filter and never
      // extends §2.5 type-ahead's diacritic folding to it: 'e' must not
      // reach 'Étude' here even though it prefix-matches there.
      final filter = ListingFilter('et');
      expect(filter.matches('Étude.doc'), isFalse);
      expect(filter.matches('étude.doc'), isFalse,
          reason: 'é is not e — folding is type-ahead-only');
      expect(filter.matches('setup.txt'), isTrue,
          reason: 'the same query still matches a plain substring');
      // The accented query still matches the accented row.
      expect(ListingFilter('ét').matches('Étude.doc'), isTrue);
    });

    test('wildcards are ordinary characters — no glob semantics', () {
      // Quick Select's * glob must not leak in: in a filter, '*' only
      // matches a literal asterisk in the name.
      final filter = ListingFilter('*.txt');
      expect(filter.matches('report.txt'), isFalse);
      expect(filter.matches('odd*.txt'), isTrue);
    });

    test('matches on basename only, not the path', () {
      // Callers pass entry.name; the contract keeps parent segments out
      // of reach ('home' must never hit every row).
      final filter = ListingFilter('home');
      expect(filter.matches('report.txt'), isFalse);
    });

    test('an empty query matches everything (the pass-through lens)', () {
      final filter = ListingFilter('');
      expect(filter.matches('anything'), isTrue);
      expect(filter.matches('.dotfile'), isTrue);
    });
  });
}
