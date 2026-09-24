part of 'sidebar_view.dart';

/// One resolved drop (10 §5's drag and drop): what the row or header draws
/// while the drag hovers, and what releasing it does.
final class _DropPlan {
  const _DropPlan(this.indicator, this.accept, {this.verb});

  final SidebarDropIndicator indicator;
  final VoidCallback accept;

  /// The transfer verb a pane-row drop would run — the drag avatar's `+`
  /// badge follows it, like a pane's own drop zone.
  final TransferOperation? verb;
}

/// Resolves a hovering payload at [fraction] of the target's height
/// (0 = top edge, 1 = bottom edge) into a plan, or null to refuse there.
typedef _DropPlanner = _DropPlan? Function(Object data, double fraction);

/// Wraps a row or header in one [DragTarget] over every payload the rail
/// understands — bookmarks (reorder, regroup), pane rows (add as
/// favorites, or copy/move into a folder), and tabs (add their folder).
///
/// Acceptance is decided once, when the drag enters (Flutter's contract),
/// so a payload is accepted if ANY zone of the target takes it; the zone
/// under the pointer then decides the plan on every move, and a release
/// over a zone with no plan does nothing.
class _SidebarDropZone extends StatefulWidget {
  const _SidebarDropZone({
    required this.planner,
    required this.builder,
    super.key,
  });

  final _DropPlanner planner;
  final Widget Function(SidebarDropIndicator indicator) builder;

  @override
  State<_SidebarDropZone> createState() => _SidebarDropZoneState();
}

class _SidebarDropZoneState extends State<_SidebarDropZone> {
  static const _probeFractions = [0.0, 0.5, 1.0];

  SidebarDropIndicator _indicator = SidebarDropIndicator.none;

  _DropPlan? _resolve(Object data, Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.height == 0) return null;
    final local = box.globalToLocal(global);
    final fraction = (local.dy / box.size.height).clamp(0.0, 1.0);
    return widget.planner(data, fraction);
  }

  void _show(_DropPlan? plan, Object data) {
    if (data is PaneEntryDrag) data.verb.value = plan?.verb;
    final indicator = plan?.indicator ?? SidebarDropIndicator.none;
    if (indicator != _indicator) setState(() => _indicator = indicator);
  }

  void _clear(Object? data) {
    if (data is PaneEntryDrag) data.verb.value = null;
    if (_indicator != SidebarDropIndicator.none) {
      setState(() => _indicator = SidebarDropIndicator.none);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<Object>(
      onWillAcceptWithDetails: (details) => _probeFractions.any(
        (fraction) => widget.planner(details.data, fraction) != null,
      ),
      onMove: (details) =>
          _show(_resolve(details.data, details.offset), details.data),
      onLeave: _clear,
      onAcceptWithDetails: (details) {
        final plan = _resolve(details.data, details.offset);
        // An accepted drop never fires onLeave — clear here or the row
        // stays armed-looking until the next drag.
        _clear(details.data);
        plan?.accept();
      },
      builder: (context, candidates, rejected) => widget.builder(_indicator),
    );
  }
}

/// A pane-row drop INTO a local folder (a device, a folder favorite): the
/// pane's own verb rules (02 §5.1 — modifiers, cross-filesystem copy, the
/// containment refusals) through the shell's queue delegate.
_DropPlan? _transferPlan(
  BuildContext context,
  SidebarView view,
  Object data, {
  required String destinationDir,
}) {
  final delegate = view.dropDelegate;
  if (delegate == null || data is! PaneEntryDrag) return null;
  const destination = LocalFsLocation();
  final modifiers = paneDropModifiers(context);
  final verb = paneDropVerb(
    source: data.source,
    sourceRoots: data.rootPaths,
    destination: destination,
    destinationDir: destinationDir,
    copyModifier: modifiers.copy,
    moveModifier: modifiers.move,
  );
  final allowed = paneDropAllowed(
    source: data.source,
    sourceRoots: data.rootPaths,
    destination: destination,
    destinationDir: destinationDir,
    operation: verb,
  );
  if (!allowed) return null;
  return _DropPlan(
    SidebarDropIndicator.into,
    () => delegate.enqueue(
      source: data.source,
      rootPaths: data.rootPaths,
      destination: destination,
      destinationDir: destinationDir,
      operation: verb,
    ),
    verb: verb,
  );
}

/// A drop that ADDS favorites (10 §5): local folders dragged from a pane,
/// or a tab showing a local folder. Remote folders are refused here —
/// saved remote locations live under SERVERS.
_DropPlan? _addFavoritePlan(
  BuildContext context,
  SidebarView view,
  Object data, {
  required SidebarDropIndicator indicator,
  String? group,
  String? beforeId,
  String? afterId,
}) {
  final (paths, checkFolders) = switch (data) {
    PaneEntryDrag(source: LocalFsLocation(), :final rootPaths) => (
      rootPaths,
      true,
    ),
    PaneTab(:final controller) => switch (controller.location) {
      LocalPaneLocation(:final path) => ([path], false),
      _ => (const <String>[], false),
    },
    _ => (const <String>[], false),
  };
  // A pane-row drag may carry files; without a way to tell folders from
  // files there is nothing safe to add.
  if (paths.isEmpty || (checkFolders && view.volumes == null)) return null;
  return _DropPlan(
    indicator,
    () => unawaited(
      _addFolders(
        context,
        view,
        paths,
        group: group,
        beforeId: beforeId,
        afterId: afterId,
        foldersOnly: checkFolders,
      ),
    ),
  );
}

/// A bookmark drag onto a row: reorder within [group] by the half the
/// pointer is in (the store's between-neighbors convention: `beforeId` is
/// the member the dropped bookmark lands after). [accepts] gates which
/// kinds this surface takes — favorites never absorb server rows and
/// vice versa.
_DropPlan? _reorderPlan(
  SidebarView view,
  Object data,
  double fraction, {
  required Bookmark target,
  required String? group,
  required bool Function(Bookmark bookmark) accepts,
}) {
  if (data is! Bookmark || data.id == target.id || !accepts(data)) {
    return null;
  }
  final before = fraction < 0.5;
  return _DropPlan(
    before ? SidebarDropIndicator.before : SidebarDropIndicator.after,
    () => unawaited(
      _dropBookmark(
        view,
        data,
        group,
        beforeId: before ? null : target.id,
        afterId: before ? target.id : null,
      ),
    ),
  );
}

/// A bookmark drag onto a group (or section) header: refile it at that
/// group's tail (null ungroups).
_DropPlan? _regroupPlan(
  SidebarView view,
  Object data, {
  required String? group,
  required bool Function(Bookmark bookmark) accepts,
}) {
  if (data is! Bookmark || data.id.isEmpty || !accepts(data)) return null;
  return _DropPlan(
    SidebarDropIndicator.into,
    () => unawaited(_dropBookmark(view, data, group)),
  );
}

/// The store move both bookmark targets resolve to.
Future<void> _dropBookmark(
  SidebarView view,
  Bookmark bookmark,
  String? group, {
  String? beforeId,
  String? afterId,
}) async {
  try {
    await view.controller.drop(
      bookmark.id,
      group,
      beforeId: beforeId,
      afterId: afterId,
    );
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
  }
}

/// Adds [paths] as favorites; with [foldersOnly], paths that are not
/// folders (a dragged file) are dropped first.
Future<void> _addFolders(
  BuildContext context,
  SidebarView view,
  List<String> paths, {
  String? label,
  String? group,
  String? beforeId,
  String? afterId,
  bool foldersOnly = false,
}) async {
  final l10n = AppLocalizations.of(context);
  try {
    var folders = paths;
    if (foldersOnly) {
      final source = view.volumes;
      if (source == null) return;
      folders = [
        for (final path in paths)
          if (await source.isDirectory(path)) path,
      ];
    }
    if (folders.isEmpty) return;
    await view.controller.addLocalFolders(
      folders,
      labelOf: label == null ? _folderLabel : (_) => label,
      group: group,
      beforeId: beforeId,
      afterId: afterId,
    );
  } on Object catch (error, stackTrace) {
    ApplicationErrorReporter().report(error, stackTrace);
    if (context.mounted) _showSidebarError(context, l10n);
  }
}

/// The bookmark drag the reorder contract rides: the row itself, with a
/// compact floating copy as the avatar. Desktop only: on touch an
/// immediate drag would steal the list's scroll (the rail is the phone's
/// home screen, 10 §9), and long-press belongs to the verb sheet, whose
/// Move to Group covers regrouping.
Widget _bookmarkDraggable(
  BuildContext context, {
  required Bookmark bookmark,
  required Widget mark,
  required Widget child,
}) {
  final theme = Theme.of(context);
  if (!isDesktopPlatform(theme.platform)) return child;
  final chrome = PoltergeistChrome.of(context);
  return Draggable<Bookmark>(
    data: bookmark,
    feedback: Material(
      elevation: 4,
      color: chrome.capsuleFill,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 200,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            SizedBox(width: 18, height: 18, child: Center(child: mark)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                bookmark.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    ),
    childWhenDragging: Opacity(opacity: 0.35, child: child),
    child: child,
  );
}
