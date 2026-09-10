import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';

import 'atomic_file.dart';

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

/// The persistence seam the import flow dedupes against and writes to
/// (03 §6's `BookmarkStore`): the UI depends on this, never on `dart:io`.
/// [FileBookmarkStore] is the on-disk implementation; tests and M5's
/// app-wide notifier substitute their own.
abstract interface class BookmarkRepository {
  /// Every stored bookmark; the order is the store's own (M5 sorts by
  /// `sortKey`).
  Future<List<Bookmark>> load();

  /// Inserts or replaces [bookmarks] by id and persists the result.
  Future<void> upsertAll(Iterable<Bookmark> bookmarks);
}

/// JSON-file persistence for the pinned [Bookmark] model (D2/D3: one
/// server model, never a second).
///
/// Storage half of 03 §6's app-wide `BookmarkStore`: M2's ssh_config
/// import needs somewhere durable to put imported favorites and a store
/// to dedupe against (07 §3.3's exit criterion). M5 adds grouping,
/// reordering, the sync-coordinator seam, and the sidebar on top; the
/// on-disk payload is already 04 §2.1's synced `Bookmark.toJson` shape, so
/// M6 can consume it without a migration. Only synced fields are written —
/// 04 §2.3's device-local data (endpoint pins, scoped-access blobs, view
/// state) must never enter this file.
///
/// Failure posture: an unreadable file rethrows (the store must not
/// overwrite data it could not read — the caller shows a notice), a
/// corrupt file is quarantined like the ported file stores (a quarantine
/// that cannot move the file fails the load rather than starting empty),
/// a newer on-disk `version` fails in place, and a single record that
/// cannot decode is preserved verbatim so a newer Poltergeist's bookmark
/// survives a local re-save (04 §2.1's skip-and-preserve).
final class FileBookmarkStore implements BookmarkRepository {
  FileBookmarkStore({
    required String path,
    Future<void> Function(File target, String contents)? atomicWriter,
    DateTime Function()? now,
    void Function(Object, StackTrace)? onError,
  }) : // Keep the filesystem path immutable and private.
       // ignore: prefer_initializing_formals
       _file = File(path),
       _atomicWriter = atomicWriter ?? writeStringAtomically,
       _now = now ?? DateTime.now,
       // Keep the callback private while allowing test-only injection.
       // ignore: prefer_initializing_formals
       _onError = onError;

  static const _versionKey = 'version';
  static const _bookmarksKey = 'bookmarks';
  static const _storeVersion = 1;

  final File _file;
  final Future<void> Function(File target, String contents) _atomicWriter;
  final DateTime Function() _now;
  final void Function(Object, StackTrace)? _onError;

  final _bookmarks = <String, Bookmark>{};

  /// Records that failed to decode, kept in their original JSON shape so
  /// a re-save cannot drop a bookmark written by a newer Poltergeist.
  final _preserved = <Object?>[];

  Future<void>? _loadFuture;
  Future<void> _writeTail = Future.value();

  @override
  Future<List<Bookmark>> load() async {
    await _ensureLoaded();
    // Read-your-writes: a load racing a queued write waits for the tail
    // (already error-healed) instead of returning pre-write state.
    await _writeTail;
    return List.unmodifiable(_bookmarks.values);
  }

  /// Inserts or replaces [bookmarks] by id and persists the whole store.
  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {
    final incoming = bookmarks.toList(growable: false);
    if (incoming.isEmpty) return;
    await _ensureLoaded();

    final operation = _writeTail.then((_) async {
      // Build the next map first and swap it in only after the write
      // lands, so a failed write leaves the in-memory state intact.
      final next = Map<String, Bookmark>.of(_bookmarks);
      for (final bookmark in incoming) {
        next[bookmark.id] = bookmark;
      }
      await _write(next);
      _bookmarks
        ..clear()
        ..addAll(next);
    });
    // The calling service owns write-error reporting; this only heals the
    // queue so one failure cannot wedge every later write.
    _writeTail = operation.then<void>((_) {}, onError: (_, _) {});
    await operation;
  }

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

  Future<void> _load() async {
    // A retried load (a previous attempt failed on the read) must start
    // from a clean slate so partially populated state can never be
    // double-appended.
    _bookmarks.clear();
    _preserved.clear();

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

  Future<void> _write(Map<String, Bookmark> bookmarks) => _atomicWriter(
    _file,
    jsonEncode({
      _versionKey: _storeVersion,
      _bookmarksKey: [
        for (final bookmark in bookmarks.values) bookmark.toJson(),
        ..._preserved,
      ],
    }),
  );

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
