import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'application_error_reporter.dart';
import 'session_state.dart';
import 'uuid.dart';
import 'view_preferences.dart';
import 'workspace_list_store.dart';
import 'workspace_state.dart';

/// 02 §3's saved-workspace list, M5 shape: a workspace IS a favorite —
/// `BookmarkKind.workspace` records in the shared [BookmarkStore] carry
/// the label, the sidebar order (`sortKey`), and each pane's headline
/// endpoint (`left`/`right`, the synced payload's whole surface), while
/// the full multi-tab snapshot stays device-local in the versioned
/// [WorkspaceListStore] document, keyed by the bookmark's id. The synced
/// schema deliberately has no room for tab arrays or per-tab lenses
/// (04 §2.1); splitting the record this way keeps `bookmarks.json`
/// inside the payload-purity contract — a workspace bookmark holds
/// locations and identities (`secretRef`, never the secret), nothing
/// else.
///
/// [workspaces] is the join over the two layers, in the store's
/// favorite order: a workspace bookmark whose detail this device holds
/// replays the exact tab sets; one without a detail (a synced-in
/// record, or a detail pruned on a device that never captured it)
/// degrades to a one-tab-per-pane snapshot built from `left`/`right` —
/// the schema's own reduced shape, opened through the same guarded
/// restore.
///
/// The v1 document predating the favorite kind marks itself
/// ([WorkspaceListDocument.legacySchema]) so [load] can mint each saved
/// record's bookmark once — same id, so the detail doc stays linked —
/// then rewrites itself v2. From then on "detail without bookmark"
/// means the favorite was deleted, and the orphan is pruned rather than
/// resurrected.
///
/// Mutations persist first and publish second: a store write that fails
/// leaves the in-memory lists untouched, so no surface renders a
/// workspace the disk does not hold. The bookmark write follows the
/// detail write on purpose — a detail whose bookmark never landed is
/// invisible residue the next load reconciles, while a bookmark without
/// its detail would publish a degraded row the user believes holds their
/// whole tab set.
final class WorkspaceLibrary extends ChangeNotifier {
  WorkspaceLibrary({
    required WorkspaceListStore store,
    required BookmarkStore bookmarks,
    DateTime Function()? now,
    ApplicationErrorReporter? errors,
  }) : // Keep the store seams private to the library.
       // ignore: prefer_initializing_formals
       _store = store,
       _bookmarks = bookmarks,
       _now = now ?? DateTime.now,
       // Keep the reporter private while allowing test-only injection.
       // ignore: prefer_initializing_formals
       _errors = errors ?? ApplicationErrorReporter() {
    _changes = bookmarks.changes.listen(_onStoreChange);
  }

  final WorkspaceListStore _store;
  final BookmarkStore _bookmarks;
  final DateTime Function() _now;
  final ApplicationErrorReporter _errors;
  late final StreamSubscription<BookmarkStoreChange> _changes;

  /// The workspace-kind favorites in the store's own (sortKey, id)
  /// order — the same order the sidebar rows render, so the Workspaces
  /// submenu and the sidebar can never disagree about sequence.
  List<Bookmark> _workspaceBookmarks = const [];

  /// The device-local detail records, keyed by bookmark id.
  Map<String, SavedWorkspace> _details = const {};

  bool _disposed = false;

  /// Set once [load] has populated both layers — mutations before that
  /// would dedupe against an empty favorite list and mint duplicate
  /// rows, so [save]/[recapture] assert it.
  bool _loaded = false;

  /// The serialized tail every detail-document write joins, so a
  /// removal landing mid-persist can never be republished from the
  /// pre-await snapshot — each operation derives its document from the
  /// CURRENT map when it actually runs.
  Future<void> _detailTail = Future.value();

  /// The saved workspaces in favorite order: each workspace-kind
  /// bookmark joined with its device-local detail (live label from the
  /// bookmark — a sidebar rename must not resurrect the captured name)
  /// or the placeholder a detail-less record degrades to.
  List<SavedWorkspace> get workspaces => List.unmodifiable([
    for (final bookmark in _workspaceBookmarks)
      _joined(bookmark) ?? _placeholder(bookmark),
  ]);

  SavedWorkspace? _joined(Bookmark bookmark) {
    final detail = _details[bookmark.id];
    if (detail == null) return null;
    return detail.label == bookmark.label
        ? detail
        : detail.copyWith(label: bookmark.label);
  }

  /// Loads the favorites and the detail document, migrating the pre-M5
  /// document (schema 1) once: every saved record mints its workspace
  /// bookmark under the SAME id — the detail doc's key — carrying the
  /// panes' endpoints and the record's own timestamps, then the
  /// document rewrites at the current schema so a later "missing
  /// bookmark" reads as deleted, never as unmigrated.
  ///
  /// A malformed or newer-schema document throws [FormatException] —
  /// the caller reports and boots an empty library; the file is never
  /// partially trusted or overwritten unread (the store's
  /// read-before-write keeps it intact).
  Future<void> load() async {
    final document = await _store.load();
    if (_disposed) return;
    var details = document?.workspaces ?? const <SavedWorkspace>[];
    final stored = await _bookmarks.load();
    if (_disposed) return;
    final workspaceBookmarks = [
      for (final bookmark in stored)
        if (bookmark.kind == BookmarkKind.workspace) bookmark,
    ];

    if (document != null && document.legacySchema) {
      // Mint the favorite per record, one upsert at a time so each
      // sortKeyForInsert sees the previous mint — batching the writes
      // would collapse every migrated row onto the same tail key.
      for (final record in details) {
        if (workspaceBookmarks.any((b) => b.id == record.id)) continue;
        final sortKey = await _bookmarks.sortKeyForInsert();
        if (_disposed) return;
        // Mint once: the persisted record and the in-memory row must be
        // the same instance, so a future _bookmarkFor change can never
        // diverge the two halves.
        final minted = _bookmarkFor(record, sortKey: sortKey);
        await _bookmarks.upsertAll([minted]);
        if (_disposed) return;
        workspaceBookmarks.add(minted);
      }
      await _store.save(WorkspaceListDocument(workspaces: details));
      if (_disposed) return;
    } else if (details.isNotEmpty) {
      // v2+: a detail whose favorite is gone is a deleted row's residue
      // (or a synced tombstone's), never a workspace to resurrect.
      final ids = {for (final b in workspaceBookmarks) b.id};
      final kept = [for (final d in details) if (ids.contains(d.id)) d];
      if (kept.length != details.length) {
        await _store.save(WorkspaceListDocument(workspaces: kept));
        if (_disposed) return;
        details = kept;
      }
    }

    workspaceBookmarks.sort(compareBookmarkSortKeys);
    _workspaceBookmarks = List.unmodifiable(workspaceBookmarks);
    _details = Map.unmodifiable({for (final d in details) d.id: d});
    _loaded = true;
    notifyListeners();
  }

  /// Saves [snapshot] under [label] — the `workspace.save` command's
  /// half: the detail record (the exact tab sets) persists first, then
  /// the workspace favorite lands in the bookmark store at the tail of
  /// the sidebar's ungrouped section.
  ///
  /// Saving over an existing label replaces that workspace in place —
  /// one named workspace per name, the standard save-over behavior —
  /// keeping the bookmark's id, group, color, icon, and sidebar
  /// position so a re-captured workspace is recognizably the same
  /// favorite. Returns the record as persisted; a store failure
  /// propagates and leaves the in-memory lists untouched.
  Future<SavedWorkspace> save({
    required String label,
    required WorkspaceSnapshot snapshot,
  }) async {
    assert(!_disposed, 'save on a disposed WorkspaceLibrary');
    assert(_loaded, 'save before WorkspaceLibrary.load() completed');
    if (label.trim().isEmpty) {
      throw ArgumentError.value(label, 'label', 'must not be blank');
    }
    final existing = _workspaceBookmarks
        .where(
          (bookmark) => bookmark.label.toLowerCase() == label.toLowerCase(),
        )
        .firstOrNull;
    if (existing == null) {
      final now = _now().toUtc();
      final record = SavedWorkspace(
        id: uuidV4(),
        label: label,
        savedAt: now,
        lastOpenedAt: null,
        snapshot: snapshot,
      );
      await _persistDetail(record);
      if (_disposed) return record;
      final sortKey = await _bookmarks.sortKeyForInsert();
      if (_disposed) return record;
      await _bookmarks.save(_bookmarkFor(record, sortKey: sortKey));
      return record;
    }
    final saved = await _persistExisting(existing, snapshot);
    return saved;
  }

  /// The sidebar row's "Update Workspace" verb: re-captures the panes
  /// over the workspace favorite [id] — same id, same label and sidebar
  /// position, refreshed endpoints and detail. Returns the updated
  /// record, or null when [id] is not a workspace favorite (the row
  /// went away between render and activation — a no-op, not an error).
  Future<SavedWorkspace?> recapture(
    String id,
    WorkspaceSnapshot snapshot,
  ) async {
    assert(!_disposed, 'recapture on a disposed WorkspaceLibrary');
    assert(_loaded, 'recapture before WorkspaceLibrary.load() completed');
    final existing = _workspaceBookmarks
        .where((bookmark) => bookmark.id == id)
        .firstOrNull;
    if (existing == null) return null;
    return _persistExisting(existing, snapshot);
  }

  /// The shared update half of [save] and [recapture]: writes the
  /// detail first, then refreshes the favorite's endpoints in place —
  /// every sidebar-facing field the user arranged (group, order,
  /// accent) survives a re-capture untouched.
  Future<SavedWorkspace> _persistExisting(
    Bookmark existing,
    WorkspaceSnapshot snapshot,
  ) async {
    final record = SavedWorkspace(
      id: existing.id,
      label: existing.label,
      savedAt: _now().toUtc(),
      lastOpenedAt: null,
      snapshot: snapshot,
    );
    await _persistDetail(record);
    if (_disposed) return record;
    await _bookmarks.save(_refreshEndpoints(existing, snapshot));
    return record;
  }

  /// Records that [id]'s workspace was opened: stamps `lastOpenedAt` on
  /// the detail record. A store failure propagates; a missing id — or a
  /// workspace favorite with no device-local detail — is a no-op.
  Future<void> markOpened(String id) async {
    if (_disposed) return;
    assert(_loaded, 'markOpened before WorkspaceLibrary.load() completed');
    final detail = _details[id];
    if (detail == null) return;
    await _persistDetail(
      detail.copyWith(lastOpenedAt: () => _now().toUtc()),
    );
  }

  /// One detail write: persist first, publish second — a failed write
  /// leaves the in-memory map untouched.
  Future<void> _persistDetail(SavedWorkspace record) =>
      _writeDetails(upsert: record);

  /// The detail counterpart of a favorite's removal: same persist-first
  /// discipline — a failed write leaves the residue for the next load's
  /// prune rather than publishing a state the disk does not hold.
  Future<void> _removeDetail(String id) => _writeDetails(removedId: id);

  /// Every detail-document mutation funnels through this serialized
  /// lane. Each operation derives its document from the CURRENT map at
  /// run time, so a removal enqueued behind an in-flight persist cannot
  /// be clobbered by the persist's pre-await snapshot — and the publish
  /// step replays that same merge into memory.
  Future<void> _writeDetails({
    SavedWorkspace? upsert,
    String? removedId,
  }) {
    final operation = _detailTail.then((_) async {
      final next = Map<String, SavedWorkspace>.of(_details);
      if (removedId != null) next.remove(removedId);
      if (upsert != null) next[upsert.id] = upsert;
      await _store.save(
        WorkspaceListDocument(workspaces: List.of(next.values)),
      );
      if (_disposed) return;
      _details = Map.unmodifiable(next);
      notifyListeners();
    });
    _detailTail = operation.then((_) {}, onError: (_, _) {});
    return operation;
  }

  /// Local bookmark-store writes the favorites list must answer to: a
  /// saved row joins the workspace set (or leaves it when its kind
  /// changed); a removed row leaves AND drops its detail — a deleted
  /// workspace keeps no residue to resurrect on the next load.
  void _onStoreChange(BookmarkStoreChange change) {
    if (_disposed) return;
    switch (change) {
      case BookmarkSavedChange(:final bookmark):
        final next = [
          for (final b in _workspaceBookmarks)
            if (b.id != bookmark.id) b,
        ];
        if (bookmark.kind == BookmarkKind.workspace) next.add(bookmark);
        next.sort(compareBookmarkSortKeys);
        _workspaceBookmarks = List.unmodifiable(next);
        notifyListeners();
      case BookmarkRemovedChange(:final id):
        _workspaceBookmarks = List.unmodifiable([
          for (final b in _workspaceBookmarks)
            if (b.id != id) b,
        ]);
        // The row is gone — publish that immediately; the detail drop
        // joins the serialized write lane (a failure reports, and the
        // residue stays invisible until the next load's prune).
        if (_details.containsKey(id)) {
          unawaited(_removeDetail(id).catchError(_errors.report));
        }
        notifyListeners();
    }
  }

  /// The workspace bookmark [record] mints: the favorite's synced
  /// surface is exactly the pinned schema's — label, order, and each
  /// pane's endpoint — never the tab set (that stays device-local).
  Bookmark _bookmarkFor(SavedWorkspace record, {required String sortKey}) =>
      Bookmark(
        id: record.id,
        kind: BookmarkKind.workspace,
        label: record.label,
        left: workspaceEndpointFor(record.snapshot.left),
        right: workspaceEndpointFor(record.snapshot.right),
        sortKey: sortKey,
        createdAt: record.savedAt,
        updatedAt: record.lastOpenedAt ?? record.savedAt,
      );

  /// The re-capture rewrite: only the endpoints change; the model has
  /// no copyWith, so the untouched fields are spelled out — same
  /// posture as the sidebar's own record rebuilds.
  Bookmark _refreshEndpoints(Bookmark existing, WorkspaceSnapshot snapshot) =>
      Bookmark(
        id: existing.id,
        kind: BookmarkKind.workspace,
        label: existing.label,
        group: existing.group,
        color: existing.color,
        icon: existing.icon,
        left: workspaceEndpointFor(snapshot.left),
        right: workspaceEndpointFor(snapshot.right),
        preferredPane: existing.preferredPane,
        sortKey: existing.sortKey,
        createdAt: existing.createdAt,
        updatedAt: existing.updatedAt,
      );

  /// The degraded record a detail-less workspace favorite joins to:
  /// the endpoints ARE the synced truth, so the placeholder replays one
  /// tab per pane at those locations — opened through the identical
  /// guarded restore as a full snapshot.
  SavedWorkspace _placeholder(Bookmark bookmark) => SavedWorkspace(
    id: bookmark.id,
    label: bookmark.label,
    savedAt: bookmark.createdAt,
    lastOpenedAt: null,
    snapshot: workspaceSnapshotFromBookmark(bookmark),
  );

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_changes.cancel());
    super.dispose();
  }
}

/// The pane's headline endpoint for the synced workspace record: its
/// ACTIVE tab's location (the surface the user saw), else the first
/// bound tab's, else `~` — a launcher pane has no location to record
/// and the bookmark schema requires one. A remote endpoint carries the
/// tab's connection identity (host, port, user, `secretRef`) — never a
/// secret; a remote tab whose bookmark lost its identity is skipped
/// like an unbound one rather than minting a location-less remote path.
BookmarkLocation workspaceEndpointFor(WorkspacePaneState pane) {
  final tabs = [
    if (pane.activeTab >= 0 && pane.activeTab < pane.tabs.length)
      pane.tabs[pane.activeTab],
    ...pane.tabs,
  ];
  for (final tab in tabs) {
    switch (tab.session.kind) {
      case SessionTabKind.local:
        final path = tab.session.path;
        // path is non-null for every bound kind by construction — guard
        // anyway so a malformed tab skips like an unbound one rather
        // than throwing mid-capture.
        if (path == null) break;
        return BookmarkLocation(path: path);
      case SessionTabKind.remote:
        final server = tab.session.bookmark?.server;
        final path = tab.session.path ?? '/';
        if (server == null) break;
        return BookmarkLocation(
          server: server,
          // The schema rejects non-absolute remote paths at decode —
          // never write a record the next load could not read.
          path: path.startsWith('/') ? path : '/',
        );
      case SessionTabKind.unbound:
        break;
    }
  }
  return const BookmarkLocation(path: '~');
}

/// The reduced snapshot a detail-less workspace favorite opens to —
/// the schema's own shape: one tab per pane at the recorded endpoint.
/// A remote endpoint becomes a remote tab bound to a synthesized
/// remotePath bookmark under the workspace's id (never persisted to the
/// store — the detail doc's SessionTabState serializes it verbatim if
/// the tab is re-captured), so the restore lands
/// disconnected-but-targeted through the ordinary session-restoration
/// path (02 §3: Reconnect bar, no auto-secret use).
WorkspaceSnapshot workspaceSnapshotFromBookmark(Bookmark bookmark) =>
    WorkspaceSnapshot(
      left: _paneFromLocation(bookmark, sessionLeftPaneId, bookmark.left),
      right: _paneFromLocation(bookmark, sessionRightPaneId, bookmark.right),
    );

WorkspacePaneState _paneFromLocation(
  Bookmark workspace,
  String paneId,
  BookmarkLocation? location,
) {
  if (location == null) {
    return WorkspacePaneState(paneId: paneId, activeTab: -1, tabs: const []);
  }
  return WorkspacePaneState(
    paneId: paneId,
    activeTab: 0,
    tabs: [
      WorkspaceTabState(
        session: _sessionFor(workspace, paneId, location),
        filterQuery: '',
        filterFieldOpen: false,
        showHidden: false,
        viewMode: PaneViewMode.details,
      ),
    ],
  );
}

SessionTabState _sessionFor(
  Bookmark workspace,
  String paneId,
  BookmarkLocation location,
) {
  final server = location.server;
  if (server == null) {
    return SessionTabState.local(path: location.path);
  }
  final endpoint = Bookmark(
    // The endpoint binding's pool id: stable per workspace+pane so a
    // re-opened workspace dedupes its own connections, and namespaced
    // off the favorites namespace so it can never collide with a stored
    // bookmark's id.
    id: '${workspace.id}:$paneId',
    kind: BookmarkKind.remotePath,
    label: workspace.label,
    server: server,
    remotePath: location.path,
    // Never reaches the store — but keep it minted-shaped so a
    // re-capture serializes a record the schema accepts.
    sortKey: sortKeyBetween(null, null),
    createdAt: workspace.createdAt,
    updatedAt: workspace.updatedAt,
  );
  return SessionTabState.remote(
    serverId: endpoint.id,
    path: location.path,
    bookmark: endpoint,
  );
}
