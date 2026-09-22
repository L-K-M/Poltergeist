// The plan view's presentation grammar (05 §7): the header's
// plain-language consequence sentence and the per-row action glyph and
// reason text. Pure functions over the controller's effective stats +
// items so the verbatim copy contract is testable without a widget
// tree.
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../l10n/app_localizations.dart';
import '../../services/pane_location.dart' show paneLastSegment;
import '../../services/sync_plan_controller.dart';

/// §7's action glyphs — shape AND color carry the state, never color
/// alone. The mapping is one-way honest: `⇒`/`⇐` mark overwrites,
/// `→`/`←` creates, `⊞` directory creation, `✕` deletions, `↯`
/// conflicts, `–` skips.
String syncActionGlyph(SyncActionType action) => switch (action) {
  SyncActionType.copyLeftToRight => '→',
  SyncActionType.updateLeftToRight => '⇒',
  SyncActionType.copyRightToLeft => '←',
  SyncActionType.updateRightToLeft => '⇐',
  SyncActionType.makeDirLeft ||
  SyncActionType.makeDirRight => '⊞',
  SyncActionType.deleteLeft || SyncActionType.deleteRight => '✕',
  SyncActionType.conflict => '↯',
  SyncActionType.skip => '–',
};

/// The semantic class the row's color expresses (paired with the
/// glyph's shape — the two channels stay independent).
enum SyncActionTone { create, update, delete, conflict, skip }

SyncActionTone syncActionTone(SyncActionType action) => switch (action) {
  SyncActionType.copyLeftToRight ||
  SyncActionType.copyRightToLeft ||
  SyncActionType.makeDirLeft ||
  SyncActionType.makeDirRight => SyncActionTone.create,
  SyncActionType.updateLeftToRight ||
  SyncActionType.updateRightToLeft => SyncActionTone.update,
  SyncActionType.deleteLeft || SyncActionType.deleteRight =>
    SyncActionTone.delete,
  SyncActionType.conflict => SyncActionTone.conflict,
  SyncActionType.skip => SyncActionTone.skip,
};

/// The row's reason column — §7's verbatim reason strings. Symlink
/// rows carry their own string: the engine skips them by policy and
/// the reason enum has no symlink case.
String syncReasonText(
  AppLocalizations l10n,
  SyncItem item, {
  DateTime? now,
}) {
  if (item.left?.kind == EntryKind.symlink ||
      item.right?.kind == EntryKind.symlink) {
    return l10n.syncReasonSymlink;
  }
  return switch (item.reason) {
    SyncReason.onlyOnLeft || SyncReason.onlyOnRight =>
      l10n.syncReasonOnlyHere,
    SyncReason.newerOnLeft || SyncReason.newerOnRight =>
      l10n.syncReasonNewerHere(
        _ageLabel(item.left?.mtimeSecs, now),
        _ageLabel(item.right?.mtimeSecs, now),
      ),
    SyncReason.sizeDiffers => l10n.syncReasonSizesDiffer(
      formatSyncSize(item.left?.size),
      formatSyncSize(item.right?.size),
    ),
    SyncReason.contentDiffers => l10n.syncReasonContentsDiffer,
    SyncReason.bothChanged => l10n.syncReasonBothChanged,
    SyncReason.typeDiffers => l10n.syncReasonTypeDiffers(
      syncKindLabel(l10n, item.left?.kind),
      syncKindLabel(l10n, item.right?.kind),
    ),
    SyncReason.excluded => l10n.syncReasonExcluded,
    SyncReason.caseCollision => l10n.syncReasonCaseCollision,
    SyncReason.normalizationCollision =>
      l10n.syncReasonNormalizationCollision,
    SyncReason.invalidNameOnDestination => l10n.syncReasonInvalidName,
    SyncReason.scanError => l10n.syncReasonScanError,
    SyncReason.equal => l10n.syncReasonEqual,
  };
}

/// `newer here (x vs y)`'s slots — short age-from-now labels.
String _ageLabel(int? mtimeSecs, DateTime? now) {
  if (mtimeSecs == null) return '—';
  final reference = now ?? DateTime.now();
  final delta = reference
      .difference(DateTime.fromMillisecondsSinceEpoch(mtimeSecs * 1000))
      .inSeconds
      .abs();
  if (delta < 60) return '${delta}s';
  if (delta < 3600) return '${delta ~/ 60}m';
  if (delta < 86400) return '${delta ~/ 3600}h';
  return '${delta ~/ 86400}d';
}

/// The kind slot inside `type differs (file here, folder there)`.
String syncKindLabel(AppLocalizations l10n, EntryKind? kind) =>
    switch (kind) {
      EntryKind.file => l10n.syncKindFile,
      EntryKind.directory => l10n.syncKindFolder,
      EntryKind.symlink => l10n.syncKindSymlink,
      EntryKind.other || null => l10n.syncKindOther,
    };

/// Byte counts in the header/reason text — B/KB/MB/GB at one decimal
/// above 1 KB (the pane format's own style, kept local so the sync
/// surface reads identically without coupling to pane internals).
String formatSyncSize(int? bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024.0;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024.0;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// The header's consequence sentence (05 §7's verbatim clauses):
/// copy/create/update counts first, then the "Nothing will be deleted"
/// assurance or the delete/replace clauses, then the conflict and
/// no-op tails. Every number comes from the EFFECTIVE actions — an
/// override that adds a delete changes the sentence before Run is
/// ever reachable.
List<String> syncHeaderClauses(
  AppLocalizations l10n,
  SyncPlanController controller,
) {
  final stats = controller.stats;
  if (stats == null) return const [];
  final clauses = <String>[];

  // §7's first clause. Additive aggregates both directions into one
  // sentence on "both sides" (the per-direction split stays in the
  // table and chips); a one-way pair spells each destination endpoint
  // that carries work — overrides can legitimately produce both.
  final bidirectional =
      controller.pair.rules.direction == SyncDirection.bidirectional;
  for (final side in SyncSide.values) {
    final newFiles = bidirectional
        ? stats.newFilesTo(SyncSide.left) + stats.newFilesTo(SyncSide.right)
        : stats.newFilesTo(side);
    final folders = bidirectional
        ? stats.foldersTo(SyncSide.left) + stats.foldersTo(SyncSide.right)
        : stats.foldersTo(side);
    final updates = bidirectional
        ? stats.updatesTo(SyncSide.left) + stats.updatesTo(SyncSide.right)
        : stats.updatesTo(side);
    if (newFiles == 0 && folders == 0 && updates == 0) continue;
    final destination = bidirectional
        ? l10n.syncHeaderBothSides
        : _endpointLabel(controller, side);
    final newBytes = bidirectional
        ? stats.newBytesTo(SyncSide.left) + stats.newBytesTo(SyncSide.right)
        : stats.newBytesTo(side);
    if (newFiles == 0 && updates == 0 && folders > 0) {
      clauses.add(l10n.syncHeaderCreateOnly(folders, destination));
      continue;
    }
    final parts = <String>[
      if (newFiles > 0)
        l10n.syncHeaderCopyNew(
          newFiles,
          formatSyncSize(newBytes),
        ),
      if (folders > 0) l10n.syncHeaderCreateFolders(folders),
      if (updates > 0) l10n.syncHeaderUpdateFiles(updates),
    ];
    // §7's verbatim join: "Copy n new files (b), create d folders,
    // and update m on X." — the last segment links with ', and'.
    final joined = parts.length > 1
        ? '${parts.sublist(0, parts.length - 1).join(', ')}, '
              'and ${parts.last}'
        : parts.first;
    clauses.add('$joined ${l10n.syncHeaderOnDestination(destination)}');
    // The aggregate renders once — looping both sides would double it.
    if (bidirectional) break;
  }

  // The deletion/replacement/cleanup clauses — per side, trash-aware.
  var anyDeletionClause = false;
  for (final side in SyncSide.values) {
    final sideLabel = _sideLabel(l10n, side);
    final deletes = stats.deletesOn(side);
    if (deletes > 0) {
      anyDeletionClause = true;
      final trash = controller.trashPathFor(side);
      clauses.add(
        controller.deletesToTrash(side)
            ? l10n.syncHeaderDeleteTrash(
                deletes,
                sideLabel,
                trash ?? RemoteTrash.rootDirectoryName,
              )
            : l10n.syncHeaderDeletePermanent(deletes, sideLabel),
      );
    }
    // §7's {j} counts ROWS — one per replaced path; the per-file toll
    // rides the chips, the rails, and the typed-confirmation total.
    final replaced = stats.replacedRowsBySide[side] ?? 0;
    if (replaced > 0) {
      anyDeletionClause = true;
      final trash = controller.trashPathFor(side);
      clauses.add(
        controller.deletesToTrash(side)
            ? l10n.syncHeaderReplaceTrash(
                replaced,
                sideLabel,
                trash ?? RemoteTrash.rootDirectoryName,
              )
            : l10n.syncHeaderReplacePermanent(replaced, sideLabel),
      );
    }
    final emptyDirs = stats.emptyDirsOn(side);
    if (emptyDirs > 0) {
      // §7: the Remove tail replaces the green 'nothing deleted'
      // tail — rail 3's wording holds even at zero file deletions.
      anyDeletionClause = true;
      clauses.add(l10n.syncHeaderRemoveEmptyFolders(emptyDirs, sideLabel));
    }
  }
  if (!anyDeletionClause && stats.hasWork) {
    clauses.add(l10n.syncHeaderNothingDeleted);
  }
  if (stats.conflicts > 0) {
    clauses.add(l10n.syncHeaderConflicts(stats.conflicts));
  }
  if (!stats.hasWork) {
    return [l10n.syncHeaderNothingToDo];
  }
  return clauses;
}

/// The §8 rail-3 dialog's per-trigger line. The `half` wording applies
/// ONLY at the default 0.5 threshold — every other configured
/// threshold renders its numeric percentage.
String syncDeleteConfirmTrigger(
  AppLocalizations l10n,
  SyncDeleteRailTrigger trigger,
  double configuredThreshold,
) {
  final side = _sideLabel(l10n, trigger.side);
  return switch (trigger.clause) {
    DeleteRailClause.floor90 => l10n.syncDeleteConfirmFloor(
      trigger.deleteCount,
      trigger.sideFileCount,
      side,
    ),
    DeleteRailClause.fraction => l10n.syncDeleteConfirmFraction(
      trigger.deleteCount,
      trigger.sideFileCount,
      side,
      configuredThreshold == 0.5
          ? l10n.syncDeleteConfirmHalf
          : '${(configuredThreshold * 100).round()} %',
    ),
  };
}

String _sideLabel(AppLocalizations l10n, SyncSide side) => switch (side) {
  SyncSide.left => l10n.syncSideLeft,
  SyncSide.right => l10n.syncSideRight,
};

/// The copy sentence's {destination} (§7): '{favoriteLabel}:{path}' —
/// the remote ref's host stands in for the label until the catalog
/// resolves it — or a shortened local path.
String _endpointLabel(SyncPlanController controller, SyncSide side) {
  final endpoint = switch (side) {
    SyncSide.left => controller.pair.left,
    SyncSide.right => controller.pair.right,
  };
  return syncEndpointLabel(endpoint);
}

/// An endpoint's display label — '{host}:{path}' for a remote leg,
/// or the local path's last segment. [shortenRemotePath] trims the
/// remote leg to its last segment for compact labels like tab
/// titles.
String syncEndpointLabel(
  SyncEndpoint endpoint, {
  bool shortenRemotePath = false,
}) =>
    switch (endpoint) {
      LocalEndpoint(:final path) => paneLastSegment(path),
      RemoteEndpoint(:final server, :final path) =>
        '${server.identity?.host ?? server.serverConfigId ?? server.identity?.username ?? 'server'}:'
            '${shortenRemotePath ? paneLastSegment(path) : path}',
    };
