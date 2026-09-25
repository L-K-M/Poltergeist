import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'application_error_reporter.dart';
import 'uuid.dart';

/// The sidebar's fixed sections (10 §5), in rail order. [pinned] is the
/// shortlist of the servers the user pinned, the account's and the
/// remote favorites (D33), drawn only while one is listed.
enum SidebarSection { pinned, devices, favorites, servers }

/// The persisted collapse-key vocabulary (02 §4: device-local). Every key
/// carries its surface's namespace — `sec:` for the three fixed sections,
/// `fav:` for favorite groups, `srv:` for server groups — so a favorite
/// group and a server group that share a name, or a group literally named
/// after a section, no longer fold each other.
abstract final class SidebarCollapseKeys {
  static const _section = 'sec:';
  static const _favoriteGroup = 'fav:';
  static const _serverGroup = 'srv:';

  static String section(SidebarSection section) => '$_section${section.name}';

  /// [groupKey] is the section's normalized key
  /// ([BookmarkGroupSection.key]).
  static String favoriteGroup(String groupKey) => '$_favoriteGroup$groupKey';

  /// [groupKey] is the server-grouping key (Séance's `serverGroupKey`).
  static String serverGroup(String groupKey) => '$_serverGroup$groupKey';

  /// The pre-D32 keys this build replaces: the Connections section's
  /// fixed key, the Séance-servers section and its group prefix.
  static const _legacyConnections = 'sidebar.connections';
  static const _legacyCatalog = 'sidebar.catalog';
  static const _legacyCatalogGroup = 'sidebar.catalog.';

  /// Rewrites a stored key set into the namespaced vocabulary. Idempotent
  /// — namespaced keys pass through — so it runs on every launch without
  /// a schema marker. Legacy keys map as the surfaces moved:
  ///
  /// - `sidebar.catalog` (the Séance-servers section) → SERVERS;
  /// - `sidebar.catalog.<group>` → that server group;
  /// - `sidebar.connections` → dropped (the section is gone: live state is
  ///   the SERVERS rows' dot now);
  /// - `''` (the old "Favorites" header over ungrouped rows) → dropped:
  ///   those rows sit directly under FAVORITES now, and folding the whole
  ///   section for them would hide more than the user folded;
  /// - anything else was a favorite group's key.
  ///
  /// A legacy favorite group whose own name starts with a namespace
  /// (`fav:`…) is indistinguishable from a migrated key and keeps its
  /// spelling — it simply reads as unfolded, which is harmless for
  /// cosmetic state.
  static Set<String> migrate(Iterable<String> stored) => {
    for (final key in stored) ?_migrated(key),
  };

  static String? _migrated(String key) {
    if (key.startsWith(_section) ||
        key.startsWith(_favoriteGroup) ||
        key.startsWith(_serverGroup)) {
      return key;
    }
    if (key == _legacyConnections || key.isEmpty) return null;
    if (key == _legacyCatalog) return section(SidebarSection.servers);
    if (key.startsWith(_legacyCatalogGroup)) {
      return serverGroup(key.substring(_legacyCatalogGroup.length));
    }
    return favoriteGroup(key);
  }
}

/// How roomy the sidebar's rows are (D33), a device-local choice the
/// sidebar kit draws: [compact] is 10 §5's one-line rail, [comfortable]
/// the two-line rows with the address or path spelled out. Comfortable
/// is the default on every platform. The view maps it onto the kit's own
/// enum, so this layer stays free of widget types.
enum SidebarDensity { compact, comfortable }

/// The persist seam for collapse state (02 §4: device-local): folds or
/// unfolds the one section [key] in the set as stored when the write
/// runs, and completes with the set now stored.
typedef CollapsedSectionWriter =
    Future<Set<String>> Function(String key, {required bool collapsed});

/// The persist seam for the PINNED shortlist (D33: device-local): pins or
/// unpins the one [serverId] in the set as stored when the write runs,
/// and completes with the set now stored.
typedef PinnedServerWriter =
    Future<Set<String>> Function(String serverId, {required bool pinned});

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
    SidebarDensity density = SidebarDensity.comfortable,
    Set<String> initiallyPinned = const {},
    this.onCollapsedChanged,
    this.onDensityChanged,
    this.onPinnedChanged,
    this.onBookmarksChanged,
    this.onBookmarkRemoved,
    ApplicationErrorReporter? errors,
  }) : // Keep the store seam private to the controller.
       // ignore: prefer_initializing_formals
       _store = store,
       _collapsed = _StoredIdSet(
         SidebarCollapseKeys.migrate(initiallyCollapsed),
       ),
       // A named parameter cannot be private; the field stays mutable
       // behind setDensity.
       // ignore: prefer_initializing_formals
       _density = density,
       _pinned = _StoredIdSet(initiallyPinned),
       // Keep the reporter private while allowing test-only injection.
       // ignore: prefer_initializing_formals
       _errors = errors ?? ApplicationErrorReporter() {
    _changes = store.changes.listen((_) => reload(), onError: _errors.report);
  }

  final BookmarkStore _store;
  final ApplicationErrorReporter _errors;
  late final StreamSubscription<BookmarkStoreChange> _changes;

  /// The persist sink for collapse state (02 §4: device-local). Called
  /// after every user toggle with the one key that changed, never the
  /// full set: this set may be missing keys (a launch whose read failed
  /// starts it empty), and writing it would drop them. The controller
  /// then shows the set the sink stored. Null leaves collapse memory
  /// in-process (tests, alternate boot paths).
  final CollapsedSectionWriter? onCollapsedChanged;

  /// The persist sink for [density] (device-local, like collapse state).
  /// Called after every change the user makes; null keeps the choice
  /// in-process.
  final void Function(SidebarDensity density)? onDensityChanged;

  /// The persist sink for the pinned-server set (device-local, like
  /// Séance's pins, which never sync). Called after every change with
  /// the one id that changed, for the reason [onCollapsedChanged] gives;
  /// the controller then shows the pins the sink stored. Null keeps pins
  /// in-process.
  final PinnedServerWriter? onPinnedChanged;

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
  final _StoredIdSet _collapsed;
  SidebarDensity _density;
  final _StoredIdSet _pinned;
  int _generation = 0;
  bool _disposed = false;
  String _filterQuery = '';
  bool _filterOpen = false;
  bool _filterFocusPending = false;
  List<String> _pendingGroups = const [];

  /// The favorites sections in the store's order (named groups sorted,
  /// ungrouped last, a single anonymous section for an all-flat list).
  List<BookmarkGroupSection> get sections => _sections;

  SidebarLoad get load => _load;

  /// Every stored bookmark, flat — the probe owner's reconciliation set.
  List<Bookmark> get bookmarks => [
    for (final section in _sections) ...section.bookmarks,
  ];

  /// Collapse keys currently folded, in [SidebarCollapseKeys]' namespaced
  /// vocabulary. Group keys are the sections' normalized keys, so a
  /// re-sorted group keeps its state.
  Set<String> get collapsedGroups => _collapsed.ids;

  bool isCollapsed(String sectionKey) => _collapsed.ids.contains(sectionKey);

  /// Toggles one section's collapse and reports the change to the
  /// persist seam. A failed write does not roll the toggle back — the
  /// state is cosmetic and the next launch's re-read is honest.
  void toggleCollapsed(String sectionKey) {
    if (_disposed) return;
    final collapsed = !isCollapsed(sectionKey);
    final change = _collapsed.apply(sectionKey, member: collapsed);
    notifyListeners();
    final sink = onCollapsedChanged;
    if (sink == null) return;
    _persist(_collapsed, change, () => sink(sectionKey, collapsed: collapsed));
  }

  /// The rows' density (D33): the bottom bar's switch, Home's app bar
  /// and View ▸ Use Compact/Comfortable Sidebar Rows all set it here, so
  /// the rail, the drawer and Home read one choice.
  SidebarDensity get density => _density;

  /// Sets the density and reports it to the persist seam. Like a
  /// collapse toggle, a failed write keeps the change: the state is
  /// cosmetic and the next launch's re-read is honest.
  void setDensity(SidebarDensity density) {
    if (_disposed || density == _density) return;
    _density = density;
    notifyListeners();
    final sink = onDensityChanged;
    if (sink == null) return;
    try {
      sink(density);
    } on Object catch (error, stackTrace) {
      _errors.report(error, stackTrace);
    }
  }

  /// The ids of the servers pinned to PINNED (10 §5's "pinned servers
  /// come first", D33): the account's servers and the remote favorites
  /// share this one set, as they share one id space (both apps mint
  /// UUIDs for both). An id whose server is no longer listed keeps its
  /// pin: it draws nothing, and comes back pinned if the server does (a
  /// sync round that restores it, the shared account back on). Only a
  /// favorite deleted here drops its pin, in [remove].
  Set<String> get pinnedServers => _pinned.ids;

  bool isPinned(String serverId) => _pinned.ids.contains(serverId);

  /// Pin to top / Unpin: toggles [serverId] and reports the change to the
  /// persist seam. Like a collapse toggle, a failed write keeps the
  /// change.
  void togglePinned(String serverId) {
    if (_disposed) return;
    _setPinned(serverId, pinned: !isPinned(serverId));
  }

  void _setPinned(String serverId, {required bool pinned}) {
    final change = _pinned.apply(serverId, member: pinned);
    notifyListeners();
    final sink = onPinnedChanged;
    if (sink == null) return;
    _persist(_pinned, change, () => sink(serverId, pinned: pinned));
  }

  /// Runs one persist [write] for [change] and shows the set it stored:
  /// after a launch whose read failed, that is what brings back every id
  /// the store still held. A failed write reports and keeps the local
  /// change until a later write lands.
  void _persist(
    _StoredIdSet target,
    int change,
    Future<Set<String>> Function() write,
  ) {
    final Future<Set<String>> stored;
    try {
      stored = write();
    } on Object catch (error, stackTrace) {
      _errors.report(error, stackTrace);
      return;
    }
    unawaited(
      stored.then<void>((ids) {
        if (!_disposed && target.adopt(change, ids)) notifyListeners();
      }, onError: _errors.report),
    );
  }

  /// The sidebar filter's query (10 §5: one field, every section). Held
  /// here rather than in the view so `view.filterSidebar` can open the
  /// field from the command registry and the drawer and inline mounts
  /// share one query.
  String get filterQuery => _filterQuery;

  /// Whether the field was opened explicitly (the command) — it then
  /// shows even below the server threshold, until dismissed.
  bool get filterOpen => _filterOpen;

  /// Whether [requestFilter] asked for focus that no rail has taken yet.
  bool get filterFocusPending => _filterFocusPending;

  /// Takes the pending focus request, once: the rail that builds next —
  /// inline, or the drawer the command just opened — focuses its field;
  /// a rail mounted later for any other reason does not steal focus.
  bool takeFilterFocus() {
    final pending = _filterFocusPending;
    _filterFocusPending = false;
    return pending;
  }

  void setFilterQuery(String query) {
    if (_disposed || query == _filterQuery) return;
    _filterQuery = query;
    notifyListeners();
  }

  /// `view.filterSidebar`: shows the field and asks it to take focus.
  void requestFilter() {
    if (_disposed) return;
    _filterOpen = true;
    _filterFocusPending = true;
    notifyListeners();
  }

  /// Esc in the field: a live query clears first; an empty one closes an
  /// explicitly opened field.
  void dismissFilter() {
    if (_disposed) return;
    if (_filterQuery.isNotEmpty) {
      _filterQuery = '';
    } else {
      _filterOpen = false;
    }
    notifyListeners();
  }

  /// Groups created with "New Group…" that hold no favorite yet. Groups
  /// are member-carried in the store (no group records, 04 §2.1), so an
  /// empty one can only live here — in memory, until a favorite is dropped
  /// into it (the next reload then finds the real group and retires this
  /// entry) or the app quits. Nothing unsynced is persisted this way.
  List<String> get pendingGroups => _pendingGroups;

  /// Adds [name] as a pending group unless a group with its key exists.
  void addPendingGroup(String name) {
    if (_disposed) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final key = serverGroupKey(trimmed);
    final exists =
        _pendingGroups.any((pending) => serverGroupKey(pending) == key) ||
        _sections.any((section) => section.key == key && section.name != null);
    if (exists) return;
    _pendingGroups = List.unmodifiable([..._pendingGroups, trimmed]);
    notifyListeners();
  }

  void removePendingGroup(String name) {
    if (_disposed) return;
    final next = [
      for (final pending in _pendingGroups)
        if (pending != name) pending,
    ];
    if (next.length == _pendingGroups.length) return;
    _pendingGroups = List.unmodifiable(next);
    notifyListeners();
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
    // A pending group that gained a member is a real group now.
    _pendingGroups = List.unmodifiable([
      for (final pending in _pendingGroups)
        if (!sections.any(
          (section) =>
              section.name != null && section.key == serverGroupKey(pending),
        ))
          pending,
    ]);
    notifyListeners();
    // Guarded like the other callback seams: reload() runs
    // fire-and-forget off the changes lane, so a throwing shell
    // callback must report here, not escape as an unhandled async
    // error nobody awaited.
    final changed = onBookmarksChanged;
    if (changed == null) return;
    try {
      changed();
    } on Object catch (error, stackTrace) {
      _errors.report(error, stackTrace);
    }
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
  /// where the engine still serves a bookmark the store forgot. A pinned
  /// remote favorite's pin goes with it: the user deleted it here, and
  /// its minted id never names another record.
  Future<bool> remove(String id) async {
    _assertLive();
    final removed = await _store.remove(id);
    if (removed && !_disposed && isPinned(id)) {
      _setPinned(id, pinned: false);
    }
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

  /// Adds local folders as favorites (10 §5: the empty state's one-click
  /// offer, drops, "Add Current Folder"): each lands at [group]'s tail
  /// through the store's minted key, labelled [labelOf] of its path. A
  /// folder some favorite already names is skipped — favorites sync, so a
  /// duplicate would follow the user to every device.
  Future<List<Bookmark>> addLocalFolders(
    Iterable<String> paths, {
    required String Function(String path) labelOf,
    String? group,
    String? beforeId,
    String? afterId,
  }) async {
    _assertLive();
    final existing = {
      for (final bookmark in await _store.load())
        if (bookmark.kind == BookmarkKind.localFolder) ?bookmark.localPath,
    };
    final added = <Bookmark>[];
    for (final path in paths) {
      if (!existing.add(path)) continue;
      final now = DateTime.now();
      // One key per insert, each landing after the previous one (the
      // store's between-neighbors convention: `beforeId` is the member
      // the new row follows), so consecutive adds keep their order.
      final sortKey = await _store.sortKeyForInsert(
        group: group,
        beforeId: added.isEmpty ? beforeId : added.last.id,
        afterId: afterId,
      );
      added.add(
        await _store.save(
          Bookmark(
            id: uuidV4(),
            kind: BookmarkKind.localFolder,
            label: labelOf(path),
            group: group,
            localPath: path,
            sortKey: sortKey,
            createdAt: now,
            updatedAt: now,
          ),
        ),
      );
    }
    return added;
  }

  /// Saves a remote location as a new server row (10 §5's "Save to
  /// Servers…" and "Add Current Folder" on a remote pane): the endpoint of
  /// [live] — never its id, which for a Quick Connect session is an adhoc
  /// key that must not enter the store — landing on [path]. Carries no
  /// secret: bookmarks hold `secretRef`s, and the live identity's is
  /// copied verbatim (an adhoc identity has none). Mirrors the pane's
  /// save-as-favorite bar.
  Future<Bookmark> saveRemoteLocation({
    required Bookmark live,
    required String? path,
    required String label,
    String? group,
  }) {
    _assertLive();
    return saveRemoteLocationTo(
      _store,
      live: live,
      path: path,
      label: label,
      group: group,
    );
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

/// A device-local id set the sidebar edits optimistically (the folded
/// sections, the PINNED shortlist): [apply] shows a change at once, and
/// [adopt] then takes the set that change's write stored, unless a later
/// change is already on its way. That write runs after this one (the
/// settings store serializes them), so its answer covers both, and
/// adopting this one first would briefly undo the later change on screen.
final class _StoredIdSet {
  _StoredIdSet(Iterable<String> initial) : _ids = Set.unmodifiable(initial);

  Set<String> _ids;
  int _changes = 0;

  Set<String> get ids => _ids;

  /// Adds ([member]) or removes [id] locally; returns the change's number
  /// for [adopt].
  int apply(String id, {required bool member}) {
    final next = Set<String>.of(_ids);
    if (member) {
      next.add(id);
    } else {
      next.remove(id);
    }
    _ids = Set.unmodifiable(next);
    return ++_changes;
  }

  /// Takes [stored] as the answer to [change]. False when a later change
  /// superseded it, or when [stored] matches what already shows.
  bool adopt(int change, Set<String> stored) {
    if (change != _changes || setEquals(stored, _ids)) return false;
    _ids = Set.unmodifiable(stored);
    return true;
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

/// Saves a live session's endpoint and [path] into [store] as a server
/// row: a fresh id (a Quick Connect id never enters the store), the live
/// identity, colour and mark, and a store-minted tail key. Carries no
/// secret — bookmarks hold `secretRef`s into the vault. The sidebar and
/// the pane's "Not saved" banner both save through this, so a session
/// saved from either lands as the same record.
Future<Bookmark> saveRemoteLocationTo(
  BookmarkStore store, {
  required Bookmark live,
  required String? path,
  required String label,
  String? group,
}) async {
  final sortKey = await store.sortKeyForInsert(group: group);
  final now = DateTime.now();
  return store.save(
    Bookmark(
      id: uuidV4(),
      kind: BookmarkKind.remotePath,
      label: label,
      group: group,
      color: live.color,
      icon: live.icon,
      server: live.server,
      remotePath: path ?? live.remotePath,
      sortKey: sortKey,
      createdAt: now,
      updatedAt: now,
    ),
  );
}
