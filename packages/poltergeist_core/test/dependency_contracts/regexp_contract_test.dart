import 'package:test/test.dart';

void main() {
  // Ported patterns must use Dart's option, not a PCRE inline flag (09 §4).
  test('inline case-insensitive flags throw at construction', () {
    // Deliberately invalid: this pins the runtime failure on SDK upgrades.
    // ignore: valid_regexps
    expect(() => RegExp('(?i)password'), throwsFormatException);
  });

  test('caseSensitive option matches mixed-case input', () {
    final pattern = RegExp('password', caseSensitive: false);

    expect(pattern.hasMatch('PaSsWoRd'), isTrue);
    expect(pattern.hasMatch('username'), isFalse);
  });
}
