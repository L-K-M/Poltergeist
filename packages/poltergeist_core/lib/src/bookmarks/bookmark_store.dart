/// The app-wide bookmark store (03 §6's `BookmarkStore` row): the pinned
/// `Bookmark` model (D2 — one schema, never a second; PR-S1's upstream copy
/// is already in the pin's ancestry, so 04 §2.1's temporary-copy clause does
/// not apply) persisted to one JSON file with atomic temp+rename writes.
///
/// The on-disk records are the model's `toJson()` payloads verbatim — the
/// exact shape M6 seals into `bookmark:` records (04 §2.4) — so the synced
/// payload and the local file share one serialization boundary. 04 §2.3's
/// device-local data (endpoint pins, scoped-access blobs, collapsed/hidden
/// view state, path-missing facts) must never enter this file: the model
/// has no fields for it, and `payload_purity` coverage proves nothing else
/// is appended.
///
/// Grouping and ordering follow 04 §2.1/§2.5: `group` is a string carried
/// by the member (no group records — LWW-safe, cannot dangle), order is the
/// `sortKey` fractional index with the record id tiebreak. Writes normalize
/// non-minted sortKeys (interim writers used `sortKey: <uuid>`) so the file
/// only ever holds keys `sortKeyBetween` can work between.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seance_core/seance_core.dart';

import '../transfer/transfer_journal.dart' show TransferJournalIo;
import 'bookmark_groups.dart';
import 'sort_key.dart';

/// 04 §2.5's hard cap on the encoded payload at save time — a save-time
/// hard cap, never a warn-and-skip-sync, so no local-only never-synced
/// bookmark state can exist.
const int bookmarkPayloadCapBytes = 64 * 1024;

/// Thrown when a bookmark's encoded `toJson()` payload exceeds
/// [bookmarkPayloadCapBytes]. The UI turns this into the §2.5 copy
/// ("This bookmark is too large to save.") when a save surface lands.
final class BookmarkTooLargeException implements Exception {
  const BookmarkTooLargeException(this.bookmarkId);

  final String bookmarkId;

  @override
  String toString() =>
      'Bookmark "$bookmarkId" exceeds the $bookmarkPayloadCapBytes-byte '
      'payload cap';
}

/// One local mutation observed through [BookmarkStore.changes] — the
/// store-behind-callback seam (03 §6): M6's `BookmarkCoordinator` marks
/// dirty on these, and the sidebar re-reads on them, without the store
/// knowing either exists.
sealed class BookmarkStoreChange {
  const BookmarkStoreChange();
}

/// A bookmark was created or replaced locally. [bookmark] is the stored
/// form (sortKey-normalized, `updatedAt`-stamped for [BookmarkStore.save]).
final class BookmarkSavedChange extends BookmarkStoreChange {
  const BookmarkSavedChange(this.bookmark);

  final Bookmark bookmark;
}

/// A bookmark was removed locally.
final class BookmarkRemovedChange extends BookmarkStoreChange {
  const BookmarkRemovedChange(this.id);

  final String id;
}

/// The LWW authorship tuple of the record last materialized into the
/// bookmark store for a row — the winning envelope's
/// `(updatedAt, deviceId)` (04 §3.2). Persisted per id alongside the rows,
/// including `deleted` tombstone tuples for rows that are gone: the
/// coordinator's apply pass compares a pulled record against this tuple,
/// and a tombstone tuple is what stops a stale live record resurrecting a
/// just-deleted row before the tombstone record has pushed.
final class BookmarkSyncTuple {
  const BookmarkSyncTuple({
    required this.updatedAt,
    required this.deviceId,
    this.deleted = false,
  });

  /// Milliseconds since epoch — the record envelope's `updatedAt`.
  final int updatedAt;

  /// The record envelope's `deviceId`. Empty when the authorship is unknown
  /// (the tuple-less `applySynced` path): an empty id loses every deviceId
  /// tie-break, so a re-pulled copy of the same write still applies.
  final String deviceId;

  /// True when the materialized state is a deletion: the row is absent and
  /// this tuple is what a pulled live record must out-tuple to resurrect.
  final bool deleted;

  Map<String, dynamic> toJson() => {
        'updatedAt': updatedAt,
        'deviceId': deviceId,
        if (deleted) 'deleted': true,
      };

  static BookmarkSyncTuple? fromJson(Object? json) {
    if (json is! Map) return null;
    final updatedAt = json['updatedAt'];
    final deviceId = json['deviceId'];
    if (updatedAt is! num || deviceId is! String) return null;
    return BookmarkSyncTuple(
      updatedAt: updatedAt.toInt(),
      deviceId: deviceId,
      deleted: json['deleted'] == true,
    );
  }
}

/// [BookmarkStore] plus the sync bookkeeping 04 §3.2 needs: the per-row
/// materialized tuples, and the record-carrying apply/remove variants that
/// persist the winning envelope's tuple with the row.
abstract interface class SyncTrackingBookmarkStore implements BookmarkStore {
  /// The tuple last materialized for [id], or null when nothing about the
  /// row's sync authorship is known (never synced, or applied through the
  /// tuple-less legacy path before tuples existed).
  Future<BookmarkSyncTuple?> syncTupleOf(String id);

  /// Every materialized tuple, including tombstone tuples — the recovery
  /// path's re-seal set.
  Future<Map<String, BookmarkSyncTuple>> syncTuples();

  /// [applySynced] carrying the winning envelope's tuple.
  Future<void> applySyncedRecords(
      Iterable<({Bookmark bookmark, BookmarkSyncTuple winner})> rows);

  /// [removeSynced] carrying the winning tombstone's tuple.
  Future<void> removeSyncedRecord(String id, BookmarkSyncTuple tombstone);
}

/// The persistence seam the import flow dedupes against and writes to:
/// consumers depend on this, never on `dart:io`. [FileBookmarkStore] is the
/// on-disk implementation; tests substitute their own.
abstract interface class BookmarkRepository {
  /// Every stored bookmark, sorted by (`sortKey`, `id`) — the 04 §2.5 order.
  Future<List<Bookmark>> load();

  /// Inserts or replaces [bookmarks] by id and persists the result. The
  /// records are stored verbatim (timestamps included): this is the
  /// materialization path — the ssh_config import today, never a local
  /// edit, which goes through [BookmarkStore.save] for the `updatedAt`
  /// stamp LWW compares.
  Future<void> upsertAll(Iterable<Bookmark> bookmarks);
}

/// The full 03 §6 store surface: [BookmarkRepository] plus the CRUD,
/// grouping, and reorder operations the sidebar and the M6 sync
/// coordinator need.
abstract interface class BookmarkStore extends BookmarkRepository {
  /// The stored bookmark with [id], or null.
  Future<Bookmark?> byId(String id);

  /// The list as ordered sections (named groups sorted by name, ungrouped
  /// last) — 02 §4's sidebar shape.
  Future<List<BookmarkGroupSection>> sections();

  /// The distinct stored group names, sorted (editor pick-lists).
  Future<List<String>> groupNames();

  /// The key a new bookmark should carry to land at the position described
  /// by [group]/[beforeId]/[afterId]. With neither neighbor named, the key
  /// appends at [group]'s tail (ungrouped tail when [group] is null). A
  /// named neighbor must exist and sit in [group].
  Future<String> sortKeyForInsert({
    String? group,
    String? beforeId,
    String? afterId,
  });

  /// A local create-or-replace edit: stamps `updatedAt` to now (the LWW
  /// half of every save, 04 §2.1) and emits [BookmarkSavedChange]. For
  /// verbatim materialization use [upsertAll]/[applySynced] instead.
  Future<Bookmark> save(Bookmark bookmark);

  /// Removes the bookmark with [id]; emits [BookmarkRemovedChange].
  /// Returns whether a row existed.
  Future<bool> remove(String id);

  /// Refiles [id] into [group] (null → ungrouped, names normalized the
  /// Séance way: trimmed, blank → none). With [beforeId]/[afterId] the
  /// bookmark lands between those neighbors inside the target group;
  /// otherwise it appends at the group tail. Emits [BookmarkSavedChange].
  Future<Bookmark> moveToGroup(
    String id,
    String? group, {
    String? beforeId,
    String? afterId,
  });

  /// Repositions [id] within its current group, between [beforeId] and
  /// [afterId] (either may be null for head/tail). Emits
  /// [BookmarkSavedChange].
  Future<Bookmark> reorder(String id, {String? beforeId, String? afterId});

  /// M6's pulled-record apply (04 §3.2): verbatim upsert with no
  /// `updatedAt` stamp and no [changes] emission — a pulled winner applied
  /// back through the local-save seam would mark itself dirty and re-push
  /// every round.
  Future<void> applySynced(Iterable<Bookmark> bookmarks);

  /// The tombstone half of [applySynced]: a quiet remove.
  Future<void> removeSynced(String id);

  /// Local mutations, in write order. Sync-apply calls emit nothing here.
  Stream<BookmarkStoreChange> get changes;
}

/// The quarantine name for a corrupt store at [path]: UTC ISO-8601 with
/// `-`, `:`, and `.` stripped, matching the ported file stores. Exposed so
/// a test can park a blocking entry where the quarantine rename will land
/// without duplicating the format.
String bookmarkQuarantinePath(String path, DateTime now) =>
    '$path.corrupt-${_quarantineStamp(now)}';

String _quarantineStamp(DateTime now) => now
    .toUtc()
    .toIso8601String()
    .replaceAll('-', '')
    .replaceAll(':', '')
    .replaceAll('.', '');

/// JSON-file persistence for the pinned [Bookmark] model.
///
/// Failure posture: an unreadable file rethrows (the store must not
/// overwrite data it could not read — the caller shows a notice), a
/// corrupt file is quarantined like the ported file stores (a quarantine
/// that cannot move the file fails the load rather than starting empty),
/// a newer on-disk `version` fails in place, and a single record that
/// cannot decode is preserved verbatim so a newer Poltergeist's bookmark
/// survives a local re-save (04 §2.1's skip-and-preserve).
final class FileBookmarkStore implements SyncTrackingBookmarkStore {
  FileBookmarkStore({
    required String path,
    Future<void> Function(File target, String contents)? atomicWriter,
    DateTime Function()? now,
    void Function(Object, StackTrace)? onError,
    String Function()? syncDeviceId,
  }) : // Keep the filesystem path immutable and private.
       // ignore: prefer_initializing_formals
       _file = File(path),
       _atomicWriter =
           atomicWriter ?? const TransferJournalIo().atomicRewrite,
       _now = now ?? DateTime.now,
       // Keep the callback private while allowing test-only injection.
       // ignore: prefer_initializing_formals
       _onError = onError,
       // ignore: prefer_initializing_formals
       _syncDeviceId = syncDeviceId;

  static const _versionKey = 'version';
  static const _bookmarksKey = 'bookmarks';
  static const _syncTuplesKey = 'syncTuples';
  static const _storeVersion = 1;

  final File _file;
  final Future<void> Function(File target, String contents) _atomicWriter;
  final DateTime Function() _now;
  final void Function(Object, StackTrace)? _onError;

  /// This install's sync device id, bound late because the app mints it
  /// asynchronously. Null before backup is configured: tuples then carry
  /// the empty authorship placeholder, which loses every tie-break — the
  /// permissive direction, harmless while no coordinator reads them.
  final String Function()? _syncDeviceId;

  final _bookmarks = <String, Bookmark>{};

  /// The materialized LWW tuples — persisted next to the rows (04 §3.2) so
  /// the apply pass can tell a genuinely newer pulled record from a stale
  /// copy of what a pending local tombstone or edit already supersedes.
  final _syncTuples = <String, BookmarkSyncTuple>{};

  /// Records that failed to decode, kept in their original JSON shape so
  /// a re-save cannot drop a bookmark written by a newer Poltergeist.
  final _preserved = <Object?>[];

  // Synchronous delivery: a listener (M6's coordinator marking dirty, the
  // sidebar re-reading) sees the change before the mutating call returns,
  // so a `save().then(reload)` can never observe the pre-write list.
  final _changes = StreamController<BookmarkStoreChange>.broadcast(sync: true);

  Future<void>? _loadFuture;
  Future<void> _writeTail = Future.value();

  @override
  Stream<BookmarkStoreChange> get changes => _changes.stream;

  @override
  Future<List<Bookmark>> load() async {
    await _ensureLoaded();
    // Read-your-writes: a load racing a queued write waits for the tail
    // (already error-healed) instead of returning pre-write state.
    await _writeTail;
    return List.unmodifiable(_sorted());
  }

  @override
  Future<Bookmark?> byId(String id) async {
    await _ensureLoaded();
    await _writeTail;
    return _bookmarks[id];
  }

  @override
  Future<List<BookmarkGroupSection>> sections() async =>
      groupBookmarks(await load());

  @override
  Future<List<String>> groupNames() async =>
      bookmarkGroupNames(await load());

  @override
  Future<String> sortKeyForInsert({
    String? group,
    String? beforeId,
    String? afterId,
  }) async {
    await _ensureLoaded();
    await _writeTail;
    final target = normalizeServerGroup(group);
    if (beforeId == null && afterId == null) {
      // Tail of the target group (the ungrouped tail when null).
      final members = _membersOf(target);
      return sortKeyBetween(
        members.isEmpty ? null : members.last.sortKey,
        null,
      );
    }
    final before = _neighborInGroup(beforeId, target);
    final after = _neighborInGroup(afterId, target);
    final members = _membersOf(target);
    var beforeKey = before?.sortKey;
    var afterKey = after?.sortKey;
    if (before != null && after == null) {
      final index = members.indexOf(before);
      afterKey = index + 1 < members.length ? members[index + 1].sortKey : null;
    } else if (after != null && before == null) {
      final index = members.indexOf(after);
      beforeKey = index > 0 ? members[index - 1].sortKey : null;
    }
    return sortKeyBetween(beforeKey, afterKey);
  }

  /// Inserts or replaces [bookmarks] by id and persists the whole store.
  /// Emits [BookmarkSavedChange] per stored record — these are local
  /// writes (the import), so M6's dirty marking belongs on them.
  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {
    final incoming = bookmarks.toList(growable: false);
    if (incoming.isEmpty) return;
    for (final bookmark in incoming) {
      _checkPayloadSize(bookmark);
    }
    await _ensureLoaded();
    await _writeNext(
      (next) {
        for (final bookmark in incoming) {
          next[bookmark.id] = bookmark;
        }
      },
      changes: (next) => [
        for (final bookmark in incoming)
          BookmarkSavedChange(next[bookmark.id]!),
      ],
      syncEdit: (tuples) {
        for (final bookmark in incoming) {
          final tuple = _localTuple(bookmark.updatedAt);
          if (tuple != null) tuples[bookmark.id] = tuple;
        }
      },
    );
  }

  @override
  Future<Bookmark> save(Bookmark bookmark) async {
    _checkPayloadSize(bookmark);
    final stamped = _copyBookmark(bookmark, updatedAt: _now().toUtc());
    await _ensureLoaded();
    final next = await _writeNext(
      (next) => next[stamped.id] = stamped,
      changes: (next) => [BookmarkSavedChange(next[stamped.id]!)],
      syncEdit: (tuples) {
        final tuple = _localTuple(stamped.updatedAt);
        if (tuple != null) tuples[stamped.id] = tuple;
      },
    );
    return next[stamped.id]!;
  }

  @override
  Future<bool> remove(String id) async {
    await _ensureLoaded();
    await _writeTail;
    if (!_bookmarks.containsKey(id)) return false;
    // The presence check above is pre-queue: another queued mutation could
    // remove the row first, so the verdict and the event are decided inside
    // the serialized operation, not by the earlier snapshot.
    var removed = false;
    await _writeNext(
      (next) {
        removed = next.remove(id) != null;
      },
      changes: (_) =>
          removed ? [BookmarkRemovedChange(id)] : const <BookmarkStoreChange>[],
      // The row is gone but its tombstone tuple is what the coordinator's
      // tuple guard compares a pulled stale copy against until the
      // tombstone record itself has pushed (04 §3.2).
      syncEdit: (tuples) {
        final tombstone = removed ? _localTombstone() : null;
        if (tombstone != null) tuples[id] = tombstone;
      },
    );
    return removed;
  }

  @override
  Future<Bookmark> moveToGroup(
    String id,
    String? group, {
    String? beforeId,
    String? afterId,
  }) async {
    await _ensureLoaded();
    await _writeTail;
    final bookmark = _bookmarks[id];
    if (bookmark == null) {
      throw ArgumentError.value(id, 'id', 'unknown bookmark');
    }
    final target = normalizeServerGroup(group);
    final before = _neighborInGroup(beforeId, target, exclude: id);
    final after = _neighborInGroup(afterId, target, exclude: id);
    final members = _membersOf(target, exclude: id);
    String? beforeKey;
    String? afterKey;
    if (before == null && after == null) {
      // No neighbors named: append at the target group's tail.
      beforeKey = members.isEmpty ? null : members.last.sortKey;
    } else {
      beforeKey = before?.sortKey;
      afterKey = after?.sortKey;
      // One named neighbor bounds the other side by the adjacent member:
      // "after b" means between b and what follows it, not the group tail.
      if (before != null && after == null) {
        final index = members.indexOf(before);
        afterKey =
            index + 1 < members.length ? members[index + 1].sortKey : null;
      } else if (after != null && before == null) {
        final index = members.indexOf(after);
        beforeKey = index > 0 ? members[index - 1].sortKey : null;
      }
    }
    final sortKey = sortKeyBetween(beforeKey, afterKey);
    final moved = _copyBookmark(
      bookmark,
      group: target,
      clearGroup: target == null,
      sortKey: sortKey,
      updatedAt: _now().toUtc(),
    );
    final next = await _writeNext(
      (next) => next[id] = moved,
      changes: (next) => [BookmarkSavedChange(next[id]!)],
      syncEdit: (tuples) {
        final tuple = _localTuple(moved.updatedAt);
        if (tuple != null) tuples[id] = tuple;
      },
    );
    return next[id]!;
  }

  @override
  Future<Bookmark> reorder(
    String id, {
    String? beforeId,
    String? afterId,
  }) async {
    await _ensureLoaded();
    await _writeTail;
    final bookmark = _bookmarks[id];
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
  Future<void> applySynced(Iterable<Bookmark> bookmarks) =>
      applySyncedRecords([
        for (final bookmark in bookmarks)
          // The tuple-less legacy path records authorship as unknown: the
          // empty deviceId loses every tie-break, so a re-pulled copy of
          // the true winner still applies over it.
          (
            bookmark: bookmark,
            winner: BookmarkSyncTuple(
              updatedAt: bookmark.updatedAt.toUtc().millisecondsSinceEpoch,
              deviceId: '',
            ),
          ),
      ]);

  @override
  Future<void> applySyncedRecords(
      Iterable<({Bookmark bookmark, BookmarkSyncTuple winner})> rows) async {
    final incoming = rows.toList(growable: false);
    if (incoming.isEmpty) return;
    for (final row in incoming) {
      _checkPayloadSize(row.bookmark);
    }
    await _ensureLoaded();
    await _writeNext(
      (next) {
        for (final row in incoming) {
          next[row.bookmark.id] = row.bookmark;
        }
      },
      syncEdit: (tuples) {
        for (final row in incoming) {
          tuples[row.bookmark.id] = row.winner;
        }
      },
    );
  }

  @override
  Future<void> removeSynced(String id) async {
    await _ensureLoaded();
    await _writeTail;
    if (!_bookmarks.containsKey(id)) return;
    await _writeNext(
      (next) => next.remove(id),
      // The tuple-less legacy path leaves no tombstone tuple: the record
      // store's own merge remains the guard until a tuple-carrying call
      // records the winning envelope.
      syncEdit: (tuples) => tuples.remove(id),
    );
  }

  @override
  Future<void> removeSyncedRecord(
      String id, BookmarkSyncTuple tombstone) async {
    await _ensureLoaded();
    await _writeNext(
      (next) => next.remove(id),
      syncEdit: (tuples) => tuples[id] = tombstone,
    );
  }

  @override
  Future<BookmarkSyncTuple?> syncTupleOf(String id) async {
    await _ensureLoaded();
    await _writeTail;
    return _syncTuples[id];
  }

  @override
  Future<Map<String, BookmarkSyncTuple>> syncTuples() async {
    await _ensureLoaded();
    await _writeTail;
    return Map.unmodifiable(_syncTuples);
  }

  /// The tuple a local write materializes: the row's stamp under this
  /// install's device id — the same tuple [BookmarkCoordinator.onBookmarkSaved]
  /// seals into the record, so store and record never disagree on authorship.
  /// Null while sync is unconfigured: tuples exist only to serve the
  /// coordinator, and writing them would change the on-disk shape for
  /// installs that never turn backup on (04 §3.4).
  BookmarkSyncTuple? _localTuple(DateTime updatedAt) {
    final deviceId = _syncDeviceId?.call();
    if (deviceId == null) return null;
    return BookmarkSyncTuple(
      updatedAt: updatedAt.toUtc().millisecondsSinceEpoch,
      deviceId: deviceId,
    );
  }

  BookmarkSyncTuple? _localTombstone() {
    final deviceId = _syncDeviceId?.call();
    if (deviceId == null) return null;
    return BookmarkSyncTuple(
      updatedAt: _now().toUtc().millisecondsSinceEpoch,
      deviceId: deviceId,
      deleted: true,
    );
  }

  /// The members of [group] (normalized) in sort order, optionally without
  /// [exclude] — a refiled bookmark never counts as its own neighbor.
  List<Bookmark> _membersOf(String? group, {String? exclude}) {
    return [
      for (final bookmark in _sorted())
        if (bookmark.id != exclude &&
            normalizeServerGroup(bookmark.group) == group)
          bookmark,
    ];
  }

  /// Resolves a named neighbor, enforcing that it exists and sits in
  /// [group] — a cross-group neighbor would silently mint a key that lands
  /// the move somewhere the drag never pointed.
  Bookmark? _neighborInGroup(String? id, String? group, {String? exclude}) {
    if (id == null) return null;
    final neighbor = _bookmarks[id];
    if (neighbor == null || neighbor.id == exclude) {
      throw ArgumentError.value(id, 'neighbor', 'unknown bookmark');
    }
    if (normalizeServerGroup(neighbor.group) != group) {
      throw ArgumentError.value(
        id,
        'neighbor',
        'not in group ${group ?? '(ungrouped)'}',
      );
    }
    return neighbor;
  }

  List<Bookmark> _sorted() =>
      _bookmarks.values.toList()..sort(compareBookmarkSortKeys);

  Future<void> _ensureLoaded() {
    final activeLoad = _loadFuture;
    if (activeLoad != null) return activeLoad;

    final load = _load();
    _loadFuture = load;
    unawaited(
      load.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          // A transient filesystem failure must not poison later reads.
          if (identical(_loadFuture, load)) _loadFuture = null;
        },
      ),
    );
    return load;
  }

  /// One serialized mutation: [edit] produces the next map (from a copy of
  /// current state), the edited map is sortKey-normalized — so a synced or
  /// imported record carrying a non-minted key is repaired before it lands,
  /// never after a reorder has already read it — written, and swapped in
  /// only after the write lands, so a failed write leaves the in-memory
  /// state intact. [changes] computes the events emitted from the stored
  /// (post-normalization) rows; nothing reaches listeners on failure.
  /// [syncEdit] mutates the materialized-tuple map in the same atomic write:
  /// a row and the tuple that guards it can never diverge on disk.
  Future<Map<String, Bookmark>> _writeNext(
    void Function(Map<String, Bookmark> next) edit, {
    List<BookmarkStoreChange> Function(Map<String, Bookmark> next)? changes,
    void Function(Map<String, BookmarkSyncTuple> tuples)? syncEdit,
  }) {
    final operation = _writeTail.then((_) async {
      // Pre-edit normalization is belt-and-suspenders: _load already
      // repairs the decoded map and the post-edit pass repairs what the
      // edit introduces, so _bookmarks should never hold a non-minted key.
      // Keeping this pass means the invariant holds even if a future write
      // path forgets to normalize on its own side.
      final next = _normalizeSortKeys(Map<String, Bookmark>.of(_bookmarks));
      final nextTuples = Map<String, BookmarkSyncTuple>.of(_syncTuples);
      edit(next);
      syncEdit?.call(nextTuples);
      final stored = _normalizeSortKeys(next);
      await _write(stored, nextTuples);
      _bookmarks
        ..clear()
        ..addAll(stored);
      _syncTuples
        ..clear()
        ..addAll(nextTuples);
      if (changes != null) {
        for (final change in changes(stored)) {
          _changes.add(change);
        }
      }
      return stored;
    });
    // The calling service owns write-error reporting; this only heals the
    // queue so one failure cannot wedge every later write.
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<void> _load() async {
    // A retried load (a previous attempt failed on the read) must start
    // from a clean slate so partially populated state can never be
    // double-appended.
    _bookmarks.clear();
    _preserved.clear();
    _syncTuples.clear();

    // Read failures propagate to the caller, which reports and shows the
    // notice; the store must not overwrite data it could not read.
    late final String? contents;
    await _file.parent.create(recursive: true);
    contents = await _file.exists() ? await _file.readAsString() : null;

    if (contents == null) return;

    Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } catch (error, stack) {
      // Quarantine throws when the bad file cannot be moved aside, so the
      // load fails instead of starting empty over bytes it could not read.
      await _quarantine();
      _report(error, stack);
      return;
    }

    if (decoded is! Map) {
      await _quarantine();
      _report(
        const FormatException('bookmark store root'),
        StackTrace.current,
      );
      return;
    }

    // A newer store format is data this version must not overwrite: fail
    // like an unreadable file (no quarantine, no empty start) so a local
    // re-save can never replace it with a v1 shape. M5/M6 own real
    // migrations; until then this is the fail-closed posture, and the
    // calling service reports the thrown error. Only this store's own
    // version integer is understood; any other non-null value fails
    // closed rather than being read as v1.
    final version = decoded[_versionKey];
    if (version != null && version != _storeVersion) {
      throw FormatException('bookmark store version $version');
    }

    if (decoded[_bookmarksKey] is! List) {
      await _quarantine();
      _report(
        const FormatException('bookmark store root'),
        StackTrace.current,
      );
      return;
    }

    for (final record in decoded[_bookmarksKey] as List) {
      final bookmark = _decode(record);
      if (bookmark == null) {
        _preserved.add(record);
      } else {
        _bookmarks[bookmark.id] = bookmark;
      }
    }

    // The tuple map is auxiliary, rebuildable bookkeeping (the record store
    // is the merge authority), so a malformed entry is dropped rather than
    // quarantining the whole document over it.
    final tuples = decoded[_syncTuplesKey];
    if (tuples is Map) {
      for (final entry in tuples.entries) {
        final id = entry.key;
        final tuple = BookmarkSyncTuple.fromJson(entry.value);
        if (id is String && tuple != null) _syncTuples[id] = tuple;
      }
    }

    // Interim writers minted `sortKey: <uuid>` and other devices may send
    // keys this build cannot mint; repair them in memory now (deterministic,
    // so an unsaved restart re-derives the same view) and let the next
    // write persist the minted keys.
    final normalized = _normalizeSortKeys(_bookmarks);
    if (!identical(normalized, _bookmarks)) {
      _bookmarks
        ..clear()
        ..addAll(normalized);
    }
  }

  /// Decodes one stored record; null when it cannot be trusted (04 §2.1's
  /// skip-and-preserve — never throw away a record this version does not
  /// understand).
  Bookmark? _decode(Object? record) {
    if (record is! Map) return null;
    final json = record.cast<String, dynamic>();
    final id = json['id'];
    if (id is! String) return null;
    try {
      return Bookmark.fromJson(json, recordId: 'bookmark:$id');
    } on FormatException {
      return null;
    }
  }

  /// Re-keys every bookmark whose sortKey this build could not have minted
  /// ([isValidSortKey] fails: the interim `sortKey: <uuid>` mints, foreign
  /// data). Re-minted keys keep the item's slot between its valid
  /// neighbors; an item that cannot fit (dead-adjacent bounds) appends at
  /// the tail instead. Returns the input map unchanged when nothing needs
  /// repair so callers can `identical()`-check for a no-op.
  Map<String, Bookmark> _normalizeSortKeys(Map<String, Bookmark> bookmarks) {
    final sorted = bookmarks.values.toList()..sort(compareBookmarkSortKeys);
    var changed = false;
    final next = <String, Bookmark>{};
    final overflow = <Bookmark>[];
    String? previous;
    final pending = <Bookmark>[];

    void flush(String? nextKey) {
      for (final bookmark in pending) {
        try {
          final key = sortKeyBetween(previous, nextKey);
          next[bookmark.id] = _copyBookmark(bookmark, sortKey: key);
          previous = key;
          changed = true;
        } on SortKeySpaceExhaustedException {
          // The neighbors admit no key between them; this item cannot hold
          // its slot and falls to the tail instead of failing the write.
          overflow.add(bookmark);
        }
      }
      pending.clear();
    }

    for (final bookmark in sorted) {
      if (!isValidSortKey(bookmark.sortKey)) {
        pending.add(bookmark);
        continue;
      }
      flush(bookmark.sortKey);
      next[bookmark.id] = bookmark;
      previous = bookmark.sortKey;
    }
    flush(null);
    for (final bookmark in overflow) {
      final key = sortKeyBetween(previous, null);
      next[bookmark.id] = _copyBookmark(bookmark, sortKey: key);
      previous = key;
      changed = true;
    }
    return changed ? next : bookmarks;
  }

  /// The 04 §2.5 save-time hard cap: the encoded payload — the same bytes
  /// M6 seals — never exceeds [bookmarkPayloadCapBytes].
  void _checkPayloadSize(Bookmark bookmark) {
    final bytes = utf8.encode(jsonEncode(bookmark.toJson())).length;
    if (bytes > bookmarkPayloadCapBytes) {
      throw BookmarkTooLargeException(bookmark.id);
    }
  }

  Future<void> _write(
    Map<String, Bookmark> bookmarks,
    Map<String, BookmarkSyncTuple> tuples,
  ) {
    final sorted = bookmarks.values.toList()..sort(compareBookmarkSortKeys);
    return _atomicWriter(
      _file,
      jsonEncode({
        _versionKey: _storeVersion,
        _bookmarksKey: [
          for (final bookmark in sorted) bookmark.toJson(),
          ..._preserved,
        ],
        // Omitted while empty so an install that never configures sync
        // keeps writing the exact pre-M6 document shape.
        if (tuples.isNotEmpty)
          _syncTuplesKey: {
            for (final entry in tuples.entries) entry.key: entry.value.toJson(),
          },
      }),
    );
  }

  /// Moves a corrupt store aside so a bad file cannot wedge startup.
  /// Throws when the file cannot be moved: starting empty over bytes this
  /// version could not read would let the next save overwrite them.
  Future<void> _quarantine() =>
      _file.rename(bookmarkQuarantinePath(_file.path, _now()));

  void _report(Object error, StackTrace stack) {
    try {
      _onError?.call(error, stack);
    } catch (_) {
      // Error reporting must never create a second unhandled async error.
    }
  }
}

/// The upstream model has no `copyWith` (04 §2.1's struct); mutations
/// rebuild the record field-by-field so no synced field can be dropped by
/// accident. [clearGroup] mirrors `ServerConfig.copyWith`'s flag: passing
/// `group: null` cannot mean "clear it" on its own.
Bookmark _copyBookmark(
  Bookmark source, {
  String? group,
  bool clearGroup = false,
  String? sortKey,
  DateTime? updatedAt,
}) => Bookmark(
  id: source.id,
  kind: source.kind,
  label: source.label,
  group: clearGroup ? null : (group ?? source.group),
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
