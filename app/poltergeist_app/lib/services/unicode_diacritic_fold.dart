part 'unicode_diacritic_fold_data.dart';

// Unicode §3.12 conjoining-jamo decomposition of precomposed Hangul
// syllables: UnicodeData.txt carries no per-syllable mappings, so the
// fold decomposes them by formula like every normalization form does.
const _hangulSBase = 0xac00;
const _hangulLBase = 0x1100;
const _hangulVBase = 0x1161;
const _hangulTBase = 0x11a7;
const _hangulLCount = 19;
const _hangulVCount = 21;
const _hangulTCount = 28;
const _hangulNCount = _hangulVCount * _hangulTCount;
const _hangulSCount = _hangulLCount * _hangulNCount;

/// The 02 §2.5 type-ahead fold: case- AND diacritic-insensitive.
///
/// Deliberately different from Quick Select's matcher (the core
/// `QuickSelectQuery`), which applies §2.3's simple case fold alone —
/// no normalization, no diacritic stripping. The two semantics are
/// specified apart and stay separate implementations: sharing one
/// matcher would silently trade prefix-jump semantics for fragment/glob
/// selection semantics. This fold runs compatibility-level matching:
/// each code point expands through its full decomposition (canonical
/// AND tagged — ligatures, enclosed and wide/narrow forms, positional
/// presentation forms, and compatibility glyphs like the lunate sigma
/// all reach their spelled-out letters), non-spacing and enclosing
/// marks (Mn/Me) drop while spacing marks stay (Mc carry Indic vowels —
/// text, not decoration), and Unicode 17's simple fold applies last —
/// generated data, `tool/unicode/generate.dart`.
String typeAheadFold(String value) {
  final result = StringBuffer();
  for (final point in value.runes) {
    final mapped = _diacriticFoldTable[point];
    if (mapped != null) {
      _writeFolded(mapped, result);
    } else if (point >= _hangulSBase &&
        point < _hangulSBase + _hangulSCount) {
      _decomposeHangul(point, result);
    } else {
      result.writeCharCode(point);
    }
  }
  return result.toString();
}

/// Deepest chain a verified table can hold; decompose-fold compositions
/// are at most a couple of hops, so eight bounds any honest data while
/// a stale or hand-edited table can never spin the chase forever.
const _maxFoldChase = 8;

/// Writes each emitted code point, chasing any that still names a table
/// entry through it. The generator resolves fold chains to a fixed
/// point and throws if any emitted value remains a table key, so on
/// verified data every lookup below misses — the chase exists so the
/// runtime stays correct even if the committed table regresses.
void _writeFolded(List<int> mapped, StringBuffer out,
    [int depth = 0]) {
  for (final unit in mapped) {
    final next = _diacriticFoldTable[unit];
    if (next != null && depth < _maxFoldChase) {
      _writeFolded(next, out, depth + 1);
    } else {
      out.writeCharCode(unit);
    }
  }
}

void _decomposeHangul(int syllable, StringBuffer out) {
  final sIndex = syllable - _hangulSBase;
  out
    ..writeCharCode(_hangulLBase + sIndex ~/ _hangulNCount)
    ..writeCharCode(
      _hangulVBase + (sIndex % _hangulNCount) ~/ _hangulTCount,
    );
  final tIndex = sIndex % _hangulTCount;
  if (tIndex != 0) out.writeCharCode(_hangulTBase + tIndex);
}
