
/// One pane's bound location (02 §2): a local folder or a remote
/// bookmark's path, browsed through the one VFS (D3 — both sides are
/// `RemoteFileSystem` listings, so panes never model the difference in
/// data, only in binding).
///
/// Value equality over the fields: locations are compared to detect
/// location changes and will key per-location state (02 §2.4), so identity
/// equality would break both.
///
/// // OPEN(status): 02 §2 places this sealed type in `poltergeist_core`
/// // and wants paths NFC-normalized (and case-folded on case-insensitive
/// // volumes) before ==/hashCode. Core is closed to this slice; the type
/// // moves with the first cross-package consumer (the per-location view
/// // prefs slice), which also lands the canonicalization rule. Tracked as
/// // a dated STATUS item.
sealed class PaneLocation {
  const PaneLocation();

  /// The bound path (canonical absolute); every location carries one, so
  /// navigation and the path bar never type-switch to read it.
  String get path;
}

final class LocalPaneLocation extends PaneLocation {
  const LocalPaneLocation(this.path);

  /// Canonical absolute path (the engine's `homePath` or a listing-derived
  /// path); trailing separators are stripped except the root's own.
  @override
  final String path;

  @override
  bool operator ==(Object other) =>
      other is LocalPaneLocation && other.path == path;

  @override
  int get hashCode => Object.hash(LocalPaneLocation, path);

  @override
  String toString() => 'LocalPaneLocation($path)';
}

final class RemotePaneLocation extends PaneLocation {
  const RemotePaneLocation(this.serverId, this.path);

  /// The bookmark's id — the pool's serverId (03 §3.5).
  final String serverId;

  /// Absolute path on the server; POSIX separators.
  @override
  final String path;

  @override
  bool operator ==(Object other) =>
      other is RemotePaneLocation &&
      other.serverId == serverId &&
      other.path == path;

  @override
  int get hashCode => Object.hash(RemotePaneLocation, serverId, path);

  @override
  String toString() => 'RemotePaneLocation($serverId, $path)';
}

/// The parent of [path], keeping every root form its own parent:
/// navigation up from a volume/server root is a no-op, never a bogus
/// path. Handles both separator styles: remote paths are POSIX, local
/// paths follow the platform (`\` on Windows, including UNC share
/// roots — only `\\server\share` is a listable root, never
/// `\\server`).
/// The display name of a path's last segment (the pane footer's
/// loading line): a root path ('/' or 'C:\') is its own label.
String paneLastSegment(String? path) {
  if (path == null) return '';
  final parent = paneParentPath(path);
  if (parent == path) return path;
  final separator = path.startsWith('/')
      ? '/'
      : (path.contains('\\') ? '\\' : '/');
  return path.substring(parent.length).replaceAll(separator, '');
}

String paneParentPath(String path) {
  // Absolute POSIX paths (every remote path; local POSIX) keep '/' even
  // when a name contains a literal backslash — a legal POSIX filename
  // character (a Windows-migrated file named 'C:\backup' on a Linux
  // server must not flip the separator heuristic).
  final separator = path.startsWith('/')
      ? '/'
      : (path.contains('\\') ? '\\' : '/');
  var trimmed = path;
  while (trimmed.length > 1 && trimmed.endsWith(separator)) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final lastSlash = trimmed.lastIndexOf(separator);
  if (lastSlash < 0) {
    // No separator at all: a bare drive ('C:') — its root keeps the
    // platform's own separator.
    if (trimmed.length == 2 && trimmed[1] == ':') {
      return '$trimmed\\';
    }
    return trimmed;
  }
  // POSIX '/x' → '/', the root its own parent.
  if (lastSlash == 0) return separator;
  final parent = trimmed.substring(0, lastSlash);
  // Windows: the parent of 'C:\x' is 'C:\', not 'C:'.
  if (parent.length == 2 && parent[1] == ':') return '$parent\\';
  // Windows UNC: '\\server\share' is itself a root — never climb to
  // '\\server', which no file API can list.
  if (separator == '\\' &&
      parent.length > 2 &&
      parent.startsWith('\\\\') &&
      !parent.substring(2).contains('\\')) {
    return trimmed;
  }
  return parent;
}
