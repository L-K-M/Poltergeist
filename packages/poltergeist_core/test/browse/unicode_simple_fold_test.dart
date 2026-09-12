import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_core/src/browse/unicode_simple_fold.dart';
import 'package:test/test.dart';

const _unicodeMaximum = 0x10ffff;
const _surrogateStart = 0xd800;
const _surrogateEnd = 0xdfff;
const _scalarBatchSize = 4096;
const _sourceSha256 =
    'ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183';

void main() {
  test('folds ASCII, Latin, Greek, Cyrillic, Armenian, and Georgian', () {
    expect(simpleCaseFold('File-ÀÉŒ-Σςσ-ЖЙ-ԱԲ-ᲐᲑ'), 'file-àéœ-σσσ-жй-աբ-აბ');
  });

  test('folds supplementary scripts without splitting surrogate pairs', () {
    expect(
      simpleCaseFold('\u{10400}\u{104b0}\u{10c80}\u{1e900}'),
      '\u{10428}\u{104d8}\u{10cc0}\u{1e922}',
    );
  });

  test('Cherokee folds to uppercase, including its lowercase tail', () {
    expect(simpleCaseFold('Ꭰꭰ\u13f0\u13f8'), 'ᎠᎠ\u13f0\u13f0');
  });

  test('folds compatibility letters and capital sharp S', () {
    expect(simpleCaseFold('KKkÅÅſSµΜẞß'), 'kkkååssμμßß');
  });

  test('excludes Turkic tailoring and full multi-character expansions', () {
    expect(simpleCaseFold('Iİıißﬀﬃǰΐ'), 'iİıißﬀﬃǰΐ');
    expect(simpleCaseFold('ẞ'), isNot(simpleCaseFold('SS')));
  });

  test('preserves normalization, uncased text, and unpaired surrogates', () {
    expect(simpleCaseFold('ÉE\u0301中文😀'), 'ée\u0301中文😀');
    expect(simpleCaseFold(''), '');
    expect(simpleCaseFold('\ud800A\udfff'), '\ud800a\udfff');
  });

  test('matches pinned C and S mappings and every unmapped scalar', () async {
    final package = await Isolate.resolvePackageUri(
      Uri.parse('package:poltergeist_core/poltergeist_core.dart'),
    );
    final source = File.fromUri(
      package!.resolve('../tool/unicode/CaseFolding-17.0.0.txt'),
    );
    final bytes = await source.readAsBytes();
    expect(sha256.convert(bytes).toString(), _sourceSha256);

    final mappings = <int, int>{};
    for (final line in await source.readAsLines()) {
      if (line.isEmpty || line.startsWith('#')) continue;

      final fields = line.split(';').map((field) => field.trim()).toList();
      if (fields[1] != 'C' && fields[1] != 'S') continue;

      expect(fields[2].split(' '), hasLength(1));
      mappings[int.parse(fields[0], radix: 16)] = int.parse(
        fields[2],
        radix: 16,
      );
    }
    expect(mappings, hasLength(1512));

    // Check gaps too: compressed ranges must never fold an unlisted scalar.
    for (var start = 0; start <= _unicodeMaximum; start += _scalarBatchSize) {
      final input = StringBuffer();
      final expected = StringBuffer();
      final end = (start + _scalarBatchSize - 1).clamp(0, _unicodeMaximum);
      for (var point = start; point <= end; point++) {
        if (point >= _surrogateStart && point <= _surrogateEnd) continue;

        input.writeCharCode(point);
        expected.writeCharCode(mappings[point] ?? point);
      }
      final folded = simpleCaseFold(input.toString());
      expect(
        folded,
        expected.toString(),
        reason: 'batch U+${start.toRadixString(16)}',
      );
      expect(simpleCaseFold(folded), folded, reason: 'folding is idempotent');
    }
  });
}
