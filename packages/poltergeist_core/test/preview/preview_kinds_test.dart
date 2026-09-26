// Contract tests for the preview kind classifier and the cache-key /
// extension-sanitization rules (06 §5.3).

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

void main() {
  group('previewKindForName', () {
    test('classifies by extension case-insensitively', () {
      expect(previewKindForName('notes.txt'), PreviewKind.text);
      expect(previewKindForName('Report.PDF'), PreviewKind.pdf);
      expect(previewKindForName('photo.PNG'), PreviewKind.image);
      expect(previewKindForName('archive.tar.gz'), PreviewKind.metadata);
      expect(previewKindForName('binary.bin'), PreviewKind.metadata);
    });

    test('classifies known text basenames without an extension', () {
      expect(previewKindForName('Makefile'), PreviewKind.text);
      expect(previewKindForName('dockerfile'), PreviewKind.text);
      expect(previewKindForName('.gitignore'), PreviewKind.text);
      expect(previewKindForName('LICENSE'), PreviewKind.text);
    });

    test('dotfiles are not their own extension', () {
      // `.zshrc` is a text basename hit; `.weird` is metadata, and
      // `.env.local` classifies on `local`, not `env`.
      expect(previewKindForName('.zshrc'), PreviewKind.text);
      expect(previewKindForName('.weird'), PreviewKind.metadata);
      expect(previewKindForName('.env.local'), PreviewKind.metadata);
    });

    test('uses only the basename for paths', () {
      expect(
        previewKindForName('/srv/site/index.html'),
        PreviewKind.text,
      );
      expect(
        previewKindForName('/srv/site/avatar.webp'),
        PreviewKind.image,
      );
    });
  });

  group('previewKindCapBytes', () {
    test('images and PDFs carry the 64 MiB kind caps', () {
      expect(
        previewKindCapBytes(PreviewKind.image),
        previewImageKindCapBytes,
      );
      expect(previewKindCapBytes(PreviewKind.pdf), previewPdfKindCapBytes);
      expect(previewImageKindCapBytes, 64 * 1024 * 1024);
    });

    test('text and metadata have no kind cap', () {
      expect(previewKindCapBytes(PreviewKind.text), isNull);
      expect(previewKindCapBytes(PreviewKind.metadata), isNull);
    });
  });

  group('sanitizePreviewExtension', () {
    test('keeps safe extensions with case preserved', () {
      // 06 §5.3: the sanitizer keeps the server's spelling — Quick Look
      // keys type off it and the cache name is never executed.
      expect(sanitizePreviewExtension('PNG'), 'PNG');
      expect(sanitizePreviewExtension('tar'), 'tar');
      expect(sanitizePreviewExtension('a' * 16), 'a' * 16);
    });

    test('drops anything outside the safe pattern', () {
      // Full-match anchoring: a valid slice inside an invalid string
      // must not survive, and the name falls back extensionless.
      expect(sanitizePreviewExtension('a b'), isNull);
      expect(sanitizePreviewExtension('e"xec'), isNull);
      expect(sanitizePreviewExtension('..'), isNull);
      expect(sanitizePreviewExtension(''), isNull);
      expect(sanitizePreviewExtension(null), isNull);
      expect(sanitizePreviewExtension('a' * 17), isNull);
      expect(sanitizePreviewExtension('jpg:x'), isNull);
    });
  });

  group('previewCacheKey', () {
    test('is stable and tuple-sensitive', () {
      final mtime = DateTime.utc(2026, 1, 1, 12);
      final a = previewCacheKey('srv-1', '/x/f.txt', mtime, 10);
      expect(a, previewCacheKey('srv-1', '/x/f.txt', mtime, 10));
      expect(a, isNot(previewCacheKey('srv-2', '/x/f.txt', mtime, 10)));
      expect(a, isNot(previewCacheKey('srv-1', '/x/g.txt', mtime, 10)));
      expect(
        a,
        isNot(
          previewCacheKey(
            'srv-1',
            '/x/f.txt',
            mtime.add(const Duration(seconds: 1)),
            10,
          ),
        ),
      );
      expect(a, isNot(previewCacheKey('srv-1', '/x/f.txt', mtime, 11)));
      expect(a, isNot(previewCacheKey('srv-1', '/x/f.txt', null, 10)));
      // 64-hex sha256 — a safe path component by construction.
      expect(a, matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  test('previewKindIsRenderable enumerates the dispatch table', () {
    expect(previewKindIsRenderable(PreviewKind.text), isTrue);
    expect(previewKindIsRenderable(PreviewKind.image), isTrue);
    expect(previewKindIsRenderable(PreviewKind.pdf), isTrue);
    expect(previewKindIsRenderable(PreviewKind.metadata), isFalse);
    expect(previewKindIsRenderable(PreviewKind.overCacheCap), isFalse);
    expect(previewKindIsRenderable(PreviewKind.overKindCap), isFalse);
  });

  test('executable blocklist pins the spec list and the charset', () {
    // 06 §5.3's membership-pinning rule: the exact Script-Host /
    // control-panel spellings plus the shortcut, installer, and
    // script-hosting types, and every entry must pass the sanitizer
    // charset so the two lists can never drift apart.
    expect(
      previewWindowsExecutableExtensions,
      unorderedEquals(const {
        'bat', 'cmd', 'com', 'scr', 'ps1', 'js', 'jse', 'vbs', 'vbe',
        'wsf', 'wsh', 'hta', 'exe', 'pif', 'scf', 'cpl', 'msp', 'mst',
        'msi', 'lnk', 'url', 'reg', 'chm', 'msc', 'jar', 'vb', 'ws',
        'wsc', 'sct', 'application', 'diagcab', 'py', 'pyw', 'pyz', 'pyzw',
      }),
    );
    for (final ext in previewWindowsExecutableExtensions) {
      expect(
        sanitizePreviewExtension(ext),
        ext,
        reason: '$ext must pass the sanitizer unchanged',
      );
    }
  });

  group('isExecutableLaunchName (06 §5.3 open boundary)', () {
    bool windows(String name) =>
        isExecutableLaunchName(name, host: LaunchHost.windows);
    bool macos(String name) =>
        isExecutableLaunchName(name, host: LaunchHost.macos);
    bool linux(String name) =>
        isExecutableLaunchName(name, host: LaunchHost.linux);

    test('Windows reads the pinned blocklist, case-insensitively', () {
      for (final extension in previewWindowsExecutableExtensions) {
        expect(windows('payload.$extension'), isTrue, reason: extension);
        expect(
          windows('PAYLOAD.${extension.toUpperCase()}'),
          isTrue,
          reason: extension,
        );
      }
      expect(windows('app.JS'), isTrue);
      expect(windows('notes.txt'), isFalse);
      expect(windows('report.pdf'), isFalse);
      expect(windows('a.tar.gz'), isFalse);
    });

    test('only the LAST extension counts', () {
      expect(windows('invoice.pdf.exe'), isTrue);
      expect(windows('invoice.exe.pdf'), isFalse);
      expect(macos('notes.txt.command'), isTrue);
      expect(linux('readme.md.desktop'), isTrue);
    });

    test('trailing dots and spaces strip the way Win32 resolves names', () {
      // `x.hta.` and `x.exe ` launch as `x.hta` / `x.exe` on Windows;
      // the strip applies on every host, where it only errs toward
      // refusing.
      expect(windows('x.hta.'), isTrue);
      expect(windows('x.exe '), isTrue);
      expect(windows('x.exe. . '), isTrue);
      expect(macos('run.command.'), isTrue);
      expect(windows('.'), isFalse);
      expect(windows('trailing.'), isFalse);
    });

    test('names without an extension are never executable types', () {
      expect(windows('Makefile'), isFalse);
      expect(macos('setup'), isFalse);
      expect(linux('install'), isFalse);
      expect(windows(''), isFalse);
    });

    test('a leading dot still names an extension (Windows semantics)', () {
      // Explorer runs a file named `.js` through Script Host — the
      // preview classifier's dotfile rule must not carry over here.
      expect(windows('.js'), isTrue);
      expect(windows('.bashrc'), isFalse);
    });

    test('classifies the last component of a POSIX or Windows path', () {
      expect(windows('/srv/www/app.js'), isTrue);
      expect(windows(r'C:\Users\me\checkouts\0a1b\app.js'), isTrue);
      expect(windows(r'C:\Users\me\app.js\notes.txt'), isFalse);
      expect(macos('/Users/me/Library/checkouts/0a1b/run.command'), isTrue);
    });

    test('macOS refuses its own launch types, not Windows ones', () {
      for (final name in [
        'run.command',
        'build.tool',
        'Shell.terminal',
        'Old.term',
        'Evil.app',
        'Flow.workflow',
        'target.fileloc',
        'target.inetloc',
        'target.webloc',
        'tool.jar',
        'Setup.PKG',
        'Bundle.mpkg',
      ]) {
        expect(macos(name), isTrue, reason: name);
      }
      expect(macos('app.js'), isFalse);
      expect(macos('setup.exe'), isFalse);
      expect(macos('script.sh'), isFalse);
    });

    test('Linux refuses launchers that need no execute bit', () {
      for (final name in ['app.desktop', 'Tool.AppImage', 'tool.jar']) {
        expect(linux(name), isTrue, reason: name);
      }
      expect(linux('script.sh'), isFalse);
      expect(linux('app.js'), isFalse);
      expect(linux('run.command'), isFalse);
    });
  });
}
