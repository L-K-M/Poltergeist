import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/unicode_diacritic_fold.dart';

void main() {
  test('ASCII letters fold case-insensitively', () {
    expect(typeAheadFold('ReadMe.TXT'), 'readme.txt');
  });

  test('composed and decomposed diacritics fold to the same base', () {
    expect(typeAheadFold('Éclair'), 'eclair');
    // NFD form (macOS listings arrive decomposed): e + combining acute.
    expect(typeAheadFold('E\u{301}clair'), 'eclair');
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
    // Every sigma glyph folds to σ: 03F9/03F2 reach it through their
    // <compat> decompositions (03F9 → 03A3, 03F2 → 03C2 — the path the
    // review cluster chased is a decomposition, not a CaseFolding row),
    // so typing any sigma variant matches the others' names.
    expect(typeAheadFold('Ϲ'), 'σ');
    expect(typeAheadFold('ϲ'), 'σ');
    expect(typeAheadFold('Σ'), 'σ');
    expect(typeAheadFold('Ϲ'), typeAheadFold('ς'));
  });

  test('compatibility glyphs fold to their spelled-out forms', () {
    // The fold runs compatibility-level decomposition, so typographic
    // and compatibility forms match their plain keystrokes.
    expect(typeAheadFold('ﬁle'), 'file');
    expect(typeAheadFold('ＦＩＬＥ'), 'file');
    expect(typeAheadFold('²'), '2');
    expect(typeAheadFold('Ⅳ'), 'iv');
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
    expect(typeAheadFold('\u{0915}\u{093F}\u{0932}'), isNot(typeAheadFold('\u{0915}\u{0932}')));
  });

  test('combining marks alone strip to nothing', () {
    expect(typeAheadFold('\u{301}'), '');
    expect(typeAheadFold('é'), 'e');
  });

  test('status-T and status-F mappings never apply', () {
    // Turkic 'I' folds to dotless-ı under T; the default (C) fold is i.
    expect(typeAheadFold('I'), 'i');
    // ß expands only under F (full folding); the simple fold keeps it.
    expect(typeAheadFold('ß'), 'ß');
    // ΐ (0390) likewise expands only under F, but its canonical
    // decomposition strips the marks and leaves the iota.
    expect(typeAheadFold('ΐ'), 'ι');
  });

  test('Cherokee folds follow the official small-to-capital direction', () {
    // Unicode's case fold maps the later-added SMALL Cherokee letters
    // (AB70–ABBF) to the original block (13A0–13EF); the capital block
    // itself has no fold. Pinned so the vendored table's direction is
    // never "corrected" by mistake.
    expect(typeAheadFold('ꭰ'), 'Ꭰ');
    expect(typeAheadFold('Ꭰ'), 'Ꭰ');
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
      'Élan Œuf ḗİ ſeaς כ\u{5B8}\u{5BC}ל 📁',
      'plain-ascii_123',
      '각.txt',
    ]) {
      expect(typeAheadFold(typeAheadFold(sample)), typeAheadFold(sample));
    }
  });

  test('vendored UCD fixtures match their pinned hashes', () {
    // Offline equivalent of an upstream diff: a hand-edited or truncated
    // fixture fails here before the generator ever consumes it.
    for (final (name, expected) in [
      ('UnicodeData-17.0.0.txt',
          '2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c'),
      ('CaseFolding-17.0.0.txt',
          'ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183'),
    ]) {
      final file = File('tool/unicode/$name');
      expect(file.existsSync(), isTrue, reason: '$name must stay vendored');
      expect(sha256.convert(file.readAsBytesSync()).toString(), expected,
          reason: '$name must stay byte-identical to the pinned release');
    }
  });
}
