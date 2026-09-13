import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:intl/intl.dart';

/// Presentation formatting for pane rows (02 §2.3's rendering rules,
/// foundation subset). The literals here are technical (units, the
/// unevaluated dash), reviewed per file in the localization contract.
const _byteUnits = ['B', 'KB', 'MB', 'GB', 'TB'];
const _unevaluated = '—';

/// Decimal size for macOS/Linux, binary for Windows — the platform file
/// managers' convention (02 §2.3). The Linux decimal/binary preference
/// setting lands with the settings slice.
String formatPaneSize(int? bytes, {required TargetPlatform platform}) {
  if (bytes == null) return _unevaluated;
  final divisor = platform == TargetPlatform.windows ? 1024.0 : 1000.0;
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= divisor && unit < _byteUnits.length - 1) {
    value /= divisor;
    unit++;
  }
  if (unit == 0) return '$bytes ${_byteUnits[0]}';
  // Round numerically first so renormalization never depends on parsing
  // the formatted text (a later locale-aware formatter must not be able
  // to break the loop on comma decimals).
  double rounded() => value >= 10
      ? value.roundToDouble()
      : (value * 10).roundToDouble() / 10;
  var text = value.toStringAsFixed(value >= 10 ? 0 : 1);
  // Rounding can push the mantissa back up to the divisor (999.999 KB
  // rounds to "1000 KB"); renormalize so a boundary value renders as
  // the next unit, like Finder/Explorer.
  while (rounded() >= divisor && unit < _byteUnits.length - 1) {
    unit++;
    value /= divisor;
    text = value.toStringAsFixed(value >= 10 ? 0 : 1);
  }
  if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  return '$text ${_byteUnits[unit]}';
}

/// Modified-time text: relative for today/yesterday, absolute otherwise
/// (02 §2.3). Links and unevaluated sizes carry null metadata — the dash.
String formatPaneModified(
  DateTime? modified, {
  required DateTime now,
  required String localeName,
  required String Function(String time) today,
  required String Function(String time) yesterday,
}) {
  if (modified == null) return _unevaluated;
  final localModified = modified.toLocal();
  final localNow = now.toLocal();
  final dayStart = DateTime(localNow.year, localNow.month, localNow.day);
  final time = DateFormat.jm(localeName).format(localModified);
  if (!localModified.isBefore(dayStart)) {
    // Same calendar day → "today"; genuinely future mtimes (clock skew,
    // migrated archives) fall through to the absolute format rather
    // than reading as today.
    final nextDayStart = DateTime(
      localNow.year,
      localNow.month,
      localNow.day + 1,
    );
    return localModified.isBefore(nextDayStart)
        ? today(time)
        : DateFormat.yMd(localeName).add_jm().format(localModified);
  }
  // Calendar-day arithmetic, not 24-hour subtraction: across a DST
  // transition, midnight minus 24h lands at 23:00 or 01:00 of the
  // previous day (Dart normalizes out-of-range day components).
  if (!localModified
      .isBefore(DateTime(localNow.year, localNow.month, localNow.day - 1))) {
    return yesterday(time);
  }
  return DateFormat.yMd(localeName)
      .add_jm()
      .format(localModified);
}
