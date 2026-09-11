import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

// Ported from Séance
// app/seance_app/lib/services/remote_files_controller.dart @ 2e6d1f1
// (the four private statics); see docs/PORTS.md.

/// The local-safety half of 03 §2.3: one implementation, four call
/// sites — `LocalFileSystem.upload` today, and the transfer queue's
/// download executor, the checkout store, and the sync executor as
/// those land (M4/M7/M8).
///
/// These are lexical and commit-path utilities, deliberately below the
/// VFS's typed error taxonomy: they throw raw `FormatException` for
/// precondition violations and `FileSystemException` for refusals, and
/// each caller funnels them through its own guard (03 §2.2). The
/// safety rules themselves are shared with Séance and never diverge
/// without a docs/PORTS.md entry (09 §4).

// Backup siblings: `.poltergeist-` everywhere Séance names `.seance-`
// (08 §2's sanctioned port-time rename). The 8-hex random suffix is
// the plan's documented shape (03 §2.3) — the same shape the pinned
// adapter's `.seance-upload-<8 hex>.tmp` temps use — and the crash
// sweep below matches exactly this pattern.
const String _transferPrefix = '.poltergeist-';
const String _backupSuffix = '.backup';
const int _randomSuffixLength = 8;

// NAME_MAX 255 is the floor across the supported platform matrix;
// overshooting it fails the replace rather than truncating into a
// collision (03 §2.3).
const int _maxFileNameBytes = 255;

/// `<name>.poltergeist-<8 hex>.backup` — the crash-recovery pattern.
/// `(.+)` (not `(.*)`) so a basename starting with the suffix can never
/// restore to an empty name.
final RegExp _backupNamePattern = RegExp(
  r'^(.+)\.poltergeist-[0-9a-f]{8}\.backup$',
);

final Random _random = Random.secure();

/// Séance's forbidden class for local destination names, minus the
/// backslash (owned by [validatePathComponent] for every destination).
final RegExp _forbiddenLocalChars = RegExp(r'[:*?"<>|\x00-\x1f\x7f]');

/// Win32 strips trailing dots and spaces from the base segment before
/// its reserved-name match ('aux .txt' is as reserved as 'aux.txt').
final RegExp _trailingDotOrSpace = RegExp(r'[ .]+$');

/// The lexical half of the local path safety rules (03 §2.3, 09 §3.5).
///
/// No empty component, no `.`/`..`, no separators. `\` is rejected
/// everywhere on purpose: it is legal POSIX filename data, but a
/// component carrying one is overwhelmingly an escaping bug, and it is
/// the path separator on a Windows destination — a server-reported name
/// like `..\..\x` that passes a `/`-only check becomes traversal the
/// moment a Windows build joins it into a local path.
void validatePathComponent(String component) {
  if (component.isEmpty ||
      component == '.' ||
      component == '..' ||
      component.contains('/') ||
      component.contains(r'\') ||
      component.contains('\x00')) {
    throw FormatException('"$component" is not a safe path component.');
  }
}

/// [validatePathComponent] plus the Windows destination hazards:
/// forbidden characters, a trailing dot or space (Win32 silently strips
/// them into a name the next listing won't match), and reserved device
/// names matched by base name — the segment before the first dot — so
/// `NUL.txt` and `Com1.tar.gz` are as invalid as the bare names.
///
/// The checks are destination-aware and apply on every platform: a
/// clean boundary error beats a confusing mid-transfer failure on the
/// host whose filesystem cares (09 §3.5).
void validateLocalName(String name) {
  validatePathComponent(name);
  if (_forbiddenLocalChars.hasMatch(name) ||
      name.endsWith('.') ||
      name.endsWith(' ')) {
    throw FormatException('"$name" is not a safe local file name.');
  }
  // Win32 matches device names ignoring trailing dots and spaces in
  // the base segment, so strip them before the reserved match
  // ('aux .txt' is as reserved as 'aux.txt').
  final base = name.split('.').first.replaceAll(_trailingDotOrSpace, '');
  if (_windowsReservedName.hasMatch(base)) {
    throw FormatException('"$name" is not a safe local file name.');
  }
}

/// 09 §3.5's full Windows reserved list: the DOS names plus CLOCK$,
/// CONIN$/CONOUT$, and the superscript COM/LPT spellings (¹²³ are real
/// Win32 alternates), matched on the base segment, case-insensitively.
/// Raw string on purpose: `\$` must reach the regex as an escaped
/// literal dollar — in a non-raw string `\$` collapses to a bare `$`,
/// which anchors the branch and silently kills it (the bug these
/// tests caught in the pre-port original).
final RegExp _windowsReservedName = RegExp(
  r'^(con|prn|aux|nul|clock\$|com[1-9\u00b9\u00b2\u00b3]|lpt[1-9\u00b9\u00b2\u00b3]|conin\$|conout\$)$',
  caseSensitive: false,
);

/// Creates [path] and every missing parent while refusing to traverse
/// through symlinks or non-directories (`followLinks: false` at every
/// component) — the containment walk 09 §3.5 names as the enforcement
/// point for locally built destinations.
///
/// Every component the walk *creates* is validated by [validateLocalName]
/// (09 §3.5: each directory a recursive walk materializes is itself a
/// target name at its own creation, so `pkg/CON/x.txt` fails at the
/// `CON` mkdir); existing ancestors are shape- and type-checked only —
/// a legal POSIX name that Windows would refuse stays traversable. A
/// lexical `.`/`..` component is rejected wherever it sits. The checks
/// are advisory against races, exactly like 03 §2.2's rename preflight.
Future<void> ensureSafeLocalDirectory(String path) async {
  final parts = p.context
      .split(Directory(path).absolute.path)
      .where((part) => part.isNotEmpty)
      .toList();
  // parts.first is the root chunk ('/' or 'C:\'); the walk starts there.
  var current = parts.first;
  for (var i = 1; i < parts.length; i++) {
    final component = parts[i];
    if (component == '.' ||
        component == '..' ||
        component.contains('/') ||
        component.contains(r'\') ||
        component.contains('\x00')) {
      throw FileSystemException(
        'Refusing to follow a non-directory or symbolic link',
        p.context.join(current, component),
      );
    }
    current = p.context.join(current, component);
    var type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      validateLocalName(component);
      await Directory(current).create();
      type = await FileSystemEntity.type(current, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Refusing to follow a non-directory or symbolic link',
        current,
      );
    }
  }
}

/// The backup-rename dance (03 §2.3): park [target] under a unique
/// `<target>.poltergeist-<8 hex>.backup` sibling, move [part] onto the
/// target, restore the backup on failure, and delete the backup only
/// after success — never delete-then-rename, which strands the user
/// with neither file when the second step fails.
///
/// Non-regular targets (links included) are refused first, and the
/// check itself does not follow links — a symlink to a regular file
/// would pass a stat-based "is regular" test and the replace would
/// silently swap the user's link for a plain file. Before the dance
/// runs, an interrupted earlier replace is repaired: any orphaned
/// backup beside the target is restored by [restoreOrphanedLocalBackups]
/// (best effort — the dance is correct either way).
Future<void> replaceLocalFile(File part, File target) async {
  try {
    await restoreOrphanedLocalBackups(Directory(p.dirname(target.path)));
  } on FileSystemException {
    // Best effort only — the replace itself must not fail on a
    // stranded sibling it could not repair.
  }

  final targetType = await FileSystemEntity.type(
    target.path,
    followLinks: false,
  );
  if (targetType == FileSystemEntityType.link ||
      (targetType != FileSystemEntityType.file &&
          targetType != FileSystemEntityType.notFound)) {
    throw FileSystemException(
      'Refusing to replace a non-regular local file',
      target.path,
    );
  }
  if (targetType == FileSystemEntityType.notFound) {
    await part.rename(target.path);
    return;
  }

  // The target's own name stays embedded in the backup name so the
  // crash-recovery sweep can strip the suffix and find what to restore
  // — never a fixed `.backup`, which the temp-prefix policy forbids
  // and which would clobber a pre-existing user `<target>.backup`.
  final backupPath =
      target.path + _transferPrefix + _randomHexString() + _backupSuffix;
  if (_utf8ByteLength(p.basename(backupPath)) > _maxFileNameBytes) {
    throw FileSystemException(
      'The backup name would exceed the filesystem file-name limit',
      target.path,
    );
  }
  final backup = File(backupPath);
  await target.rename(backup.path);
  try {
    await part.rename(target.path);
  } on FileSystemException {
    // Restore the original unless something else already took the
    // target name; the nested guard keeps a failed restore from
    // masking the original failure (the backup retains the content
    // under its suffixed name either way).
    try {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
    } on FileSystemException {
      // Best effort only — the rethrow below carries the real failure.
    }
    rethrow;
  }
  try {
    await backup.delete();
  } on FileSystemException {
    // Replacement succeeded. A stale backup is safer than deleting the
    // new destination or claiming the transfer failed after commit.
  }
}

/// Restores orphaned backup siblings in [directory]: a
/// `<name>.poltergeist-<8 hex>.backup` whose `<name>` is absent is an
/// interrupted [replaceLocalFile] — a crash or power loss between the
/// two renames strands the data in the hidden backup with the target
/// missing (03 §2.3). The startup sweep (and the sweep inside every
/// replace) renames such a backup back to its target before anything
/// leaves the user's file looking deleted.
///
/// Backups whose target still exists are left alone (stale, not
/// orphaned), as are names outside the pattern and non-file entries.
/// The `<name>.poltergeist-<8 hex>.backup` shape is reserved for this
/// dance by convention — application code must not write other files
/// matching it. When several orphans share one absent target the newest
/// (by mtime) is restored; the others stay parked — never deleted.
/// An orphan whose rename fails (locked, permission-denied, vanished)
/// stays parked for a later sweep and never aborts the remaining
/// restores — aborting would strand exactly the interrupted replaces
/// this function exists to repair.
Future<void> restoreOrphanedLocalBackups(Directory directory) async {
  final orphans = <(File, DateTime, String)>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) continue;
    final match = _backupNamePattern.firstMatch(p.basename(entity.path));
    if (match == null) continue;
    final stat = await FileStat.stat(entity.path);
    orphans.add((entity, stat.modified, match.group(1)!));
  }
  orphans.sort((a, b) => b.$2.compareTo(a.$2));
  for (final (orphan, _, targetName) in orphans) {
    final targetPath = p.join(p.dirname(orphan.path), targetName);
    if (await FileSystemEntity.type(targetPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      continue;
    }
    try {
      await orphan.rename(targetPath);
    } on FileSystemException {
      // Locked, permission-denied, or vanished mid-sweep: park it for
      // the next pass and keep repairing the rest.
    }
  }
}

String _randomHexString() => List.generate(
  _randomSuffixLength,
  (_) => _random.nextInt(16).toRadixString(16),
).join();

/// UTF-8 byte count without transcoding: 1 per ASCII unit, 2/3 per BMP
/// unit, 4 across a surrogate pair. A lone surrogate counts 3 — the
/// encoder substitutes U+FFFD, itself a 3-byte sequence — so the
/// NAME_MAX guard never under-counts.
int _utf8ByteLength(String value) {
  var total = 0;
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit < 0x80) {
      total += 1;
    } else if (unit < 0x800) {
      total += 2;
    } else if (unit >= 0xD800 &&
        unit <= 0xDBFF &&
        i + 1 < units.length &&
        units[i + 1] >= 0xDC00 &&
        units[i + 1] <= 0xDFFF) {
      total += 4;
      i++;
    } else {
      total += 3;
    }
  }
  return total;
}
