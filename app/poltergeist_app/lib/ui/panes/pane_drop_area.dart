import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/pane_controller.dart';
import '../../services/pane_drop.dart';
import '../../services/pane_location.dart';

/// The D14 spring-load delay (02 §5.1): a folder row held under a drag
/// for this long opens in place.
const paneSpringLoadDelay = Duration(seconds: 1);

/// The effective drop modifiers (02 §5.1): macOS maps ⌥→copy and
/// ⌘→move; Windows/Linux map Ctrl→copy and Shift→move. Read live so a
/// key pressed or released mid-drag changes the verb — the avatar's `+`
/// badge and the hover label follow it immediately.
({bool copy, bool move}) paneDropModifiers(BuildContext context) {
  final keyboard = HardwareKeyboard.instance;
  return Theme.of(context).platform == TargetPlatform.macOS
      ? (copy: keyboard.isAltPressed, move: keyboard.isMetaPressed)
      : (copy: keyboard.isControlPressed, move: keyboard.isShiftPressed);
}

/// One pane's drop zone (02 §5.1, D14): the in-app `DragTarget` for
/// pane↔pane row drags plus the `desktop_drop` `DropTarget` for OS
/// drop-in, wrapped around the pane body. Owns the hover affordances —
/// the hovered folder row's highlight (reported to the parent so the
/// row itself paints it), the action overlay, the zone border — and
/// the spring-load timer. Resolution is honest against the virtualized
/// list: the fixed row extent plus the scroll offset map the drop point
/// onto the rendered rows — never an unrendered model index.
class PaneDropArea extends StatefulWidget {
  const PaneDropArea({
    super.key,
    required this.controller,
    required this.delegate,
    required this.scrollController,
    required this.listAreaKey,
    required this.rowExtent,
    required this.onHoverFolderRow,
    required this.supportsOsDrop,
    required this.child,
  });

  /// The destination pane tab's controller — its `location` is the
  /// current-directory target and its listing provides the folder rows.
  final PaneController controller;

  /// The enqueue seam shared by both panes; null (no queue wired)
  /// refuses every drop — rows still render undraggable upstream.
  final PaneDropDelegate? delegate;

  /// The listing's scroll state — hit math rides rendered row extents
  /// plus this offset, so a scrolled viewport maps correctly.
  final ScrollController scrollController;

  /// Keys the `ListView`'s render box: drop positions resolve to
  /// list-local coordinates through it (not the zone's, which includes
  /// no list when the folder is empty).
  final GlobalKey listAreaKey;

  /// The rendered row height (`scaledPaneRowExtent` at this build) —
  /// the fixed extent the virtualized list lays out with, so hit math
  /// is honest about what is on screen.
  final double rowExtent;

  /// Reports the folder row the hover currently targets (null = the
  /// current directory or a refused hover) so the parent can paint the
  /// row highlight — the highlight state lives on the view, not here.
  final ValueChanged<int?> onHoverFolderRow;

  /// Whether the OS drop-in `DropTarget` mounts at all — false on
  /// platforms `desktop_drop` does not serve (mobile).
  final bool supportsOsDrop;

  final Widget child;

  @override
  State<PaneDropArea> createState() => _PaneDropAreaState();
}

class _PaneDropAreaState extends State<PaneDropArea> {
  /// The overlay's action line ("Copy to /srv/www"), non-null only
  /// while an acceptable hover is in progress.
  String? _hoverLabel;

  /// The folder row under the pointer, null for a current-directory
  /// or refused hover.
  int? _hoverRow;

  Timer? _springTimer;
  int? _springRow;

  /// The in-app drag currently hovering this zone and its last global
  /// position — kept so a modifier key pressed or released mid-hover
  /// (no pointer move, so no `onMove`) still re-resolves the verb and
  /// the affordance; the avatar's badge reads it through the payload's
  /// notifier.
  PaneEntryDrag? _activeDrag;
  Offset? _activeHoverGlobal;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _springTimer?.cancel();
    super.dispose();
  }

  /// A modifier flip while a payload hovers — HardwareKeyboard's
  /// pressed set is already updated when handlers run, so the
  /// re-resolution reads the live verb. Never consumes the event.
  bool _onKeyEvent(KeyEvent _) {
    final drag = _activeDrag;
    final global = _activeHoverGlobal;
    if (drag != null && global != null) {
      _updateInAppHover(drag, global);
    }
    return false;
  }

  /// The pane's transfer endpoint — null while unbound (a launcher or a
  /// pane that never got a location).
  FsLocation? get _destinationFs {
    final location = widget.controller.location;
    return location == null ? null : fsLocationForLocation(location);
  }

  /// Maps a global drop position onto a destination: the folder row it
  /// lands on (its path + index for the highlight) or the pane's
  /// current directory (background, file rows, below the last row, and
  /// the empty-folder surface all resolve here). Null while the pane
  /// cannot accept drops (loading, error, unbound, disowned rows).
  ({String dir, int? folderRow})? _resolveDrop(Offset global) {
    final controller = widget.controller;
    if (!controller.verbsEnabled) return null;
    final location = controller.location;
    if (location == null) return null;
    final listObject = widget.listAreaKey.currentContext?.findRenderObject();
    if (listObject is! RenderBox || !listObject.hasSize) {
      // No rendered list — the empty-folder state or a surface without
      // rows: the whole zone is the current directory.
      return (dir: location.path, folderRow: null);
    }
    final local = listObject.globalToLocal(global);
    final scrollOffset = widget.scrollController.hasClients
        ? widget.scrollController.offset
        : 0.0;
    final index = ((local.dy + scrollOffset) / widget.rowExtent).floor();
    final entries = controller.entries;
    if (index >= 0 &&
        index < entries.length &&
        entries[index].type == RemoteFileType.directory) {
      return (dir: entries[index].path, folderRow: index);
    }
    return (dir: location.path, folderRow: null);
  }

  /// The overlay's verb line (02 §5.1's "Copy to /var/www /
  /// Upload to /var/www" — direction-aware for the copy verb).
  String _labelFor(TransferOperation operation, String dir, FsLocation source) {
    final l10n = AppLocalizations.of(context);
    if (operation == TransferOperation.move) {
      return l10n.dropMoveTo(dir);
    }
    return switch ((source, _destinationFs)) {
      (LocalFsLocation(), ServerFsLocation()) => l10n.dropUploadTo(dir),
      (ServerFsLocation(), LocalFsLocation()) => l10n.dropDownloadTo(dir),
      _ => l10n.dropCopyTo(dir),
    };
  }

  /// Recomputes the in-app hover: destination, verb (live modifiers),
  /// and the §5.1 containment rules. Returns whether the drop would be
  /// accepted. Called from `onWillAcceptWithDetails` and every `onMove`
  /// so a mid-hover modifier flip (⌥/Ctrl turning a refused move into a
  /// legal copy) re-arms the affordance — the accept path re-checks
  /// regardless, so a stale "allowed" can never slip a refused drop in.
  bool _updateInAppHover(PaneEntryDrag drag, Offset global) {
    _activeDrag = drag;
    _activeHoverGlobal = global;
    final delegate = widget.delegate;
    final resolved = _resolveDrop(global);
    final destination = _destinationFs;
    String? label;
    int? row;
    var allowed = false;
    if (resolved != null && delegate != null && destination != null) {
      final modifiers = paneDropModifiers(context);
      final verb = paneDropVerb(
        source: drag.source,
        sourceRoots: drag.rootPaths,
        destination: destination,
        destinationDir: resolved.dir,
        copyModifier: modifiers.copy,
        moveModifier: modifiers.move,
      );
      allowed = paneDropAllowed(
        source: drag.source,
        sourceRoots: drag.rootPaths,
        destination: destination,
        destinationDir: resolved.dir,
        operation: verb,
      );
      if (allowed) {
        label = _labelFor(verb, resolved.dir, drag.source);
        row = resolved.folderRow;
      }
      drag.verb.value = allowed ? verb : null;
    } else {
      // A mid-flight leave (drag outside, pane gone busy) clears the
      // badge without a stale verb.
      drag.verb.value = null;
    }
    _setHover(label: label, folderRow: row);
    return allowed;
  }

  void _clearHover() {
    _activeDrag = null;
    _activeHoverGlobal = null;
    _setHover(label: null, folderRow: null);
  }

  void _setHover({String? label, int? folderRow}) {
    // The spring-load timer keys on the hovered row — moving off the
    // row (or onto a refused one) disarms it; hovering a new folder
    // row re-arms.
    if (folderRow != _springRow) {
      _springTimer?.cancel();
      _springTimer = null;
      _springRow = folderRow;
      if (folderRow != null) {
        _springTimer = Timer(paneSpringLoadDelay, _springLoad);
      }
    }
    if (folderRow != _hoverRow) {
      // The highlight belongs to the view (the row paints it) — report
      // before the setState so the parent learns the change even when
      // the label is already equal.
      widget.onHoverFolderRow(folderRow);
    }
    if (label == _hoverLabel && folderRow == _hoverRow) return;
    setState(() {
      _hoverLabel = label;
      _hoverRow = folderRow;
    });
  }

  /// 02 §5.1's spring-load: a folder row held under a drag for a second
  /// opens in place, so nested drops reach without abandoning the drag.
  /// Re-checks the row at fire time — a listing that changed mid-hover
  /// must not navigate into an entry that moved.
  void _springLoad() {
    _springTimer = null;
    final row = _springRow;
    if (row == null) return;
    final controller = widget.controller;
    if (!controller.verbsEnabled) return;
    // Re-resolve under the last pointer position: a listing refresh or
    // re-sort during the hold can make [row] point at an entry the user
    // never hovered, so the armed index alone proves nothing — open
    // whatever row the pointer rests on now (a file row or an
    // out-of-range index refuses instead).
    final global = _activeHoverGlobal;
    final target = global == null ? row : _resolveDrop(global)?.folderRow;
    if (target == null || target >= controller.entries.length) return;
    final entry = controller.entries[target];
    if (entry.type != RemoteFileType.directory) return;
    unawaited(controller.openEntry(entry));
    // The listing changes under the drag — the row highlight and label
    // describe the old folder; clear them until the next move or
    // modifier event re-resolves against the new rows.
    _setHover(label: null, folderRow: null);
  }

  /// The drop lands: resolve once more at release time — the pointer
  /// may have moved past the last `onMove` — then enqueue through the
  /// shared seam. The verb reads the modifiers held AT RELEASE.
  void _acceptInApp(PaneEntryDrag drag, Offset global) {
    final delegate = widget.delegate;
    final resolved = _resolveDrop(global);
    final destination = _destinationFs;
    drag.verb.value = null;
    _clearHover();
    if (resolved == null || delegate == null || destination == null) {
      return;
    }
    final modifiers = paneDropModifiers(context);
    final verb = paneDropVerb(
      source: drag.source,
      sourceRoots: drag.rootPaths,
      destination: destination,
      destinationDir: resolved.dir,
      copyModifier: modifiers.copy,
      moveModifier: modifiers.move,
    );
    if (!paneDropAllowed(
      source: drag.source,
      sourceRoots: drag.rootPaths,
      destination: destination,
      destinationDir: resolved.dir,
      operation: verb,
    )) {
      return;
    }
    delegate.enqueue(
      source: drag.source,
      rootPaths: drag.rootPaths,
      destination: destination,
      destinationDir: resolved.dir,
      operation: verb,
    );
  }

  /// Whether the OS drop target advertises itself to the platform right
  /// now (Séance's files_pane.dart gate, 02 §5.1): a pane that is off
  /// (hidden — unmounted entirely — the widget never exists), covered
  /// by a pushed route, or inside a paused ticker (background tab
  /// surfaces) must not swallow drops; a pane without a live listing
  /// (loading, error, connection-lost, disowned rows) accepts nothing.
  bool _osDropEnabled(BuildContext context) =>
      widget.delegate != null &&
      widget.controller.verbsEnabled &&
      TickerMode.valuesOf(context).enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  /// OS drop hover: always a copy (D14 — a cross-application drag
  /// carries no move intent the app can honor), the position still
  /// deciding hovered-folder vs current directory.
  void _updateOsHover(Offset global) {
    // Recorded so the spring-load timer can re-resolve under the
    // pointer at fire time, same as the in-app path.
    _activeHoverGlobal = global;
    final resolved = _resolveDrop(global);
    _setHover(
      label: resolved == null
          ? null
          : _labelFor(
              TransferOperation.copy,
              resolved.dir,
              const LocalFsLocation(),
            ),
      folderRow: resolved?.folderRow,
    );
  }

  /// The OS drop: the file paths arrive in `files` (file:// URIs are
  /// already unwrapped by the plugin on Linux). Containment is checked
  /// here rather than at hover — the package reports positions during
  /// hover but paths only at drop time.
  void _acceptOsDrop(DropDoneDetails details) {
    final delegate = widget.delegate;
    final resolved = _resolveDrop(details.globalPosition);
    final destination = _destinationFs;
    if (resolved == null || delegate == null || destination == null) {
      return;
    }
    final paths = [
      for (final item in details.files)
        if (item.path.isNotEmpty) item.path,
    ];
    if (paths.isEmpty) return;
    const source = LocalFsLocation();
    if (!paneDropAllowed(
      source: source,
      sourceRoots: paths,
      destination: destination,
      destinationDir: resolved.dir,
      operation: TransferOperation.copy,
    )) {
      return;
    }
    delegate.enqueue(
      source: source,
      rootPaths: paths,
      destination: destination,
      destinationDir: resolved.dir,
      operation: TransferOperation.copy,
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget zone = DragTarget<PaneEntryDrag>(
      // Accept the TYPE at the boundary, not the verb: a drag refused
      // here is locked out for the whole hover even if a modifier flip
      // (move → copy) would make it legal, so willAccept answers only
      // "is a queue wired" and the affordance/accept paths carry the
      // honest resolution.
      onWillAcceptWithDetails: (details) {
        _updateInAppHover(details.data, details.offset);
        return widget.delegate != null;
      },
      onMove: (details) => _updateInAppHover(details.data, details.offset),
      onLeave: (data) {
        // Leaving clears the badge too — the avatar outlives the hover.
        data?.verb.value = null;
        _clearHover();
      },
      onAcceptWithDetails: (details) =>
          _acceptInApp(details.data, details.offset),
      builder: (context, candidateData, rejectedData) => widget.child,
    );
    if (widget.supportsOsDrop) {
      zone = DropTarget(
        enable: _osDropEnabled(context),
        onDragEntered: (details) => _updateOsHover(details.globalPosition),
        onDragUpdated: (details) => _updateOsHover(details.globalPosition),
        onDragExited: (_) => _clearHover(),
        onDragDone: (details) {
          _clearHover();
          _acceptOsDrop(details);
        },
        child: zone,
      );
    }
    final label = _hoverLabel;
    final colors = Theme.of(context).colorScheme;
    // The Stack must wrap the zone unconditionally: swapping the build's
    // root between the bare DragTarget and a Stack mid-hover unmounts the
    // DragTarget's element, and the drag avatar's recorded targets point
    // at the defunct state — the drop then silently never lands.
    return Stack(
      // StackFit.expand preserves the tight constraints the bare zone
      // used to get — loose fit would collapse the listing to its
      // intrinsic size (the rows render 1px wide).
      fit: StackFit.expand,
      children: [
        zone,
        // The zone border (02 §5.1's target highlight): the whole pane
        // body reads as the destination while a drop can land, with the
        // folder-row highlight carrying the finer-grained case.
        if (label != null)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: colors.primary, width: 2),
                ),
              ),
            ),
          ),
        if (label != null)
          PositionedDirectional(
            start: 0,
            end: 0,
            bottom: 8,
            child: IgnorePointer(
              child: Center(child: _DropActionLabel(label: label)),
            ),
          ),
      ],
    );
  }
}

/// The drop-hover action line (02 §5.1): a pill naming the effective
/// verb and destination, floating at the zone's bottom like the
/// type-ahead badge.
class _DropActionLabel extends StatelessWidget {
  const _DropActionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colors.inverseSurface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: colors.onInverseSurface),
      ),
    );
  }
}

/// The drag avatar for an in-app row drag (02 §5.1): stacked file icons
/// plus a count badge for multi-selections, and the `+` verb badge the
/// hovered target's resolution drives — repaint-only via the payload's
/// notifier so modifier flips update mid-drag.
class PaneEntryDragAvatar extends StatelessWidget {
  const PaneEntryDragAvatar({super.key, required this.drag});

  final PaneEntryDrag drag;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final count = drag.rootPaths.length;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Material(
          elevation: 4,
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 26,
                  height: 24,
                  child: Stack(
                    children: [
                      const Positioned(
                        left: 0,
                        top: 0,
                        child: Icon(Icons.insert_drive_file_outlined, size: 18),
                      ),
                      const Positioned(
                        left: 5,
                        top: 4,
                        child: Icon(Icons.insert_drive_file_outlined, size: 18),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    count == 1
                        ? paneLastSegment(drag.rootPaths.first)
                        : l10n.dropItemCount(count),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (count > 1)
          PositionedDirectional(
            top: -6,
            end: -6,
            child: _AvatarBadge(
              colors: colors,
              child: Text(
                '$count',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: colors.onPrimary),
              ),
            ),
          ),
        // The `+` badge = copy (02 §5.1); a move carries no badge —
        // Finder's own convention.
        PositionedDirectional(
          bottom: -6,
          end: -6,
          child: ValueListenableBuilder<TransferOperation?>(
            valueListenable: drag.verb,
            builder: (context, verb, _) => verb == TransferOperation.copy
                ? _AvatarBadge(
                    colors: colors,
                    child: Text(
                      '+',
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: colors.onPrimary),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

class _AvatarBadge extends StatelessWidget {
  const _AvatarBadge({required this.colors, required this.child});

  final ColorScheme colors;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(color: colors.primary, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: child,
    );
  }
}
