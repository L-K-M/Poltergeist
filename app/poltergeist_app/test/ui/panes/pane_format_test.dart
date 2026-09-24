import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:poltergeist_app/ui/panes/pane_format.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show RemoteFileEntry, RemoteFileType;

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

  group('formatPosixModeSymbolic', () {
    test('renders the nine rwx positions with file-type bits ignored', () {
      // 0644 regular file, 0755 directory, 0600 with a symlink's 0120000
      // type bits — the render reads only the permission field.
      expect(formatPosixModeSymbolic(0x81A4), 'rw-r--r--');
      expect(formatPosixModeSymbolic(0x41ED), 'rwxr-xr-x');
      expect(formatPosixModeSymbolic(0xA180), 'rw-------');
      expect(formatPosixModeSymbolic(0x1FF), 'rwxrwxrwx');
    });

    test('folds suid, sgid, and sticky into the execute slots', () {
      expect(formatPosixModeSymbolic(0x5ED), 'rwxr-sr-x'); // sgid
      expect(formatPosixModeSymbolic(0x9ED), 'rwsr-xr-x'); // suid
      expect(formatPosixModeSymbolic(0x3ED), 'rwxr-xr-t'); // sticky
      // Special bit without execute renders the capital.
      expect(formatPosixModeSymbolic(0x800), '--S------'); // suid, no x
      expect(formatPosixModeSymbolic(0x200), '--------T'); // sticky, no x
      expect(formatPosixModeSymbolic(0x400), '-----S---'); // sgid, no x
    });
  });

  group('formatPosixModeOctal', () {
    test('renders four digits including the special-bit digit', () {
      expect(formatPosixModeOctal(0x81A4), '0644');
      expect(formatPosixModeOctal(0x41ED), '0755');
      expect(formatPosixModeOctal(0x9ED), '4755');
      expect(formatPosixModeOctal(0x3FF), '1777');
      // Type bits never leak into the display.
      expect(formatPosixModeOctal(0xA1A4), '0644');
      // Type and special bits combined: symlink + suid + 0755.
      expect(formatPosixModeOctal(0xA9ED), '4755');
    });
  });

  group('paneKindCategory (D32 §6 kind glyphs)', () {
    RemoteFileEntry entry(
      String name, [
      RemoteFileType type = RemoteFileType.file,
    ]) => RemoteFileEntry(path: '/x/$name', name: name, type: type);

    test('the file type wins over any extension', () {
      expect(
        paneKindCategory(entry('photos.png', RemoteFileType.directory)),
        PaneKindCategory.folder,
      );
      expect(
        paneKindCategory(entry('latest.zip', RemoteFileType.symbolicLink)),
        PaneKindCategory.link,
      );
    });

    test('extensions map to their family, case-insensitively', () {
      expect(paneKindCategory(entry('IMG_0001.JPG')), PaneKindCategory.image);
      expect(paneKindCategory(entry('main.dart')), PaneKindCategory.text);
      expect(paneKindCategory(entry('notes.md')), PaneKindCategory.text);
      expect(paneKindCategory(entry('site.tar.gz')), PaneKindCategory.archive);
      expect(paneKindCategory(entry('manual.pdf')), PaneKindCategory.pdf);
      expect(paneKindCategory(entry('talk.mp4')), PaneKindCategory.media);
      expect(paneKindCategory(entry('song.flac')), PaneKindCategory.media);
      expect(paneKindCategory(entry('data.bin')), PaneKindCategory.other);
    });

    test('dotfiles and bare names have no extension', () {
      expect(paneKindCategory(entry('.bashrc')), PaneKindCategory.other);
      expect(paneKindCategory(entry('Makefile')), PaneKindCategory.other);
      expect(paneKindCategory(entry('trailing.')), PaneKindCategory.other);
      // A dotfile WITH an extension still classifies by it.
      expect(paneKindCategory(entry('.config.json')), PaneKindCategory.text);
    });
  });
}
