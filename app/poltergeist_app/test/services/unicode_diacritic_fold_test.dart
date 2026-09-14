import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/unicode_diacritic_fold.dart';

void main() {
  test('ASCII letters fold case-insensitively', () {
    expect(typeAheadFold('ReadMe.TXT'), 'readme.txt');
  });

  test('composed and decomposed diacritics fold to the same base', () {
    expect(typeAheadFold('Éclair'), 'eclair');
    // NFD form (macOS listings arrive decomposed): e + combining acute.
    expect(typeAheadFold('Ećlair'), 'eclair');
    expect(typeAheadFold('Œuvre'), 'œuvre');
    expect(typeAheadFold('ñaño'), 'nano');
  });

  test('recursive decompositions strip every mark', () {
    // 1E17 (e + macron + acute) decomposes through 0113.
    expect(typeAheadFold('ḗ'), 'e');
    // İ (0130) decomposes to I + combining dot, which folds to i.
    expect(typeAheadFold('İ'), 'i');
  });

  test('simple-fold-only letters still fold', () {
    // Long s and final sigma fold under C+S but never lowercase.
    expect(typeAheadFold('ſ'), 's');
    expect(typeAheadFold('ς'), 'σ');
  });

  test('letters without canonical decompositions stay distinct', () {
    // ø and ł are atomic letters (no UnicodeData decomposition), not
    // diacritic variants of o/l — the fold leaves them alone.
    expect(typeAheadFold('ø'), 'ø');
    expect(typeAheadFold('ł'), 'ł');
    expect(typeAheadFold('ø'), isNot('o'));
  });

  test('spacing marks survive — they carry text, not decoration', () {
    // The Devanagari vowel sign ि (Mc) must not strip: folding would
    // otherwise conflate कल and किल.
    expect(typeAheadFold('किल'), isNot(typeAheadFold('कल')));
  });

  test('combining marks alone strip to nothing', () {
    expect(typeAheadFold('́'), '');
    expect(typeAheadFold('é'), 'e');
  });

  test('Hangul syllables decompose to conjoining jamos', () {
    // A precomposed syllable and its jamo sequence fold identically —
    // the decomposed listing form macOS serves still matches.
    expect(typeAheadFold('각'), '각');
    expect(typeAheadFold('각'), typeAheadFold('각'));
  });

  test('non-BMP code points pass through unchanged', () {
    expect(typeAheadFold('📁 dir'), '📁 dir');
  });

  test('folding is idempotent over the whole table', () {
    // Spot-check idempotence plus the identity path: folding twice can
    // never drift (a mark once stripped stays stripped).
    for (final sample in [
      'Élan Œuf ḗİ ſeaς כָּל 📁',
      'plain-ascii_123',
      '각.txt',
    ]) {
      expect(typeAheadFold(typeAheadFold(sample)), typeAheadFold(sample));
    }
  });
}
