import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'application_error_reporter.dart';

/// The favorites list's own load state — distinct from the connections
/// truth the sidebar composes beside it (a ready list can hold no live
/// connections, and a failed load has no sections to describe).
enum SidebarLoad { idle, loading, ready, failed }

/// The app-facing owner of 02 §4's sidebar favorites list: sections from
/// the [BookmarkStore], collapse state (persisted device-locally through
/// the injected seam, 04 §2.3), and every mutation the sidebar's rows and
/// menus run — all routed through the store so ordering, `updatedAt`
/// stamps, and change emissions keep the core's contracts.
///
/// Local edits land on the store's `changes` lane; the controller reloads
/// its sections on every emission and forwards the edge through
/// [onBookmarksChanged] so the connections list and the probe owner
/// re-derive from the same truth (one reload per write, serialized like
/// the store's own write tail).
///
/// Construction performs no read: the owner must call [reload] exactly
/// once after wiring the callbacks — a constructor-time load would fire
/// before the caller's seams exist and would leave [load] indistinguishable
/// from "nobody asked yet" ([SidebarLoad.idle]).
final class SidebarController extends ChangeNotifier {
  SidebarController({
    required BookmarkStore store,
    Set<String> initiallyCollapsed = const {},
    this.onCollapsedChanged,
    this.onBookmarksChanged,
    this.onBookmarkRemoved,
    ApplicationErrorReporter? errors,
  }) : // Keep the store seam private to the controller.
       // ignore: prefer_initializing_formals
       _store = store,
       _collapsed = Set.of(initiallyCollapsed),
       // Keep the reporter private while allowing test-only injection.
       // ignore: prefer_initializing_formals
       _errors = errors ?? ApplicationErrorReporter() {
    _changes = store.changes.listen((_) => reload(), onError: _errors.report);
  }

  final BookmarkStore _store;
  final ApplicationErrorReporter _errors;
  late final StreamSubscription<BookmarkStoreChange> _changes;

  /// The persist sink for collapse state (02 §4: device-local). Called
  /// after every user toggle with the full key set; null leaves collapse
  /// memory in-process (tests, alternate boot paths).
  final void Function(Set<String> collapsed)? onCollapsedChanged;

  /// Fires after every store-driven reload — the shell reloads the
  /// connections list and re-syncs the probe owner here, so all three
  /// surfaces re-derive from one store truth.
  final VoidCallback? onBookmarksChanged;

  /// The bookmark-removal cascade seam (03 §6): the shell forwards the
  /// deleted id to the engine (`removeBookmark`) and the probe owner's
  /// device-local record cleanup. Called after a successful [remove],
  /// in call order; errors inside it are the callee's own concern.
  final void Function(String serverId)? onBookmarkRemoved;

  List<BookmarkGroupSection> _sections = const [];
  SidebarLoad _load = SidebarLoad.idle;
  Set<String> _collapsed;
  int _generation = 0;
  bool _disposed = false;

  /// The favorites sections in the store's order (named groups sorted,
  /// ungrouped last, a single anonymous section for an all-flat list).
  List<BookmarkGroupSection> get sections => _sections;

  SidebarLoad get load => _load;

  /// Every stored bookmark, flat — the probe owner's reconciliation set.
  List<Bookmark> get bookmarks => [
    for (final section in _sections) ...section.bookmarks,
  ];

  /// Section keys currently collapsed. Keys are the sections' own
  /// [BookmarkGroupSection.key] values, so a re-sorted group keeps its
  /// state and a deleted group leaves nothing behind to leak.
  Set<String> get collapsedGroups => Set.unmodifiable(_collapsed);

  bool isCollapsed(String sectionKey) => _collapsed.contains(sectionKey);

  /// Toggles one section's collapse and reports the new set to the
  /// persist seam. A failed write does not roll the toggle back — the
  /// state is cosmetic and the next launch's re-read is honest.
  void toggleCollapsed(String sectionKey) {
    if (_disposed) return;
    final next = Set<String>.of(_collapsed);
    if (!next.add(sectionKey)) next.remove(sectionKey);
    _collapsed = next;
    notifyListeners();
    final sink = onCollapsedChanged;
    if (sink == null) return;
    try {
      sink(Set.unmodifiable(next));
    } on Object catch (error, stackTrace) {
      _errors.report(error, stackTrace);
    }
  }

  /// Reads the store's sections. Re-runnable: a store change reloads, and
  /// a superseded read drops itself on the generation counter (09 §3.1).
  Future<void> reload() async {
    if (_disposed) return;
    final generation = ++_generation;
    _load = SidebarLoad.loading;
    notifyListeners();

    final List<BookmarkGroupSection> sections;
    try {
      sections = await _store.sections();
    } on Object catch (error, stackTrace) {
      _errors.report(error, stackTrace);
      if (_disposed || generation != _generation) return;
      _load = SidebarLoad.failed;
      notifyListeners();
      return;
    }
    if (_disposed || generation != _generation) return;

    _sections = List.unmodifiable(sections);
    _load = SidebarLoad.ready;
    notifyListeners();
    onBookmarksChanged?.call();
  }

  /// The row's local rename: a full-record [BookmarkStore.save] so the
  /// `updatedAt` stamp lands (the LWW half of every local edit, 04 §2.1).
  Future<Bookmark> rename(String id, String label) {
    _assertLive();
    return _store.byId(id).then((bookmark) {
      if (bookmark == null) {
        throw ArgumentError.value(id, 'id', 'unknown bookmark');
      }
      return _store.save(_withLabel(bookmark, label));
    });
  }

  /// The row's delete: removes the record, then forwards the id to the
  /// removal cascade seam (engine teardown, probe-facts cleanup) in the
  /// store's own order — delete first, cascade second, never a half state
  /// where the engine still serves a bookmark the store forgot.
  Future<bool> remove(String id) async {
    _assertLive();
    final removed = await _store.remove(id);
    if (removed) {
      // The store delete is already committed — a cascade throw must
      // not surface here as a failed delete (the caller would retry,
      // get `false`, and the cascade would never re-run), so errors
      // report and the removal stands.
      try {
        onBookmarkRemoved?.call(id);
      } on Object catch (error, stackTrace) {
        _errors.report(error, stackTrace);
      }
    }
    return removed;
  }

  /// Refiles [id] into [group] (null ungroups) between the named
  /// neighbors — the store's [BookmarkStore.moveToGroup] handles the
  /// sort-key math and normalization.
  Future<Bookmark> moveToGroup(
    String id,
    String? group, {
    String? beforeId,
    String? afterId,
  }) {
    _assertLive();
    return _store.moveToGroup(id, group, beforeId: beforeId, afterId: afterId);
  }

  /// Repositions [id] inside its own group — the store's
  /// [BookmarkStore.reorder].
  Future<Bookmark> reorder(String id, {String? beforeId, String? afterId}) {
    _assertLive();
    return _store.reorder(id, beforeId: beforeId, afterId: afterId);
  }

  /// A drop resolution shared by row-split and group-header targets:
  /// same-group drops are a reorder, cross-group drops a refile — both
  /// land on the store's single move operation.
  Future<Bookmark> drop(
    String id,
    String? group, {
    String? beforeId,
    String? afterId,
  }) => moveToGroup(id, group, beforeId: beforeId, afterId: afterId);

  void _assertLive() {
    if (_disposed) {
      throw StateError('SidebarController used after dispose');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    unawaited(_changes.cancel());
    super.dispose();
  }
}

/// The only field the sidebar's rename owns: the model exposes no
/// `copyWith`, so the edit is spelled out field by field — a record
/// rebuilt here stays inside the pinned schema by construction.
Bookmark _withLabel(Bookmark source, String label) => Bookmark(
  id: source.id,
  kind: source.kind,
  label: label,
  group: source.group,
  color: source.color,
  icon: source.icon,
  server: source.server,
  localPath: source.localPath,
  remotePath: source.remotePath,
  left: source.left,
  right: source.right,
  sync: source.sync,
  preferredPane: source.preferredPane,
  sortKey: source.sortKey,
  createdAt: source.createdAt,
  updatedAt: source.updatedAt,
);
