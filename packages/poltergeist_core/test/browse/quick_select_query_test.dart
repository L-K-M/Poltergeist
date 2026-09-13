import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

void main() {
  final cases = <({String query, String name, bool matches})>[
    (query: '', name: '', matches: false),
    (query: '', name: 'report.txt', matches: false),
    (query: 'port', name: 'report.txt', matches: true),
    (query: 'report.txt', name: 'report.txt', matches: true),
    (query: 'reports', name: 'report.txt', matches: false),
    (query: 'directory', name: 'report.txt', matches: false),
    (query: ' ', name: 'two words.txt', matches: true),
    (query: ' report ', name: 'report.txt', matches: false),
    (query: '?', name: 'question?.txt', matches: true),
    (query: '?', name: 'question.txt', matches: false),
    (query: '[a-z]', name: 'literal[a-z].txt', matches: true),
    (query: '[a-z]', name: 'letter.txt', matches: false),
    (query: r'\', name: r'literal\name', matches: true),
    (query: r'\', name: 'literal/name', matches: false),
    (query: r'.+$^(){}|', name: r'literal.+$^(){}|name', matches: true),
    (query: '*', name: '', matches: true),
    (query: '*', name: 'report.txt', matches: true),
    (query: '**', name: '.hidden', matches: true),
    (query: '*.txt', name: 'report.txt', matches: true),
    (query: '*.txt', name: '.hidden.txt', matches: true),
    (query: '*.txt', name: '.txt', matches: true),
    (query: '*.txt', name: 'report.txt.bak', matches: false),
    (query: '*.txt', name: 'reportxtxt', matches: false),
    (query: 'report*', name: 'report.txt', matches: true),
    (query: 'report*', name: 'old-report.txt', matches: false),
    (query: '*port*', name: 'report.txt', matches: true),
    (query: 'r*t', name: 'report.txt', matches: true),
    (query: 'r*t', name: 'old-report.txt', matches: false),
    (query: 'r*t', name: 'report.txt.bak', matches: false),
    (query: 'a*b', name: 'ab', matches: true),
    (query: 'a*b', name: 'abxb', matches: true),
    (query: 'a*a', name: 'a', matches: false),
    (query: 'aba*aba', name: 'ababa', matches: false),
    (query: 'aba*aba', name: 'abaaba', matches: true),
    (query: '*ab*ab', name: 'abab', matches: true),
    (query: '*ab*ab', name: 'ab', matches: false),
    (query: '*ab*bc', name: 'abc', matches: false),
    (query: 'a*b*c', name: 'axbyczc', matches: true),
    (query: 'a*b*c', name: 'axcbyc', matches: true),
    (query: 'a*b*c', name: 'axcyb', matches: false),
    (query: 'a*b*c', name: 'axbyd', matches: false),
    (query: 'a?*b', name: 'a?middleb', matches: true),
    (query: 'a?*b', name: 'axmiddleb', matches: false),
    (query: '[*]', name: '[literal]', matches: true),
    (query: '[*]', name: 'literal', matches: false),
    (query: r'\*', name: r'\literal', matches: true),
    (query: r'\*', name: '*', matches: false),
    (query: '* *', name: 'two words', matches: true),
    (query: '* *', name: 'two-words', matches: false),
    (query: 'REPORT', name: 'report.txt', matches: true),
    (query: '*.TXT', name: 'report.txt', matches: true),
    (query: 'Σ', name: 'final-ς.txt', matches: true),
    (query: 'ſ', name: 'S.txt', matches: true),
    (query: 'ẞ', name: 'straße.txt', matches: true),
    (query: 'SS', name: 'straße.txt', matches: false),
    (query: 'I', name: 'file.txt', matches: true),
    (query: 'i', name: 'İ.txt', matches: false),
    (query: 'i', name: 'ı.txt', matches: false),
    (query: 'É', name: 'café.txt', matches: true),
    (query: 'cafe', name: 'café.txt', matches: false),
    (query: 'é', name: 'cafe\u0301.txt', matches: false),
    (query: '*é', name: 'cafe\u0301', matches: false),
    (query: '\u{10400}', name: '\u{10428}.txt', matches: true),
    (query: '\u{10400}*😀', name: '\u{10428}中😀', matches: true),
    (query: '😀*中', name: '😀中', matches: true),
    (query: '😀*中', name: '😀🦇中', matches: true),
    (query: '😀*😀', name: '😀', matches: false),
    (query: '�', name: 'valid-�.txt', matches: true),
  ];

  for (final fixture in cases) {
    test('query ${fixture.query} against ${fixture.name}', () {
      expect(
        QuickSelectQuery(fixture.query).matches(fixture.name),
        fixture.matches,
      );
    });
  }

  test('consecutive stars are equivalent everywhere in a pattern', () {
    for (final query in ['*', '*ab', 'ab*', 'a*b*c', '*ab*ab*']) {
      final single = QuickSelectQuery(query);
      final repeated = QuickSelectQuery(query.replaceAll('*', '***'));
      for (final name in ['', 'ab', 'abab', 'abc', 'axbyc', 'zabzabz']) {
        expect(
          repeated.matches(name),
          single.matches(name),
          reason: '$query against $name',
        );
      }
    }
  });

  test('repetitive patterns finish without combinatorial wildcard search', () {
    const repetitions = 2000;
    final query = QuickSelectQuery('${'a*' * repetitions}b*c');
    final prefix = 'a' * (repetitions * 2);

    expect(query.matches('${prefix}bc'), isTrue);
    expect(query.matches('${prefix}dc'), isFalse);
    expect(QuickSelectQuery('*' * repetitions).matches(prefix), isTrue);
  });

  test('a compiled query is reusable without retaining match position', () {
    final query = QuickSelectQuery('*ab*ab');

    expect(query.matches('zabzab'), isTrue);
    expect(query.matches('ab'), isFalse);
    expect(query.matches('abab'), isTrue);
  });
}
