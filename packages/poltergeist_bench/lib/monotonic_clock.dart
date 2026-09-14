import 'dart:io';

const _linuxUptimePath = '/proc/uptime';
const _microsecondDigits = 6;
final _uptimePattern = RegExp(r'^(\d+)(?:\.(\d+))?$');

typedef MonotonicClock = Duration Function();

/// Reads Linux uptime so wall-clock changes cannot extend an evidence budget.
abstract final class HostMonotonicClock {
  static Duration read() {
    if (!Platform.isLinux) {
      throw UnsupportedError('M0 monotonic evidence requires Linux.');
    }
    final uptime = File(
      _linuxUptimePath,
    ).readAsStringSync().trimLeft().split(RegExp(r'\s+')).first;
    final match = _uptimePattern.firstMatch(uptime);
    if (match == null) {
      throw const FormatException('Linux monotonic clock is malformed.');
    }
    final seconds = int.parse(match.group(1)!);
    final fraction = (match.group(2) ?? '')
        .padRight(_microsecondDigits, '0')
        .substring(0, _microsecondDigits);

    return Duration(seconds: seconds, microseconds: int.parse(fraction));
  }
}
