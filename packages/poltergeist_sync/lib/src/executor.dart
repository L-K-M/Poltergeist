// Plan execution (05 §4's setTimes/verification loop, §6's ordering
// contract, §8's safety rails, §10's progress surface). The executor
// applies a SyncPlan item-by-item over the one VFS — two injected
// RemoteFileSystem instances (D3): makeDir* first shallowest-first,
// copies/updates next under the pair's transferConcurrency bound,
// deletions last deepest-first and only behind a clean copy phase.
// There is no execute path that skips the plan (rail 1): run() takes
// the SyncPlan the preview rendered and executes exactly its items'
// effective actions, re-verifying each item's precondition immediately
// before acting (rail 7).

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'journal.dart';
import 'plan.dart';
import 'scan.dart';

/// Which clause of the >50 % rail (05 §8 rail 3) tripped — the typed
/// confirmation's copy differs per clause.
enum DeleteRailClause {
  /// Deletions exceed `deleteFractionWarn` of the side's file count and
  /// are ≥ 10 — the "more than {pct}" rendering.
  fraction,

  /// Deletions are ≥ 90 % of the side however few — the floor clause
  /// always wins and renders `90 % or more`, never "more than 90 %".
  floor90,
}

/// The executor's gate verdict for a plan (05 §8 rails 3–4).
sealed class SyncRunGate {
  const SyncRunGate();
}

/// Deletions stay under both thresholds — the Run button may proceed.
final class SyncRunClear extends SyncRunGate {
  const SyncRunClear();
}

/// Rail 3 tripped: the UI must collect a typed `DELETE` before running.
final class SyncRunNeedsConfirmation extends SyncRunGate {
  const SyncRunNeedsConfirmation({
    required this.side,
    required this.deleteCount,
    required this.sideFileCount,
    required this.clause,
  });

  /// The side whose deletion share tripped the rail.
  final SyncSide side;
  final int deleteCount;

  /// That side's scanned non-directory entry count (the denominator —
  /// planned deletions included; the trash root is never scanned).
  final int sideFileCount;
  final DeleteRailClause clause;
}

/// Rail 4: deletions exceed `maxDelete`. The plan refuses to run at
/// all — never a stripped partial run.
final class SyncRunRefused extends SyncRunGate {
  const SyncRunRefused({
    required this.side,
    required this.deleteCount,
    required this.maxDelete,
  });

  final SyncSide side;
  final int deleteCount;
  final int maxDelete;
}

/// Thrown by [SyncExecutor.run] when rail 4 caps the plan — before any
/// item executes.
final class SyncRunRefusedException implements Exception {
  const SyncRunRefusedException(this.gate);

  final SyncRunRefused gate;

  @override
  String toString() =>
      'sync run refused: ${gate.deleteCount} deletions on '
      '${gate.side.name} exceed the maxDelete cap of ${gate.maxDelete}';
}

/// Thrown by [SyncExecutor.run] when rail 3 needs the typed
/// confirmation the caller did not acknowledge — the gate data rides
/// the exception so the UI can render the dialog verbatim.
final class SyncConfirmationRequiredException implements Exception {
  const SyncConfirmationRequiredException(this.gate);

  final SyncRunNeedsConfirmation gate;

  @override
  String toString() =>
      'sync run needs typed confirmation: ${gate.deleteCount} of '
      '${gate.sideFileCount} files on ${gate.side.name} would be '
      'deleted (${gate.clause.name})';
}

/// Per-side rail accounting — the unit every surface reconciles on
/// (05 §8 rail 3): non-directory removals per side against that side's
/// scanned non-directory count. Delete-phase directories are
/// zero-count cleanup items; pre-delete removals count per removed
/// file, never "one item = one deletion".
final class SyncDeleteAssessment {
  const SyncDeleteAssessment({
    required this.removals,
    required this.sideEntries,
    required this.gate,
  });

  /// Planned deletions per side: delete-phase items plus rule-4
  /// pre-delete removals, counted per non-directory entry.
  final Map<SyncSide, int> removals;

  /// Each side's scanned non-directory count.
  final Map<SyncSide, int> sideEntries;
  final SyncRunGate gate;
}

/// Counts a plan's deletions per side and evaluates rails 3–4. Pure —
/// the UI runs the same evaluation the executor enforces at run time.
/// Update backups (`backups: trash`) are recoverable moves, not
/// deletions, and count on no rail.
SyncDeleteAssessment assessDeletions(SyncPlan plan) {
  final removals = <SyncSide, int>{SyncSide.left: 0, SyncSide.right: 0};
  final sideEntries = <SyncSide, int>{SyncSide.left: 0, SyncSide.right: 0};
  for (final item in plan.items) {
    final left = item.left;
    final right = item.right;
    if (left != null && left.kind != EntryKind.directory) {
      sideEntries[SyncSide.left] = sideEntries[SyncSide.left]! + 1;
    }
    if (right != null && right.kind != EntryKind.directory) {
      sideEntries[SyncSide.right] = sideEntries[SyncSide.right]! + 1;
    }
    switch (item.effective) {
      case SyncActionType.deleteLeft:
        removals[SyncSide.left] =
            removals[SyncSide.left]! + _removalWeight(item.left);
      case SyncActionType.deleteRight:
        removals[SyncSide.right] =
            removals[SyncSide.right]! + _removalWeight(item.right);
      default:
        if (_carriesPreDelete(item)) {
          final side = _destinationSide(item.effective)!;
          final dest = side == SyncSide.left ? item.left : item.right;
          if (dest == null) break;
          removals[side] = removals[side]! + _preDeleteWeight(item, dest);
          if (dest.kind == EntryKind.directory) {
            // The subsumed subtree's files are scanned entries on this
            // side even though they are not their own plan items.
            final subtree = item.destinationSubtree;
            if (subtree != null) {
              for (final snapshot in subtree.values) {
                if (snapshot.kind != EntryKind.directory) {
                  sideEntries[side] = sideEntries[side]! + 1;
                }
              }
            }
          }
        }
    }
  }
  // Rail 3's denominator is the side's *scanned* file count — the
  // differ's count when the plan carries it, else the lower bound the
  // items themselves imply.
  sideEntries[SyncSide.left] =
      plan.leftFileCount ?? sideEntries[SyncSide.left]!;
  sideEntries[SyncSide.right] =
      plan.rightFileCount ?? sideEntries[SyncSide.right]!;
  return SyncDeleteAssessment(
    removals: removals,
    sideEntries: sideEntries,
    gate: _evaluateRails(plan, removals, sideEntries),
  );
}

/// The destination side an action writes to; null for skip/conflict.
SyncSide? _destinationSide(SyncActionType action) => switch (action) {
  SyncActionType.copyLeftToRight ||
  SyncActionType.updateLeftToRight ||
  SyncActionType.makeDirRight ||
  SyncActionType.deleteRight => SyncSide.right,
  SyncActionType.copyRightToLeft ||
  SyncActionType.updateRightToLeft ||
  SyncActionType.makeDirLeft ||
  SyncActionType.deleteLeft => SyncSide.left,
  SyncActionType.skip || SyncActionType.conflict => null,
};

/// Whether [item]'s effective action creates over a different-kind
/// destination — §6 rule 4's pre-delete carrier.
bool _carriesPreDelete(SyncItem item) {
  final destSide = _destinationSide(item.effective);
  if (destSide == null) return false;
  final dest = destSide == SyncSide.left ? item.left : item.right;
  if (dest == null) return false;
  return switch (item.effective) {
    SyncActionType.makeDirLeft ||
    SyncActionType.makeDirRight => dest.kind != EntryKind.directory,
    SyncActionType.copyLeftToRight ||
    SyncActionType.copyRightToLeft ||
    SyncActionType.updateLeftToRight ||
    SyncActionType.updateRightToLeft => dest.kind != EntryKind.file,
    _ => false,
  };
}

/// Removal weight of a delete-phase item's destination entry — files
/// and links count, directories are zero-count cleanup items.
int _removalWeight(EntrySnapshot? destination) =>
    destination != null && destination.kind != EntryKind.directory ? 1 : 0;

/// Removal weight of a pre-delete: one for a non-directory destination,
/// the subtree's non-directory count for a replaced directory.
int _preDeleteWeight(SyncItem item, EntrySnapshot destination) {
  if (destination.kind != EntryKind.directory) return 1;
  final subtree = item.destinationSubtree;
  if (subtree == null) return 0;
  var count = 0;
  for (final snapshot in subtree.values) {
    if (snapshot.kind != EntryKind.directory) count++;
  }
  return count;
}

SyncRunGate _evaluateRails(
  SyncPlan plan,
  Map<SyncSide, int> removals,
  Map<SyncSide, int> sideEntries,
) {
  // Rail 4 dominates: the cap is checked before the typed
  // confirmation ever fires.
  for (final side in SyncSide.values) {
    final count = removals[side]!;
    if (count > plan.pair.rules.maxDelete) {
      return SyncRunRefused(
        side: side,
        deleteCount: count,
        maxDelete: plan.pair.rules.maxDelete,
      );
    }
  }
  for (final side in SyncSide.values) {
    final count = removals[side]!;
    if (count == 0) continue;
    final total = sideEntries[side]!;
    // The ≥ 90 % floor trips at any threshold and wins over the
    // fraction clause (05 §8 rail 3).
    if (total > 0 && count >= 0.9 * total) {
      return SyncRunNeedsConfirmation(
        side: side,
        deleteCount: count,
        sideFileCount: total,
        clause: DeleteRailClause.floor90,
      );
    }
    if (count >= 10 && count > plan.pair.rules.deleteFractionWarn * total) {
      return SyncRunNeedsConfirmation(
        side: side,
        deleteCount: count,
        sideFileCount: total,
        clause: DeleteRailClause.fraction,
      );
    }
  }
  return const SyncRunClear();
}

/// One progress event for the plan view's live rows and the activity
/// panel (05 §10).
final class SyncRunEvent {
  const SyncRunEvent._(this.kind, this.item, this.transferred, this.total);

  /// The item began executing.
  static const int itemStarted = 0;

  /// Byte progress for a running transfer item.
  static const int itemProgress = 1;

  /// The item reached a terminal status.
  static const int itemFinished = 2;

  /// The run closed its journal.
  static const int runFinished = 3;

  final int kind;
  final SyncItem? item;
  final int? transferred;
  final int? total;
}

/// What one run leaves behind: the journal, the updated §4 mtime-trust
/// flags for the pair's sync_state, and the cancel marker.
final class SyncRun {
  const SyncRun({
    required this.journal,
    required this.plan,
    required this.mtimeUnreliableLeft,
    required this.mtimeUnreliableRight,
    required this.cancelled,
  });

  /// The run's journal — replay source for Retry Failed and
  /// Restore Trashed Files… (rail 9).
  final SyncRunJournal journal;
  final SyncPlan plan;
  final bool mtimeUnreliableLeft;
  final bool mtimeUnreliableRight;
  final bool cancelled;

  String get runId => journal.record.runId;
}

/// Applies a [SyncPlan] over two [RemoteFileSystem] roots.
final class SyncExecutor {
  SyncExecutor({
    required this.leftFileSystem,
    required this.rightFileSystem,
    required this.leftRoot,
    required this.rightRoot,
    required this.syncRunsDirectory,
    this.deviceId = '',
    this.mtimeUnreliableLeft = false,
    this.mtimeUnreliableRight = false,
    RemoteTrash? trash,
  }) : _trash = trash ?? RemoteTrash();

  final RemoteFileSystem leftFileSystem;
  final RemoteFileSystem rightFileSystem;

  /// The canonicalized sync roots (ScanResult.rootPath) — every
  /// destination address is `remoteJoin(root, relativePath)`.
  final String leftRoot;
  final String rightRoot;

  /// `<app-support>/sync_runs` — where the JSONL journals live.
  final String syncRunsDirectory;

  /// 04 §3.1's device identity; the runId prefix is its sha256's first
  /// 8 hex (§6's SyncRunRecord — remote-visible trash names carry no
  /// slice of the raw id).
  final String deviceId;

  /// The §4 per-side flags at run start — either flag (or
  /// `preserveMtime: false`, or `sizeOnly`) puts precondition checks
  /// and conflict defaults on the distrusted-clock path.
  bool mtimeUnreliableLeft;
  bool mtimeUnreliableRight;

  final RemoteTrash _trash;

  /// `<first 8 hex of sha256(deviceId)>-<uuidV4>` (05 §6).
  String mintRunId() {
    final prefix = sha256
        .convert(utf8.encode(deviceId))
        .toString()
        .substring(0, 8);
    return '$prefix-${uuidV4()}';
  }

  /// Whether the pair's clocks are untrusted for precondition
  /// comparisons — §4's flags, the size-only fallback, or
  /// `preserveMtime: false`: no safety check may trust a clock the
  /// engine itself has flagged.
  bool _distrustsMtimes(SyncRuleSet rules) =>
      !rules.preserveMtime ||
      rules.comparison == ComparisonMode.sizeOnly ||
      mtimeUnreliableLeft ||
      mtimeUnreliableRight;

  /// Executes [plan] item-by-item under §6's ordering contract. Rail 1:
  /// the plan *is* the execution — there is no other entry point.
  ///
  /// [pairId] is §9's canonical state key (endpoint-derived), supplied
  /// by the caller — never the favorite's bookmark id.
  /// [deleteConfirmationAcknowledged] is the typed-`DELETE` result when
  /// rail 3 trips; without it a tripping plan throws
  /// [SyncConfirmationRequiredException]. Rail 4 always throws
  /// [SyncRunRefusedException] before any item executes.
  Future<SyncRun> run(
    SyncPlan plan, {
    required String pairId,
    bool deleteConfirmationAcknowledged = false,
    RemoteTransferCancellation? cancellation,
    void Function(SyncRunEvent event)? onEvent,
    DateTime? startedAt,
  }) async {
    plan.pair.rules.ensureSupported();
    final gate = assessDeletions(plan).gate;
    if (gate is SyncRunRefused) {
      throw SyncRunRefusedException(gate);
    }
    if (gate is SyncRunNeedsConfirmation &&
        !deleteConfirmationAcknowledged) {
      throw SyncConfirmationRequiredException(gate);
    }

    final journal = await SyncRunJournal.create(
      syncRunsDirectory,
      SyncRunRecord(
        runId: mintRunId(),
        pairId: pairId,
        startedAt: startedAt ?? DateTime.now(),
        rules: plan.pair.rules,
        totals: plan.totals,
        warnings: plan.warnings,
      ),
    );
    final session = _RunSession(
      executor: this,
      plan: plan,
      journal: journal,
      cancellation: cancellation,
      onEvent: onEvent,
    );
    await session.execute();
    return SyncRun(
      journal: journal,
      plan: plan,
      mtimeUnreliableLeft: mtimeUnreliableLeft,
      mtimeUnreliableRight: mtimeUnreliableRight,
      cancelled: session.cancelled,
    );
  }

  /// `Retry Failed` (05 §8 rail 8): re-executes only [previous]'s
  /// `failed` items — re-statting each source first, so a retry never
  /// quietly pushes content the user never previewed: a source whose
  /// stat no longer matches the plan snapshot flips the item to a
  /// `conflicted` row instead of executing. Re-executions journal at
  /// attempt n+1 under the same runId (§11's uniqueness contract).
  Future<SyncRun> retryFailed(
    SyncRun previous, {
    RemoteTransferCancellation? cancellation,
    void Function(SyncRunEvent event)? onEvent,
  }) async {
    final session = _RunSession(
      executor: this,
      plan: previous.plan,
      journal: previous.journal,
      cancellation: cancellation,
      onEvent: onEvent,
      retry: true,
    );
    await session.execute();
    return SyncRun(
      journal: previous.journal,
      plan: previous.plan,
      mtimeUnreliableLeft: mtimeUnreliableLeft,
      mtimeUnreliableRight: mtimeUnreliableRight,
      cancelled: session.cancelled,
    );
  }
}

/// One run's mutable execution state.
final class _RunSession {
  _RunSession({
    required this.executor,
    required this.plan,
    required this.journal,
    this.cancellation,
    this.onEvent,
    this.retry = false,
  });

  final SyncExecutor executor;
  final SyncPlan plan;
  final SyncRunJournal journal;
  final RemoteTransferCancellation? cancellation;
  final void Function(SyncRunEvent)? onEvent;

  /// `Retry Failed` — only `failed` items re-run, at attempt n+1.
  final bool retry;

  /// Per-side remaining deletion budget; a pre-delete that would
  /// exceed it flips skipped before its removal step (§6 rule 4).
  final Map<SyncSide, int> removalBudget = {};

  /// Relative paths this run already removed — the delete-phase parent
  /// check allows only these inside a directory it is about to rmdir.
  final Set<String> removedPaths = {};

  /// The run's trash directories per side (lazy — a run that trashes
  /// nothing never creates them).
  final Map<SyncSide, String> _trashDirs = {};

  var _failed = false;
  var cancelled = false;
  var _trashSequence = 0;

  SyncRuleSet get rules => plan.pair.rules;

  Future<void> execute() async {
    removalBudget[SyncSide.left] = rules.maxDelete;
    removalBudget[SyncSide.right] = rules.maxDelete;

    // Skip/conflict items execute as skip — counted, never acted on
    // (05 §5: unresolved conflicts are surfaced, not silently
    // resolved). On retry they keep their settled status.
    if (!retry) {
      for (final item in plan.items) {
        if (item.effective == SyncActionType.skip) {
          item.status = SyncItemStatus.skipped;
        } else if (item.effective == SyncActionType.conflict) {
          item.status = SyncItemStatus.skipped;
          item.error = 'Unresolved conflict';
        }
      }
    }

    final mkdirs = <SyncItem>[];
    final transfers = <SyncItem>[];
    final deletes = <SyncItem>[];
    for (final item in plan.items) {
      if (item.status == SyncItemStatus.skipped) continue;
      if (retry && item.status != SyncItemStatus.failed) continue;
      switch (item.effective) {
        case SyncActionType.makeDirLeft || SyncActionType.makeDirRight:
          mkdirs.add(item);
        case SyncActionType.deleteLeft || SyncActionType.deleteRight:
          deletes.add(item);
        case SyncActionType.copyLeftToRight ||
              SyncActionType.copyRightToLeft ||
              SyncActionType.updateLeftToRight ||
              SyncActionType.updateRightToLeft:
          transfers.add(item);
        case SyncActionType.skip || SyncActionType.conflict:
          break;
      }
    }
    int depthOf(SyncItem item) => item.relativePath.split('/').length;
    // Phase order is the §6 contract: mkdirs shallowest-first, then
    // copies/updates (parallel up to transferConcurrency), then
    // deletions deepest-first behind a clean copy phase.
    mkdirs.sort((a, b) => depthOf(a) - depthOf(b));
    deletes.sort((a, b) => depthOf(b) - depthOf(a));

    for (final item in mkdirs) {
      if (!_claim(item)) continue;
      await _runItem(item);
    }

    // Phase 2's pool: plain transfers run up to transferConcurrency; a
    // pre-delete-carrying item is a barrier — it drains all in-flight
    // transfers, re-checks the failure flag, and only then removes
    // (§6 rule 4 — a moment-in-time check would let a sibling fail
    // mid-removal).
    final running = <Future<void>>{};
    Future<void> drain() async {
      final pending = running.toList();
      running.clear();
      await Future.wait(pending);
    }

    for (final item in transfers) {
      if (!_claim(item)) continue;
      if (_carriesPreDelete(item)) {
        await drain();
        await _runItem(item);
      } else {
        while (running.length >= rules.transferConcurrency) {
          await Future.any(running);
        }
        late final Future<void> tracked;
        tracked = _runItem(item).whenComplete(() => running.remove(tracked));
        running.add(tracked);
      }
    }
    await drain();

    if (_failed) {
      for (final item in deletes) {
        item.status = SyncItemStatus.skipped;
        item.error = 'Skipped: earlier errors in this run';
      }
    } else {
      for (final item in deletes) {
        if (!_claim(item)) continue;
        await _runItem(item);
      }
    }
    if (cancelled) {
      for (final item in plan.items) {
        if (item.status == SyncItemStatus.pending) {
          item.status = SyncItemStatus.skipped;
          item.error = 'Cancelled';
        }
      }
    }
    await _finish();
  }

  bool _claim(SyncItem item) {
    if (cancelled || cancellation?.isCancelled == true) {
      cancelled = true;
      if (item.status == SyncItemStatus.pending) {
        item.status = SyncItemStatus.skipped;
        item.error = 'Cancelled';
      }
      return false;
    }
    return true;
  }

  Future<void> _runItem(SyncItem item) async {
    final destSide = _destinationSide(item.effective) ?? SyncSide.left;
    final attempt =
        journal.lastAttempt(item.relativePath, destSide, item.effective) + 1;
    final stopwatch = Stopwatch()..start();
    item.status = SyncItemStatus.running;
    _emit(SyncRunEvent.itemStarted, item);
    _ItemOutcome outcome;
    try {
      outcome = await _executeItem(item);
    } on _ItemConflicted catch (error) {
      item.status = SyncItemStatus.conflicted;
      item.error = error.message;
      outcome = const _ItemOutcome();
    } on _ItemSkipped catch (error) {
      item.status = SyncItemStatus.skipped;
      item.error = error.message;
      outcome = const _ItemOutcome();
    } on RemoteFileException catch (error) {
      // A name-collision mid-operation is the same race class as rail
      // 7's precondition mismatch — destination churn, not a fault.
      if (error.kind == RemoteFileErrorKind.conflict) {
        item.status = SyncItemStatus.conflicted;
      } else {
        item.status = SyncItemStatus.failed;
      }
      item.error = error.message;
      outcome = const _ItemOutcome();
    } on Object catch (error) {
      item.status = SyncItemStatus.failed;
      item.error = error.toString();
      outcome = const _ItemOutcome();
    }
    if (item.status == SyncItemStatus.running) {
      item.status = SyncItemStatus.done;
    }
    stopwatch.stop();
    if (item.status == SyncItemStatus.failed ||
        item.status == SyncItemStatus.conflicted) {
      _failed = true;
    }
    await journal.appendItem(
      SyncJournalItemLine(
        relativePath: item.relativePath,
        side: destSide,
        action: item.effective,
        outcome: item.status,
        attempt: attempt,
        bytes: outcome.bytes ?? 0,
        durationMs: stopwatch.elapsedMilliseconds,
        userOverridden: item.userOverridden,
        trashLocation: outcome.trashLocation,
        trashBytes: outcome.trashBytes,
        trashContentSha256: outcome.trashSha256,
        observedMtimeAfterWrite: outcome.observedMtimeSecs,
        setstatIgnored: outcome.setstatIgnored,
        error: item.error,
      ),
    );
    _emit(SyncRunEvent.itemFinished, item);
  }

  Future<_ItemOutcome> _executeItem(SyncItem item) async {
    final destSide = _destinationSide(item.effective);
    if (destSide == null) return const _ItemOutcome();
    final srcSide =
        destSide == SyncSide.left ? SyncSide.right : SyncSide.left;
    final destFs = _fs(destSide);
    final srcFs = _fs(srcSide);
    final destAbs = _abs(destSide, item.relativePath);
    final srcAbs = _abs(srcSide, item.relativePath);
    final destSnapshot = destSide == SyncSide.left ? item.left : item.right;
    final srcSnapshot = destSide == SyncSide.left ? item.right : item.left;

    // §6 rule 5 + rail 7: no write may escape the root through a link
    // introduced since the scan — the destination parent chain is
    // re-stat'd before the item's own precondition runs.
    await _checkParentChain(destFs, destSide, item.relativePath);
    switch (item.effective) {
      case SyncActionType.makeDirLeft || SyncActionType.makeDirRight:
        if (destSnapshot == null) {
          await _verifyAbsent(destFs, destAbs);
        } else {
          await _verifyDestination(item, destFs, destAbs, destSnapshot);
          // Only a different-kind destination carries a pre-delete —
          // a matching directory is §6 rule 4's no-op shape and must
          // not be removed.
          if (_carriesPreDelete(item)) {
            await _removeDestination(
              item,
              destFs,
              destSide,
              destAbs,
              destSnapshot,
            );
          }
        }
        await destFs.createDirectory(destAbs);
        return const _ItemOutcome();
      case SyncActionType.deleteLeft || SyncActionType.deleteRight:
        await _verifyDestination(
          item,
          destFs,
          destAbs,
          destSnapshot,
          forDelete: true,
        );
        return _deletePhaseEntry(item, destFs, destSide, destAbs,
            destSnapshot!);
      case SyncActionType.copyLeftToRight ||
          SyncActionType.copyRightToLeft ||
          SyncActionType.updateLeftToRight ||
          SyncActionType.updateRightToLeft:
        final isUpdate =
            item.effective == SyncActionType.updateLeftToRight ||
            item.effective == SyncActionType.updateRightToLeft;
        final preDelete = _carriesPreDelete(item);
        // The source must still offer what the preview promised:
        // vanished fails the item (rail 8), a changed stat flips it.
        final liveSource = await _verifySource(srcFs, srcAbs, srcSnapshot);
        String? trashLocation;
        String? trashSha;
        int? trashBytes;
        RemoteFileEntry? expectedTarget;
        if (preDelete) {
          await _verifyDestination(item, destFs, destAbs, destSnapshot!);
          await _removeDestination(
            item,
            destFs,
            destSide,
            destAbs,
            destSnapshot,
          );
          // The per-file trash lines the removal wrote carry the
          // origin map; the item line does not repeat them.
        } else if (isUpdate) {
          final liveDest =
              await _verifyDestination(item, destFs, destAbs, destSnapshot);
          if (rules.backups == BackupPolicy.trash) {
            final moved = await _trashEntry(
              destFs,
              destSide,
              RemoteFileEntry(
                path: destAbs,
                name: remoteBasename(destAbs),
                type: _remoteType(destSnapshot!.kind),
                size: destSnapshot.size,
              ),
              item.relativePath,
            );
            trashLocation = moved.location;
            trashSha = moved.sha256;
            trashBytes = destSnapshot.size;
          } else {
            expectedTarget = liveDest;
          }
        } else {
          await _verifyAbsent(destFs, destAbs);
        }
        final uploaded = await _transfer(
          srcFs,
          srcAbs,
          destFs,
          destAbs,
          length: srcSnapshot?.size ?? liveSource.size,
          preserveMode: liveSource.mode,
          expectedTarget: expectedTarget,
          overwrite: expectedTarget != null,
          item: item,
          computeHash: false,
        );
        final stamp = await _stampAndVerify(
          destFs,
          destSide,
          destAbs,
          liveSource,
        );
        return _ItemOutcome(
          trashLocation: trashLocation,
          trashBytes: trashBytes,
          trashSha256: trashSha,
          observedMtimeSecs: stamp.observed,
          setstatIgnored: stamp.ignored,
          bytes: uploaded.size ?? srcSnapshot?.size ?? 0,
        );
      case SyncActionType.skip || SyncActionType.conflict:
        return const _ItemOutcome();
    }
  }

  /// Copy-new and plain-mkdir precondition: the destination must still
  /// be absent.
  Future<void> _verifyAbsent(RemoteFileSystem destFs, String destAbs) async {
    if (await _statOrNull(destFs, destAbs) != null) {
      throw const _ItemConflicted('changed since preview');
    }
  }

  /// Rail 7's destination precondition re-stat for entries the plan
  /// expects present: kind first, then — for files — size plus the
  /// tolerant mtime rule (size-only when the pair distrusts clocks),
  /// then §6 rule 4's recursive entry-set check for replaced
  /// directories and the emptied-set check for delete-phase parents.
  /// Returns the live entry for callers that need it.
  Future<RemoteFileEntry> _verifyDestination(
    SyncItem item,
    RemoteFileSystem destFs,
    String destAbs,
    EntrySnapshot? snapshot, {
    bool forDelete = false,
  }) async {
    final live = await _statOrNull(destFs, destAbs);
    if (live == null || snapshot == null) {
      throw const _ItemConflicted('changed since preview');
    }
    final liveKind = switch (live.type) {
      RemoteFileType.file => EntryKind.file,
      RemoteFileType.directory => EntryKind.directory,
      RemoteFileType.symbolicLink => EntryKind.symlink,
      RemoteFileType.other => EntryKind.other,
    };
    if (liveKind != snapshot.kind) {
      throw const _ItemConflicted('changed since preview');
    }
    if (snapshot.kind == EntryKind.directory) {
      if (_carriesPreDelete(item) && item.destinationSubtree != null) {
        await _verifySubtree(item, destFs, destAbs);
      } else if (forDelete) {
        // Deepest-first already removed the planned children; anything
        // still inside that this run did not remove is new work (rail
        // 7's emptied-set rule).
        final listing = await destFs.listDirectory(destAbs);
        for (final entry in listing) {
          if (!removedPaths.contains('${item.relativePath}/${entry.name}')) {
            throw const _ItemConflicted('changed since preview');
          }
        }
      }
      return live;
    }
    if (live.size != snapshot.size) {
      throw const _ItemConflicted('changed since preview');
    }
    if (!_distrustsMtimes(rules)) {
      final liveSecs = _seconds(live.modifiedAt);
      final planSecs = snapshot.mtimeSecs;
      if (liveSecs != null && planSecs != null) {
        final delta = (liveSecs - planSecs).abs();
        var within = delta <= rules.mtimeToleranceSecs;
        if (!within) {
          for (final shift in rules.acceptedTimeShifts) {
            if ((delta - shift).abs() <= rules.mtimeToleranceSecs) {
              within = true;
              break;
            }
          }
        }
        if (!within) throw const _ItemConflicted('changed since preview');
      }
    }
    return live;
  }

  /// §6 rule 4's directory precondition: the replaced tree's live
  /// recursive entry set must still match the scan snapshot — same
  /// names, kinds, and file sizes — because the pre-delete removes it
  /// wholesale and anything new would otherwise die unplanned.
  Future<void> _verifySubtree(
    SyncItem item,
    RemoteFileSystem destFs,
    String destAbs,
  ) async {
    final live = await _listSubtree(destFs, destAbs, item.relativePath);
    final expected = item.destinationSubtree!;
    for (final expectedEntry in expected.entries) {
      final liveEntry = live[expectedEntry.key];
      if (liveEntry == null ||
          liveEntry.kind != expectedEntry.value.kind ||
          (expectedEntry.value.kind == EntryKind.file &&
              liveEntry.size != expectedEntry.value.size)) {
        throw const _ItemConflicted('changed since preview');
      }
    }
    for (final path in live.keys) {
      if (!expected.containsKey(path)) {
        throw const _ItemConflicted('changed since preview');
      }
    }
  }

  /// The source-side re-stat: vanished fails (rail 8), a different
  /// kind or size means the content is no longer what the preview
  /// showed — a conflict, never a quiet push. Returns the live entry
  /// for mtime/mode stamping.
  Future<RemoteFileEntry> _verifySource(
    RemoteFileSystem srcFs,
    String srcAbs,
    EntrySnapshot? snapshot,
  ) async {
    final live = await _statOrNull(srcFs, srcAbs);
    if (live == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'read',
        path: srcAbs,
        message: 'The source item "$srcAbs" vanished before it was read.',
      );
    }
    if (live.type != RemoteFileType.file ||
        (snapshot != null && live.size != snapshot.size)) {
      throw const _ItemConflicted('changed since preview');
    }
    return live;
  }

  /// §6 rule 5: every component of the destination's parent chain is
  /// re-stat'd nofollow — a link introduced since the scan would let a
  /// write or removal escape the sync root.
  Future<void> _checkParentChain(
    RemoteFileSystem fs,
    SyncSide side,
    String relativePath,
  ) async {
    final segments = relativePath.split('/');
    var current = _root(side);
    for (var i = 0; i < segments.length - 1; i++) {
      current = remoteJoin(current, segments[i]);
      final RemoteFileEntry entry;
      try {
        entry = await fs.stat(current, followLinks: false);
      } on RemoteFileException {
        throw const _ItemConflicted('changed since preview');
      }
      if (entry.isSymbolicLink || !entry.isDirectory) {
        throw const _ItemConflicted('changed since preview');
      }
    }
  }

  /// §6 rule 4's removal step: honors `DeletionPolicy` in Mirror
  /// (permanent opt-in included) and always trashes in the no-delete
  /// modes — there is no permanent opt-in to honor there. The barrier
  /// has already drained in-flight transfers; a recorded failure or an
  /// exhausted delete budget flips the whole item before anything is
  /// removed. The removal and the item's creation stay one plan item.
  Future<void> _removeDestination(
    SyncItem item,
    RemoteFileSystem destFs,
    SyncSide side,
    String destAbs,
    EntrySnapshot snapshot,
  ) async {
    if (_failed) {
      throw const _ItemSkipped('Skipped: earlier errors in this run');
    }
    final toTrash = rules.deletions != DeletionPolicy.permanent;
    if (snapshot.kind != EntryKind.directory) {
      _spendBudget(item, side, 1);
      final entry = RemoteFileEntry(
        path: destAbs,
        name: remoteBasename(destAbs),
        type: _remoteType(snapshot.kind),
        size: snapshot.size,
      );
      if (toTrash) {
        final moved = await _trashEntry(
          destFs,
          side,
          entry,
          item.relativePath,
        );
        await journal.appendTrash(
          SyncJournalTrashLine(
            parentPath: item.relativePath,
            relativePath: item.relativePath,
            side: side,
            trashLocation: moved.location,
            bytes: snapshot.size ?? 0,
            trashContentSha256: moved.sha256,
          ),
        );
      } else {
        await destFs.delete(entry);
        await journal.appendRemove(
          SyncJournalRemoveLine(
            parentPath: item.relativePath,
            relativePath: item.relativePath,
            side: side,
            bytes: snapshot.size ?? 0,
          ),
        );
      }
      removedPaths.add(item.relativePath);
      return;
    }

    // A replaced directory: its files move to trash one flat entry at
    // a time (deepest-first), the emptied directories rmdir with their
    // own lines, then the husk itself.
    final subtree = item.destinationSubtree ??
        await _listSubtree(destFs, destAbs, item.relativePath);
    final sorted = subtree.entries.toList()
      ..sort((a, b) => b.key.split('/').length - a.key.split('/').length);
    _spendBudget(item, side, _preDeleteWeight(item, snapshot));
    for (final entry in sorted) {
      if (entry.value.kind == EntryKind.directory) continue;
      final abs = remoteJoin(destAbs, _underPrefix(item, entry.key));
      final fileEntry = RemoteFileEntry(
        path: abs,
        name: remoteBasename(abs),
        type: _remoteType(entry.value.kind),
        size: entry.value.size,
      );
      if (toTrash) {
        final moved = await _trashEntry(
          destFs,
          side,
          fileEntry,
          item.relativePath,
        );
        await journal.appendTrash(
          SyncJournalTrashLine(
            parentPath: item.relativePath,
            relativePath: entry.key,
            side: side,
            trashLocation: moved.location,
            bytes: entry.value.size ?? 0,
            trashContentSha256: moved.sha256,
          ),
        );
      } else {
        await destFs.delete(fileEntry);
        await journal.appendRemove(
          SyncJournalRemoveLine(
            parentPath: item.relativePath,
            relativePath: entry.key,
            side: side,
            bytes: entry.value.size ?? 0,
          ),
        );
      }
      removedPaths.add(entry.key);
    }
    for (final entry in sorted) {
      if (entry.value.kind != EntryKind.directory) continue;
      final abs = remoteJoin(destAbs, _underPrefix(item, entry.key));
      await destFs.delete(
        RemoteFileEntry(
          path: abs,
          name: remoteBasename(abs),
          type: RemoteFileType.directory,
        ),
      );
      await journal.appendRmdir(
        SyncJournalRmdirLine(
          relativePath: entry.key,
          side: side,
          parentPath: item.relativePath,
        ),
      );
      removedPaths.add(entry.key);
    }
    await destFs.delete(
      RemoteFileEntry(
        path: destAbs,
        name: remoteBasename(destAbs),
        type: RemoteFileType.directory,
      ),
    );
    await journal.appendRmdir(
      SyncJournalRmdirLine(
        relativePath: item.relativePath,
        side: side,
        parentPath: item.relativePath,
      ),
    );
    removedPaths.add(item.relativePath);
  }

  /// Delete-phase removal for one item: files/symlinks honor
  /// `DeletionPolicy` (trash move or outright delete); an emptied
  /// directory is rmdir'd — a zero-count cleanup item. The item line
  /// carries a trashed file's location (rail 9's origin map).
  Future<_ItemOutcome> _deletePhaseEntry(
    SyncItem item,
    RemoteFileSystem destFs,
    SyncSide side,
    String destAbs,
    EntrySnapshot snapshot,
  ) async {
    // A delete* item in a no-delete plan is a differ bug, not an
    // action — refuse loudly rather than delete anything (§5: Update
    // and Additive perform no deletes by construction).
    if (rules.deletions == DeletionPolicy.none) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'delete',
        path: destAbs,
        message: 'Delete item in a no-deletion plan',
      );
    }
    final entry = RemoteFileEntry(
      path: destAbs,
      name: remoteBasename(destAbs),
      type: _remoteType(snapshot.kind),
      size: snapshot.size,
    );
    if (snapshot.kind == EntryKind.directory) {
      await destFs.delete(entry);
      await journal.appendRmdir(
        SyncJournalRmdirLine(
          relativePath: item.relativePath,
          side: side,
          parentPath: item.relativePath,
        ),
      );
      removedPaths.add(item.relativePath);
      return const _ItemOutcome();
    }
    if (rules.deletions == DeletionPolicy.permanent) {
      await destFs.delete(entry);
      removedPaths.add(item.relativePath);
      return const _ItemOutcome();
    }
    final moved = await _trashEntry(destFs, side, entry, item.relativePath);
    removedPaths.add(item.relativePath);
    return _ItemOutcome(
      trashLocation: moved.location,
      trashBytes: snapshot.size,
      trashSha256: moved.sha256,
      bytes: snapshot.size ?? 0,
    );
  }

  void _spendBudget(SyncItem item, SyncSide side, int count) {
    final remaining = removalBudget[side]!;
    if (count > remaining) {
      throw const _ItemSkipped('Skipped: deletion cap reached');
    }
    removalBudget[side] = remaining - count;
  }

  /// One trash move through the RemoteTrash seam (the D15 flat
  /// `<runId>/<seq>-<basename>` naming, seq zero-padded per run) plus
  /// §8 rail 5's copy-then-delete fallback: EXDEV-classified on a
  /// local filesystem, any non-collision rename failure on a remote
  /// one (SFTP status codes carry no errno). A copy-fallback entry
  /// returns its content digest for the journal's
  /// `trashContentSha256` — rail 9 hash-verifies it at restore.
  Future<({String location, String? sha256})> _trashEntry(
    RemoteFileSystem fs,
    SyncSide side,
    RemoteFileEntry entry,
    String parentPath,
  ) async {
    final runDir = await _runTrashDir(fs, side);
    try {
      final location = await executor._trash.moveToTrash(
        fs,
        entry,
        runDir,
        _nextSequence,
      );
      return (location: location, sha256: null);
    } on RemoteFileException catch (error) {
      final isLocal = fs is LocalFileSystem;
      final fallback = isLocal
          ? error is LocalCrossDeviceRenameException
          : error.kind != RemoteFileErrorKind.conflict;
      if (!fallback) rethrow;
      // The copy fallback needs readable content — only regular
      // files qualify; anything else surfaces the rename failure.
      if (entry.type != RemoteFileType.file) rethrow;
      final name =
          '${_nextSequence().toString().padLeft(6, '0')}-${entry.name}';
      final target = remoteJoin(runDir, name);
      final uploaded = await _transfer(
        fs,
        entry.path,
        fs,
        target,
        length: entry.size,
        overwrite: false,
      );
      await fs.delete(entry);
      return (location: target, sha256: uploaded.contentSha256);
    }
  }

  int _nextSequence() => ++_trashSequence;

  /// The run's trash directory on [side]: the in-root
  /// `.poltergeist-trash/<runId>` default or that side's out-of-root
  /// `trashPath*` (§8 rail 5), created 0700 by the RemoteTrash seam.
  Future<String> _runTrashDir(RemoteFileSystem fs, SyncSide side) async {
    final cached = _trashDirs[side];
    if (cached != null) return cached;
    final configured =
        side == SyncSide.left ? rules.trashPathLeft : rules.trashPathRight;
    final runDir = configured == null
        ? remoteJoin(
            remoteJoin(_root(side), RemoteTrash.rootDirectoryName),
            journal.record.runId,
          )
        : remoteJoin(configured, journal.record.runId);
    await executor._trash.ensureExistingRunDirectory(fs, runDir);
    return _trashDirs[side] = runDir;
  }

  /// Streams one file through the bounded pipe between two
  /// filesystems — the copy/update path and the trash copy-fallback
  /// share it (same VFS on both ends there). [computeHash] is off for
  /// transfers but on for trash copies, whose digest the journal needs.
  Future<RemoteFileEntry> _transfer(
    RemoteFileSystem srcFs,
    String srcAbs,
    RemoteFileSystem destFs,
    String destAbs, {
    required int? length,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    required bool overwrite,
    SyncItem? item,
    bool computeHash = true,
  }) async {
    final pipe = _BoundedPipe();
    final uploadFuture = destFs.upload(
      destAbs,
      pipe.stream,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      onProgress: item == null
          ? null
          : (transferred, total) =>
              _emit(SyncRunEvent.itemProgress, item, transferred, total),
      cancellation: cancellation,
      computeHash: computeHash,
    );
    // An upload that dies early leaves nobody draining the pipe —
    // fail it so the download half unblocks instead of waiting on
    // queue space forever. The catchError branch swallows nothing:
    // `await uploadFuture` below still receives the original error.
    unawaited(
      uploadFuture.then<void>(
        (_) {},
        onError: (Object error) => pipe.fail(error),
      ),
    );
    Object? downloadError;
    try {
      await srcFs.download(
        srcAbs,
        pipe,
        cancellation: cancellation,
        computeHash: false,
      );
      await pipe.close();
    } on Object catch (error) {
      downloadError = error;
      pipe.fail(error);
    }
    final uploaded = await uploadFuture;
    if (downloadError != null) throw downloadError;
    return uploaded;
  }

  /// §4's mtime preservation: setTimes(atime+mtime to the source's
  /// live values), then re-stat and journal the observed mtime.
  /// Divergence beyond tolerance — or a setTimes the filesystem
  /// refuses outright — journals `setstatIgnored` and raises that
  /// side's mtimeUnreliable flag, the data §9's sizeOnly fallback
  /// persists.
  Future<({int? observed, bool ignored})> _stampAndVerify(
    RemoteFileSystem destFs,
    SyncSide side,
    String destAbs,
    RemoteFileEntry liveSource,
  ) async {
    final sourceMtime = liveSource.modifiedAt;
    if (!rules.preserveMtime || sourceMtime == null) {
      final stat = await _statOrNull(destFs, destAbs);
      return (observed: _seconds(stat?.modifiedAt), ignored: false);
    }
    final requestedSecs = clampSftpMtimeSecs(
      sourceMtime.millisecondsSinceEpoch ~/ 1000,
    );
    try {
      await destFs.setTimes(
        destAbs,
        accessedAt: sourceMtime,
        modifiedAt: sourceMtime,
      );
    } on Object {
      _flagUnreliable(side);
      final stat = await _statOrNull(destFs, destAbs);
      return (observed: _seconds(stat?.modifiedAt), ignored: true);
    }
    final observed = await _statOrNull(destFs, destAbs);
    final observedSecs = _seconds(observed?.modifiedAt);
    final ignored =
        observedSecs == null ||
        (observedSecs - requestedSecs).abs() > rules.mtimeToleranceSecs;
    if (ignored) _flagUnreliable(side);
    return (observed: observedSecs, ignored: ignored);
  }

  void _flagUnreliable(SyncSide side) {
    if (side == SyncSide.left) {
      executor.mtimeUnreliableLeft = true;
    } else {
      executor.mtimeUnreliableRight = true;
    }
  }

  /// A live recursive listing under [destAbs], keyed by root-relative
  /// path — shared by the subtree precondition and the pre-delete
  /// removal's fallback for a missing differ snapshot.
  Future<Map<String, EntrySnapshot>> _listSubtree(
    RemoteFileSystem fs,
    String destAbs,
    String relativePath,
  ) async {
    final entries = <String, EntrySnapshot>{};
    final queue = <String>[destAbs];
    while (queue.isNotEmpty) {
      final dir = queue.removeLast();
      for (final entry in await fs.listDirectory(dir)) {
        final relative = entry.path.substring(
          destAbs.length - relativePath.length,
        );
        entries[relative] = EntrySnapshot(
          kind: switch (entry.type) {
            RemoteFileType.file => EntryKind.file,
            RemoteFileType.directory => EntryKind.directory,
            RemoteFileType.symbolicLink => EntryKind.symlink,
            RemoteFileType.other => EntryKind.other,
          },
          size: entry.size,
          mtimeSecs: _seconds(entry.modifiedAt),
          mode: entry.mode,
        );
        if (entry.isDirectory) queue.add(entry.path);
      }
    }
    return entries;
  }

  /// Strips the item's own path off a subtree key so it can join
  /// under the destination root.
  String _underPrefix(SyncItem item, String path) {
    final prefix = '${item.relativePath}/';
    return path.startsWith(prefix) ? path.substring(prefix.length) : path;
  }

  Future<RemoteFileEntry?> _statOrNull(
    RemoteFileSystem fs,
    String path,
  ) async {
    try {
      return await fs.stat(path, followLinks: false);
    } on RemoteFileException catch (error) {
      if (error.kind == RemoteFileErrorKind.notFound) return null;
      rethrow;
    }
  }

  RemoteFileSystem _fs(SyncSide side) => side == SyncSide.left
      ? executor.leftFileSystem
      : executor.rightFileSystem;

  String _root(SyncSide side) =>
      side == SyncSide.left ? executor.leftRoot : executor.rightRoot;

  String _abs(SyncSide side, String relativePath) =>
      remoteJoin(_root(side), relativePath);

  bool _distrustsMtimes(SyncRuleSet rules) => executor._distrustsMtimes(rules);

  void _emit(int kind, SyncItem? item, [int? transferred, int? total]) {
    onEvent?.call(SyncRunEvent._(kind, item, transferred, total));
  }

  Future<void> _finish() async {
    final counts = <SyncItemStatus, int>{};
    var bytesTransferred = 0;
    for (final item in plan.items) {
      counts[item.status] = (counts[item.status] ?? 0) + 1;
    }
    for (final line in journal.items) {
      bytesTransferred += line.bytes;
    }
    await journal.appendSummary(
      SyncJournalSummary(
        counts: counts,
        bytesTransferred: bytesTransferred,
        cancelled: cancelled,
        mtimeUnreliableLeft: executor.mtimeUnreliableLeft,
        mtimeUnreliableRight: executor.mtimeUnreliableRight,
      ),
    );
    _emit(SyncRunEvent.runFinished, null);
  }
}

final class _ItemOutcome {
  const _ItemOutcome({
    this.trashLocation,
    this.trashBytes,
    this.trashSha256,
    this.observedMtimeSecs,
    this.setstatIgnored = false,
    this.bytes,
  });

  /// Update-backup and delete-phase trash location — the item line's
  /// `trashLocation` (rail 9's origin map). Pre-delete removals write
  /// their own per-file trash lines instead.
  final String? trashLocation;

  /// The trashed file's own size — the journal's `trashBytes`, which
  /// restore checks against (the line's `bytes` is the written
  /// payload on update lines).
  final int? trashBytes;
  final String? trashSha256;
  final int? observedMtimeSecs;
  final bool setstatIgnored;
  final int? bytes;
}

/// Rail 7's changed-since-preview flip — a race, not a hard error.
final class _ItemConflicted implements Exception {
  const _ItemConflicted(this.message);

  final String message;
}

/// Rule 4's barrier/cap flips — the item stays whole and skips.
final class _ItemSkipped implements Exception {
  const _ItemSkipped(this.message);

  final String message;
}

/// A bounded one-way chunk pipe: the download side writes through a
/// StreamSink (backpressure applied in addStream, which both VFS
/// adapters use), the upload side reads the stream. At most
/// [_capacity] chunks buffer in memory.
final class _BoundedPipe implements StreamSink<List<int>> {
  static const int _capacity = 8;

  final Queue<List<int>> _queue = Queue<List<int>>();
  Completer<void>? _space;
  Completer<void>? _data;
  final Completer<void> _done = Completer<void>();
  Object? _error;
  var _closed = false;

  /// The upload-side stream — completes when the sink closed and the
  /// queue drained, errors when the download failed.
  Stream<List<int>> get stream async* {
    while (true) {
      while (_queue.isEmpty && !_closed && _error == null) {
        _data ??= Completer<void>();
        await _data!.future;
      }
      final error = _error;
      if (error != null) {
        _completeDone();
        throw error;
      }
      if (_queue.isEmpty) {
        _completeDone();
        return;
      }
      yield _queue.removeFirst();
      _space?.complete();
      _space = null;
    }
  }

  @override
  void add(List<int> data) {
    _queue.add(data);
    _data?.complete();
    _data = null;
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      while (_queue.length >= _capacity && _error == null) {
        _space ??= Completer<void>();
        await _space!.future;
      }
      final error = _error;
      if (error != null) throw error;
      add(chunk);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _data?.complete();
    _data = null;
  }

  /// Kills the upload half after a download-side failure — the upload
  /// stream throws, its temp is cleaned by the adapter.
  void fail(Object error) {
    _error = error;
    _data?.complete();
    _data = null;
    _space?.complete();
    _space = null;
  }

  void _completeDone() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}

RemoteFileType _remoteType(EntryKind kind) => switch (kind) {
  EntryKind.file => RemoteFileType.file,
  EntryKind.directory => RemoteFileType.directory,
  EntryKind.symlink => RemoteFileType.symbolicLink,
  EntryKind.other => RemoteFileType.other,
};

int? _seconds(DateTime? time) =>
    time == null ? null : time.millisecondsSinceEpoch ~/ 1000;
