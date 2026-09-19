// D15 Linux trash round-trip (03 §7.3, 07 §3.5's exit criterion): the
// production GioTrashBackend — real Process.run spawns, no seams —
// delivers a real file to the freedesktop trash and the spec-level
// listing (.trashinfo + files/) proves it landed; the file is then
// moved back, which is the restore slice's own mechanism (05's
// DeletionDate/Path contract is not yet shipped — see the QA note).
//
// Guarded: where `gio` is absent the suite skips rather than fails —
// the backend's own answer in that case is `unavailable`, which the
// unit tests already pin. CI's ubuntu leg installs libglib2.0-bin so
// the round-trip really runs there.

@Timeout(Duration(minutes: 2))
@TestOn('linux')
library;

import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

/// Every directory a trashed file can land in, per the FreeDesktop
/// Trash spec: the home trash plus the volume trash at the mount point
/// of [trashedFrom] (`<topdir>/.Trash-$UID` / `<topdir>/.Trash/$UID`) —
/// `/tmp` is tmpfs on many hosts, so the volume half is real, not a
/// fallback. Call while [trashedFrom]'s parent still exists — the
/// mount-point stat targets the parent directory.
List<Directory> _trashInfoDirs(String trashedFrom) {
  final dirs = <Directory>[];
  // `UID` is a shell variable bash/zsh never export; `id -u` is reliable.
  final uid = Process.runSync('id', const ['-u']).stdout.toString().trim();
  final dataHome =
      Platform.environment['XDG_DATA_HOME'] ??
      '${Platform.environment['HOME']}/.local/share';
  dirs.add(Directory('$dataHome/Trash/info'));
  // The file's own topdir: `stat -c %m` prints the mount point, which is
  // where the spec puts the volume trash — not a guessed '/' or '/tmp'.
  // The parent directory, not the file: the file may already be trashed
  // (the teardown path) while its parent still exists.
  final mount =
      Process.runSync('stat', [
            '-c',
            '%m',
            File(trashedFrom).parent.path,
          ])
          .stdout
          .toString()
          .trim();
  if (uid.isNotEmpty && mount.isNotEmpty) {
    final top = mount.endsWith('/') ? mount : '$mount/';
    dirs.add(Directory('$top.Trash-$uid/info'));
    dirs.add(Directory('$top.Trash/$uid/info'));
  }
  return dirs;
}

/// Finds the .trashinfo record for [path] inside [infoDirs] — Path= is
/// percent-encoded per the spec, so decode before comparing.
File? _findTrashInfo(String path, List<Directory> infoDirs) {
  for (final dir in infoDirs) {
    if (!dir.existsSync()) continue;
    for (final entry in dir.listSync()) {
      if (entry is! File || !entry.path.endsWith('.trashinfo')) continue;
      for (final line in entry.readAsLinesSync()) {
        if (line.startsWith('Path=') &&
            Uri.decodeComponent(line.substring(5)) == path) {
          return entry;
        }
      }
    }
  }
  return null;
}

/// One synchronous probe at suite load — the `skip:` reason must be a
/// build-time value, and this is the same `gio --version` contract the
/// backend's cached probe runs.
bool _gioPresent() {
  try {
    return Process.runSync('gio', const ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void main() {
  test('gio trash delivers a file and it restores from the listing', () async {
    final backend = GioTrashBackend();

    final fixture = await Directory.systemTemp.createTemp(
      'poltergeist-trash-roundtrip-',
    );
    addTearDown(() async {
      if (fixture.existsSync()) await fixture.delete(recursive: true);
    });
    final file = File('${fixture.path}/roundtrip victim.txt')
      ..writeAsStringSync('roundtrip');

    // Snapshot the candidate dirs while the file exists — after trashing
    // (and after the fixture teardown deletes its parent) the mount
    // point can no longer be stat'ed, so the teardown reuses this list.
    final infoDirs = _trashInfoDirs(file.path);
    addTearDown(() async {
      // Best effort: a failed expect before the restore must not strand
      // the payload and record in the real user trash.
      final info = _findTrashInfo(file.path, infoDirs);
      if (info == null) return;
      final name = info.uri.pathSegments.last;
      final payload = File(
        '${info.parent.parent.path}/files/'
        '${name.substring(0, name.length - '.trashinfo'.length)}',
      );
      if (payload.existsSync()) await payload.delete();
      await info.delete();
    });
    await backend.trash(file.path);
    expect(file.existsSync(), isFalse, reason: 'trash moved the file out');

    // The restore-listing half of the round-trip: the spec record exists
    // and points back at the origin, and the payload sits beside it.
    final info = _findTrashInfo(file.path, infoDirs);
    expect(
      info,
      isNotNull,
      reason:
          'a .trashinfo record names the origin — that IS the '
          'restore listing every freedesktop trash reader shows',
    );
    final infoName = info!.uri.pathSegments.last;
    final trashed = File(
      '${info.parent.parent.path}/files/'
      '${infoName.substring(0, infoName.length - '.trashinfo'.length)}',
    );
    expect(trashed.existsSync(), isTrue);

    // Restore: move the payload back to the Path= origin and drop the
    // record — exactly what the future restore slice does (03 §7.3).
    await trashed.rename(file.path);
    await info.delete();
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), 'roundtrip');
    // The suite reports a real skip where the primitive is absent rather
    // than passing vacuously — CI's ubuntu leg installs libglib2.0-bin.
  }, skip: _gioPresent() ? false : 'gio not installed (libglib2.0-bin)');
}
