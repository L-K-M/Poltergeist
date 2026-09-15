import 'pane_location.dart';

final RegExp _driveSpec = RegExp(r'^[A-Za-z]:');
final RegExp _driveLetterOnly = RegExp(r'^[A-Za-z]:$');

/// Resolves a raw path-field submission into an absolute navigation
/// target under the pane's location model (02 §2.1): an absolute path
/// passes through, a leading `~` expands to the channel's home (local
/// user home or the remote server home), a relative name joins onto the
/// current location, and — on a Windows local pane only — a drive
/// letter switches volume.
///
/// Returns null for input whose shape can never name a location under
/// this pane: control characters, `~name` (other-user expansion needs
/// the engine), a drive spec on a POSIX target, a drive-relative
/// `C:name`, a root-relative `\name` or a shareless `\\server` UNC. The
/// caller surfaces the pane error affordance without an engine
/// round-trip; whether a well-formed result exists is the listing's
/// question, not this check's.
///
/// [remote] selects the POSIX ruleset for a remote pane; a local pane
/// reads its conventions from [homePath]'s separator, so the same field
/// serves all three desktops. [currentPath] is the pane's committed
/// location — relative input is unresolvable while it is null.
String? resolvePanePathInput({
  required String raw,
  required bool remote,
  required String? currentPath,
  required String homePath,
}) {
  final input = raw.trim();
  if (input.isEmpty) return null;
  for (final unit in input.codeUnits) {
    if (unit < 0x20 || unit == 0x7f) return null;
  }

  // `~` expands to the channel home on either side (02 §2.1). `~name`
  // is other-user expansion, which has no app-side meaning.
  if (input == '~') return homePath;
  if (input.startsWith('~/') || input.startsWith('~\\')) {
    return _join(homePath, input.substring(2), paneSeparator(homePath));
  }
  if (input.startsWith('~')) {
    return null; // `~name` is other-user expansion — engine-side only.
  }

  final separator = remote ? '/' : paneSeparator(homePath);
  if (separator == '\\') {
    // Windows local: normalize the forward-slash forms the field
    // accepts, then apply the volume rules.
    final win = input.replaceAll('/', '\\');
    if (_driveLetterOnly.hasMatch(win)) return '${win[0]}:\\';
    if (win.length > 2 && _driveSpec.hasMatch(win) && win[2] == '\\') {
      return _normalize(win, separator);
    }
    if (_driveSpec.hasMatch(win)) {
      return null; // `C:name` is drive-relative — no per-drive cwd exists.
    }
    if (win.startsWith('\\\\')) {
      return _normalize(win, separator); // UNC: needs \\server\share.
    }
    if (win.startsWith('\\')) return null; // root-relative names no volume.
    if (currentPath == null) return null;
    return _join(currentPath, win, separator);
  }

  // POSIX — local or remote. An input like `C:\x` is a legal relative
  // name here (the colon and backslash are ordinary characters); the
  // drive rules above are Windows-only.
  if (input.startsWith('/')) return _normalize(input, separator);
  if (currentPath == null) return null;
  return _join(currentPath, input, separator);
}

String? _join(String base, String child, String separator) {
  final stem = base.endsWith(separator) && base.length > 1
      ? base.substring(0, base.length - 1)
      : base;
  return _normalize('$stem$separator$child', separator);
}

/// Collapses duplicate separators, resolves `.`/`..` segments (clamped
/// at the root, matching shell semantics), and strips a trailing
/// separator so the path bar and history hold canonical strings.
/// Returns null when a UNC input resolves below its `\\server\share`
/// root.
String? _normalize(String path, String separator) {
  final rawSegments = path.split(separator);
  var prefix = '';
  var start = 0;
  if (separator == '/') {
    prefix = '/';
    start = 1;
  } else if (path.startsWith('\\\\')) {
    prefix = '\\\\';
    start = 2;
  } else {
    prefix = '${rawSegments[0]}\\'; // drive root `C:\`
    start = 1;
  }
  final segments = <String>[];
  for (var i = start; i < rawSegments.length; i++) {
    final segment = rawSegments[i];
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  if (prefix == '\\\\' && segments.length < 2) return null;
  if (segments.isEmpty) return prefix;
  return '$prefix${segments.join(separator)}';
}
