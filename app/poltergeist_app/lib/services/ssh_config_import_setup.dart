import 'package:poltergeist_core/poltergeist_core.dart';

import 'bookmark_store.dart';
import 'ssh_config_file_source.dart';
import 'uuid.dart';

/// What the app shell needs to register the D22 ssh_config import command
/// (07 §3.3): the pinned-importer service, the destination bookmark
/// store, and the config file to read.
///
/// One value keeps filesystem-touching services out of widget-build time:
/// `main.dart` builds the wiring once and hands it down.
class SshConfigImportSetup {
  const SshConfigImportSetup({
    required this.service,
    required this.bookmarks,
    required this.configPath,
  });

  final SshConfigImportService service;
  final BookmarkRepository bookmarks;
  final String configPath;
}

/// Builds the D22 import wiring for the platform described by
/// [environment]: `~/.ssh/config` read read-only, imported rows persisted
/// through [bookmarks].
///
/// The store is the caller's: the Connections surface lists the same
/// bookmarks, and two instances over one file would race their write tails.
///
/// Returns null when no home directory resolves, or on Windows — the core
/// import service normalizes POSIX paths (its include base is `.ssh/`), so
/// a drive-letter config path cannot be read until that lands. The command
/// stays unregistered rather than offering a surface that always fails.
SshConfigImportSetup? buildSshConfigImportSetup({
  required Map<String, String> environment,
  required bool isMacOS,
  required bool isWindows,
  required BookmarkRepository bookmarks,
}) {
  if (isWindows) return null;

  // Recover the real home when a macOS sandbox points HOME at the app
  // container (the ported `expandHomePath` rule): `~/.ssh` means the
  // user's keys, never the container's.
  final home = expandHomePath('~', environment: environment, isMacOS: isMacOS);
  if (home == '~') return null;

  return SshConfigImportSetup(
    service: SshConfigImportService(
      homeDirectory: home,
      source: const LocalSshConfigFileSource(),
      mintId: uuidV4,
    ),
    bookmarks: bookmarks,
    // ssh_config paths are POSIX-shaped: the core import service
    // normalizes on `/` (its include base is `.ssh/`), so these literal
    // separators are deliberate.
    configPath: '$home/.ssh/config',
  );
}
