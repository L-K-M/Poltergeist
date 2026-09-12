Unicode 17.0.0 simple case folding uses `CaseFolding.txt` statuses C and S.
F expansions and T tailoring are excluded. Unlisted code points stay unchanged.

Sources, retrieved 2026-09-12:

- [CaseFolding.txt](https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt)
- [Unicode license](https://www.unicode.org/license.txt), retained in `LICENSE.txt`

The package-level `LICENSE` includes the Unicode notice for bundled clients.

The fixture is verbatim. Its SHA-256 is
`ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183`.

Regenerate offline from the repository root:

```sh
dart run packages/poltergeist_core/tool/unicode/generate.dart
dart test packages/poltergeist_core/test/browse/unicode_simple_fold_test.dart
```

The generator verifies the source hash, then combines adjacent mappings with
equal offsets at stride 1 or 2. Binary search locates each non-ASCII mapping.
Tests compare every Unicode scalar against the source, including unmapped gaps.
