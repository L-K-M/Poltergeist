/// 02 §5.1's pane↔pane drop logic (D14): the drag payload, the
/// copy-vs-move verb resolution, the self-containment rules a drop must
/// pass, and the enqueue seam the panes and tab strips share.
///
/// The rules live here as free functions so the widget layer stays
/// hit-testing and rendering only, and every decision tests without a
/// widget tree.
library;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:poltergeist_core/poltergeist_core.dart';

import 'app_transfer_queue.dart';
import 'pane_location.dart';

/// The payload an in-app listing-row drag carries (02 §5.1). Built when
/// the drag starts: [rootPaths] is the selection snapshot the gesture
/// grabbed — a row inside a multi-selection drags the whole selection —
/// so a mid-drag listing change on the source pane (a spring-load, a
/// refresh) cannot retroactively alter what the user picked up.
class PaneEntryDrag {
  PaneEntryDrag({required this.source, required this.rootPaths});

  /// The endpoint the dragged rows live on (03 §4.1's `FsLocation`).
  final FsLocation source;

  /// Absolute source paths — one gesture's roots, in listing order.
  final List<String> rootPaths;

  /// The verb the currently hovered target resolved, for the avatar's
  /// `+` badge; null while nothing claims the drag. Listenable so a
  /// mid-drag modifier flip repaints the badge without rebuilding the
  /// avatar.
  final ValueNotifier<TransferOperation?> verb =
      ValueNotifier<TransferOperation?>(null);
}

/// The pane location's transfer endpoint (03 §4.1): a local pane is the
/// local filesystem; a remote pane is its bound server id.
FsLocation fsLocationForLocation(PaneLocation location) =>
    switch (location) {
      LocalPaneLocation() => const LocalFsLocation(),
      RemotePaneLocation(:final serverId) => ServerFsLocation(serverId),
    };

/// Whether two endpoints share one filesystem for 02 §5.1's verb
/// default: local↔local is one namespace (volumes checked separately by
/// [paneDropVerb]); two remote panes share one only on the same server
/// id — same-server moves can execute server-side, cross-server work is
/// always a piped copy.
bool paneDropSameFilesystem(FsLocation a, FsLocation b) =>
    switch ((a, b)) {
      (LocalFsLocation(), LocalFsLocation()) => true,
      (
        ServerFsLocation(serverId: final aId),
        ServerFsLocation(serverId: final bId),
      ) =>
        aId == bId,
      _ => false,
    };

/// The volume a Windows local path lives on — a drive letter's `C:` or a
/// UNC path's `\\server\share` root — so a same-"local" drop across
/// drives still defaults to copy. POSIX paths return null: one
/// filesystem namespace from the pane's view (mount boundaries are the
/// executor's business, not the gesture's).
String? localVolumeOf(String path) {
  if (path.length >= 2 && path[1] == ':') {
    return path.substring(0, 2).toUpperCase();
  }
  if (path.startsWith(r'\\')) {
    final shareEnd = path.indexOf(r'\', 2);
    if (shareEnd < 0) return path; // '\\server' — a server root alone
    final shareTail = path.indexOf(r'\', shareEnd + 1);
    return (shareTail < 0 ? path : path.substring(0, shareTail))
        .toLowerCase();
  }
  return null;
}

/// The effective verb for a hover or a drop (02 §5.1). The modifiers
/// force: copy-modifier = ⌥ on macOS / Ctrl elsewhere, move-modifier =
/// ⌘ on macOS / Shift elsewhere (the widget layer maps the keys). An
/// explicit move wins the modifier race. Absent a modifier: within one
/// filesystem (same volume, or same server) a drag moves; across
/// filesystems or servers it copies — Finder/Explorer's rule.
TransferOperation paneDropVerb({
  required FsLocation source,
  required List<String> sourceRoots,
  required FsLocation destination,
  required String destinationDir,
  required bool copyModifier,
  required bool moveModifier,
}) {
  if (moveModifier) return TransferOperation.move;
  if (copyModifier) return TransferOperation.copy;
  if (!paneDropSameFilesystem(source, destination)) {
    return TransferOperation.copy;
  }
  if (source is LocalFsLocation) {
    // Same-namespace local drops still cross volumes on Windows: a
    // 'C:' → 'D:' "move" is a copy-then-delete in disguise, so the
    // default verb must not promise a rename.
    final destVolume = localVolumeOf(destinationDir);
    if (destVolume != null) {
      for (final root in sourceRoots) {
        if (localVolumeOf(root) != destVolume) {
          return TransferOperation.copy;
        }
      }
    }
  }
  return TransferOperation.move;
}

/// Whether a drop may land at all, same-filesystem pairs only (02 §5.1):
/// a folder can never drop onto itself or into its own subtree, and a
/// move onto a root's own parent directory is a no-op the queue must
/// never see. A copy onto the source's own directory stays legal —
/// §5.2's conflict flow answers the self-collision the same way it
/// answers every other.
bool paneDropAllowed({
  required FsLocation source,
  required List<String> sourceRoots,
  required FsLocation destination,
  required String destinationDir,
  required TransferOperation operation,
}) {
  if (!paneDropSameFilesystem(source, destination)) return true;
  final dest = _normalizedPath(destinationDir);
  final separator = paneSeparator(dest);
  for (final raw in sourceRoots) {
    final root = _normalizedPath(raw);
    if (root == dest) return false;
    if (dest.startsWith('$root$separator')) return false;
    if (operation == TransferOperation.move &&
        paneParentPath(root) == dest) {
      return false;
    }
  }
  return true;
}

/// Trailing-separator normalization for the equality/prefix checks —
/// pane paths arrive canonical, but a root spelling ('/', 'C:\') must
/// keep its separator while a directory's redundant tail goes.
String _normalizedPath(String path) {
  final separator = paneSeparator(path);
  var trimmed = path;
  while (trimmed.length > 1 && trimmed.endsWith(separator)) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

/// The enqueue seam every drop target funnels through (02 §5.1: "every
/// drop lands in the transfer queue — nothing uploads inline"). It
/// resolves the §5.2 direction bucket at enqueue time from the
/// settings-level [ConflictPolicy], so the gesture never carries a
/// policy of its own.
class PaneDropDelegate {
  PaneDropDelegate({required this.queue, ConflictPolicy? conflictPolicy})
    : conflictPolicy = conflictPolicy ?? ConflictPolicy();

  /// The app-facing queue seam — never the concrete `TransferQueue`
  /// (the same posture as the activity panel's).
  final AppTransferQueue queue;

  /// The persisted conflict matrix (02 §5.2); absent settings decode to
  /// the spec defaults — ask on every bucket.
  final ConflictPolicy conflictPolicy;

  /// Enqueues one gesture's roots as one task. Returns null when the
  /// drop carries no roots.
  TransferTask? enqueue({
    required FsLocation source,
    required List<String> rootPaths,
    required FsLocation destination,
    required String destinationDir,
    required TransferOperation operation,
  }) {
    if (rootPaths.isEmpty) return null;
    return queue.enqueue(
      TransferTaskSpec(
        source: source,
        destination: destination,
        rootPaths: List.unmodifiable(rootPaths),
        destinationDir: destinationDir,
        policy: conflictPolicy.policyFor(source, destination),
        operation: operation,
      ),
    );
  }
}
