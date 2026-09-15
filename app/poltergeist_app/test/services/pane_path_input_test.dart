import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_path_input.dart';

/// The path field's shape check (02 §2.1): resolution rules for local
/// POSIX, Windows local, and remote panes. The seam is pure — the
/// controller never asks the engine to validate.
void main() {
  group('local POSIX', () {
    String? resolve(
      String raw, {
      String? current = '/home/tester',
      String home = '/home/tester',
    }) {
      return resolvePanePathInput(
        raw: raw,
        remote: false,
        currentPath: current,
        homePath: home,
      );
    }

    test('absolute paths pass through, normalized', () {
      expect(resolve('/var/log'), '/var/log');
      expect(resolve('/var//log/'), '/var/log');
      expect(resolve('/var/./log'), '/var/log');
      expect(resolve('/var/log/../tmp'), '/var/tmp');
      expect(resolve('/a/../../b'), '/b', reason: '.. clamps at the root');
      expect(resolve('/'), '/');
    });

    test('~ expands to the channel home', () {
      expect(resolve('~'), '/home/tester');
      expect(resolve('~/docs'), '/home/tester/docs');
      expect(resolve('~/docs/../pix'), '/home/tester/pix');
      // Other-user expansion has no app-side meaning — it needs the
      // engine, so it is an invalid shape, not a silent home.
      expect(resolve('~root'), isNull);
      expect(resolve('~root/x'), isNull);
    });

    test('relative input joins the current location', () {
      expect(resolve('sub'), '/home/tester/sub');
      expect(resolve('sub/deep'), '/home/tester/sub/deep');
      expect(resolve('../sibling'), '/home/sibling');
      expect(resolve('./sub'), '/home/tester/sub');
      expect(resolve('..'), '/home');
    });

    test('relative input without a committed location is invalid', () {
      expect(resolve('sub', current: null), isNull);
      expect(resolve('/abs', current: null), '/abs');
      expect(resolve('~', current: null), '/home/tester');
    });

    test('obviously-invalid shapes never reach the engine', () {
      expect(resolve(''), isNull);
      expect(resolve('   '), isNull);
      expect(resolve('a\nb'), isNull);
      expect(resolve('/x/\ty'), isNull);
    });

    test('a drive-looking name is a legal relative name on POSIX', () {
      // 'C:\x' carries no volume semantics off Windows: the colon and
      // backslash are ordinary filename characters (02 §2.1's drive rule
      // is Windows-local only).
      expect(resolve('C:\\x'), '/home/tester/C:\\x');
      expect(resolve('C:'), '/home/tester/C:');
    });
  });

  group('remote', () {
    String? resolve(String raw, {String? current = '/srv/home'}) {
      return resolvePanePathInput(
        raw: raw,
        remote: true,
        currentPath: current,
        homePath: '/srv/home',
      );
    }

    test('follows POSIX rules against the server home', () {
      expect(resolve('/var/www'), '/var/www');
      expect(resolve('~'), '/srv/home');
      expect(resolve('~/public'), '/srv/home/public');
      expect(resolve('public'), '/srv/home/public');
      expect(resolve('../logs'), '/srv/logs');
      // A drive spec means nothing on the server — but it is still a
      // legal POSIX relative name, matching the local-POSIX treatment.
      expect(resolve('D:\\x'), '/srv/home/D:\\x');
    });
  });

  group('local Windows', () {
    String? resolve(
      String raw, {
      String? current = 'C:\\Users\\tester',
      String home = 'C:\\Users\\tester',
    }) {
      return resolvePanePathInput(
        raw: raw,
        remote: false,
        currentPath: current,
        homePath: home,
      );
    }

    test('drive letters switch volumes (02 §2.1)', () {
      expect(resolve('D:\\'), 'D:\\');
      expect(resolve('D:'), 'D:\\');
      expect(resolve('D:\\games'), 'D:\\games');
      expect(resolve('d:\\games'), 'd:\\games');
      expect(resolve('D:/games'), 'D:\\games',
          reason: 'forward slashes normalize to the volume separator');
    });

    test('UNC paths need a server AND a share', () {
      expect(resolve('\\\\nas\\media'), '\\\\nas\\media');
      expect(resolve('\\\\nas\\media\\4k'), '\\\\nas\\media\\4k');
      expect(resolve('\\\\nas'), isNull,
          reason: 'a bare server names no listable share');
      expect(resolve('\\\\'), isNull);
      expect(resolve('\\\\nas\\media\\..'), isNull,
          reason: 'popping above the share root leaves no UNC');
    });

    test('~ and relative input join their anchors', () {
      expect(resolve('~'), 'C:\\Users\\tester');
      expect(resolve('~\\docs'), 'C:\\Users\\tester\\docs');
      expect(resolve('~/docs'), 'C:\\Users\\tester\\docs');
      expect(resolve('sub'), 'C:\\Users\\tester\\sub');
      expect(resolve('..\\other'), 'C:\\Users\\other');
    });

    test('drive-relative and root-relative input is invalid', () {
      // 'C:name' is relative to drive C's private cwd — no such state
      // exists app-side; '\name' names no volume.
      expect(resolve('C:name'), isNull);
      expect(resolve('\\name'), isNull);
      expect(resolve('/'), isNull);
      expect(resolve('C:', current: null), 'C:\\',
          reason: 'a drive root needs no current location');
      expect(resolve('sub', current: null), isNull);
    });

    test('UNC homes normalize relative joins onto the share', () {
      expect(
        resolve('sub', current: '\\\\nas\\media', home: '\\\\nas\\media'),
        '\\\\nas\\media\\sub',
      );
      expect(
        resolve('..', current: '\\\\nas\\media', home: '\\\\nas\\media'),
        isNull,
        reason: 'above the share root there is no listable path',
      );
    });
  });
}
