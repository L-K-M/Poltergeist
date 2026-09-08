import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';

/// The dart:io half of the import seam (D22): read-only access to
/// `~/.ssh/config` and whatever its top-level includes reference — the
/// same local-file trust already granted to the config itself. Nothing
/// here writes, moves, or rotates; the source is injectable so the
/// preview dialog and its tests never touch a real home directory.
class LocalSshConfigFileSource implements SshConfigFileSource {
  const LocalSshConfigFileSource();

  @override
  Future<String?> readText(String path) async {
    try {
      // Only open regular files (missing paths report notFound): an
      // Include pointing at a FIFO or device file would otherwise read
      // forever waiting for EOF, hanging the preview with no error.
      if (await FileSystemEntity.type(path) != FileSystemEntityType.file) {
        return null;
      }
      final file = File(path);
      // ssh treats the config as bytes; a stray cp1252 smart quote or
      // Latin-1 hostname must not make a readable file look unreadable.
      // Malformed sequences decode to U+FFFD, which no ssh directive
      // cares about in practice.
      return await file.readAsString(
        encoding: const Utf8Codec(allowMalformed: true),
      );
    } on FileSystemException {
      // Unreadable (permissions, races): the caller decides whether that
      // is a fatal root-config failure or a noted skipped include.
      // Programming errors (Error subtypes) stay loud instead of
      // masquerading as an unreadable config.
      return null;
    }
  }

  @override
  Future<List<String>?> listLexical(String directory) async {
    try {
      final dir = Directory(directory);
      if (!await dir.exists()) return null;

      final files = <String>[];
      await for (final entry in dir.list(followLinks: true)) {
        // followLinks resolves symlinked entries, but the stream still
        // reports them as Link; only keep real targets that are files.
        if (await FileSystemEntity.isFile(entry.path)) {
          files.add(entry.path);
        }
      }
      // Deterministic code-unit sort. OpenSSH's glob(3) sorts with
      // strcoll (locale-dependent) — an accepted approximation that only
      // diverges for non-ASCII include filenames; dotfile filtering is
      // the matcher's job (glob `*` never matches a leading dot).
      files.sort();
      return files;
    } on FileSystemException {
      return null;
    }
  }
}
