import 'session_state.dart';
import 'view_preferences.dart';

/// 02 §3's workspace document — the saved snapshot of both panes' tab
/// sets, active tabs, and per-tab view state that `workspace.save`
/// writes and `workspace.open.*` replays.
///
/// Storage boundary (the task-58 slice): the plan's workspace is a
/// favorite KIND (02 §4, 04 §2.1's `BookmarkKind.workspace`), but the
/// favorites store is M5 work. Until then the workspace list is its own
/// versioned document inside `settings.json`, behind
/// [WorkspaceListStore] — clearly separated from the auto-session
/// document (`session.state`) that the safe-point writer keeps. M5
/// migrates this document into the favorites store; the schema here is
/// the record that migration reads.
///
/// Per-tab records deliberately reuse [SessionTabState]'s flat field
/// set (location, bookmark, cached listing) and add the transient
/// lenses — filter, hidden override, view mode — which the session
/// document excludes but a workspace must keep (02 §3: "per-tab view
/// state"). Decode posture matches the sibling versioned stores:
/// unknown fields are ignored, malformed present fields fail the whole
/// document, and an unknown schema version fails closed.
final class WorkspaceTabState {
  const WorkspaceTabState({
    required this.session,
    required this.filterQuery,
    required this.filterFieldOpen,
    required this.showHidden,
    required this.viewMode,
  });

  /// The tab's location, remote binding, and cached listing — the same
  /// shape the session document persists, so a workspace tab replays
  /// through the identical markRestored path (stale rows behind a
  /// Reconnect bar for remote tabs, live rebind for local ones).
  final SessionTabState session;

  /// The transient per-tab lenses the session document never persists:
  /// a workspace restores the view the user saved, not a fresh default.
  final String filterQuery;
  final bool filterFieldOpen;
  final bool showHidden;
  final PaneViewMode viewMode;

  Map<String, Object?> toJson() => {
    // Flat record: the session fields and the lenses share one object,
    // so SessionTabState.fromJson reads its half and ignores the rest.
    ...session.toJson(),
    'filterQuery': filterQuery,
    'filterFieldOpen': filterFieldOpen,
    'hiddenFiles': showHidden,
    'viewMode': viewMode.name,
  };

  factory WorkspaceTabState.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Invalid workspace tab');
    final session = SessionTabState.fromJson(json);
    final filterQuery = json['filterQuery'];
    final filterFieldOpen = json['filterFieldOpen'];
    final showHidden = json['hiddenFiles'];
    final viewMode = json['viewMode'];
    if (filterQuery is! String) {
      throw const FormatException('Invalid workspace tab filter');
    }
    if (filterFieldOpen is! bool || showHidden is! bool) {
      throw const FormatException('Invalid workspace tab flags');
    }
    return WorkspaceTabState(
      session: session,
      filterQuery: filterQuery,
      filterFieldOpen: filterFieldOpen,
      showHidden: showHidden,
      viewMode: switch (viewMode) {
        'list' => PaneViewMode.list,
        'details' => PaneViewMode.details,
        _ => throw const FormatException('Invalid workspace tab view mode'),
      },
    );
  }
}

/// One pane's saved strip: the ordered tabs and the active index (-1
/// while the pane sat on the launcher). Unlike the session document no
/// tab-id counter persists — restored tabs mint fresh ids from the live
/// strip's own counter, which is already monotonic per session.
final class WorkspacePaneState {
  const WorkspacePaneState({
    required this.paneId,
    required this.activeTab,
    required this.tabs,
  });

  final String paneId;
  final int activeTab;
  final List<WorkspaceTabState> tabs;

  Map<String, Object?> toJson() => {
    'paneId': paneId,
    'activeTab': activeTab,
    'tabs': [for (final tab in tabs) tab.toJson()],
  };

  factory WorkspacePaneState.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Invalid workspace pane');
    final paneId = json['paneId'];
    final activeTab = json['activeTab'];
    final tabs = json['tabs'];
    if (paneId is! String || paneId.isEmpty) {
      throw const FormatException('Invalid workspace pane id');
    }
    if (activeTab is! int) {
      throw const FormatException('Invalid workspace pane active tab');
    }
    if (tabs is! List) {
      throw const FormatException('Invalid workspace pane tabs');
    }
    final decodedTabs = List<WorkspaceTabState>.unmodifiable([
      for (final tab in tabs) WorkspaceTabState.fromJson(tab),
    ]);
    // An active index outside [-1, tabs.length) is a corrupt document,
    // not a value to clamp into plausibility (the session schema's rule).
    if (activeTab < -1 || activeTab >= decodedTabs.length) {
      throw const FormatException('Invalid workspace pane active tab');
    }
    return WorkspacePaneState(
      paneId: paneId,
      activeTab: activeTab,
      tabs: decodedTabs,
    );
  }
}

/// The arrangement a workspace applies: both panes' strips. Kept to the
/// two-pane document — pane visibility and the active pane are launch
/// session state, not workspace state (02 §3 enumerates tab sets,
/// active tabs, and per-tab view state only).
final class WorkspaceSnapshot {
  const WorkspaceSnapshot({required this.left, required this.right});

  final WorkspacePaneState left;
  final WorkspacePaneState right;

  Map<String, Object?> toJson() => {
    'panes': [left.toJson(), right.toJson()],
  };

  factory WorkspaceSnapshot.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('Invalid workspace snapshot');
    }
    final panes = json['panes'];
    if (panes is! List) {
      throw const FormatException('Invalid workspace panes');
    }
    final decoded = List<WorkspacePaneState>.unmodifiable([
      for (final pane in panes) WorkspacePaneState.fromJson(pane),
    ]);
    // Exactly the two canonical panes — a truncated write, a duplicate,
    // or a foreign pane id is corrupt, not a partial restore to
    // improvise around (the session document's pane-set rule).
    if (decoded.length != 2 ||
        decoded.map((pane) => pane.paneId).toSet().length != 2) {
      throw const FormatException('Invalid workspace panes');
    }
    final left = decoded
        .where((pane) => pane.paneId == sessionLeftPaneId)
        .firstOrNull;
    final right = decoded
        .where((pane) => pane.paneId == sessionRightPaneId)
        .firstOrNull;
    if (left == null || right == null) {
      throw const FormatException('Invalid workspace panes');
    }
    return WorkspaceSnapshot(left: left, right: right);
  }
}

/// One named workspace: the user's label plus the snapshot it replays.
/// [savedAt] records when the snapshot was taken; [lastOpenedAt] tracks
/// the most recent open so the menu's newest-first order survives
/// restarts. Both are records, not ordering keys — the document's list
/// position IS the newest-first order.
final class SavedWorkspace {
  const SavedWorkspace({
    required this.id,
    required this.label,
    required this.savedAt,
    required this.lastOpenedAt,
    required this.snapshot,
  });

  final String id;
  final String label;
  final DateTime savedAt;
  final DateTime? lastOpenedAt;
  final WorkspaceSnapshot snapshot;

  SavedWorkspace copyWith({
    String? label,
    DateTime? savedAt,
    DateTime? Function()? lastOpenedAt,
    WorkspaceSnapshot? snapshot,
  }) {
    return SavedWorkspace(
      id: id,
      label: label ?? this.label,
      savedAt: savedAt ?? this.savedAt,
      lastOpenedAt: lastOpenedAt == null ? this.lastOpenedAt : lastOpenedAt(),
      snapshot: snapshot ?? this.snapshot,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'savedAt': savedAt.millisecondsSinceEpoch,
    if (lastOpenedAt != null)
      'lastOpenedAt': lastOpenedAt!.millisecondsSinceEpoch,
    'snapshot': snapshot.toJson(),
  };

  factory SavedWorkspace.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('Invalid workspace');
    final id = json['id'];
    final label = json['label'];
    final savedAt = json['savedAt'];
    final lastOpenedAt = json['lastOpenedAt'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Invalid workspace id');
    }
    if (label is! String || label.trim().isEmpty) {
      throw const FormatException('Invalid workspace label');
    }
    if (savedAt is! int) {
      throw const FormatException('Invalid workspace timestamp');
    }
    if (lastOpenedAt != null && lastOpenedAt is! int) {
      throw const FormatException('Invalid workspace timestamp');
    }
    return SavedWorkspace(
      id: id,
      label: label,
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAt, isUtc: true),
      lastOpenedAt: lastOpenedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastOpenedAt, isUtc: true),
      snapshot: WorkspaceSnapshot.fromJson(json['snapshot']),
    );
  }
}

/// The root workspace-list document inside `settings.json` — the M3
/// interim home of what becomes a §4 favorite kind at M5. Versioned
/// like the sibling stores; the list order is newest-first (saves and
/// opens move their record to the front), so no timestamp ties can
/// reorder the menu.
final class WorkspaceListDocument {
  const WorkspaceListDocument({required this.workspaces});

  static const schemaVersion = 1;

  final List<SavedWorkspace> workspaces;

  Map<String, Object?> toJson() => {
    'version': schemaVersion,
    'workspaces': [for (final workspace in workspaces) workspace.toJson()],
  };

  factory WorkspaceListDocument.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('Invalid workspace list');
    }
    if (json['version'] is! int || json['version'] != schemaVersion) {
      throw const FormatException('Unsupported workspace list schema');
    }
    final workspaces = json['workspaces'];
    if (workspaces is! List) {
      throw const FormatException('Invalid workspace list entries');
    }
    // Duplicate ids would make menu commands collide — corrupt, not a
    // document to dedupe silently.
    final decoded = List<SavedWorkspace>.unmodifiable([
      for (final entry in workspaces) SavedWorkspace.fromJson(entry),
    ]);
    if (decoded.map((w) => w.id).toSet().length != decoded.length) {
      throw const FormatException('Invalid workspace list entries');
    }
    return WorkspaceListDocument(workspaces: decoded);
  }
}
