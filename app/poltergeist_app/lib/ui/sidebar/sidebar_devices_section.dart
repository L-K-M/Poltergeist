part of 'sidebar_view.dart';

/// DEVICES (10 §5): Home, the root volume, and the mounted volumes, each
/// opening its folder in the active pane through the favorite-open path
/// (a transient local-folder bookmark — nothing is stored). Free space is
/// the trailing text; removable volumes offer Eject on hover.
List<Widget> _devicesSection(_SidebarData data) {
  if (data.view.volumes == null) return const [];
  if (data.volumes.isEmpty) return _thisDeviceSection(data);
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

/// DEVICES on a touch platform whose volume source lists nothing by
/// design (Android, iOS: the local pane there is the app's own storage,
/// not a volume the user mounts): one "This device" row onto the local
/// home, so the phone's own files stay one tap from Home. It waits for
/// the listing to land, and never shows on a desktop, whose rail always
/// lists at least the home and root volumes.
List<Widget> _thisDeviceSection(_SidebarData data) {
  final platform = Theme.of(data.context).platform;
  final open = data.view.onOpenFavorite;
  if (!data.state._volumesLoaded ||
      isDesktopPlatform(platform) ||
      open == null) {
    return const [];
  }
  final l10n = data.l10n;
  final label = l10n.sidebarThisDevice;
  final bookmark = _deviceBookmark(
    LocalVolume(path: '~', name: label, kind: LocalVolumeKind.home),
  );
  void openHome(SidebarOpenAction action) => open(bookmark, action);
  if (!data.countRow(label, open: () => openHome(SidebarOpenAction.plain))) {
    return const [];
  }
  final sectionKey = SidebarCollapseKeys.section(SidebarSection.devices);
  final collapsed = data.collapsed(sectionKey);
  final context = data.context;
  final subtitle = l10n.compactHomeThisDeviceSubtitle;
  return [
    SidebarSectionHeader(
      headerKey: ValueKey('sidebar.section.$sectionKey'),
      title: l10n.sidebarDevicesSection,
      count: 1,
      collapsed: collapsed,
      onToggle: () => data.controller.toggleCollapsed(sectionKey),
    ),
    if (!collapsed)
      SidebarRow(
        key: const ValueKey('sidebar.device.thisDevice'),
        mark: data.list
            ? _HomeDisc(
                glyph: thisDeviceGlyph.glyph,
                tint: FamilyPalette.of(context).glyph(thisDeviceGlyph.hue),
              )
            : _placeMark(context, thisDeviceGlyph),
        title: label,
        subtitle: subtitle,
        semanticLabel: data.comfortable
            ? _spokenLabel([label, subtitle])
            : null,
        // No volume or favorite claims a local location here, so any
        // local folder the active pane shows is this device's.
        selected:
            data.selectionKey == null &&
            data.facts.activeLocation is LocalPaneLocation,
        onActivate: (how) => openHome(_openActionFor(how)),
        menuEntries: () => _openVerbs(data.l10n, openHome),
      ),
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
    final view = data.view;
    final open = onOpen;
    final eject = volume.ejectable
        ? () => unawaited(
            _eject(context, view, volume, l10n, data.state._reloadVolumes),
          )
        : null;

    final free = freeSpace;
    final place = volumeGlyph(volume.kind);
    // A comfortable row spells the free space (or, without it, the
    // place) on its second line; a compact one keeps free space trailing
    // and the path in the tooltip.
    final comfortable = data.comfortable;
    final subtitle = free == null
        ? sidebarHomeRelativePath(volume.path, data.localHome)
        : l10n.compactHomeFreeSpace(free);
    final semanticLabel = comfortable
        ? _spokenLabel([
            volume.name,
            free == null ? subtitle : l10n.sidebarFreeSpaceSemantics(free),
          ])
        : free == null
        ? volume.name
        : '${volume.name}, ${l10n.sidebarFreeSpaceSemantics(freeSpace!)}';
    Widget row(SidebarDropIndicator indicator) => SidebarRow(
      dropIndicator: indicator,
      mark: data.list
          ? _HomeDisc(
              glyph: place.glyph,
              tint: FamilyPalette.of(context).glyph(place.hue),
            )
          : _placeMark(context, place),
      title: volume.name,
      subtitle: subtitle,
      trailingText: comfortable ? null : freeSpace,
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
      planner: (data, _) => _transferPlan(
        context,
        view,
        data,
        destinationDir: volume.path,
        copyByDefault: true,
      ),
      builder: row,
    );
  }
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
