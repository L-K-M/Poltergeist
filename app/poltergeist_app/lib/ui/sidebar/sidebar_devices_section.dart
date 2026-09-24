part of 'sidebar_view.dart';

/// DEVICES (10 §5): Home, the root volume, and the mounted volumes, each
/// opening its folder in the active pane through the favorite-open path
/// (a transient local-folder bookmark — nothing is stored). Free space is
/// the trailing text; removable volumes offer Eject on hover.
List<Widget> _devicesSection(_SidebarData data) {
  if (data.view.volumes == null || data.volumes.isEmpty) return const [];
  final l10n = data.l10n;
  final sectionKey = SidebarCollapseKeys.section(SidebarSection.devices);
  final platform = Theme.of(data.context).platform;

  final rows = <Widget>[];
  for (final volume in data.volumes) {
    final bookmark = _deviceBookmark(volume);
    void open(SidebarOpenAction action) =>
        data.view.onOpenFavorite?.call(bookmark, action);
    if (!data.countRow(
      '${volume.name} ${volume.path}',
      open: data.view.onOpenFavorite == null
          ? null
          : () => open(SidebarOpenAction.plain),
    )) {
      continue;
    }
    rows.add(
      _DeviceRow(
        key: ValueKey('sidebar.device.${volume.path}'),
        volume: volume,
        data: data,
        freeSpace: volume.freeBytes == null
            ? null
            : formatPaneSize(volume.freeBytes, platform: platform),
        onOpen: data.view.onOpenFavorite == null ? null : open,
      ),
    );
  }
  if (data.filtering && rows.isEmpty) return const [];

  final collapsed = data.collapsed(sectionKey);
  return [
    SidebarSectionHeader(
      headerKey: ValueKey('sidebar.section.$sectionKey'),
      title: l10n.sidebarDevicesSection,
      count: data.volumes.length,
      collapsed: collapsed,
      onToggle: () => data.controller.toggleCollapsed(sectionKey),
    ),
    if (!collapsed) ...rows,
  ];
}

/// The transient bookmark a device row opens through — never saved; its
/// id namespaces it away from every stored one.
Bookmark _deviceBookmark(LocalVolume volume) => Bookmark(
  id: 'device:${volume.path}',
  kind: BookmarkKind.localFolder,
  label: volume.name,
  localPath: volume.path,
  sortKey: '',
  createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
);

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.volume,
    required this.data,
    required this.freeSpace,
    required this.onOpen,
    super.key,
  });

  final LocalVolume volume;
  final _SidebarData data;
  final String? freeSpace;
  final void Function(SidebarOpenAction action)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = data.l10n;
    final chrome = PoltergeistChrome.of(context);
    final view = data.view;
    final open = onOpen;
    final eject = volume.ejectable
        ? () => unawaited(
            _eject(context, view, volume, l10n, data.state._reloadVolumes),
          )
        : null;

    final semanticLabel = freeSpace == null
        ? volume.name
        : '${volume.name}, ${l10n.sidebarFreeSpaceSemantics(freeSpace!)}';
    Widget row(SidebarDropIndicator indicator) => SidebarRow(
      dropIndicator: indicator,
      mark: Icon(_iconFor(volume.kind), size: 16, color: chrome.secondaryText),
      title: volume.name,
      trailingText: freeSpace,
      tooltip: volume.path,
      semanticLabel: semanticLabel,
      selected: data.selectionKey == _deviceSelectionKey(volume.path),
      onActivate: open == null ? null : (how) => open(_openActionFor(how)),
      hoverAction: eject == null
          ? null
          : SidebarRowAction(
              key: ValueKey('sidebar.device.eject.${volume.path}'),
              icon: Icons.eject,
              tooltip: l10n.sidebarEject,
              onPressed: eject,
            ),
      menuEntries: () => [
        ..._openVerbs(l10n, open),
        const SidebarMenuDivider(),
        SidebarMenuAction(
          key: const ValueKey('sidebar.menu.addToFavorites'),
          label: l10n.sidebarAddToFavorites,
          onSelected: () => unawaited(
            _addFolders(context, view, [volume.path], label: volume.name),
          ),
        ),
        if (eject != null)
          SidebarMenuAction(
            key: const ValueKey('sidebar.menu.eject'),
            label: l10n.sidebarEject,
            onSelected: eject,
          ),
      ],
    );
    // A device takes pane rows dropped on it: copy (or, with the move
    // modifier, move) into its folder.
    return _SidebarDropZone(
      planner: (data, _) =>
          _transferPlan(context, view, data, destinationDir: volume.path),
      builder: row,
    );
  }

  static IconData _iconFor(LocalVolumeKind kind) => switch (kind) {
    LocalVolumeKind.home => Icons.home_outlined,
    LocalVolumeKind.root => Icons.computer_outlined,
    LocalVolumeKind.removable => Icons.usb_outlined,
    LocalVolumeKind.fixed => Icons.storage_outlined,
  };
}

/// Ejects through the source; a refusal says so (a volume in use is the
/// common case), never reads as done.
Future<void> _eject(
  BuildContext context,
  SidebarView view,
  LocalVolume volume,
  AppLocalizations l10n,
  VoidCallback onEjected,
) async {
  final source = view.volumes;
  if (source == null) return;
  var ejected = false;
  try {
    ejected = await source.eject(volume);
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
  }
  if (ejected) {
    // The mount watch usually reports this too; re-reading now keeps a
    // source that cannot watch honest.
    onEjected();
    return;
  }
  if (context.mounted) {
    _showSidebarNotice(context, l10n.sidebarEjectFailed(volume.name));
  }
}
