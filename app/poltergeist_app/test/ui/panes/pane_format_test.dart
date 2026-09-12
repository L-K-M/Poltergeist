import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:poltergeist_app/ui/panes/pane_format.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en'));
  group('formatPaneSize', () {
    test('bytes render bare, mantissas trim their trailing zero', () {
      expect(
        formatPaneSize(512, platform: TargetPlatform.linux),
        '512 B',
      );
      expect(
        formatPaneSize(2048, platform: TargetPlatform.linux),
        '2 KB',
      );
      expect(
        formatPaneSize(1500, platform: TargetPlatform.linux),
        '1.5 KB',
      );
    });

    test('decimal units on macOS/Linux, binary on Windows', () {
      expect(
        formatPaneSize(1 << 20, platform: TargetPlatform.linux),
        '1 MB',
      );
      // 1 MiB is 1.048576 MB decimal — still "1 MB" at one decimal.
      expect(
        formatPaneSize(1 << 20, platform: TargetPlatform.windows),
        '1 MB',
      );
      expect(
        formatPaneSize(10 * 1000 * 1000, platform: TargetPlatform.macOS),
        '10 MB',
      );
      expect(
        formatPaneSize(10 * 1024 * 1024, platform: TargetPlatform.windows),
        '10 MB',
      );
    });

    test('rounding never renders the divisor as a mantissa', () {
      // 999999 B decimal is 999.999 KB — rounds to the next unit, so it
      // must read "1 MB", never "1000 KB".
      expect(
        formatPaneSize(999999, platform: TargetPlatform.macOS),
        '1 MB',
      );
      // 1048575 B binary is 1023.999 KiB — likewise.
      expect(
        formatPaneSize(1048575, platform: TargetPlatform.windows),
        '1 MB',
      );
    });

    test('null renders the unevaluated dash', () {
      expect(formatPaneSize(null, platform: TargetPlatform.linux), '—');
    });
  });

  group('formatPaneModified', () {
    final now = DateTime(2026, 9, 15, 10, 0);

    test('today and yesterday render relative', () {
      expect(
        formatPaneModified(
          DateTime(2026, 9, 15, 14, 32),
          now: now,
          localeName: 'en',
          today: (t) => 'T($t)',
          yesterday: (t) => 'Y($t)',
        ),
        startsWith('T('),
      );
      expect(
        formatPaneModified(
          DateTime(2026, 9, 14, 23, 0),
          now: now,
          localeName: 'en',
          today: (t) => 'T($t)',
          yesterday: (t) => 'Y($t)',
        ),
        startsWith('Y('),
      );
    });

    test('older dates render absolute; null renders the dash', () {
      expect(
        formatPaneModified(
          DateTime(2026, 9, 10, 14, 32),
          now: now,
          localeName: 'en',
          today: (t) => 'T($t)',
          yesterday: (t) => 'Y($t)',
        ),
        contains('9/10/2026'),
      );
      expect(
        formatPaneModified(
          null,
          now: now,
          localeName: 'en',
          today: (t) => 'T($t)',
          yesterday: (t) => 'Y($t)',
        ),
        '—',
      );
    });

    // DST-boundary coverage is untestable in this container (fixed UTC
    // zone; the boundary fix uses calendar-day arithmetic by
    // construction).
  });
}
