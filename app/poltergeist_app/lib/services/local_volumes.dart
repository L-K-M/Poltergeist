import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart' show expandHomePath;

/// What kind of place a DEVICES row is (10 §5) — it picks the row's glyph
/// and whether the row offers Eject.
enum LocalVolumeKind {
  /// The user's home folder, listed first under the user's name.
  home,

  /// The boot volume: `/` on POSIX, the system drive on Windows.
  root,

  /// A volume the OS mounted on demand (`/Volumes/*`, `/media/$USER/*`,
  /// `/run/media/$USER/*`) — the only kind that offers Eject.
  removable,

  /// A standing mount the user placed (`/mnt/*`) or another drive letter.
  /// Unmounting one is an administrator's job, so no Eject.
  fixed,
}

/// One DEVICES row's facts: where it opens, what it is called, and how
/// much room is left there (null when the platform cannot say cheaply).
final class LocalVolume {
  const LocalVolume({
    required this.path,
    required this.name,
    required this.kind,
    this.freeBytes,
  });

  final String path;
  final String name;
  final LocalVolumeKind kind;
  final int? freeBytes;

  bool get ejectable => kind == LocalVolumeKind.removable;

  LocalVolume withFreeBytes(int? bytes) =>
      LocalVolume(path: path, name: name, kind: kind, freeBytes: bytes);

  @override
  bool operator ==(Object other) =>
      other is LocalVolume &&
      other.path == path &&
      other.name == name &&
      other.kind == kind &&
      other.freeBytes == freeBytes;

  @override
  int get hashCode => Object.hash(path, name, kind, freeBytes);
}

/// The DEVICES section's seam: the sidebar reads mounts through this, so
/// a test lists a scripted set instead of whatever the host has mounted.
abstract interface class LocalVolumeSource {
  /// Home first, then the root volume, then the mounted volumes by name.
  Future<List<LocalVolume>> list();

  /// The Desktop, Documents, and Downloads folders that actually exist —
  /// the empty-favorites offer adds only these (10 §5).
  Future<List<String>> standardFolders();

  /// The folder `~` names for the local pane — where "This device" opens
  /// — so a location can be shown home-relative; null when the platform
  /// gives no home.
  String? get homeDirectory;

  /// Whether [path] is a folder — the check a drop onto FAVORITES runs so
  /// a dragged file never becomes a folder favorite.
  Future<bool> isDirectory(String path);

  /// Fires when a mount may have appeared or gone; the sidebar re-lists.
  /// A source that cannot watch returns a stream that never fires.
  Stream<void> get changes;

  /// Ejects [volume]. False when the OS refused or has no eject verb —
  /// the caller says so; a refused eject never reads as done.
  Future<bool> eject(LocalVolume volume);
}

/// The process seam `df` and the eject verbs run through.
typedef LocalProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// The directory reads the enumeration needs, injectable so the platform
/// rules are testable without the host's mounts.
abstract interface class VolumeDirectoryReader {
  /// The child directories of [path] as absolute paths (empty when [path]
  /// is missing or unreadable). Symbolic links count when they resolve to
  /// a directory — macOS's boot-volume entry is one.
  List<String> childDirectories(String path);

  /// Where the symbolic link at [path] resolves, or null when [path] is
  /// not a link.
  String? resolveLink(String path);

  bool isDirectory(String path);
}

final class _IoDirectoryReader implements VolumeDirectoryReader {
  const _IoDirectoryReader();

  @override
  List<String> childDirectories(String path) {
    try {
      return [
        for (final entity in Directory(path).listSync(followLinks: false))
          if (FileSystemEntity.isDirectorySync(entity.path)) entity.path,
      ];
    } on FileSystemException {
      return const [];
    }
  }

  @override
  String? resolveLink(String path) {
    try {
      if (!FileSystemEntity.isLinkSync(path)) return null;
      return Link(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  bool isDirectory(String path) => FileSystemEntity.isDirectorySync(path);
}

/// The host's volumes (10 §5's DEVICES rules):
///
/// - **macOS:** `/Volumes/*`. The entry that links back to `/` is the
///   boot volume — its name ("Macintosh HD") labels the root row and the
///   link itself is skipped, so the boot disk never lists twice.
/// - **Linux:** `/media/$USER/*` and `/run/media/$USER/*` (udisks'
///   removable mounts), plus `/mnt/*` directories as fixed mounts; the
///   root row is labelled with the host name.
/// - **Windows:** drive letters C–Z (A and B are floppy letters, and
///   probing an empty floppy drive stalls), the system drive as root.
/// - **Android/iOS:** nothing — the local pane there is app storage, not
///   a volume the user mounts.
///
/// Free space comes from `df -kP` on POSIX and is omitted on Windows.
final class SystemLocalVolumes implements LocalVolumeSource {
  SystemLocalVolumes({
    String? operatingSystem,
    Map<String, String>? environment,
    String? hostName,
    VolumeDirectoryReader? directories,
    LocalProcessRunner? run,
  }) : _os = operatingSystem ?? Platform.operatingSystem,
       _env = environment ?? Platform.environment,
       // Keep the host-name override private while allowing injection.
       // ignore: prefer_initializing_formals
       _hostName = hostName,
       _dirs = directories ?? const _IoDirectoryReader(),
       _run = run ?? Process.run;

  /// The running host's volumes — one instance, so a rebuilt sidebar
  /// never re-binds (and re-lists) because its source changed identity.
  static final host = SystemLocalVolumes();

  final String _os;
  final Map<String, String> _env;
  final String? _hostName;
  final VolumeDirectoryReader _dirs;
  final LocalProcessRunner _run;

  static const _macVolumes = '/Volumes';
  static const _linuxMedia = '/media';
  static const _linuxRunMedia = '/run/media';
  static const _linuxMnt = '/mnt';
  static const _posixRoot = '/';

  bool get _windows => _os == 'windows';
  bool get _mac => _os == 'macos';
  bool get _linux => _os == 'linux';

  String? get _home {
    final home = _windows ? _env['USERPROFILE'] : _env['HOME'];
    return home == null || home.isEmpty ? null : home;
  }

  String? get _userName {
    for (final key in const ['USER', 'USERNAME', 'LOGNAME']) {
      final value = _env[key];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  @override
  Future<List<LocalVolume>> list() async {
    if (!_windows && !_mac && !_linux) return const [];
    final volumes = [...?_homeVolume(), ..._mountedVolumes()];
    if (_windows) return volumes;
    // One `df` per row, concurrently: a hung network mount delays only
    // its own row's number, never the list.
    return Future.wait([
      for (final volume in volumes)
        dfFreeSpaceBytes(volume.path, run: _run).then(volume.withFreeBytes),
    ]);
  }

  List<LocalVolume>? _homeVolume() {
    final home = _home;
    if (home == null) return null;
    return [
      LocalVolume(
        path: home,
        name: _userName ?? p.basename(home),
        kind: LocalVolumeKind.home,
      ),
    ];
  }

  List<LocalVolume> _mountedVolumes() {
    if (_windows) return _windowsDrives();
    final mounted = <LocalVolume>[];
    String? rootName;
    if (_mac) {
      for (final path in _dirs.childDirectories(_macVolumes)) {
        if (_dirs.resolveLink(path) == _posixRoot) {
          rootName = p.basename(path);
          continue;
        }
        mounted.add(_volume(path, LocalVolumeKind.removable));
      }
    } else {
      final user = _userName;
      if (user != null) {
        for (final parent in [
          p.join(_linuxMedia, user),
          p.join(_linuxRunMedia, user),
        ]) {
          for (final path in _dirs.childDirectories(parent)) {
            mounted.add(_volume(path, LocalVolumeKind.removable));
          }
        }
      }
      for (final path in _dirs.childDirectories(_linuxMnt)) {
        mounted.add(_volume(path, LocalVolumeKind.fixed));
      }
    }
    mounted.sort(_byName);
    return [
      LocalVolume(
        path: _posixRoot,
        name: rootName ?? _hostName ?? Platform.localHostname,
        kind: LocalVolumeKind.root,
      ),
      ...mounted,
    ];
  }

  List<LocalVolume> _windowsDrives() {
    final systemDrive = (_env['SystemDrive'] ?? 'C:').toUpperCase();
    final drives = <LocalVolume>[];
    // C..Z — see the class doc for why A: and B: are never probed.
    for (var code = 0x43; code <= 0x5A; code++) {
      final letter = '${String.fromCharCode(code)}:';
      final root = '$letter\\';
      if (!_dirs.isDirectory(root)) continue;
      drives.add(
        LocalVolume(
          path: root,
          name: letter,
          kind: letter == systemDrive
              ? LocalVolumeKind.root
              : LocalVolumeKind.fixed,
        ),
      );
    }
    // The system drive leads, like the POSIX root row.
    drives.sort(
      (a, b) => a.kind == b.kind
          ? a.name.compareTo(b.name)
          : (a.kind == LocalVolumeKind.root ? -1 : 1),
    );
    return drives;
  }

  LocalVolume _volume(String path, LocalVolumeKind kind) =>
      LocalVolume(path: path, name: p.basename(path), kind: kind);

  static int _byName(LocalVolume a, LocalVolume b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.path.compareTo(b.path);
  }

  /// The engine's own `~` rule (the local pane canonicalizes through
  /// [expandHomePath]), so a path shown as `~/…` is one the pane reaches
  /// as `~/…`.
  @override
  String? get homeDirectory {
    final home = expandHomePath('~', environment: _env, isMacOS: _mac);
    return home == '~' ? null : home;
  }

  @override
  Future<List<String>> standardFolders() async {
    final home = _home;
    if (home == null) return const [];
    final xdg = _linux ? _xdgUserDirs(home) : const <String, String>{};
    return [
      for (final (xdgKey, fallback) in _standardFolderNames)
        if (xdg[xdgKey] ?? p.join(home, fallback) case final path
            when _dirs.isDirectory(path))
          path,
    ];
  }

  /// The three offered folders, with the XDG key a Linux desktop may
  /// have relocated (or localized) each one under.
  static const _standardFolderNames = [
    ('XDG_DESKTOP_DIR', 'Desktop'),
    ('XDG_DOCUMENTS_DIR', 'Documents'),
    ('XDG_DOWNLOAD_DIR', 'Downloads'),
  ];

  /// `~/.config/user-dirs.dirs`: `KEY="$HOME/Folder"` lines. A missing or
  /// unreadable file answers nothing, and the English names stand.
  Map<String, String> _xdgUserDirs(String home) {
    final configHome = _env['XDG_CONFIG_HOME'] ?? p.join(home, '.config');
    final file = File(p.join(configHome, 'user-dirs.dirs'));
    final String text;
    try {
      if (!file.existsSync()) return const {};
      text = file.readAsStringSync();
    } on FileSystemException {
      return const {};
    }
    return parseXdgUserDirs(text, home: home);
  }

  @override
  Future<bool> isDirectory(String path) async => _dirs.isDirectory(path);

  @override
  Stream<void> get changes {
    final parents = _watchedParents();
    if (parents.isEmpty) return const Stream.empty();
    late final StreamController<void> controller;
    final subscriptions = <StreamSubscription<FileSystemEvent>>[];
    controller = StreamController<void>.broadcast(
      onListen: () {
        for (final parent in parents) {
          try {
            subscriptions.add(
              Directory(parent).watch().listen(
                (_) => controller.add(null),
                // A watch the platform refuses (no inotify slots, a
                // parent unmounted underneath) just stops reporting.
                onError: (Object _) {},
              ),
            );
          } on Object {
            // Same posture: an unwatchable parent is simply not watched.
          }
        }
      },
      onCancel: () {
        for (final subscription in subscriptions) {
          unawaited(subscription.cancel());
        }
        subscriptions.clear();
      },
    );
    return controller.stream;
  }

  List<String> _watchedParents() {
    final candidates = <String>[
      if (_mac) _macVolumes,
      if (_linux) ...[
        if (_userName case final user?) ...[
          p.join(_linuxMedia, user),
          p.join(_linuxRunMedia, user),
        ],
        _linuxMnt,
      ],
    ];
    return [
      for (final path in candidates)
        if (_dirs.isDirectory(path)) path,
    ];
  }

  @override
  Future<bool> eject(LocalVolume volume) async {
    if (!volume.ejectable) return false;
    try {
      if (_mac) {
        final result = await _run('diskutil', ['eject', volume.path]);
        return result.exitCode == 0;
      }
      if (_linux) {
        // gio talks to udisks as the desktop user (no root needed); the
        // plain umount is the fallback on desktops without it.
        final gio = await _run('gio', ['mount', '-u', volume.path]);
        if (gio.exitCode == 0) return true;
        final umount = await _run('umount', [volume.path]);
        return umount.exitCode == 0;
      }
    } on ProcessException {
      return false;
    }
    return false;
  }
}

/// [text]'s `XDG_*_DIR="…"` assignments with `$HOME` expanded. Relative
/// or unparsable values are skipped: the spec only allows `$HOME/…` or an
/// absolute path.
Map<String, String> parseXdgUserDirs(String text, {required String home}) {
  final result = <String, String>{};
  // \x22 is the double quote the spec wraps every value in.
  final assignment = RegExp(r'^\s*(XDG_[A-Z]+_DIR)\s*=\s*\x22(.*)\x22\s*$');
  for (final line in text.split('\n')) {
    final match = assignment.firstMatch(line);
    if (match == null) continue;
    var value = match.group(2)!;
    if (value.startsWith(r'$HOME')) {
      value = '$home${value.substring(5)}';
    }
    if (!value.startsWith('/')) continue;
    result[match.group(1)!] = value;
  }
  return result;
}

/// Free bytes on the volume holding [path] from `df -kP`'s Available
/// column, or null where there is no `df` (Windows) or it fails — every
/// caller treats the number as optional.
Future<int?> dfFreeSpaceBytes(String path, {LocalProcessRunner? run}) async {
  if (Platform.isWindows) return null;
  try {
    // -P forces one line per filesystem: without it a long device name
    // wraps and shifts every column the parser counts.
    final result = await (run ?? Process.run)('df', ['-kP', path]);
    if (result.exitCode != 0) return null;
    final kibibytes = parseDfAvailableKibibytes(result.stdout as String);
    return kibibytes == null ? null : kibibytes * 1024;
  } on Object {
    return null;
  }
}

/// The Available column of `df -k`'s output. The header is dropped and the
/// remaining lines are joined, so a wrapped row (a non-POSIX `df` that
/// ignored `-P`) still splits into `<fs> <blocks> <used> <avail> …`.
int? parseDfAvailableKibibytes(String stdout) {
  final lines = stdout
      .trim()
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      .toList();
  if (lines.length < 2) return null;
  final fields = lines.skip(1).join(' ').trim().split(RegExp(r'\s+'));
  if (fields.length < 4) return null;
  return int.tryParse(fields[3]);
}
