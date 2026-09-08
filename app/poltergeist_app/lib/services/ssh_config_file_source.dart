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
      final file = File(path);
      if (!await file.exists()) return null;
      return await file.readAsString();
    } on Object {
      // Unreadable (permissions, races): the caller decides whether that
      // is a fatal root-config failure or a noted skipped include.
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
      // Byte-order sort: ssh processes glob results in lexical order.
      files.sort();
      return files;
    } on Object {
      return null;
    }
  }
}
