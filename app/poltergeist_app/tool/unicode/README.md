Unicode 17.0.0 type-ahead folding combines canonical decomposition
(`UnicodeData.txt`, field 5 mappings without a `<compat>` tag) with mark
stripping (general categories Mn and Me; spacing marks Mc carry Indic
vowels and are text, not decoration) and simple case folding
(`CaseFolding.txt` statuses C and S — F expansions and T tailoring are
excluded, unlisted code points stay unchanged). Hangul syllable
decomposition is algorithmic (Unicode §3.12), not table-driven, so
UnicodeData's empty Hangul fields are expected.

Sources, retrieved 2026-09-14:

- [UnicodeData.txt](https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt)
- [CaseFolding.txt](https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt)
- [Unicode license](https://www.unicode.org/license.txt), retained in
  `LICENSE.txt`

The fixtures are verbatim. Their SHA-256 digests are
`2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c`
(UnicodeData) and
`ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183`
(CaseFolding).

Regenerate offline from the app directory:

```sh
dart run tool/unicode/generate.dart
flutter test test/services/unicode_diacritic_fold_test.dart
```

The generator verifies both source hashes, then emits one table mapping
each affected code point to its folded replacement (an empty list strips
a mark outright).
