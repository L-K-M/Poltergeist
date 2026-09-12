part 'unicode_simple_fold_data.dart';

const _asciiUpperA = 0x41;
const _asciiUpperZ = 0x5a;
const _asciiLowerOffset = 0x20;
const _asciiMaximum = 0x7f;

/// Unicode 17.0.0 simple folding, independent of platform and Dart's tables.
///
/// Uses CaseFolding.txt statuses C and S only. It neither normalizes text nor
/// expands letters (ß stays ß); Turkic tailoring is excluded (İ stays İ).
String simpleCaseFold(String value) {
  final result = StringBuffer();
  for (final point in value.runes) {
    result.writeCharCode(_foldCodePoint(point));
  }
  return result.toString();
}

int _foldCodePoint(int point) {
  // Most filenames need only the fixed ASCII mapping.
  if (point <= _asciiMaximum) {
    return point >= _asciiUpperA && point <= _asciiUpperZ
        ? point + _asciiLowerOffset
        : point;
  }

  var lower = 0;
  var upper = _foldRanges.length - 1;
  while (lower <= upper) {
    final middle = (lower + upper) ~/ 2;
    final range = _foldRanges[middle];
    if (point < range.start) {
      upper = middle - 1;
      continue;
    }
    if (point > range.end) {
      lower = middle + 1;
      continue;
    }

    // Alternating uppercase/lowercase runs leave the intervening letters alone.
    return (point - range.start) % range.stride == 0
        ? point + range.delta
        : point;
  }
  return point;
}
