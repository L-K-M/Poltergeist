import 'package:flutter/material.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../services/local_volumes.dart';
import '../services/pane_location.dart';
import '../theme/family_hues.dart';
import 'server_appearance.dart';

/// A place's glyph and family hue (D34): what a sidebar row's tile, a
/// Home disc, and the palette's favorite badge draw for a device or a
/// favorite that carries no colour of its own. A favorite's own colour
/// always wins; this is the default it falls back to.
typedef PlaceGlyph = ({IconData glyph, FamilyHue hue});

/// DEVICES: Home in the places blue, the disks in graphite, and a
/// removable volume in the cargo brown of things you carry.
PlaceGlyph volumeGlyph(LocalVolumeKind kind) => switch (kind) {
  LocalVolumeKind.home => (glyph: Icons.home, hue: FamilyHue.blue),
  LocalVolumeKind.root => (glyph: Icons.computer, hue: FamilyHue.graphite),
  LocalVolumeKind.removable => (glyph: Icons.usb, hue: FamilyHue.brown),
  LocalVolumeKind.fixed => (glyph: Icons.storage, hue: FamilyHue.graphite),
};

/// A phone's one DEVICES row.
const PlaceGlyph thisDeviceGlyph = (
  glyph: Icons.smartphone,
  hue: FamilyHue.blue,
);

/// A live Quick Connect session: go, live.
const PlaceGlyph quickConnectSessionGlyph = (
  glyph: Icons.bolt,
  hue: FamilyHue.green,
);

/// [bookmark]'s glyph and hue. A local folder takes the icon the user
/// picked for it, else (when it is one of [home]'s standard folders)
/// that folder's own glyph (Finder's Downloads arrow, Pictures' photo),
/// else a folder; a remote location its server's glyph; a workspace the
/// saved-recipe teal; a saved sync the sync indigo.
PlaceGlyph favoriteGlyph(Bookmark bookmark, {String? home}) =>
    switch (bookmark.kind) {
      BookmarkKind.localFolder =>
        bookmark.icon != null
            ? (glyph: serverIconData(bookmark.icon), hue: FamilyHue.blue)
            : standardFolderGlyph(bookmark.localPath, home: home) ??
                  (glyph: Icons.folder, hue: FamilyHue.blue),
      BookmarkKind.remotePath => (
        glyph: serverIconData(bookmark.icon),
        hue: FamilyHue.blue,
      ),
      BookmarkKind.workspace => (
        glyph: Icons.space_dashboard,
        hue: FamilyHue.teal,
      ),
      BookmarkKind.savedSync => (glyph: Icons.sync_alt, hue: FamilyHue.indigo),
    };

/// The standard folders directly under a home folder, by lowercase
/// name, in the hue of what they hold (D34's kind hues).
const Map<String, PlaceGlyph> _standardFolders = {
  'desktop': (glyph: Icons.desktop_windows, hue: FamilyHue.blue),
  'documents': (glyph: Icons.description, hue: FamilyHue.blue),
  'downloads': (glyph: Icons.download, hue: FamilyHue.cyan),
  'pictures': (glyph: Icons.photo, hue: FamilyHue.pink),
  'photos': (glyph: Icons.photo, hue: FamilyHue.pink),
  'music': (glyph: Icons.music_note, hue: FamilyHue.purple),
  'movies': (glyph: Icons.movie, hue: FamilyHue.purple),
  'videos': (glyph: Icons.movie, hue: FamilyHue.purple),
  'applications': (glyph: Icons.apps, hue: FamilyHue.blue),
};

/// [path]'s glyph when it is a standard folder directly inside [home]
/// (`~/Downloads`, not `/srv/Downloads`: a name alone is not a
/// promise), else null. Names match case-insensitively, as the
/// case-insensitive macOS and Windows file systems do.
PlaceGlyph? standardFolderGlyph(String? path, {required String? home}) {
  if (path == null || home == null) return null;
  final parent = paneParentPath(path);
  if (parent == path || _trimmed(parent) != _trimmed(home)) return null;
  return _standardFolders[paneLastSegment(path).toLowerCase()];
}

String _trimmed(String path) {
  final separator = paneSeparator(path);
  var trimmed = path;
  while (trimmed.length > 1 && trimmed.endsWith(separator)) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}
