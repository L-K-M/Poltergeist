import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/application_error_reporter.dart';
import '../../services/connection_status_controller.dart';
import '../../services/local_volumes.dart';
import '../../services/pane_drop.dart';
import '../../services/pane_location.dart';
import '../../services/pane_tabs_controller.dart';
import '../../services/quick_connect_address.dart';
import '../../services/sidebar_controller.dart';
import '../../services/sidebar_probe_owner.dart';
import '../../services/workspace_controller.dart';
import '../../theme/app_theme.dart';
import '../panes/pane_drop_area.dart' show paneDropModifiers;
import '../panes/pane_format.dart' show formatPaneSize;
import '../save_to_servers.dart';
import '../server_appearance.dart';
import '../server_filter.dart' show serverSearchHaystack;
import '../server_state_indicator.dart';
import 'sidebar_facts.dart';
import 'sidebar_kit.dart';

// The shell's one sidebar import carries the command and the host volume
// source it wires, so the rail's composition stays a single seam there.
export '../../services/local_volumes.dart' show SystemLocalVolumes;
export 'sidebar_commands.dart'
    show buildSidebarFilterCommand, kViewFilterSidebarCommandId;

part 'sidebar_devices_section.dart';
part 'sidebar_dialogs.dart';
part 'sidebar_drop_zone.dart';
part 'sidebar_favorites_section.dart';
part 'sidebar_home.dart';
part 'sidebar_servers_section.dart';

/// How a row's activation resolves against the panes (02 §4): [plain]
/// follows the preferred-pane rules, [newTab] grows a tab in the pane a
/// plain click would have used, and [oppositePane] flips to the other
/// side — the explicit modifier always wins over `preferredPane`.
enum SidebarOpenAction { plain, newTab, oppositePane }

/// Where the sidebar renders (D32 §9): [rail] is the desktop column (and
/// its drawer mount) with the 30 px bottom bar; [home] is the compact
/// posture's full-screen Home — the same sections and rows at touch
/// size, an always-shown search bar, the "+" menu as a floating action
/// button, and the sync status as the list's footer (the host's app bar
/// carries Settings).
enum SidebarPresentation { rail, home }

/// The bookmark-backup facts the bottom bar's sync chip reads (10 §5).
/// A value the shell composes from the service at read time, so the chip
/// never shows a status older than the service's last notification.
@immutable
final class SidebarSyncStatus {
  const SidebarSyncStatus({
    required this.enrolled,
    this.syncing = false,
    this.lastSyncAt,
    this.error,
  });

  final bool enrolled;
  final bool syncing;
  final DateTime? lastSyncAt;
  final String? error;
}

/// The SERVERS filter threshold (10 §5): below eight servers the field is
/// chrome; it still shows while a query is live or after ⌥⌘F.
const _filterServerThreshold = 8;

/// The D32 sidebar (10 §5): DEVICES, FAVORITES, and SERVERS over the
/// shared kit, a filter field that spans all three, and the bottom bar.
/// Every store mutation routes through [controller]; the shell owns pane
/// resolution and every verb that reaches past the rail.
class SidebarView extends StatefulWidget {
  const SidebarView({
    required this.controller,
    required this.onOpenFavorite,
    this.connections,
    this.probes,
    this.onDisconnect,
    this.onReviewBlocked,
    this.onUpdateWorkspace,
    this.onLocalEdits,
    this.onImportSshConfig,
    this.catalog,
    this.catalogListenable,
    this.syncStatus,
    this.onSyncNow,
    this.onOpenSyncSettings,
    this.onOpenCatalogServer,
    this.onAddCatalogServer,
    this.onEditCatalogServer,
    this.onDuplicateCatalogServer,
    this.onDeleteCatalogServer,
    this.workspace,
    this.volumes,
    this.onQuickConnect,
    this.onOpenSettings,
    this.dropDelegate,
    this.clock = DateTime.now,
    this.presentation = SidebarPresentation.rail,
    super.key,
  });

  /// The bookmark sections, collapse state, filter query, and the
  /// store-routed mutations.
  final SidebarController controller;

  /// Live connection truth for saved servers' dots (02 §4: live truth
  /// outranks probes). Null leaves the dots to the probes.
  final ConnectionStatusController? connections;

  /// The reachability owner behind the probe dots.
  final SidebarProbeOwner? probes;

  /// Opens a bookmark per the resolved action — favorites, saved servers,
  /// device rows (as transient local-folder bookmarks), and Quick Connect
  /// sessions all ride it. Null renders every such row inert (no
  /// workspace exists to bind panes into), never a silent dead tap.
  final void Function(Bookmark bookmark, SidebarOpenAction action)?
  onOpenFavorite;

  /// Drops the pool reference for a server row (Disconnect, and the hover
  /// glyph on a connected row).
  final void Function(ConnectionServer server)? onDisconnect;

  /// Leads a blocked row to the changed-key review (D18).
  final void Function(ConnectionServer server)? onReviewBlocked;

  /// A workspace favorite's "Update Workspace" (02 §3); null hides it.
  final void Function(Bookmark bookmark)? onUpdateWorkspace;

  /// A saved server's `Local Edits…` (06 §3.7); null hides it.
  final void Function(Bookmark bookmark)? onLocalEdits;

  /// D22's adoption affordance: the ssh_config import. Offered in the
  /// empty SERVERS state and the + menu; null hides both.
  final VoidCallback? onImportSshConfig;

  /// The shared-mode Séance server catalog (04 §4.2), merged into SERVERS.
  /// Null in separate mode.
  final SeanceServerCatalog? catalog;

  /// Repaints the rail when the backup service lands a round (the catalog
  /// and the sync status both change in place).
  final Listenable? catalogListenable;

  /// Read at build time for the sync chip; null hides the chip (no backup
  /// service is wired).
  final SidebarSyncStatus Function()? syncStatus;

  /// One sync round now — the chip's click while enrolled.
  final VoidCallback? onSyncNow;

  /// The chip's click while Sync is off: the backup settings.
  final VoidCallback? onOpenSyncSettings;

  /// Opens a catalog server in the resolved pane.
  final void Function(ServerConfig server, SidebarOpenAction action)?
  onOpenCatalogServer;

  /// 04 §4.2's editor verbs. [onAddCatalogServer] is "New Server…"; each
  /// null hides its verb.
  final VoidCallback? onAddCatalogServer;
  final void Function(ServerConfig server)? onEditCatalogServer;
  final void Function(ServerConfig server)? onDuplicateCatalogServer;
  final void Function(ServerConfig server)? onDeleteCatalogServer;

  /// The panes: the active location marks the selection pill and feeds
  /// "Add Current Folder to Favorites"; live Quick Connect sessions and
  /// catalog bindings are read from the tabs.
  final WorkspaceController? workspace;

  /// The DEVICES source; null renders no DEVICES section.
  final LocalVolumeSource? volumes;

  /// "Quick Connect…" (the registered `connect.quickConnect`).
  final VoidCallback? onQuickConnect;

  /// The gear (the registered `app.settings`).
  final VoidCallback? onOpenSettings;

  /// Drops of pane rows onto a local row copy or move there through the
  /// queue (02 §5.1's verbs); null leaves those rows refusing file drops.
  final PaneDropDelegate? dropDelegate;

  /// The sync chip's "2 min ago" reference; injectable for tests.
  final DateTime Function() clock;

  /// The desktop rail or the compact Home (D32 §9).
  final SidebarPresentation presentation;

  @override
  State<SidebarView> createState() => _SidebarViewState();
}

class _SidebarViewState extends State<SidebarView> {
  List<LocalVolume> _volumes = const [];
  List<String> _standardFolders = const [];

  /// Whether a volume listing has landed — DEVICES' "This device"
  /// fallback waits for it, so a desktop rail never flashes the fallback
  /// row before its real volumes arrive.
  bool _volumesLoaded = false;
  StreamSubscription<void>? _volumeChanges;
  int _volumeGeneration = 0;
  SidebarPaneFacts _facts = SidebarPaneFacts.empty;
  Listenable? _paneListenable;
  AppLifecycleListener? _lifecycle;
  Timer? _syncAgeTicker;
  AppLocalizations? _stringsFor;
  SidebarKitStrings? _kitStrings;
  final _filterFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _bindVolumes();
    _bindWorkspace();
    // Free space and mounts drift while the app is away; a return is the
    // cheap moment to re-read them.
    _lifecycle = AppLifecycleListener(onResume: _reloadVolumes);
  }

  @override
  void didUpdateWidget(SidebarView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.volumes, widget.volumes)) _bindVolumes();
    if (!identical(oldWidget.workspace, widget.workspace)) _bindWorkspace();
  }

  @override
  void dispose() {
    _volumeGeneration++;
    unawaited(_volumeChanges?.cancel());
    _paneListenable?.removeListener(_onPanesChanged);
    _lifecycle?.dispose();
    _syncAgeTicker?.cancel();
    _filterFocus.dispose();
    super.dispose();
  }

  void _bindVolumes() {
    unawaited(_volumeChanges?.cancel());
    _volumeChanges = null;
    final source = widget.volumes;
    if (source == null) {
      _volumeGeneration++;
      _volumes = const [];
      _standardFolders = const [];
      return;
    }
    _volumeChanges = source.changes.listen((_) => _reloadVolumes());
    _reloadVolumes();
  }

  void _reloadVolumes() {
    final source = widget.volumes;
    if (source == null) return;
    final generation = ++_volumeGeneration;
    unawaited(() async {
      try {
        final volumes = await source.list();
        final standard = await source.standardFolders();
        if (!mounted || generation != _volumeGeneration) return;
        setState(() {
          _volumes = List.unmodifiable(volumes);
          _standardFolders = List.unmodifiable(standard);
          _volumesLoaded = true;
        });
      } on Object catch (error, stackTrace) {
        ApplicationErrorReporter().report(error, stackTrace);
      }
    }());
  }

  void _bindWorkspace() {
    _paneListenable?.removeListener(_onPanesChanged);
    final workspace = widget.workspace;
    _paneListenable = workspace == null
        ? null
        : Listenable.merge([workspace, workspace.left, workspace.right]);
    _paneListenable?.addListener(_onPanesChanged);
    _facts = workspace == null
        ? SidebarPaneFacts.empty
        : sidebarPaneFactsOf(workspace);
  }

  /// Strips forward every tab notification (a listing's selection too);
  /// only a change in what the rail shows repaints it.
  void _onPanesChanged() {
    final workspace = widget.workspace;
    if (workspace == null || !mounted) return;
    final next = sidebarPaneFactsOf(workspace);
    if (next == _facts) return;
    setState(() => _facts = next);
  }

  SidebarKitStrings _stringsOf(AppLocalizations l10n) {
    if (identical(_stringsFor, l10n) && _kitStrings != null) {
      return _kitStrings!;
    }
    _stringsFor = l10n;
    return _kitStrings = SidebarKitStrings(
      sectionSemantics: (title, count) =>
          l10n.sidebarSectionSemantics(title, l10n.paneItemCount(count)),
      showSection: l10n.sidebarShowSection,
      hideSection: l10n.sidebarHideSection,
      filterHint: l10n.sidebarFilterHint,
      filterClear: l10n.sidebarCatalogFilterClear,
      addMenu: l10n.sidebarAddMenu,
      settings: l10n.sidebarSettings,
      rowMenu: l10n.sidebarRowMenu,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final view = widget;
    return SidebarKitScope(
      strings: _stringsOf(l10n),
      child: ListenableBuilder(
        listenable: Listenable.merge([
          view.controller,
          ?view.connections,
          ?view.probes,
          ?view.catalogListenable,
        ]),
        builder: (context, _) => _buildRail(context, l10n),
      ),
    );
  }

  Widget _buildRail(BuildContext context, AppLocalizations l10n) {
    final chrome = PoltergeistChrome.of(context);
    final data = _SidebarData(
      state: this,
      context: context,
      l10n: l10n,
      volumes: _volumes,
      standardFolders: _standardFolders,
      facts: _facts,
    );

    final children = <Widget>[
      ..._devicesSection(data),
      ..._favoritesSection(data),
      ..._serversSection(data),
    ];
    if (data.filtering && data.matched == 0) {
      children.add(
        _SidebarHint(
          key: const ValueKey('sidebar.noMatches'),
          text: l10n.sidebarNoMatches,
        ),
      );
    }

    final controller = widget.controller;
    if (widget.presentation == SidebarPresentation.home) {
      return _buildHome(data, children);
    }
    final showFilter =
        data.serverCount >= _filterServerThreshold ||
        controller.filterQuery.isNotEmpty ||
        controller.filterOpen;
    // `view.filterSidebar` asked for focus: take it once, after the frame
    // that mounts the field (it may be mounting right now).
    if (controller.takeFilterFocus()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _filterFocus.requestFocus();
      });
    }

    return ColoredBox(
      color: chrome.sidebarBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showFilter)
            SidebarFilterField(
              key: const ValueKey('sidebar.filter'),
              fieldKey: const ValueKey('sidebar.filter.field'),
              query: controller.filterQuery,
              focusNode: _filterFocus,
              onChanged: controller.setFilterQuery,
              onDismiss: controller.dismissFilter,
              onSubmitted: data.firstMatch,
              countText: data.filtering
                  ? l10n.sidebarCatalogFilterCount(data.matched, data.total)
                  : null,
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              children: children,
            ),
          ),
          SidebarBottomBar(
            key: const ValueKey('sidebar.bottomBar'),
            addKey: const ValueKey('sidebar.add'),
            settingsKey: const ValueKey('sidebar.settings'),
            addEntries: () => _addMenuEntries(data),
            sync: _syncChip(l10n),
            onSettings: widget.onOpenSettings,
          ),
        ],
      ),
    );
  }

  /// The bottom bar's "+" (10 §5): creation verbs, each hidden when its
  /// seam is absent and disabled while it has nothing to act on. [icons]
  /// dresses the touch sheet's rows (Home's FAB); the desktop menu stays
  /// text-only.
  List<SidebarMenuEntry> _addMenuEntries(
    _SidebarData data, {
    bool icons = false,
  }) {
    final l10n = data.l10n;
    final view = widget;
    return [
      if (view.onAddCatalogServer != null)
        SidebarMenuAction(
          key: const ValueKey('sidebar.add.newServer'),
          label: l10n.sidebarAddNewServer,
          icon: icons ? Icons.dns_outlined : null,
          onSelected: view.onAddCatalogServer,
        ),
      if (view.onQuickConnect != null)
        SidebarMenuAction(
          key: const ValueKey('sidebar.add.quickConnect'),
          label: l10n.sidebarAddQuickConnect,
          icon: icons ? Icons.power_outlined : null,
          onSelected: view.onQuickConnect,
        ),
      SidebarMenuAction(
        key: const ValueKey('sidebar.add.currentFolder'),
        label: l10n.sidebarAddCurrentFolder,
        icon: icons ? Icons.star_outline : null,
        onSelected: data.canAddCurrentFolder
            ? () => unawaited(_addCurrentFolder(data))
            : null,
      ),
      SidebarMenuAction(
        key: const ValueKey('sidebar.add.newGroup'),
        label: l10n.sidebarNewGroup,
        icon: icons ? Icons.playlist_add : null,
        onSelected: () => unawaited(_newPendingGroup(context, widget)),
      ),
      if (view.onImportSshConfig != null) ...[
        const SidebarMenuDivider(),
        SidebarMenuAction(
          key: const ValueKey('sidebar.add.importSshConfig'),
          label: l10n.sidebarImportSshConfig,
          icon: icons ? Icons.download_outlined : null,
          onSelected: view.onImportSshConfig,
        ),
      ],
    ];
  }

  /// "Add Current Folder to Favorites": a local pane's folder becomes a
  /// favorite; a remote pane's becomes a saved server location (remote
  /// bookmarks live under SERVERS).
  Future<void> _addCurrentFolder(_SidebarData data) async {
    final location = _facts.activeLocation;
    if (location == null) return;
    final l10n = data.l10n;
    try {
      switch (location) {
        case LocalPaneLocation(:final path):
          final added = await widget.controller.addLocalFolders([
            path,
          ], labelOf: _folderLabel);
          if (added.isEmpty && mounted) {
            _showSidebarNotice(
              context,
              l10n.sidebarAlreadyFavorite(_folderLabel(path)),
            );
          }
        case RemotePaneLocation(:final path):
          final live = _facts.activeRemote;
          if (live == null) return;
          await widget.controller.saveRemoteLocation(
            live: live,
            path: path,
            label: path == '/' ? live.label : p.posix.basename(path),
          );
      }
    } on Object catch (error, stackTrace) {
      ApplicationErrorReporter().report(error, stackTrace);
      if (mounted) _showSidebarError(context, l10n);
    }
  }

  /// The sync chip (10 §5), or null without a backup service.
  SidebarSyncChipData? _syncChip(AppLocalizations l10n) {
    final read = widget.syncStatus;
    if (read == null) {
      _syncAgeTicker?.cancel();
      _syncAgeTicker = null;
      return null;
    }
    final status = read();
    final chip = _syncChipFor(status, l10n);
    // The age label ("2 min") goes stale between rounds; a slow ticker
    // repaints it while one is shown, and stops when none is.
    final ageShown =
        status.enrolled &&
        !status.syncing &&
        status.error == null &&
        status.lastSyncAt != null;
    if (ageShown && _syncAgeTicker == null) {
      _syncAgeTicker = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else if (!ageShown) {
      _syncAgeTicker?.cancel();
      _syncAgeTicker = null;
    }
    return chip;
  }

  SidebarSyncChipData _syncChipFor(
    SidebarSyncStatus status,
    AppLocalizations l10n,
  ) {
    const key = ValueKey('sidebar.syncChip');
    if (!status.enrolled) {
      return SidebarSyncChipData(
        key: key,
        label: l10n.sidebarSyncOff,
        tone: SidebarSyncTone.muted,
        tooltip: l10n.sidebarSyncOffTooltip,
        onPressed: widget.onOpenSyncSettings,
      );
    }
    if (status.syncing) {
      return SidebarSyncChipData(
        key: key,
        label: l10n.sidebarCatalogSyncing,
        tone: SidebarSyncTone.busy,
      );
    }
    if (status.error case final error?) {
      return SidebarSyncChipData(
        key: key,
        label: l10n.sidebarSyncFailedChip,
        tone: SidebarSyncTone.error,
        tooltip: l10n.sidebarCatalogSyncFailed(error),
        onPressed: widget.onSyncNow,
      );
    }
    final last = status.lastSyncAt;
    return SidebarSyncChipData(
      key: key,
      label: last == null
          ? l10n.sidebarSyncNever
          : _syncedAgo(l10n, widget.clock().difference(last)),
      tone: SidebarSyncTone.normal,
      tooltip: l10n.sidebarCatalogSyncNow,
      onPressed: widget.onSyncNow,
    );
  }
}

String _syncedAgo(AppLocalizations l10n, Duration age) {
  if (age.inMinutes < 1) return l10n.sidebarSyncedJustNow;
  if (age.inHours < 1) return l10n.sidebarSyncedMinutes(age.inMinutes);
  if (age.inDays < 1) return l10n.sidebarSyncedHours(age.inHours);
  return l10n.sidebarSyncedDays(age.inDays);
}

/// A folder's row label: its last path component, the whole path for a
/// root (`/`, `C:\`).
String _folderLabel(String path) {
  final context = path.contains(r'\') ? p.windows : p.posix;
  final name = context.basename(path);
  return name.isEmpty ? path : name;
}

/// Everything one rail build derives once and every section reads: the
/// resolved selection, the filter, and the counts the field reports.
final class _SidebarData {
  _SidebarData({
    required this.state,
    required this.context,
    required this.l10n,
    required this.volumes,
    required this.standardFolders,
    required this.facts,
  }) : query = state.widget.controller.filterQuery.trim() {
    selectionKey = _resolveSelection();
  }

  final _SidebarViewState state;
  final BuildContext context;
  final AppLocalizations l10n;
  final List<LocalVolume> volumes;
  final List<String> standardFolders;
  final SidebarPaneFacts facts;
  final String query;
  late final String? selectionKey;

  SidebarView get view => state.widget;
  SidebarController get controller => view.controller;
  bool get filtering => query.isNotEmpty;

  /// Rows the filter considered and kept, for "3 of 12" — every section
  /// counts through [countRow].
  int total = 0;
  int matched = 0;

  /// SERVERS' size, for the filter's appearance threshold.
  int serverCount = 0;

  VoidCallback? _firstMatch;

  /// Enter in the filter field opens the first visible match, in rail
  /// order — Séance's affordance, extended to every section.
  void firstMatch() => _firstMatch?.call();

  /// Counts one row against the filter; true when it shows.
  bool countRow(String haystack, {VoidCallback? open}) {
    total++;
    final shows = sidebarQueryMatches(haystack, query);
    if (shows) {
      matched++;
      if (filtering && open != null) _firstMatch ??= open;
    }
    return shows;
  }

  /// A section or group is folded unless a live query is looking inside
  /// it — a filter reporting "3 of 12" while showing one row reads as
  /// broken (Séance's rule).
  bool collapsed(String key) => !filtering && controller.isCollapsed(key);

  bool get canAddCurrentFolder => switch (facts.activeLocation) {
    null => false,
    LocalPaneLocation() => true,
    RemotePaneLocation() => facts.activeRemote != null,
  };

  List<Bookmark> get favorites => [
    for (final section in controller.sections)
      for (final bookmark in section.bookmarks)
        if (bookmark.kind != BookmarkKind.remotePath) bookmark,
  ];

  String? _resolveSelection() {
    switch (facts.activeLocation) {
      case null:
        return null;
      case RemotePaneLocation(:final serverId):
        return _serverSelectionKey(serverId);
      case LocalPaneLocation(:final path):
        final here = sidebarComparablePath(path);
        for (final volume in volumes) {
          if (sidebarComparablePath(volume.path) == here) {
            return _deviceSelectionKey(volume.path);
          }
        }
        for (final bookmark in favorites) {
          final local = bookmark.localPath;
          if (bookmark.kind == BookmarkKind.localFolder &&
              local != null &&
              sidebarComparablePath(local) == here) {
            return _favoriteSelectionKey(bookmark.id);
          }
        }
        return null;
    }
  }
}

String _deviceSelectionKey(String path) => 'device:$path';
String _favoriteSelectionKey(String id) => 'fav:$id';
String _serverSelectionKey(String serverId) => 'server:$serverId';

/// The pointer's modifier vocabulary (02 §4): ⌥/Alt opens in the other
/// pane, ⌘/Ctrl in a new tab. A keyboard activation is always plain.
SidebarOpenAction _openActionFor(SidebarActivation how) {
  if (how == SidebarActivation.keyboard) return SidebarOpenAction.plain;
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isAltPressed) return SidebarOpenAction.oppositePane;
  if (keyboard.isControlPressed || keyboard.isMetaPressed) {
    return SidebarOpenAction.newTab;
  }
  return SidebarOpenAction.plain;
}

/// The three open verbs every openable row's menu starts with.
List<SidebarMenuEntry> _openVerbs(
  AppLocalizations l10n,
  void Function(SidebarOpenAction action)? open, {
  String keyPrefix = 'sidebar.menu',
  bool modifiers = true,
}) => [
  SidebarMenuAction(
    key: ValueKey('$keyPrefix.open'),
    label: l10n.sidebarOpen,
    onSelected: open == null ? null : () => open(SidebarOpenAction.plain),
  ),
  if (modifiers) ...[
    SidebarMenuAction(
      key: ValueKey('$keyPrefix.openNewTab'),
      label: l10n.sidebarOpenInNewTab,
      onSelected: open == null ? null : () => open(SidebarOpenAction.newTab),
    ),
    SidebarMenuAction(
      key: ValueKey('$keyPrefix.openOtherPane'),
      label: l10n.sidebarOpenInOtherPane,
      onSelected: open == null
          ? null
          : () => open(SidebarOpenAction.oppositePane),
    ),
  ],
];

/// A server row's one dot and the words for it (10 §5): connected is a
/// solid green disc, connecting or reconnecting amber, a failure or a
/// host-key block red, a server that answers the probe but holds no
/// connection a hollow green ring, and an unknown or idle server paints
/// nothing. An unreachable probe stays red. [appearance] carries the
/// state's words for the row's semantics and tooltip, dot or not.
@visibleForTesting
({ServerIndicatorAppearance appearance, SidebarStatusDot? dot})
sidebarServerIndicator(
  AppLocalizations l10n,
  PoltergeistChrome chrome,
  ColorScheme scheme, {
  ServerStatus? status,
  ProbeStatus? probe,
}) {
  final appearance = railIndicatorOf(l10n, status: status, probe: probe);
  final dot = switch (appearance.glyph) {
    ServerIndicatorGlyph.connected => SidebarStatusDot(chrome.statusConnected),
    ServerIndicatorGlyph.pending => SidebarStatusDot(chrome.statusConnecting),
    ServerIndicatorGlyph.failed ||
    ServerIndicatorGlyph.blocked => SidebarStatusDot(scheme.error),
    ServerIndicatorGlyph.probe => switch (probe) {
      ProbeStatus.online => SidebarStatusDot(
        chrome.statusConnected,
        style: SidebarDotStyle.ring,
      ),
      ProbeStatus.offline => SidebarStatusDot(scheme.error),
      ProbeStatus.unknown || null => null,
    },
    ServerIndicatorGlyph.none || ServerIndicatorGlyph.idle => null,
  };
  return (appearance: appearance, dot: dot);
}

/// [sidebarServerIndicator] with the row's theme.
({ServerIndicatorAppearance appearance, SidebarStatusDot? dot})
_serverIndicator(
  BuildContext context,
  AppLocalizations l10n, {
  ServerStatus? status,
  ProbeStatus? probe,
}) => sidebarServerIndicator(
  l10n,
  PoltergeistChrome.of(context),
  Theme.of(context).colorScheme,
  status: status,
  probe: probe,
);

/// A section's secondary line: loading, empty, or no-match copy, set in
/// the rail's caption style and inset like a row title.
class _SidebarHint extends StatelessWidget {
  const _SidebarHint({required this.text, this.action, super.key});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final chrome = PoltergeistChrome.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 4, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: chrome.secondaryText),
          ),
          if (action != null) ...[const SizedBox(height: 4), action!],
        ],
      ),
    );
  }
}

/// Marks a row's first mount for the probe owner (02 §4: a server's first
/// probe waits until its row is visible).
class _ProbeVisibility extends StatefulWidget {
  const _ProbeVisibility({
    required this.probes,
    required this.id,
    required this.child,
  });

  final SidebarProbeOwner? probes;
  final String id;
  final Widget child;

  @override
  State<_ProbeVisibility> createState() => _ProbeVisibilityState();
}

class _ProbeVisibilityState extends State<_ProbeVisibility> {
  @override
  void initState() {
    super.initState();
    widget.probes?.noteVisible(widget.id);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
