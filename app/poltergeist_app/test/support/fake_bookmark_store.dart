import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';

/// In-memory [BookmarkStore]: consumers depend on the seam, never on
/// `dart:io` (the on-disk behavior is covered in `bookmark_store_test`).
/// Mirrors the file store's contracts that matter to app code — sorted
/// loads, `updatedAt` stamping on [save], local-change emissions, and the
/// neighbor math of [sortKeyForInsert]/[moveToGroup]/[reorder] — while the
/// public [bookmarks] list stays directly scriptable.
final class FakeBookmarkStore implements BookmarkStore {
  FakeBookmarkStore([this.bookmarks = const []]);

  /// The stored rows; assignable so a test can re-seed between reloads.
  List<Bookmark> bookmarks;

  /// Thrown by [load] instead of returning rows.
  Object? failure;

  /// Thrown by [upsertAll] instead of recording rows.
  Object? upsertFailure;

  /// Thrown by [save] instead of recording the row.
  Object? saveFailure;

  int loadCalls = 0;
  final upserted = <Bookmark>[];

  /// Parks a load until completed — the superseded-load regression.
  Completer<void>? gate;

  /// Stamps `updatedAt` on local edits; injectable for ordering-sensitive
  /// assertions. Defaults to wall clock like the file store.
  DateTime Function() now = DateTime.now;

  final _changes = StreamController<BookmarkStoreChange>.broadcast(sync: true);

  /// Closes the [changes] lane — the broadcast controller would otherwise
  /// keep the test's pending-timer check awake.
  Future<void> close() => _changes.close();

  List<Bookmark> _sorted() => List.of(bookmarks)..sort(compareBookmarkSortKeys);

  @override
  Stream<BookmarkStoreChange> get changes => _changes.stream;

  @override
  Future<List<Bookmark>> load() async {
    loadCalls++;
    // Snapshotted before the gate: a parked load returns what the store held
    // when it was asked, which is what makes a stale completion observable.
    final snapshot = List<Bookmark>.unmodifiable(_sorted());
    final gate = this.gate;
    if (gate != null) await gate.future;
    final failure = this.failure;
    if (failure != null) throw failure;
    return snapshot;
  }

  @override
  Future<Bookmark?> byId(String id) async {
    // Mutations resolve their target here — read the rows directly so a
    // scripted gate/failure (a LOAD-path script) cannot wedge a reorder
    // or inflate loadCalls (the file store reads its rows, not load()).
    for (final bookmark in _sorted()) {
      if (bookmark.id == id) return bookmark;
    }
    return null;
  }

  @override
  Future<List<BookmarkGroupSection>> sections() async =>
      groupBookmarks(await load());

  @override
  Future<List<String>> groupNames() async => bookmarkGroupNames(await load());

  @override
  Future<String> sortKeyForInsert({
    String? group,
    String? beforeId,
    String? afterId,
  }) async {
    final target = normalizeServerGroup(group);
    final members = _membersOf(target, exclude: null);
    return sortKeyBetween(
      _neighborKey(members, beforeId),
      _neighborKey(members, afterId),
    );
  }

  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {
    final upsertFailure = this.upsertFailure;
    if (upsertFailure != null) throw upsertFailure;
    // Materialized once: a lazy or one-shot iterable must not enumerate
    // differently across the recording, the id set, and the rows.
    final incoming = List<Bookmark>.of(bookmarks);
    upserted.addAll(incoming);
    _upsert(incoming);
  }

  void _upsert(List<Bookmark> incoming) {
    // Update-or-insert by id, like the file store: an upserted bookmark
    // replaces its row instead of appending a duplicate.
    final ids = incoming.map((bookmark) => bookmark.id).toSet();
    bookmarks = [
      ...bookmarks.where((bookmark) => !ids.contains(bookmark.id)),
      ...incoming,
    ];
  }

  @override
  Future<Bookmark> save(Bookmark bookmark) async {
    final saveFailure = this.saveFailure;
    if (saveFailure != null) throw saveFailure;
    final stamped = _copy(bookmark, updatedAt: now().toUtc());
    _upsert([stamped]);
    _changes.add(BookmarkSavedChange(stamped));
    return stamped;
  }

  @override
  Future<bool> remove(String id) async {
    final before = bookmarks.length;
    bookmarks = [
      for (final bookmark in bookmarks)
        if (bookmark.id != id) bookmark,
    ];
    final removed = bookmarks.length != before;
    if (removed) _changes.add(BookmarkRemovedChange(id));
    return removed;
  }

  @override
  Future<Bookmark> moveToGroup(
    String id,
    String? group, {
    String? beforeId,
    String? afterId,
  }) async {
    final bookmark = await byId(id);
    if (bookmark == null) {
      throw ArgumentError.value(id, 'id', 'unknown bookmark');
    }
    final target = normalizeServerGroup(group);
    final members = _membersOf(target, exclude: id);
    String? beforeKey;
    String? afterKey;
    if (beforeId == null && afterId == null) {
      // No neighbors named: append at the target group's tail.
      beforeKey = members.isEmpty ? null : members.last.sortKey;
    } else {
      beforeKey = _neighborKey(members, beforeId);
      afterKey = _neighborKey(members, afterId);
      // One named neighbor bounds the other side by the adjacent member:
      // "after b" means between b and what follows it, not the tail.
      if (beforeId != null && afterId == null) {
        final index = members.indexWhere((m) => m.id == beforeId);
        afterKey = index + 1 < members.length
            ? members[index + 1].sortKey
            : null;
      } else if (afterId != null && beforeId == null) {
        final index = members.indexWhere((m) => m.id == afterId);
        beforeKey = index > 0 ? members[index - 1].sortKey : null;
      }
    }
    final moved = _copy(
      bookmark,
      group: target,
      clearGroup: target == null,
      sortKey: sortKeyBetween(beforeKey, afterKey),
      updatedAt: now().toUtc(),
    );
    _upsert([moved]);
    _changes.add(BookmarkSavedChange(moved));
    return moved;
  }

  @override
  Future<Bookmark> reorder(
    String id, {
    String? beforeId,
    String? afterId,
  }) async {
    final bookmark = await byId(id);
    if (bookmark == null) {
      throw ArgumentError.value(id, 'id', 'unknown bookmark');
    }
    return moveToGroup(
      id,
      bookmark.group,
      beforeId: beforeId,
      afterId: afterId,
    );
  }

  @override
  Future<void> applySynced(Iterable<Bookmark> bookmarks) async {
    // The quiet materialization path: verbatim upsert, no [changes]
    // emission, and not gated on the local-edit failure scripts.
    _upsert(List<Bookmark>.of(bookmarks));
  }

  @override
  Future<void> removeSynced(String id) async {
    // The quiet path emits nothing — mirrored from the file store.
    bookmarks = [
      for (final bookmark in bookmarks)
        if (bookmark.id != id) bookmark,
    ];
  }

  /// The sorted members of [group] (null = ungrouped), optionally without
  /// [exclude] — the same view the file store's neighbor math uses.
  List<Bookmark> _membersOf(String? group, {required String? exclude}) {
    final members = [
      for (final bookmark in _sorted())
        if (normalizeServerGroup(bookmark.group) == group &&
            bookmark.id != exclude)
          bookmark,
    ];
    return members;
  }

  /// The sortKey of the member named [id] among [members]; null when
  /// [id] is null. A named neighbor absent from the group throws,
  /// mirroring the file store's validation.
  String? _neighborKey(List<Bookmark> members, String? id) {
    if (id == null) return null;
    for (final member in members) {
      if (member.id == id) return member.sortKey;
    }
    throw ArgumentError.value(id, 'id', 'neighbor not in target group');
  }
}

/// The field-level copy the app needs for rename-style edits: mirrors the
/// file store's private copier, which the model itself does not expose.
Bookmark _copy(
  Bookmark source, {
  String? label,
  String? group,
  bool clearGroup = false,
  String? sortKey,
  DateTime? updatedAt,
}) => Bookmark(
  id: source.id,
  kind: source.kind,
  label: label ?? source.label,
  group: clearGroup ? null : group ?? source.group,
  color: source.color,
  icon: source.icon,
  server: source.server,
  localPath: source.localPath,
  remotePath: source.remotePath,
  left: source.left,
  right: source.right,
  sync: source.sync,
  preferredPane: source.preferredPane,
  sortKey: sortKey ?? source.sortKey,
  createdAt: source.createdAt,
  updatedAt: updatedAt ?? source.updatedAt,
);
