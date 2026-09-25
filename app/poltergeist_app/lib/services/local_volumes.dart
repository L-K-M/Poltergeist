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
  /// Rows come back without free space, and the enumeration is bounded:
  /// a dead mount can delay it by a probe timeout, never hold it.
  Future<List<LocalVolume>> list();

  /// Free bytes on [volume], or null when the platform cannot say (no
  /// `df`, a failure, or a volume that did not answer in time). Asked
  /// per row after [list] so a hung network mount costs only its own
  /// number, never the list.
  Future<int?> freeBytes(LocalVolume volume);

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
///
/// Every read is asynchronous on purpose: a `stat()` of a dead hard NFS
/// mount point, or of a disconnected mapped drive, blocks for as long as
/// the network stack keeps retrying. dart:io's async calls block one of
/// its I/O worker threads instead of the UI isolate, and
/// [SystemLocalVolumes] stops waiting after its probe timeout.
abstract interface class VolumeDirectoryReader {
  /// The child directories of [path] as absolute paths (empty when [path]
  /// is missing or unreadable). Symbolic links count when they resolve to
  /// a directory — macOS's boot-volume entry is one.
  Future<List<String>> childDirectories(String path);

  /// Where the symbolic link at [path] resolves, or null when [path] is
  /// not a link.
  Future<String?> resolveLink(String path);

  Future<bool> isDirectory(String path);
}

final class _IoDirectoryReader implements VolumeDirectoryReader {
  const _IoDirectoryReader();

  /// One link's resolution; a link into a dead mount answers "not a
  /// directory" rather than taking its siblings down with it.
  static const _linkProbeTimeout = Duration(seconds: 2);

  @override
  Future<List<String>> childDirectories(String path) async {
    final List<FileSystemEntity> entries;
    try {
      entries = await Directory(path).list(followLinks: false).toList();
    } on FileSystemException {
      return const [];
    }
    // readdir already says what a plain entry is, so only links need a
    // stat(); the mount points themselves are never touched here.
    final links = [for (final entry in entries) entry is Link];
    final linkTargetsAreDirectories = await Future.wait([
      for (final entry in entries)
        if (entry is Link)
          _withinWallClock(
            FileSystemEntity.isDirectory(entry.path),
            _linkProbeTimeout,
            false,
          ),
    ]);
    final directories = <String>[];
    var linkIndex = 0;
    for (var i = 0; i < entries.length; i++) {
      if (links[i]) {
        if (linkTargetsAreDirectories[linkIndex++]) {
          directories.add(entries[i].path);
        }
      } else if (entries[i] is Directory) {
        directories.add(entries[i].path);
      }
    }
    return directories;
  }

  @override
  Future<String?> resolveLink(String path) async {
    try {
      if (!await FileSystemEntity.isLink(path)) return null;
      return await Link(path).resolveSymbolicLinks();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<bool> isDirectory(String path) => FileSystemEntity.isDirectory(path);
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
///
/// Every probe (a directory read, a link resolution, a drive letter, a
/// `df`) is abandoned after [probeTimeout]: the probe's answer is then
/// "absent" (no entries, not a directory, no number). Probes run
/// concurrently, so a dead network mount can delay the section by a
/// timeout or two but can never hold it.
final class SystemLocalVolumes implements LocalVolumeSource {
  SystemLocalVolumes({
    String? operatingSystem,
    Map<String, String>? environment,
    String? hostName,
    VolumeDirectoryReader? directories,
    LocalProcessRunner? run,
    Duration probeTimeout = const Duration(seconds: 3),
  }) : _os = operatingSystem ?? Platform.operatingSystem,
       _env = environment ?? Platform.environment,
       // Keep the host-name override private while allowing injection.
       // ignore: prefer_initializing_formals
       _hostName = hostName,
       _dirs = directories ?? const _IoDirectoryReader(),
       _run = run ?? Process.run,
       // Keep the timeout private; named parameters cannot be private.
       // ignore: prefer_initializing_formals
       _probeTimeout = probeTimeout;

  /// The running host's volumes — one instance, so a rebuilt sidebar
  /// never re-binds (and re-lists) because its source changed identity.
  static final host = SystemLocalVolumes();

  final String _os;
  final Map<String, String> _env;
  final String? _hostName;
  final VolumeDirectoryReader _dirs;
  final LocalProcessRunner _run;
  final Duration _probeTimeout;

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
    return [...?_homeVolume(), ...await _mountedVolumes()];
  }

  @override
  Future<int?> freeBytes(LocalVolume volume) async {
    if (_windows) return null;
    return dfFreeSpaceBytes(volume.path, run: _run, timeout: _probeTimeout);
  }

  /// [probe]'s answer, or [absent] once it has taken [_probeTimeout].
  Future<T> _bounded<T>(Future<T> probe, T absent) =>
      _withinWallClock(probe, _probeTimeout, absent);

  Future<List<String>> _children(String path) =>
      _bounded(_dirs.childDirectories(path), const <String>[]);

  Future<bool> _isDirectory(String path) =>
      _bounded(_dirs.isDirectory(path), false);

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

  Future<List<LocalVolume>> _mountedVolumes() async {
    if (_windows) return _windowsDrives();
    final mounted = <LocalVolume>[];
    String? rootName;
    if (_mac) {
      final paths = await _children(_macVolumes);
      final targets = await Future.wait([
        for (final path in paths) _bounded(_dirs.resolveLink(path), null),
      ]);
      for (var i = 0; i < paths.length; i++) {
        if (targets[i] == _posixRoot) {
          rootName = p.basename(paths[i]);
          continue;
        }
        mounted.add(_volume(paths[i], LocalVolumeKind.removable));
      }
    } else {
      final user = _userName;
      final [media, runMedia, mnt] = await Future.wait([
        user == null
            ? Future.value(const <String>[])
            : _children(p.join(_linuxMedia, user)),
        user == null
            ? Future.value(const <String>[])
            : _children(p.join(_linuxRunMedia, user)),
        _children(_linuxMnt),
      ]);
      for (final path in [...media, ...runMedia]) {
        mounted.add(_volume(path, LocalVolumeKind.removable));
      }
      for (final path in mnt) {
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

  Future<List<LocalVolume>> _windowsDrives() async {
    final systemDrive = (_env['SystemDrive'] ?? 'C:').toUpperCase();
    final drives = <LocalVolume>[];
    // C..Z — see the class doc for why A: and B: are never probed. All
    // at once: a disconnected mapped drive stalls for the SMB timeout,
    // and each letter waits on nobody else's.
    final letters = [
      for (var code = 0x43; code <= 0x5A; code++)
        '${String.fromCharCode(code)}:',
    ];
    final present = await Future.wait([
      for (final letter in letters) _isDirectory('$letter\\'),
    ]);
    for (var i = 0; i < letters.length; i++) {
      if (!present[i]) continue;
      final letter = letters[i];
      final root = '$letter\\';
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
    final xdg = _linux ? await _xdgUserDirs(home) : const <String, String>{};
    final candidates = [
      for (final (xdgKey, fallback) in _standardFolderNames)
        xdg[xdgKey] ?? p.join(home, fallback),
    ];
    final present = await Future.wait(candidates.map(_isDirectory));
    return [
      for (var i = 0; i < candidates.length; i++)
        if (present[i]) candidates[i],
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
  Future<Map<String, String>> _xdgUserDirs(String home) async {
    final configHome = _env['XDG_CONFIG_HOME'] ?? p.join(home, '.config');
    final file = File(p.join(configHome, 'user-dirs.dirs'));
    final String text;
    try {
      if (!await file.exists()) return const {};
      text = await file.readAsString();
    } on FileSystemException {
      return const {};
    }
    return parseXdgUserDirs(text, home: home);
  }

  @override
  Future<bool> isDirectory(String path) => _isDirectory(path);

  @override
  Stream<void> get changes {
    if (!_mac && !_linux) return const Stream.empty();
    late final StreamController<void> controller;
    final subscriptions = <StreamSubscription<FileSystemEvent>>[];
    // Bumped by every listen and cancel, so a parent probe that resolves
    // after its listener left never installs a watch.
    var generation = 0;
    controller = StreamController<void>.broadcast(
      onListen: () {
        final listen = ++generation;
        unawaited(() async {
          final parents = await _watchedParents();
          if (listen != generation) return;
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
        }());
      },
      onCancel: () {
        generation++;
        for (final subscription in subscriptions) {
          unawaited(subscription.cancel());
        }
        subscriptions.clear();
      },
    );
    return controller.stream;
  }

  Future<List<String>> _watchedParents() async {
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
    final present = await Future.wait(candidates.map(_isDirectory));
    return [
      for (var i = 0; i < candidates.length; i++)
        if (present[i]) candidates[i],
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
/// column, or null where there is no `df` (Windows), it fails, or it has
/// not answered within [timeout]: `df` over a dead hard NFS mount never
/// exits. Every caller treats the number as optional.
Future<int?> dfFreeSpaceBytes(
  String path, {
  LocalProcessRunner? run,
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (Platform.isWindows) return null;
  try {
    // -P forces one line per filesystem: without it a long device name
    // wraps and shifts every column the parser counts.
    final result = await _withinWallClock<ProcessResult?>(
      (run ?? Process.run)('df', ['-kP', path]),
      timeout,
      null,
    );
    if (result == null || result.exitCode != 0) return null;
    final kibibytes = parseDfAvailableKibibytes(result.stdout as String);
    return kibibytes == null ? null : kibibytes * 1024;
  } on Object {
    return null;
  }
}

/// [probe]'s answer, or [absent] once [limit] has passed or the probe
/// failed: a probe that cannot answer reads as "absent", never as an
/// error the enumeration has to survive.
///
/// The limit bounds how long a syscall blocked on a dead mount may hold
/// the caller, which is wall-clock time by definition, so its timer runs
/// on the root zone: a fake clock (the widget-test binding drives one)
/// neither advances it nor holds it as pending work, while the real I/O
/// it guards runs on the real clock either way.
Future<T> _withinWallClock<T>(Future<T> probe, Duration limit, T absent) {
  final answer = Completer<T>();
  final timer = Zone.root.createTimer(limit, () {
    if (!answer.isCompleted) answer.complete(absent);
  });
  probe.then(
    (value) {
      timer.cancel();
      if (!answer.isCompleted) answer.complete(value);
    },
    onError: (Object _) {
      timer.cancel();
      if (!answer.isCompleted) answer.complete(absent);
    },
  );
  return answer.future;
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
