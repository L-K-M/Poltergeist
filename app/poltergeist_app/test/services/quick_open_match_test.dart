import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/quick_open_match.dart';

void main() {
  group('quickOpenScore', () {
    test('empty query matches everything at score 0', () {
      expect(quickOpenScore('', 'anything'), 0);
      expect(quickOpenScore('', ''), 0);
    });

    test('a non-subsequence returns null', () {
      expect(quickOpenScore('zzz', 'Open With'), isNull);
      expect(quickOpenScore('longer', 'short'), isNull);
    });

    test('matching is case-insensitive', () {
      expect(quickOpenScore('open', 'Open With'), isNotNull);
      expect(quickOpenScore('OPEN', 'Open With'), isNotNull);
    });

    test('word-boundary hits outrank mid-word hits', () {
      final boundary = quickOpenScore('with', 'Open With')!;
      final midWord = quickOpenScore('wit', 'Twittle')!;
      expect(boundary, greaterThan(midWord));
    });

    test('consecutive runs outrank scattered subsequences', () {
      final run = quickOpenScore('tab', 'New Tab')!;
      // Every letter matches mid-word: no boundary bonuses, no run.
      final scattered = quickOpenScore('tab', 'tall alphabet')!;
      expect(run, greaterThan(scattered));
    });
  });

  group('quickOpenFilter', () {
    test('empty query returns the source order untouched', () {
      final items = ['b', 'a', 'c'];
      expect(quickOpenFilter('', items, (s) => s), items);
    });

    test('drops non-matches and ranks best-first', () {
      final items = ['Copy File', 'New Tab', 'Paste'];
      expect(quickOpenFilter('tab', items, (s) => s), ['New Tab']);
    });

    test('ties keep the source order (stable ranking)', () {
      final items = ['a b', 'a c', 'a d'];
      expect(quickOpenFilter('a', items, (s) => s), items);
    });
  });
}
