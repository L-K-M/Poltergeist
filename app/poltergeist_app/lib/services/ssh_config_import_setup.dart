import 'package:poltergeist_core/poltergeist_core.dart';

import 'bookmark_store.dart';

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
