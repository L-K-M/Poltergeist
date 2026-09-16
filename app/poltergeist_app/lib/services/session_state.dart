import 'package:poltergeist_core/poltergeist_core.dart';

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
        base['bookmark'] = bookmark!.toJson();
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
            bookmarkJson.cast<String, dynamic>(),
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
    return SessionPaneState(
      paneId: paneId,
      activeTab: activeTab,
      nextTabOrdinal: nextTabOrdinal,
      tabs: List.unmodifiable([
        for (final tab in tabs) SessionTabState.fromJson(tab),
      ]),
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
    required this.panes,
  });

  static const schemaVersion = 1;

  final String activePaneId;
  final bool secondPaneHidden;
  final List<SessionPaneState> panes;

  Map<String, Object?> toJson() => {
    'version': schemaVersion,
    'activePane': activePaneId,
    'secondPaneHidden': secondPaneHidden,
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
    final panes = json['panes'];
    if (activePane is! String) {
      throw const FormatException('Invalid session active pane');
    }
    if (secondPaneHidden is! bool) {
      throw const FormatException('Invalid session pane visibility');
    }
    if (panes is! List) {
      throw const FormatException('Invalid session panes');
    }
    return SessionState(
      activePaneId: activePane,
      secondPaneHidden: secondPaneHidden,
      panes: List.unmodifiable([
        for (final pane in panes) SessionPaneState.fromJson(pane),
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
