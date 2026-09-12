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
  var text = value.toStringAsFixed(value >= 10 ? 0 : 1);
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
  if (!localModified.isBefore(dayStart)) return today(time);
  if (!localModified.isBefore(dayStart.subtract(const Duration(days: 1)))) {
    return yesterday(time);
  }
  return DateFormat.yMd(localeName)
      .add_jm()
      .format(localModified);
}
