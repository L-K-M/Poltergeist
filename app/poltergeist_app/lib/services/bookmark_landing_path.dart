import 'package:poltergeist_core/poltergeist_core.dart' show BookmarkKind;

/// [bookmark] (a record's JSON) with a remotePath record's landing path
/// filled in as `/`, the pane's spelling of "the server's home" on bind
/// (PaneController's connect).
///
/// A Quick Connect to `sftp://user@host` and a SERVERS catalog open bind
/// a live bookmark with no landing path, which the Bookmark model refuses
/// to decode. The session document and the recents both persist that
/// live record: written verbatim, it failed every later session save (the
/// store re-reads before it writes) and the relaunch, and dropped the
/// recent entry. Both apply this on write, and on read so a document
/// already written that way decodes again.
Map<String, dynamic> withRemoteLandingPath(Map<String, dynamic> bookmark) {
  if (bookmark['kind'] != BookmarkKind.remotePath.name ||
      bookmark['remotePath'] != null) {
    return bookmark;
  }
  return {...bookmark, 'remotePath': '/'};
}
