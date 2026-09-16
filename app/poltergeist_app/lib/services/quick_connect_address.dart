/// 02 §2.7's Quick Connect address grammar: `user@host:port` bare form
/// and `sftp://` URLs.
///
/// Pure Dart — no Flutter, no I/O — so the behavior is unit-testable and
/// the widget layer stays a thin ARB-mapping + connect seam. The parser
/// returns codes ([QuickConnectIssue]); user copy lives in ARB (D20) and
/// is mapped at the render site.
///
/// Bare-form disambiguation against scp syntax: in `user@host:token`, a
/// purely numeric token in 1–65535 is a port and anything else (a path
/// like `/srv/www`, a dashed name like `22-backup`, or a `port/path`
/// compound) is an scp-style remote start path on the default port —
/// passed through verbatim for the server to resolve. `sftp://` URLs
/// parse port and path positionally and are the unambiguous escape hatch
/// (a folder literally named `2222` is `sftp://host/2222`, never the
/// bare form, which reads it as a port with a visible hint).
///
/// Passwords never survive parsing: userinfo (delimited by the LAST `@`
/// WHATWG-style, so a raw `@` in a pasted password cannot split the host
/// early; the password is the segment after the FIRST `:` within it) is
/// extracted before the bracket/colon heuristics run, and the password
/// component is dropped with a [QuickConnectIssue.passwordStripped] flag
/// — never connected with, echoed, or persisted.
library;

/// The default SSH port assumed when the address names none.
const quickConnectDefaultPort = 22;

/// Lowest and highest values a numeric token may take to read as a port;
/// anything else numeric parses as a path with a visible hint.
const quickConnectMinPort = 1;
const quickConnectMaxPort = 65535;

/// The ephemeral server-id prefix for Quick Connect sessions (03 §3.5):
/// `adhoc:<uuid>`, promoted to the bookmark id on "Save as favorite…".
const quickConnectAdhocIdPrefix = 'adhoc:';

/// One machine-readable parse outcome (02 §2.7). Informational issues
/// ([portAssumed], [pathAssumed], [passwordStripped]) ride an otherwise
/// valid parse so the field can render its visible interpretation; the
/// rest reject the input.
enum QuickConnectIssue {
  /// An in-range numeric token was taken as a port; the field hints how
  /// to address a folder of that name instead.
  portAssumed,

  /// An out-of-range numeric token was taken as a path; the field hints
  /// why it is not a port.
  pathAssumed,

  /// An unbracketed host holds more than one colon; the field hints to
  /// wrap the IPv6 address in `[ ]` instead of silently dialing a
  /// truncated host.
  ipv6NeedsBrackets,

  /// A pasted password was stripped; the field says so inline.
  passwordStripped,

  /// Nothing to parse.
  emptyInput,

  /// A user with no host (`user@`).
  missingHost,

  /// A port-position value outside 1–65535 or not numeric at all.
  invalidPort,

  /// A `://` address whose scheme is not `sftp`.
  unsupportedScheme,
}

/// The dialable endpoint a valid parse resolves to. [username] may be
/// empty — the credential prompt resolves it at connect time, like an
/// imported row without a `User`. [remotePath] is the verbatim scp-style
/// start path (null for the server home); it never carries a password.
final class QuickConnectTarget {
  const QuickConnectTarget({
    required this.username,
    required this.host,
    this.port = quickConnectDefaultPort,
    this.remotePath,
  });

  final String username;
  final String host;
  final int port;
  final String? remotePath;
}

/// The parse result: [ok] with a [target] and any informational issues,
/// or rejected with only rejecting issues. [sanitizedInput] carries the
/// input with a pasted password removed (null when no password was
/// present) so the field can echo the stripped form instead of the
/// secret (02 §2.7 — never echoed, never persisted).
final class QuickConnectParse {
  const QuickConnectParse._({
    required this.target,
    required this.issues,
    required this.sanitizedInput,
  });

  const QuickConnectParse.ok(
    QuickConnectTarget target, [
    Set<QuickConnectIssue> issues = const {},
    String? sanitizedInput,
  ]) : this._(
         target: target,
         issues: issues,
         sanitizedInput: sanitizedInput,
       );

  const QuickConnectParse.invalid(Set<QuickConnectIssue> issues, [
    String? sanitizedInput,
  ]) : this._(target: null, issues: issues, sanitizedInput: sanitizedInput);

  final QuickConnectTarget? target;
  final Set<QuickConnectIssue> issues;
  final String? sanitizedInput;

  bool get ok => target != null;
}

/// Parses one Quick Connect address field value per 02 §2.7.
QuickConnectParse parseQuickConnectAddress(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    return const QuickConnectParse.invalid({QuickConnectIssue.emptyInput});
  }
  if (_hasScheme(text)) {
    if (!_isSftpScheme(text)) {
      return const QuickConnectParse.invalid({
        QuickConnectIssue.unsupportedScheme,
      });
    }
    return _parseUrlWithSanitized(text);
  }
  return _parseBareWithSanitized(text);
}

/// Attaches the password-stripped echo form (02 §2.7 — the field shows
/// the stripped address, never the secret) in one place so the grammar
/// below stays free of echo bookkeeping.
QuickConnectParse _parseBareWithSanitized(String text) {
  final parsed = _parseBare(text);
  final split = _splitUserinfo(text);
  if (!split.passwordStripped) return parsed;
  final sanitized = '${split.username}@${split.hostport}';
  final target = parsed.target;
  if (target == null) {
    return QuickConnectParse.invalid(parsed.issues, sanitized);
  }
  return QuickConnectParse.ok(target, parsed.issues, sanitized);
}

QuickConnectParse _parseUrlWithSanitized(String text) {
  final parsed = _parseUrl(text);
  final withoutScheme = text.substring('sftp://'.length);
  final slash = withoutScheme.indexOf('/');
  final authority = slash < 0 ? withoutScheme : withoutScheme.substring(0, slash);
  final suffix = slash < 0 ? '' : withoutScheme.substring(slash);
  final split = _splitUserinfo(authority);
  if (!split.passwordStripped) return parsed;
  final sanitized = 'sftp://${split.username}@${split.hostport}$suffix';
  final target = parsed.target;
  if (target == null) {
    return QuickConnectParse.invalid(parsed.issues, sanitized);
  }
  return QuickConnectParse.ok(target, parsed.issues, sanitized);
}

bool _hasScheme(String text) => text.contains('://');

bool _isSftpScheme(String text) =>
    text.length > 'sftp://'.length &&
    text.substring(0, 'sftp://'.length).toLowerCase() == 'sftp://';

/// Splits `userinfo@hostport` at the LAST `@` (02 §2.7's lenient rule)
/// and drops the password (after the FIRST `:` in the userinfo),
/// reporting whether one was stripped.
({String username, String hostport, bool passwordStripped}) _splitUserinfo(
  String authority,
) {
  final at = authority.lastIndexOf('@');
  if (at < 0) return (username: '', hostport: authority, passwordStripped: false);
  final userinfo = authority.substring(0, at);
  final colon = userinfo.indexOf(':');
  if (colon < 0) {
    return (
      username: _decode(userinfo),
      hostport: authority.substring(at + 1),
      passwordStripped: false,
    );
  }
  return (
    username: _decode(userinfo.substring(0, colon)),
    hostport: authority.substring(at + 1),
    passwordStripped: true,
  );
}

String _decode(String component) {
  try {
    return Uri.decodeComponent(component);
  } on ArgumentError {
    return component;
  }
}

QuickConnectParse _finish({
  required String username,
  required String host,
  required int port,
  required String? remotePath,
  required bool passwordStripped,
  QuickConnectIssue? hint,
}) {
  if (host.isEmpty) {
    return const QuickConnectParse.invalid({QuickConnectIssue.missingHost});
  }
  final issues = <QuickConnectIssue>{
    if (passwordStripped) QuickConnectIssue.passwordStripped,
  };
  // Added imperatively: the collection-`if` null-aware form the lint
  // prefers does not parse on this SDK's element grammar.
  if (hint != null) issues.add(hint);
  return QuickConnectParse.ok(
    QuickConnectTarget(
      username: username,
      host: host,
      port: port,
      remotePath: remotePath,
    ),
    issues,
  );
}

/// Resolves one bracketed-form `:head[/tail]` token: a purely numeric
/// in-range head reads as a port with the tail as the start path;
/// anything else is the verbatim token as a path.
QuickConnectParse _resolveBracketToken({
  required String username,
  required String host,
  required String token,
  required bool passwordStripped,
}) {
  final slash = token.indexOf('/');
  final head = slash < 0 ? token : token.substring(0, slash);
  final tail = slash < 0 ? null : token.substring(slash);
  if (head.isEmpty) {
    return _finish(
      username: username,
      host: host,
      port: quickConnectDefaultPort,
      remotePath: token,
      passwordStripped: passwordStripped,
    );
  }
  final port = int.tryParse(head);
  if (port != null &&
      port >= quickConnectMinPort &&
      port <= quickConnectMaxPort) {
    return _finish(
      username: username,
      host: host,
      port: port,
      remotePath: tail,
      passwordStripped: passwordStripped,
      hint: QuickConnectIssue.portAssumed,
    );
  }
  if (port != null) {
    return _finish(
      username: username,
      host: host,
      port: quickConnectDefaultPort,
      remotePath: token,
      passwordStripped: passwordStripped,
      hint: QuickConnectIssue.pathAssumed,
    );
  }
  return _finish(
    username: username,
    host: host,
    port: quickConnectDefaultPort,
    remotePath: token,
    passwordStripped: passwordStripped,
  );
}

/// Resolves one bare-form `:token`: purely numeric and in range reads as
/// a port (with the hint); anything else is a verbatim start path.
QuickConnectParse _resolveToken({
  required String username,
  required String host,
  required String token,
  required bool passwordStripped,
}) {
  if (token.isEmpty) {
    return _finish(
      username: username,
      host: host,
      port: quickConnectDefaultPort,
      remotePath: null,
      passwordStripped: passwordStripped,
    );
  }
  final port = int.tryParse(token);
  if (port != null &&
      port >= quickConnectMinPort &&
      port <= quickConnectMaxPort) {
    return _finish(
      username: username,
      host: host,
      port: port,
      remotePath: null,
      passwordStripped: passwordStripped,
      hint: QuickConnectIssue.portAssumed,
    );
  }
  if (port != null) {
    return _finish(
      username: username,
      host: host,
      port: quickConnectDefaultPort,
      remotePath: token,
      passwordStripped: passwordStripped,
      hint: QuickConnectIssue.pathAssumed,
    );
  }
  return _finish(
    username: username,
    host: host,
    port: quickConnectDefaultPort,
    remotePath: token,
    passwordStripped: passwordStripped,
  );
}

QuickConnectParse _parseBare(String text) {
  final split = _splitUserinfo(text);
  final rest = split.hostport;
  if (rest.startsWith('[')) {
    // Bracketed IPv6: the port follows the closing bracket — the plain
    // heuristic must not split the address at its first colon.
    final close = rest.indexOf(']');
    if (close < 0) {
      return const QuickConnectParse.invalid({
        QuickConnectIssue.ipv6NeedsBrackets,
      });
    }
    final host = rest.substring(1, close);
    final after = rest.substring(close + 1);
    if (after.isEmpty) {
      return _finish(
        username: split.username,
        host: host,
        port: quickConnectDefaultPort,
        remotePath: null,
        passwordStripped: split.passwordStripped,
      );
    }
    if (!after.startsWith(':')) {
      // `[host]/path`: the path follows the bracket directly.
      return _finish(
        username: split.username,
        host: host,
        port: quickConnectDefaultPort,
        remotePath: after,
        passwordStripped: split.passwordStripped,
      );
    }
    // 02 §2.7's bracketed form (`user@[host]:port/path`): the port is
    // the head up to the first `/`, the path is the tail from it. The
    // unbracketed form below keeps the whole-token rule instead — only
    // a purely numeric token reads as a port there.
    return _resolveBracketToken(
      username: split.username,
      host: host,
      token: after.substring(1),
      passwordStripped: split.passwordStripped,
    );
  }
  final firstColon = rest.indexOf(':');
  if (firstColon >= 0 && rest.indexOf(':', firstColon + 1) >= 0) {
    // An unbracketed multi-colon host: connecting would silently dial a
    // truncated host with a junk path, so reject with the bracket hint.
    return const QuickConnectParse.invalid({
      QuickConnectIssue.ipv6NeedsBrackets,
    });
  }
  if (firstColon < 0) {
    return _finish(
      username: split.username,
      host: rest,
      port: quickConnectDefaultPort,
      remotePath: null,
      passwordStripped: split.passwordStripped,
    );
  }
  return _resolveToken(
    username: split.username,
    host: rest.substring(0, firstColon),
    token: rest.substring(firstColon + 1),
    passwordStripped: split.passwordStripped,
  );
}

QuickConnectParse _parseUrl(String text) {
  final withoutScheme = text.substring('sftp://'.length);
  final slash = withoutScheme.indexOf('/');
  final authority = slash < 0 ? withoutScheme : withoutScheme.substring(0, slash);
  final path = slash < 0
      ? null
      : _decode(withoutScheme.substring(slash + 1));
  final split = _splitUserinfo(authority);
  final hostport = split.hostport;
  final remotePath = path == null || path.isEmpty ? null : '/$path';
  if (hostport.startsWith('[')) {
    final close = hostport.indexOf(']');
    if (close < 0) {
      return const QuickConnectParse.invalid({
        QuickConnectIssue.ipv6NeedsBrackets,
      });
    }
    final host = hostport.substring(1, close);
    final after = hostport.substring(close + 1);
    if (after.isEmpty) {
      return _finish(
        username: split.username,
        host: host,
        port: quickConnectDefaultPort,
        remotePath: remotePath,
        passwordStripped: split.passwordStripped,
      );
    }
    final port = _parseUrlPort(after);
    if (port == null) {
      return const QuickConnectParse.invalid({QuickConnectIssue.invalidPort});
    }
    return _finish(
      username: split.username,
      host: host,
      port: port,
      remotePath: remotePath,
      passwordStripped: split.passwordStripped,
    );
  }
  final colon = hostport.indexOf(':');
  if (colon >= 0 && hostport.indexOf(':', colon + 1) >= 0) {
    return const QuickConnectParse.invalid({
      QuickConnectIssue.ipv6NeedsBrackets,
    });
  }
  if (colon < 0) {
    return _finish(
      username: split.username,
      host: hostport,
      port: quickConnectDefaultPort,
      remotePath: remotePath,
      passwordStripped: split.passwordStripped,
    );
  }
  final port = _parseUrlPort(hostport.substring(colon));
  if (port == null) {
    return const QuickConnectParse.invalid({QuickConnectIssue.invalidPort});
  }
  return _finish(
    username: split.username,
    host: hostport.substring(0, colon),
    port: port,
    remotePath: remotePath,
    passwordStripped: split.passwordStripped,
  );
}

/// Parses one URL-position `:port`: strictly numeric and in range, or the
/// URL is rejected — positionally this segment can only be a port, never
/// a path.
int? _parseUrlPort(String colonPrefix) {
  if (!colonPrefix.startsWith(':')) return null;
  final port = int.tryParse(colonPrefix.substring(1));
  if (port == null ||
      port < quickConnectMinPort ||
      port > quickConnectMaxPort) {
    return null;
  }
  return port;
}
