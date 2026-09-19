/// Group sectioning for the bookmark list — the same rules Séance's
/// `server_grouping.dart` applies to servers (02 §4 names it the pattern):
/// sections keyed case-insensitively by group name, sorted by that key, the
/// ungrouped remainder last, and a single anonymous section when nothing is
/// filed anywhere so a flat list needs no headers. Members keep the 04 §2.5
/// order (`sortKey`, `id` tiebreak). Written fresh for the `Bookmark` model —
/// no Séance source is copied — so collapse state stays a UI concern (04
/// §2.3 keeps it device-local regardless).
library;

import 'package:seance_core/seance_core.dart';

import 'sort_key.dart';

/// The section key for bookmarks with no group. Empty is safe as a sentinel
/// because a real group key never is: `normalizeServerGroup` turns a blank
/// name into null, which is what puts a bookmark here.
const String kUngroupedBookmarkKey = '';

/// One section of the bookmark list: a named group or the ungrouped
/// remainder.
final class BookmarkGroupSection {
  /// The group's name as the user spelled it, or null for the ungrouped
  /// remainder — which is also what a list with no groups collapses to, so
  /// the sidebar knows not to draw headers.
  final String? name;

  /// Members in the section, sorted by (`sortKey`, `id`).
  final List<Bookmark> bookmarks;

  const BookmarkGroupSection({required this.name, required this.bookmarks});

  /// The identity this section is collapsed and re-found by, stable across
  /// a re-sort and across a member being renamed.
  String get key => name == null ? kUngroupedBookmarkKey : serverGroupKey(name!);
}

/// [bookmarks] split into sections: one per group, sorted by
/// case-insensitive name, with the ungrouped remainder last.
///
/// Returns a single unnamed section when no bookmark carries a group, so
/// the common case renders as a plain list. The displayed spelling is the
/// one on the first member in sort order, so a group does not rename itself
/// when a member is edited elsewhere in the list.
List<BookmarkGroupSection> groupBookmarks(Iterable<Bookmark> bookmarks) {
  final sorted = bookmarks.toList()..sort(compareBookmarkSortKeys);
  final byKey = <String, List<Bookmark>>{};
  final names = <String, String>{};
  final ungrouped = <Bookmark>[];

  for (final bookmark in sorted) {
    final group = normalizeServerGroup(bookmark.group);
    if (group == null) {
      ungrouped.add(bookmark);
      continue;
    }
    final key = serverGroupKey(group);
    byKey.putIfAbsent(key, () => []).add(bookmark);
    names.putIfAbsent(key, () => group);
  }

  if (byKey.isEmpty) {
    return [BookmarkGroupSection(name: null, bookmarks: sorted)];
  }

  final keys = byKey.keys.toList()..sort();
  return [
    for (final key in keys)
      BookmarkGroupSection(name: names[key], bookmarks: byKey[key]!),
    if (ungrouped.isNotEmpty)
      BookmarkGroupSection(name: null, bookmarks: ungrouped),
  ];
}

/// The distinct group names in [bookmarks], sorted, for offering existing
/// groups in an editor instead of making the user retype (and misspell) one.
List<String> bookmarkGroupNames(Iterable<Bookmark> bookmarks) {
  final names = <String, String>{};
  for (final bookmark in bookmarks) {
    final group = normalizeServerGroup(bookmark.group);
    if (group != null) names.putIfAbsent(serverGroupKey(group), () => group);
  }
  final keys = names.keys.toList()..sort();
  return [for (final key in keys) names[key]!];
}
