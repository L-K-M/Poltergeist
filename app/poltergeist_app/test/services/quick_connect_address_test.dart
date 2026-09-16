import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/quick_connect_address.dart';

void main() {
  group('bare user@host:port form', () {
    test('parses a full address with port', () {
      final parsed = parseQuickConnectAddress('deploy@example.com:2222');

      expect(parsed.ok, isTrue);
      expect(parsed.target?.username, 'deploy');
      expect(parsed.target?.host, 'example.com');
      expect(parsed.target?.port, 2222);
      expect(parsed.target?.remotePath, isNull);
    });

    test('defaults to port 22 with no token', () {
      final parsed = parseQuickConnectAddress('deploy@example.com');

      expect(parsed.ok, isTrue);
      expect(parsed.target?.port, 22);
      expect(parsed.target?.remotePath, isNull);
      expect(parsed.issues, isEmpty);
    });

    test('in-range numeric token is a port with a visible hint', () {
      final parsed = parseQuickConnectAddress('deploy@example.com:2222');

      expect(parsed.ok, isTrue);
      expect(parsed.target?.port, 2222);
      expect(
        parsed.issues,
        contains(QuickConnectIssue.portAssumed),
      );
    });

    test('a remote start path parses on the default port', () {
      final parsed = parseQuickConnectAddress('deploy@example.com:/srv/www');

      expect(parsed.ok, isTrue);
      expect(parsed.target?.port, 22);
      expect(parsed.target?.remotePath, '/srv/www');
      expect(
        parsed.issues,
        isNot(contains(QuickConnectIssue.portAssumed)),
      );
    });

    test('a dashed token is a path, never a port', () {
      final parsed = parseQuickConnectAddress('deploy@example.com:22-backup');

      expect(parsed.ok, isTrue);
      expect(parsed.target?.port, 22);
      expect(parsed.target?.remotePath, '22-backup');
    });

    test('an out-of-range numeric token parses as a path with a hint', () {
      final parsed = parseQuickConnectAddress('deploy@example.com:99999');

      expect(parsed.ok, isTrue);
      expect(parsed.target?.port, 22);
      expect(parsed.target?.remotePath, '99999');
      expect(
        parsed.issues,
        contains(QuickConnectIssue.pathAssumed),
      );
    });

    test('port zero parses as a path with a hint', () {
      final parsed = parseQuickConnectAddress('deploy@example.com:0');

      expect(parsed.ok, isTrue);
      expect(parsed.target?.port, 22);
      expect(parsed.target?.remotePath, '0');
      expect(
        parsed.issues,
        contains(QuickConnectIssue.pathAssumed),
      );
    });

    test('a bare host without a user is accepted for prompt-time auth', () {
      final parsed = parseQuickConnectAddress('example.com');

      expect(parsed.ok, isTrue);
      expect(parsed.target?.username, '');
      expect(parsed.target?.host, 'example.com');
      expect(parsed.target?.port, 22);
    });
  });

  group('sftp:// URLs', () {
    test('parses user, port, and path positionally', () {
      final parsed = parseQuickConnectAddress(
        'sftp://deploy@example.com:2222/srv/www',
      );

      expect(parsed.ok, isTrue);
      expect(parsed.target?.username, 'deploy');
      expect(parsed.target?.host, 'example.com');
      expect(parsed.target?.port, 2222);
      expect(parsed.target?.remotePath, '/srv/www');
      expect(parsed.issues, isEmpty);
    });

    test('a numeric path segment stays a path without a port hint', () {
      final parsed = parseQuickConnectAddress('sftp://example.com/2222');

      expect(parsed.ok, isTrue);
      expect(parsed.target?.port, 22);
      expect(parsed.target?.remotePath, '/2222');
      expect(
        parsed.issues,
        isNot(contains(QuickConnectIssue.portAssumed)),
      );
    });

    test('an out-of-range URL port is rejected, never a silent path', () {
      final parsed = parseQuickConnectAddress('sftp://example.com:99999/');

      expect(parsed.ok, isFalse);
      expect(
        parsed.issues,
        contains(QuickConnectIssue.invalidPort),
      );
    });
  });

  group('IPv6', () {
    test('an unbracketed multi-colon host is rejected with the hint', () {
      final parsed = parseQuickConnectAddress('deploy@2001:db8::1');

      expect(parsed.ok, isFalse);
      expect(
        parsed.issues,
        contains(QuickConnectIssue.ipv6NeedsBrackets),
      );
    });

    test('a bracketed address parses the port after the bracket', () {
      final parsed = parseQuickConnectAddress(
        'deploy@[2001:db8::1]:2222/srv/www',
      );

      expect(parsed.ok, isTrue);
      expect(parsed.target?.host, '2001:db8::1');
      expect(parsed.target?.port, 2222);
      expect(parsed.target?.remotePath, '/srv/www');
      expect(
        parsed.issues,
        contains(QuickConnectIssue.portAssumed),
      );
    });

    test('a bracketed address without a port takes the default', () {
      final parsed = parseQuickConnectAddress('deploy@[2001:db8::1]/srv/www');

      expect(parsed.ok, isTrue);
      expect(parsed.target?.host, '2001:db8::1');
      expect(parsed.target?.port, 22);
      expect(parsed.target?.remotePath, '/srv/www');
    });

    test('an empty bracketed token lands home, like the bare form', () {
      final parsed = parseQuickConnectAddress('deploy@[2001:db8::1]:');

      expect(parsed.ok, isTrue);
      expect(parsed.target?.port, 22);
      expect(parsed.target?.remotePath, isNull);
    });

    test('an unclosed bracket is rejected with the hint', () {
      final parsed = parseQuickConnectAddress('deploy@[2001:db8::1');

      expect(parsed.ok, isFalse);
      expect(
        parsed.issues,
        contains(QuickConnectIssue.ipv6NeedsBrackets),
      );
    });
  });

  group('passwords', () {
    test('a pasted URL password is stripped with an inline notice', () {
      final parsed = parseQuickConnectAddress(
        'sftp://deploy:secret@example.com:2222/srv/www',
      );

      expect(parsed.ok, isTrue);
      expect(parsed.target?.username, 'deploy');
      expect(parsed.target?.host, 'example.com');
      expect(parsed.target?.port, 2222);
      expect(
        parsed.issues,
        contains(QuickConnectIssue.passwordStripped),
      );
      expect(
        parsed.sanitizedInput,
        'sftp://deploy@example.com:2222/srv/www',
      );
    });

    test('a raw @ inside a pasted password cannot leak into the host', () {
      final parsed = parseQuickConnectAddress(
        'sftp://deploy:p@ss@example.com/srv/www',
      );

      expect(parsed.ok, isTrue);
      expect(parsed.target?.username, 'deploy');
      expect(parsed.target?.host, 'example.com');
      expect(
        parsed.issues,
        contains(QuickConnectIssue.passwordStripped),
      );
    });

    test('a bare-form password is stripped with an inline notice', () {
      final parsed = parseQuickConnectAddress('deploy:secret@example.com');

      expect(parsed.ok, isTrue);
      expect(parsed.target?.username, 'deploy');
      expect(parsed.target?.host, 'example.com');
      expect(
        parsed.issues,
        contains(QuickConnectIssue.passwordStripped),
      );
      expect(parsed.sanitizedInput, 'deploy@example.com');
    });
  });

  group('invalid input', () {
    test('empty input is rejected', () {
      final parsed = parseQuickConnectAddress('   ');

      expect(parsed.ok, isFalse);
      expect(parsed.issues, contains(QuickConnectIssue.emptyInput));
    });

    test('a user without a host is rejected', () {
      final parsed = parseQuickConnectAddress('deploy@');

      expect(parsed.ok, isFalse);
      expect(parsed.issues, contains(QuickConnectIssue.missingHost));
    });

    test('a non-sftp scheme is rejected', () {
      final parsed = parseQuickConnectAddress('https://example.com/');

      expect(parsed.ok, isFalse);
      expect(
        parsed.issues,
        contains(QuickConnectIssue.unsupportedScheme),
      );
    });
  });
}
