import 'dart:async';

import 'package:poltergeist_app/services/bookmark_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// In-memory [BookmarkRepository]: consumers must depend on the seam, never
/// on `dart:io` (the on-disk behavior is covered in `bookmark_store_test`).
final class FakeBookmarkStore implements BookmarkRepository {
  FakeBookmarkStore([this.bookmarks = const []]);

  List<Bookmark> bookmarks;

  /// Thrown by [load] instead of returning rows.
  Object? failure;

  int loadCalls = 0;
  final upserted = <Bookmark>[];

  /// Parks a load until completed — the superseded-load regression.
  Completer<void>? gate;

  @override
  Future<List<Bookmark>> load() async {
    loadCalls++;
    // Snapshotted before the gate: a parked load returns what the store held
    // when it was asked, which is what makes a stale completion observable.
    final snapshot = List<Bookmark>.unmodifiable(bookmarks);
    final gate = this.gate;
    if (gate != null) await gate.future;
    final failure = this.failure;
    if (failure != null) throw failure;
    return snapshot;
  }

  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {
    upserted.addAll(bookmarks);
    for (final bookmark in bookmarks) {
      this.bookmarks = [...this.bookmarks, bookmark];
    }
  }
}
