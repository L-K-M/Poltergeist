import 'package:poltergeist_core/poltergeist_core.dart';

import 'bookmark_landing_path.dart';

/// 02 §3's session-state document — what launch restoration persists per
/// pane and per tab. Pure data with strict decoding (the sibling stores'
/// posture: unknown fields ignored, malformed present fields fail, an
/// unknown schema version fails closed — a newer Poltergeist's document
/// is never read as v1 and never overwritten).
///
/// The document lives inside `settings.json` behind the prefs layer
/// ([SessionStateStore] owns the key); the schema is versioned like
/// D12's catalogs. Session persistence covers panes, tabs, and locations
/// ONLY — selection, history, and the transient lenses stay session-
/// scoped by the same data-loss rule the ghost ring documents.
enum SessionTabKind { local, remote, unbound }

/// The two canonical pane ids a v1 session document covers — the
/// schema's own constants, aliased by [PaneTabsController]'s public
/// names so the strips and the schema share one source (a foreign or
/// duplicated pane id fails decode, below).
const sessionLeftPaneId = 'pane.left';
const sessionRightPaneId = 'pane.right';

/// One persisted tab: a local folder, a remote binding's path plus its
/// cached listing (the rows the Reconnect bar covers until activation),
/// or an unbound launcher tab (02 §2.7 — a legal pane state that must
/// round-trip as itself, never as an auto-opened tab).
final class SessionTabState {
  const SessionTabState._({
    required this.kind,
    this.path,
    this.serverId,
    this.bookmark,
    this.listing = const [],
  });

  const SessionTabState.local({
    required String path,
    List<RemoteFileEntry> listing = const [],
  }) : this._(kind: SessionTabKind.local, path: path, listing: listing);

  const SessionTabState.remote({
    required String serverId,
    required String path,
    required Bookmark bookmark,
    List<RemoteFileEntry> listing = const [],
  }) : this._(
         kind: SessionTabKind.remote,
         serverId: serverId,
         path: path,
         bookmark: bookmark,
         listing: listing,
       );

  const SessionTabState.unbound() : this._(kind: SessionTabKind.unbound);

  final SessionTabKind kind;

  /// The bound path (local or remote); null only for [unbound] tabs.
  final String? path;

  /// The remote binding's serverId — the pool's bookmark id (03 §3.5).
  final String? serverId;

  /// The remote binding's bookmark record, persisted verbatim so the
  /// restored tab reconnects the endpoint the session knew — including
  /// `adhoc:` bookmarks that never reached the store. No secrets: the
  /// record carries `secretRef`, never the secret.
  final Bookmark? bookmark;

  /// The cached listing snapshot a restored remote tab shows behind its
  /// Reconnect bar (persisted for local tabs too — the same uniform
  /// restored presentation until activation rebinds live).
  final List<RemoteFileEntry> listing;

  Map<String, Object?> toJson() {
    final base = <String, Object?>{'kind': kind.name};
    switch (kind) {
      case SessionTabKind.unbound:
        return base;
      case SessionTabKind.local:
        base['path'] = path;
      case SessionTabKind.remote:
        base['serverId'] = serverId;
        base['path'] = path;
        base['bookmark'] = withRemoteLandingPath(bookmark!.toJson());
    }
    if (listing.isNotEmpty) {
      base['listing'] = [for (final entry in listing) _entryToJson(entry)];
    }
    return base;
  }

  factory SessionTabState.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Invalid session tab');
    final kind = switch (json['kind']) {
      'local' => SessionTabKind.local,
      'remote' => SessionTabKind.remote,
      'unbound' => SessionTabKind.unbound,
      _ => throw const FormatException('Invalid session tab kind'),
    };
    final listing = _decodeListing(json['listing']);
    switch (kind) {
      case SessionTabKind.unbound:
        return const SessionTabState.unbound();
      case SessionTabKind.local:
        return SessionTabState.local(
          path: _requiredPath(json),
          listing: listing,
        );
      case SessionTabKind.remote:
        final serverId = json['serverId'];
        if (serverId is! String || serverId.isEmpty) {
          throw const FormatException('Invalid session tab serverId');
        }
        final bookmarkJson = json['bookmark'];
        if (bookmarkJson is! Map || bookmarkJson['id'] is! String) {
          throw const FormatException('Invalid session tab bookmark');
        }
        return SessionTabState.remote(
          serverId: serverId,
          path: _requiredPath(json),
          bookmark: Bookmark.fromJson(
            withRemoteLandingPath(bookmarkJson.cast<String, dynamic>()),
            recordId: 'bookmark:${bookmarkJson['id']}',
          ),
          listing: listing,
        );
    }
  }

  static String _requiredPath(Map<dynamic, dynamic> json) {
    final path = json['path'];
    if (path is! String || path.isEmpty) {
      throw const FormatException('Invalid session tab path');
    }
    return path;
  }

  static List<RemoteFileEntry> _decodeListing(Object? json) {
    if (json == null) return const [];
    if (json is! List) {
      throw const FormatException('Invalid session tab listing');
    }
    return List.unmodifiable([for (final record in json) _entryFromJson(record)]);
  }
}

/// One pane's persisted strip: the ordered tabs, the active index (-1
/// while the pane sat on the launcher), and the tab-id counter so
/// post-restore mints cannot collide with the persisted ids.
final class SessionPaneState {
  const SessionPaneState({
    required this.paneId,
    required this.activeTab,
    required this.nextTabOrdinal,
    required this.tabs,
  });

  final String paneId;
  final int activeTab;
  final int nextTabOrdinal;
  final List<SessionTabState> tabs;

  Map<String, Object?> toJson() => {
    'paneId': paneId,
    'activeTab': activeTab,
    'nextTabOrdinal': nextTabOrdinal,
    'tabs': [for (final tab in tabs) tab.toJson()],
  };

  factory SessionPaneState.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Invalid session pane');
    final paneId = json['paneId'];
    final activeTab = json['activeTab'];
    final nextTabOrdinal = json['nextTabOrdinal'];
    final tabs = json['tabs'];
    if (paneId is! String || paneId.isEmpty) {
      throw const FormatException('Invalid session pane id');
    }
    if (activeTab is! int || nextTabOrdinal is! int) {
      throw const FormatException('Invalid session pane counters');
    }
    if (tabs is! List) {
      throw const FormatException('Invalid session pane tabs');
    }
    final decodedTabs = List<SessionTabState>.unmodifiable([
      for (final tab in tabs) SessionTabState.fromJson(tab),
    ]);
    // Counter ranges are schema too: an active index outside
    // [-1, tabs.length) or an id counter below the first mint (1) is a
    // corrupt document, not a value to clamp into plausibility.
    if (activeTab < -1 || activeTab >= decodedTabs.length) {
      throw const FormatException('Invalid session pane active tab');
    }
    // Restored tabs mint their ids positionally from the counter
    // (`$paneId.tab${1..}`), so a counter at or below the tab count
    // would let a later mint collide with a restored id.
    if (nextTabOrdinal <= decodedTabs.length) {
      throw const FormatException('Invalid session pane tab counter');
    }
    return SessionPaneState(
      paneId: paneId,
      activeTab: activeTab,
      nextTabOrdinal: nextTabOrdinal,
      tabs: decodedTabs,
    );
  }
}

/// The root session document: both panes' strips, the active pane, and
/// the pane toggle's persisted user intent (02 §3 — the stage-2
/// auto-hide stays transient by the same rule it always was).
final class SessionState {
  const SessionState({
    required this.activePaneId,
    required this.secondPaneHidden,
    this.activityPanelHidden = true,
    this.inspectorHidden,
    this.inspectorTab,
    required this.panes,
  });

  static const schemaVersion = 1;

  final String activePaneId;
  final bool secondPaneHidden;

  /// `view.toggleActivityPanel`'s persisted user intent (02 §1's
  /// persistence list). Added inside v1 as an optional field — a
  /// document written before the panel existed decodes to the default
  /// (hidden) rather than failing the strict root.
  final bool activityPanelHidden;

  /// The D32 inspector's persisted visibility and tab (10 §3.1): optional
  /// fields inside v1 like [activityPanelHidden] — a document written
  /// before the inspector existed decodes them as null and the shell
  /// derives them from the legacy flag.
  final bool? inspectorHidden;
  final String? inspectorTab;
  final List<SessionPaneState> panes;

  Map<String, Object?> toJson() => {
    'version': schemaVersion,
    'activePane': activePaneId,
    'secondPaneHidden': secondPaneHidden,
    'activityPanelHidden': activityPanelHidden,
    if (inspectorHidden != null) 'inspectorHidden': inspectorHidden,
    if (inspectorTab != null) 'inspectorTab': inspectorTab,
    'panes': [for (final pane in panes) pane.toJson()],
  };

  /// Strict decode: a non-v1 version, a malformed root, or any malformed
  /// present field fails the whole document (the store's caller reports
  /// and boots a default session — the document is never partially
  /// trusted and never overwritten unread).
  factory SessionState.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Invalid session state');
    if (json['version'] is! int || json['version'] != schemaVersion) {
      throw const FormatException('Unsupported session state schema');
    }
    final activePane = json['activePane'];
    final secondPaneHidden = json['secondPaneHidden'];
    final activityPanelHidden = json['activityPanelHidden'];
    final inspectorHidden = json['inspectorHidden'];
    final inspectorTab = json['inspectorTab'];
    final panes = json['panes'];
    if (activePane is! String) {
      throw const FormatException('Invalid session active pane');
    }
    if (secondPaneHidden is! bool) {
      throw const FormatException('Invalid session pane visibility');
    }
    // Optional since it postdates the document's first shape: absent
    // means the pre-panel default; present means a bool, strictly.
    if (activityPanelHidden != null && activityPanelHidden is! bool) {
      throw const FormatException('Invalid session activity panel flag');
    }
    if (inspectorHidden != null && inspectorHidden is! bool) {
      throw const FormatException('Invalid session inspector flag');
    }
    if (inspectorTab != null && inspectorTab is! String) {
      throw const FormatException('Invalid session inspector tab');
    }
    if (panes is! List) {
      throw const FormatException('Invalid session panes');
    }
    final decodedPanes = List<SessionPaneState>.unmodifiable([
      for (final pane in panes) SessionPaneState.fromJson(pane),
    ]);
    // v1 is the two-pane document: the pane list is exactly the left and
    // right strips — a truncated write, a duplicate, a foreign pane id,
    // or an active pane naming no restored strip is corrupt, not a
    // partial restore to improvise around. The raw-length check matters:
    // the id set alone collapses duplicates, so [left, right, left]
    // would otherwise pass and decode one pane twice.
    final paneIds = decodedPanes.map((pane) => pane.paneId).toSet();
    if (decodedPanes.length != 2 ||
        paneIds.length != 2 ||
        !paneIds.containsAll(const {
          sessionLeftPaneId,
          sessionRightPaneId,
        }) ||
        !paneIds.contains(activePane)) {
      throw const FormatException('Invalid session panes');
    }
    return SessionState(
      activePaneId: activePane,
      secondPaneHidden: secondPaneHidden,
      activityPanelHidden: activityPanelHidden as bool? ?? true,
      inspectorHidden: inspectorHidden as bool?,
      inspectorTab: inspectorTab as String?,
      panes: decodedPanes,
    );
  }
}

/// The windows open beside the first one (00 D39), each a whole
/// [SessionState]. It lives under its own key beside the first window's
/// document, which keeps its v1 shape: a build from before multiple windows
/// reads that one and restores the first window as it always did.
final class SessionWindowsState {
  const SessionWindowsState({required this.windows});

  static const schemaVersion = 1;

  final List<SessionState> windows;

  Map<String, Object?> toJson() => {
    'version': schemaVersion,
    'windows': [for (final window in windows) window.toJson()],
  };

  /// Strict like [SessionState.fromJson]: one malformed window fails the
  /// whole document, which is then neither restored nor overwritten.
  factory SessionWindowsState.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Invalid session windows');
    if (json['version'] is! int || json['version'] != schemaVersion) {
      throw const FormatException('Unsupported session windows schema');
    }
    final windows = json['windows'];
    if (windows is! List) {
      throw const FormatException('Invalid session windows list');
    }
    return SessionWindowsState(
      windows: List.unmodifiable([
        for (final window in windows) SessionState.fromJson(window),
      ]),
    );
  }
}

Map<String, Object?> _entryToJson(RemoteFileEntry entry) => {
  'path': entry.path,
  'name': entry.name,
  'type': entry.type.name,
  if (entry.size != null) 'size': entry.size,
  if (entry.uid != null) 'uid': entry.uid,
  if (entry.gid != null) 'gid': entry.gid,
  if (entry.accessedAt != null)
    'accessedAt': entry.accessedAt!.millisecondsSinceEpoch,
  if (entry.modifiedAt != null)
    'modifiedAt': entry.modifiedAt!.millisecondsSinceEpoch,
  if (entry.contentSha256 != null) 'contentSha256': entry.contentSha256,
  if (entry.mode != null) 'mode': entry.mode,
};

RemoteFileEntry _entryFromJson(Object? json) {
  if (json is! Map) throw const FormatException('Invalid session entry');
  final path = json['path'];
  final name = json['name'];
  final type = json['type'];
  if (path is! String || name is! String) {
    throw const FormatException('Invalid session entry');
  }
  RemoteFileType? kind;
  for (final value in RemoteFileType.values) {
    if (value.name == type) kind = value;
  }
  if (kind == null) throw const FormatException('Invalid session entry');
  int? intField(String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! int) throw const FormatException('Invalid session entry');
    return value;
  }

  final sha = json['contentSha256'];
  if (sha != null && sha is! String) {
    throw const FormatException('Invalid session entry');
  }
  final accessedMs = intField('accessedAt');
  final modifiedMs = intField('modifiedAt');
  return RemoteFileEntry(
    path: path,
    name: name,
    type: kind,
    size: intField('size'),
    uid: intField('uid'),
    gid: intField('gid'),
    accessedAt: accessedMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(accessedMs),
    modifiedAt: modifiedMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(modifiedMs),
    contentSha256: sha as String?,
    mode: intField('mode'),
  );
}
