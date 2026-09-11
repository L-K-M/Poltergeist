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

/// `<name>.poltergeist-<8 hex>.backup` — the crash-recovery pattern,
/// derived from the same constants the dance builds backup names from
/// (the hex class matches `_randomHexString`'s lowercase output) so a
/// future prefix/length/suffix change cannot silently strand crashed
/// replaces behind a pattern the sweep no longer matches.
/// `(.+)` (not `(.*)`) so a basename starting with the suffix can never
/// restore to an empty name.
final RegExp _backupNamePattern = RegExp(
  '^(.+)${RegExp.escape(_transferPrefix)}'
  '[0-9a-f]{$_randomSuffixLength}${RegExp.escape(_backupSuffix)}\$',
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
  // 09 §3.5's boundary rule: an over-long component fails here with a
  // clean FormatException instead of mid-transfer as an opaque
  // ENAMETOOLONG. POSIX NAME_MAX counts UTF-8 bytes.
  if (_utf8ByteLength(name) > _maxFileNameBytes) {
    throw FormatException(
      '"$name" exceeds the $_maxFileNameBytes-byte file-name limit.',
    );
  }
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
/// Pre-existing symlinked *ancestors* are refused too — the strict
/// containment posture — so a root like macOS `/tmp` (a symlink to
/// `/private/tmp`) is rejected: pass roots whose existing portion has
/// been resolved (`Directory.resolveSymbolicLinksSync`) first —
/// `Directory.systemTemp` itself begins at a symlinked component on
/// macOS (`/tmp` or `/var/folders/...`) and is rejected unresolved.
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
      // A static path-shape rejection, not a type observation — the
      // distinct message keeps a lexical `..` from sending anyone
      // hunting for symlinks that do not exist.
      throw FileSystemException(
        'Refusing to traverse an unsafe path component',
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
/// silently swap the user's link for a plain file. The target's
/// basename is validated like every locally materialized name (09
/// §3.5) — this is the file-commit point, the leaf-level twin of
/// [ensureSafeLocalDirectory]'s per-component check. Before the dance
/// runs, an interrupted earlier replace of the *same* target is
/// repaired by [restoreOrphanedLocalBackups] (best effort — the dance
/// is correct either way), scoped to this target so a concurrent
/// dance's live backup for another name in the directory is never
/// consumed.
Future<void> replaceLocalFile(File part, File target) async {
  validateLocalName(p.basename(target.path));
  try {
    await restoreOrphanedLocalBackups(
      Directory(p.dirname(target.path)),
      targetBasename: p.basename(target.path),
    );
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
  // The symmetric refusal on the part side: a staged part swapped for
  // a symlink would have the dance install the *link* as the user's
  // file — rename moves the link itself, it does not follow it.
  final partType = await FileSystemEntity.type(part.path, followLinks: false);
  if (partType != FileSystemEntityType.file) {
    throw FileSystemException(
      'Refusing to replace with a non-regular local file',
      part.path,
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
/// missing (03 §2.3). The startup sweep (and the target-scoped sweep
/// inside every replace) renames such a backup back to its target
/// before anything leaves the user's file looking deleted.
///
/// [targetBasename] narrows the repair to one target's orphans —
/// [replaceLocalFile] passes its own target's name, because a
/// directory-wide restore there could consume a *concurrent* dance's
/// live backup (its target is absent precisely between the two
/// renames) and, on Windows, fail that transfer. A null
/// [targetBasename] (the startup sweep) repairs every orphan in the
/// directory — at a moment no dance is known to be in flight.
///
/// Backups whose target still exists are left alone (stale, not
/// orphaned), as are names outside the pattern and non-file entries.
/// The `<name>.poltergeist-<8 hex>.backup` shape is reserved for this
/// dance by convention — application code must not write other files
/// matching it. When several orphans share one absent target the newest
/// (by mtime) is restored; the others stay parked — never deleted, and
/// if the newest cannot be renamed, the older ones stay parked too
/// (restoring an older generation would strand the newest forever).
/// An orphan whose rename fails (locked, permission-denied, vanished)
/// stays parked for a later sweep and never aborts the remaining
/// restores — aborting would strand exactly the interrupted replaces
/// this function exists to repair. The absent-target check and the
/// rename are advisory against races (dart:io has no no-clobber
/// rename): a target created in the window between them is replaced —
/// the same accepted posture as 03 §2.2's rename preflight.
Future<void> restoreOrphanedLocalBackups(
  Directory directory, {
  String? targetBasename,
}) async {
  final orphans = <(File, DateTime, String)>[];
  try {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final match = _backupNamePattern.firstMatch(p.basename(entity.path));
      if (match == null) continue;
      if (targetBasename != null && match.group(1)! != targetBasename) {
        continue;
      }
      final FileStat stat;
      try {
        stat = await entity.stat();
      } on FileSystemException {
        // Vanished between listing and stat: nothing to restore here.
        continue;
      }
      // A vanished entry stats as notFound with an epoch mtime —
      // enqueueing it would only pollute the ordering.
      if (stat.type == FileSystemEntityType.notFound) continue;
      orphans.add((entity, stat.modified, match.group(1)!));
    }
  } on FileSystemException {
    // Directory missing, unreadable, or deleted mid-sweep: repair what
    // was already collected; the next sweep retries the rest. The
    // sweep is best-effort by contract — aborting here would fail an
    // app's startup pass over a since-deleted destination root.
  }
  orphans.sort((a, b) => b.$2.compareTo(a.$2));
  // Equal mtimes (coarse filesystem granularity) are ordered
  // arbitrarily: List.sort is not stable and no portable
  // rename-recency signal exists — a tie may restore an older
  // generation and strand the other parked until the target
  // disappears again. Documented rather than papered over.
  // A target whose newest orphan could not be renamed keeps its older
  // orphans parked too: restoring an older generation would strand the
  // newest data forever (the target would then exist, so no later sweep
  // repairs it).
  final unrestorable = <String>{};
  for (final (orphan, _, targetName) in orphans) {
    if (unrestorable.contains(targetName)) continue;
    final targetPath = p.join(p.dirname(orphan.path), targetName);
    if (await FileSystemEntity.type(targetPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      continue;
    }
    try {
      await orphan.rename(targetPath);
    } on FileSystemException {
      // Locked, permission-denied, or vanished mid-sweep: park it and
      // its same-target siblings for the next pass, but keep repairing
      // unrelated targets.
      unrestorable.add(targetName);
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
