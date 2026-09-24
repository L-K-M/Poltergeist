// The plan-view controller (05 §6–§8): owns one sync session's whole
// lifecycle — scan → diff → overrides → rails → run → retry/restore —
// and every figure the view renders. It is deliberately engine-faced:
// the widget layer never touches TreeScanner/SyncExecutor/journal, and
// tests drive the full flow against in-memory filesystems through the
// [SyncPairScanner]/[SyncPlanDiffer] seams.
//
// State machine:
//   scanning → ready ⇄ running → completed|failed|cancelled
//      ↑ rescan() rebuilds from scratch (rules edits included)
//   error — scan/environment failures, dead end until rescan()
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import 'rsync_endpoints.dart';
import 'sync_environment.dart';
import 'sync_queue_facade.dart';

/// Lifecycle phases the plan view renders.
enum SyncPlanPhase {
  scanning,
  ready,
  running,
  completed,
  failed,
  cancelled,
  error,
}

/// The header's exact figures — §7's sentence is built from these and
/// only these; the view never re-derives counts from raw items. Kept
/// override-aware: every effective-action mutation recomputes (the
/// plan's own [PlanTotals] describe the *suggested* plan).
final class SyncEffectiveStats {
  const SyncEffectiveStats({
    required this.counts,
    required this.bytes,
    required this.replacedFiles,
    required this.replacedBytes,
    required this.replacedBySide,
    required this.replacedRowsBySide,
    required this.fileDeletesBySide,
    required this.dirDeletesBySide,
  });

  /// Items per effective action class.
  final Map<SyncActionType, int> counts;

  /// Payload bytes per effective action class (the copy/update source
  /// sizes — creates and deletes carry none).
  final Map<SyncActionType, int> bytes;

  /// §6 rule 4 pre-delete removals by destination side — the rails and
  /// the Deletes chip count these per removed FILE.
  final Map<SyncSide, int> replacedBySide;

  /// §7's replace clause counts ROWS — one per replaced path — where
  /// [replacedBySide] keeps the per-file toll.
  final Map<SyncSide, int> replacedRowsBySide;
  final int replacedFiles;
  final int replacedBytes;

  /// File deletions per side — delete rows whose destination is not a
  /// directory (the §8 rail weight). Empty-directory cleanup rows stay
  /// visible under [emptyDirsOn] but count as zero file deletions.
  final Map<SyncSide, int> fileDeletesBySide;
  final Map<SyncSide, int> dirDeletesBySide;

  int countOf(SyncActionType action) => counts[action] ?? 0;
  int bytesOf(SyncActionType action) => bytes[action] ?? 0;

  /// Buckets §7's first clause enumerates, per destination side.
  int newFilesTo(SyncSide side) => switch (side) {
    SyncSide.right => countOf(SyncActionType.copyLeftToRight),
    SyncSide.left => countOf(SyncActionType.copyRightToLeft),
  };

  int updatesTo(SyncSide side) => switch (side) {
    SyncSide.right => countOf(SyncActionType.updateLeftToRight),
    SyncSide.left => countOf(SyncActionType.updateRightToLeft),
  };

  int newBytesTo(SyncSide side) => switch (side) {
    SyncSide.right => bytesOf(SyncActionType.copyLeftToRight),
    SyncSide.left => bytesOf(SyncActionType.copyRightToLeft),
  };

  int foldersTo(SyncSide side) => switch (side) {
    SyncSide.right => countOf(SyncActionType.makeDirRight),
    SyncSide.left => countOf(SyncActionType.makeDirLeft),
  };

  int deletesOn(SyncSide side) => fileDeletesBySide[side] ?? 0;

  /// Zero-file-deletion cleanup rows (05 §8: empty-directory removals
  /// are visible but count as zero file deletions on every rail).
  int emptyDirsOn(SyncSide side) => dirDeletesBySide[side] ?? 0;

  int get conflicts =>
      countOf(SyncActionType.conflict);

  /// "Both sides match. Nothing to do." — no actionable work and no
  /// pending conflict rows.
  bool get hasWork =>
      counts.entries.any(
        (entry) =>
            entry.key != SyncActionType.skip &&
            entry.key != SyncActionType.conflict &&
            entry.value > 0,
      ) ||
      conflicts > 0;
}

/// A §9 heavy-directory suggestion: on a first-run pair, when one of
/// the known noise names covers more than half the actionable items.
final class SyncHeavyDirectorySuggestion {
  const SyncHeavyDirectorySuggestion({
    required this.name,
    required this.itemCount,
  });
  final String name;
  final int itemCount;
}

/// The bulk-conflict bar's four decisions (§7).
enum SyncConflictChoice { newerWins, keepLeft, keepRight, skip }

/// The pair editor's per-side case-sensitivity overrides (05 §3/§9 —
/// the remote side's only sensitivity input). A null side means "auto":
/// local sides probe, remote sides assume case-sensitive.
final class SyncCaseOverrides {
  const SyncCaseOverrides({this.left, this.right});
  final bool? left;
  final bool? right;
}

/// The scan seam — production walks through [TreeScanner]; tests feed
/// canned [ScanResult]s. Per-side overrides arrive as arguments: the
/// pair-state rescan path re-probes with them.
abstract interface class SyncPairScanner {
  Future<ScanResult> scan(
    SyncEndpoint endpoint,
    SyncSide side,
    SyncRuleSet rules, {
    bool? caseSensitivityOverride,
    ScanCancellation? cancellation,
    void Function(int entriesScanned)? onProgress,
  });
}

/// The differ seam — production calls the engine's `diffScans`; tests
/// build plans directly.
abstract interface class SyncPlanDiffer {
  Future<SyncPlan> diff(
    ScanResult left,
    ScanResult right,
    SyncPair pair, {
    bool mtimeUnreliableLeft,
    bool mtimeUnreliableRight,
  });
}

/// The controller behind `SyncPlanView`. One instance per open sync
/// tab; the tab owns and disposes it.
final class SyncPlanController extends ChangeNotifier {
  SyncPlanController({
    required SyncPair pair,
    required SyncEnvironment environment,
    required this.syncTasks,
    SyncPairScanner? scanner,
    SyncPlanDiffer? differ,
    this.deviceId = 'local',
    SyncCaseOverrides? caseOverrides,
    // Required rather than defaulted to `resolveRsyncEndpoints`: the
    // plain resolver cannot see the shared-mode server catalog, so a
    // construction site that forgot to bind one would silently disable
    // rsync export for every serverConfigId pair. Forcing the argument
    // makes the choice visible (tests pass the plain resolver or a
    // stub; the shell binds the catalog lookup).
    required RsyncEndpointResolver rsyncEndpoints,
  // `_pair`/`_rsyncEndpoints` stay private: initializing formals would
  // make the named parameters unusable outside this library (ui/
  // constructs sessions by `pair:`/`rsyncEndpoints:`).
  // ignore: prefer_initializing_formals
  }) : _pair = pair,
       _environment = environment,
       _pendingCaseOverrides = caseOverrides,
       // ignore: prefer_initializing_formals
       _rsyncEndpoints = rsyncEndpoints,
       _scanner = scanner ?? _TreeScannerAdapter(environment),
       _differ = differ ?? _EngineDiffer(environment);

  SyncPair _pair;
  final SyncEnvironment _environment;

  /// The activity-panel registry this controller reports runs into.
  final SyncQueueTasks syncTasks;
  final SyncPairScanner _scanner;
  final SyncPlanDiffer _differ;

  /// Resolves the pair's server refs to the rsync exporter's
  /// connection-shaped endpoints (rsync_endpoints.dart); the shell
  /// binds the shared-mode catalog lookup, tests inject their own.
  final RsyncEndpointResolver _rsyncEndpoints;

  /// 04 §3.1's device identity — the runId prefix source (05 §6).
  final String deviceId;

  /// Case-sensitivity overrides awaiting application — set by the
  /// constructor (session open) and by [updatePairDefinition] (the
  /// editor's save). Applied onto each freshly loaded pair state so
  /// an override-mismatch rescan's reload cannot drop them, and
  /// persisted under the FINAL pairId — never saved under the
  /// pre-edit one. Null leaves the stored state authoritative.
  SyncCaseOverrides? _pendingCaseOverrides;

  // -- Session state -----------------------------------------------------

  SyncPlanPhase _phase = SyncPlanPhase.scanning;
  String? _errorMessage;
  RemoteFileErrorKind? _errorKind;
  SyncPlan? _plan;
  SyncEffectiveStats? _stats;
  SyncDeleteAssessment? _assessment;
  String? _pairId;
  SyncPairState _pairState = SyncPairState();
  SyncHeavyDirectorySuggestion? _heavySuggestion;
  int _scanGeneration = 0;
  ScanCancellation? _scanCancellation;
  int _leftScanned = 0;
  int _rightScanned = 0;

  /// The canonicalized roots the last scan produced — the executor and
  /// restore path run under these, never the raw endpoint spellings.
  String? _leftRoot;
  String? _rightRoot;

  // -- Run state -----------------------------------------------------------

  SyncExecutor? _executor;
  SyncRun? _lastRun;
  SyncRunPause? _pause;
  RemoteTransferCancellation? _runCancellation;
  SyncTaskBinding? _binding;

  bool _disposed = false;

  // -- Reads the view binds on -------------------------------------------

  SyncPair get pair => _pair;
  SyncPlanPhase get phase => _phase;
  String? get errorMessage => _errorMessage;
  RemoteFileErrorKind? get errorKind => _errorKind;
  SyncPlan? get plan => _plan;
  SyncEffectiveStats? get stats => _stats;
  String? get pairId => _pairId;
  SyncPairState get pairState => _pairState;
  SyncHeavyDirectorySuggestion? get heavySuggestion => _heavySuggestion;
  SyncRun? get lastRun => _lastRun;
  int get leftScanned => _leftScanned;
  int get rightScanned => _rightScanned;
  bool get isRunning => _phase == SyncPlanPhase.running;
  bool get isPaused => _pause?.isPaused ?? false;

  /// The run's rail outcome — reassessed on every effective-action
  /// change so the Run button always describes what would happen NOW.
  SyncRunGate? get gate => _assessment?.gate;

  /// Rail 3's typed `DELETE` is owed before [run] can proceed.
  bool get needsTypedConfirmation =>
      _assessment?.gate is SyncRunNeedsConfirmation;

  /// Rail 4 refuses the plan outright — Run stays disabled and the
  /// banner explains; the plan is never silently stripped.
  SyncRunRefused? get refusal =>
      _assessment?.gate is SyncRunRefused
          ? _assessment!.gate as SyncRunRefused
          : null;

  /// Whether the last run left failed work [retryFailed] can drive.
  bool get canRetryFailed =>
      _lastRun != null &&
      !isRunning &&
      _lastRun!.plan.items.any(
        (item) => item.status == SyncItemStatus.failed,
      );

  /// Restore affordance — only while the last run's journal still
  /// holds unrestored trash entries (05 §8 rail 9).
  bool get canRestore =>
      _lastRun != null && _lastRun!.journal.hasUnpurgedTrash;

  /// The configured per-side trash path, or null (in-root
  /// `.poltergeist-trash` — §8 rail 5's default location text).
  String? trashPathFor(SyncSide side) => switch (side) {
    SyncSide.left => _pair.rules.trashPathLeft,
    SyncSide.right => _pair.rules.trashPathRight,
  };

  /// Whether deletions on [side] land in trash (vs permanently).
  bool deletesToTrash(SyncSide side) =>
      _pair.rules.deletions == DeletionPolicy.trash;

  // -- Lifecycle ---------------------------------------------------------

  /// Kicks off the first scan. Called once by the tab that owns this
  /// controller; idempotent while a scan is already in flight.
  void start() {
    if (_phase != SyncPlanPhase.scanning || _scanCancellation != null) {
      return;
    }
    unawaited(_scanAndDiff());
  }

  /// Full rescan — refresh affordance and every rules edit (excludes,
  /// hidden, trash paths, direction): a fresh walk is the only honest
  /// answer to "the rules changed".
  Future<void> rescan() async {
    if (_phase == SyncPlanPhase.running) return;
    _scanCancellation?.cancel();
    await _scanAndDiff();
  }

  /// Mode-picker changes — direction/deletion policy are rule fields,
  /// so this is the same rescan path [rescan] runs; kept as its own
  /// verb so the view's intent stays legible.
  Future<void> setMode({
    SyncDirection? direction,
    DeletionPolicy? deletions,
  }) async {
    if (_phase == SyncPlanPhase.running) return;
    _pair = _pairWithRules(
      _rulesWith(
        direction: direction,
        deletions: deletions,
      ),
    );
    await rescan();
  }

  /// Options edits that change the walk (excludes, hidden files,
  /// comparison mode, conflict default, trash paths).
  Future<void> updateRules(SyncRuleSet rules) async {
    if (_phase == SyncPlanPhase.running) return;
    _pair = _pairWithRules(rules);
    await rescan();
  }

  /// The pair editor's save (05 §9): swaps the whole definition —
  /// name, endpoints, rules — plus the per-side case-sensitivity
  /// overrides that live in pair state rather than the ruleset, then
  /// rescans. An endpoint edit re-keys `sync_state` by construction
  /// (the canonical pairId is endpoint-derived).
  Future<void> updatePairDefinition(
    SyncPair pair, {
    SyncCaseOverrides? caseOverrides,
  }) async {
    if (_phase == SyncPlanPhase.running) return;
    _pair = pair;
    // The overrides land on the state the rescan loads — saving under
    // the pre-edit pairId here would write a record the post-edit
    // pairId never sees, and the rescan's load() would discard it.
    _pendingCaseOverrides = caseOverrides;
    await rescan();
  }

  /// The heavy-dir suggestion's accept affordance: add `**/{name}/` to
  /// the pair's excludes and rescan (05 §6).
  Future<void> acceptHeavySuggestion() async {
    final name = _heavySuggestion?.name;
    if (name == null) return;
    _heavySuggestion = null;
    await updateRules(
      _rulesWith(excludeGlobs: [
        ..._pair.rules.excludeGlobs,
        '**/$name/',
      ]),
    );
  }

  void dismissHeavySuggestion() {
    _heavySuggestion = null;
    notifyListeners();
  }

  // -- Overrides ---------------------------------------------------------

  /// The actions a row's glyph/menu may offer (§7): suggested, every
  /// copy direction the item's sides permit, skip, and — for the rows
  /// §7 calls out — delete. Conflicted rows admit both copy directions
  /// regardless of pair direction: the conflict IS the direction
  /// question.
  List<SyncActionType> availableOverrides(SyncItem item) {
    final actions = <SyncActionType>{item.suggested, SyncActionType.skip};
    final leftExists = item.left != null;
    final rightExists = item.right != null;
    final isConflict =
        item.suggested == SyncActionType.conflict ||
        item.effective == SyncActionType.conflict;
    final canLeftToRight =
        leftExists &&
        (isConflict ||
            _pair.rules.direction != SyncDirection.rightToLeft);
    final canRightToLeft =
        rightExists &&
        (isConflict ||
            _pair.rules.direction != SyncDirection.leftToRight);
    if (canLeftToRight) {
      // The destination-kind test picks the action — file-into-dir is
      // §6 rule 4's pre-delete carrier and only valid per-row.
      final dest = item.right;
      actions.add(
        dest == null
            ? SyncActionType.copyLeftToRight
            : dest.kind == EntryKind.directory
            ? SyncActionType.makeDirRight
            : SyncActionType.updateLeftToRight,
      );
    }
    if (canRightToLeft) {
      final dest = item.left;
      actions.add(
        dest == null
            ? SyncActionType.copyRightToLeft
            : dest.kind == EntryKind.directory
            ? SyncActionType.makeDirLeft
            : SyncActionType.updateRightToLeft,
      );
    }
    // Delete offers: Mirror only (§7 — no-delete modes authorize a
    // pre-delete only through the explicit per-row type-change action,
    // which the copy/update offers above already express).
    if (_pair.rules.deletions != DeletionPolicy.none) {
      if (rightExists) actions.add(SyncActionType.deleteRight);
      if (leftExists) actions.add(SyncActionType.deleteLeft);
    }
    return List.unmodifiable(actions);
  }

  /// Applies an effective-action override. Out-of-set actions are
  /// ignored — the menu builds from [availableOverrides], but a stale
  /// menu must never smuggle an invalid action in. No-delete modes
  /// additionally refuse any action whose destination kind differs —
  /// §6 rule 4's pre-delete is only reachable through the type-change
  /// row's own copy/update offer.
  void applyOverride(SyncItem item, SyncActionType action) {
    if (_plan == null || isRunning) return;
    if (action == item.suggested) {
      resetOverride(item);
      return;
    }
    if (!availableOverrides(item).contains(action)) return;
    if (_pair.rules.deletions == DeletionPolicy.none &&
        _isTypeChangePreDelete(item, action) &&
        item.reason != SyncReason.typeDiffers) {
      return;
    }
    item.effective = action;
    item.userOverridden = true;
    _reassess();
  }

  /// Back to the differ's proposal.
  void resetOverride(SyncItem item) {
    if (_plan == null || isRunning) return;
    item.effective = item.suggested;
    item.userOverridden = false;
    _reassess();
  }

  /// Bulk conflict decisions (§7's bar). Returns the resolved count —
  /// `newerWins` silently resolves nothing on untrusted clocks (the
  /// bar hides it then), `keepLeft`/`keepRight` skip rows whose source
  /// side is absent.
  int resolveConflicts(SyncConflictChoice choice) {
    if (_plan == null || isRunning) return 0;
    var resolved = 0;
    for (final item in _plan!.items) {
      if (item.suggested != SyncActionType.conflict &&
          item.effective != SyncActionType.conflict) {
        continue;
      }
      final action = switch (choice) {
        SyncConflictChoice.skip => SyncActionType.skip,
        SyncConflictChoice.keepLeft =>
          item.left != null ? _keepResolution(item, SyncSide.left) : null,
        SyncConflictChoice.keepRight =>
          item.right != null ? _keepResolution(item, SyncSide.right) : null,
        SyncConflictChoice.newerWins => _newerWinsAction(item),
      };
      if (action == null) continue;
      // The bulk bar follows the bulk-override rules (§7): only the
      // row's offered actions, and in a no-delete mode a rule-4
      // pre-delete stays per-item-only — a typeDiffers row keeps its
      // conflict until the user picks it per-row.
      if (!availableOverrides(item).contains(action)) continue;
      if (_pair.rules.deletions == DeletionPolicy.none &&
          _isTypeChangePreDelete(item, action)) {
        continue;
      }
      item.effective = action;
      item.userOverridden = true;
      resolved++;
    }
    if (resolved > 0) _reassess();
    return resolved;
  }

  /// What the differ's `_keepSide` decides (diff.dart): a one-way pair
  /// never writes its destination side, so keeping that side resolves
  /// to a deliberate skip — never a counter-direction write.
  SyncActionType _keepResolution(SyncItem item, SyncSide keep) {
    final writesRight = keep == SyncSide.left;
    final permitted = switch (_pair.rules.direction) {
      SyncDirection.bidirectional => true,
      SyncDirection.leftToRight => writesRight,
      SyncDirection.rightToLeft => !writesRight,
    };
    if (!permitted) return SyncActionType.skip;
    return _copyAction(
      item,
      keep == SyncSide.left ? SyncSide.right : SyncSide.left,
    );
  }

  SyncActionType _copyAction(SyncItem item, SyncSide destination) {
    final dest = destination == SyncSide.left ? item.left : item.right;
    return switch ((destination, dest)) {
      (SyncSide.right, null) => SyncActionType.copyLeftToRight,
      (SyncSide.left, null) => SyncActionType.copyRightToLeft,
      (SyncSide.right, EntrySnapshot(kind: EntryKind.directory)) =>
        SyncActionType.makeDirRight,
      (SyncSide.left, EntrySnapshot(kind: EntryKind.directory)) =>
        SyncActionType.makeDirLeft,
      (SyncSide.right, _) => SyncActionType.updateLeftToRight,
      (SyncSide.left, _) => SyncActionType.updateRightToLeft,
    };
  }

  SyncActionType? _newerWinsAction(SyncItem item) {
    // §7 hides the button on untrusted clocks — the verb honors the
    // same guard so a direct call can't trust a clock the engine
    // itself flagged.
    if (!offersNewerWins) return null;
    final left = item.left?.mtimeSecs;
    final right = item.right?.mtimeSecs;
    if (left == null || right == null) return null;
    // EntryComparator semantics: out-of-range originals compare
    // clamped, and a delta inside mtimeToleranceSecs (or within
    // tolerance of an accepted shift) is equal — not "newer".
    final (l, r) = sftpMtimeInRange(left) && sftpMtimeInRange(right)
        ? (left, right)
        : (clampSftpMtimeSecs(left), clampSftpMtimeSecs(right));
    final delta = (l - r).abs();
    final tolerance = _pair.rules.mtimeToleranceSecs;
    final equal = delta <= tolerance ||
        _pair.rules.acceptedTimeShifts.any(
          (shift) => (delta - shift).abs() <= tolerance,
        );
    if (equal) return null;
    return _keepResolution(item, l > r ? SyncSide.left : SyncSide.right);
  }

  /// Whether `newerWins` may be offered — §7 hides it when mtimes are
  /// untrusted or `preserveMtime` is off.
  bool get offersNewerWins =>
      _pair.rules.preserveMtime &&
      !_pairState.mtimeUnreliableLeft &&
      !_pairState.mtimeUnreliableRight;

  /// §4's automatic fallback: a `sizeAndMtime` pair with either
  /// `mtimeUnreliable` flag recorded compares `sizeOnly` from then on.
  /// `contentHash` is never downgraded — hashes do not depend on
  /// mtimes — and an explicit `sizeOnly` pair needs no rewrite.
  bool get _downgradesToSizeOnly =>
      _pair.rules.comparison == ComparisonMode.sizeAndMtime &&
      (_pairState.mtimeUnreliableLeft || _pairState.mtimeUnreliableRight);

  /// The `sync.copyRsyncCommand` enablement probe (05 §2.1): true when
  /// [rsyncExport] would produce text — a settled plan exists and every
  /// remote side resolves. Cheap: no string is built.
  bool get canExportRsync =>
      _exportablePlan != null && _rsyncEndpoints(_pair) != null;

  /// The plan export may quote: settled only. During `scanning`/`error`
  /// `_plan` can hold a PREVIOUS scan's result while `_pair.rules` have
  /// already moved on — exporting the mix would render new rules against
  /// a stale plan's skip paths.
  SyncPlan? get _exportablePlan => switch (_phase) {
    SyncPlanPhase.scanning || SyncPlanPhase.error => null,
    _ => _plan,
  };

  /// §2.1's "Copy as rsync command" body: the EFFECTIVE ruleset
  /// rendered as the commented rsync block — §4's `mtimeUnreliable`
  /// downgrade resolved here because it lives in sync_state, outside
  /// the ruleset. Null when there is no plan yet or a remote side's
  /// `serverConfigId` resolves to nothing (shared-mode catalog not
  /// pulled) — the caller hides the affordance rather than emit a
  /// silently wrong command. [now] is a seam so the timestamped
  /// backup-dir stays deterministic under test.
  ({String text, bool permanentDeletions})? rsyncExport({DateTime? now}) {
    final plan = _exportablePlan;
    if (plan == null) return null;
    final endpoints = _rsyncEndpoints(_pair);
    if (endpoints == null) return null;
    final downgraded = _downgradesToSizeOnly;
    final rules = downgraded
        ? _rulesWith(comparison: ComparisonMode.sizeOnly)
        : _pair.rules;
    return (
      text: buildRsyncCommand(
        endpoints,
        rules,
        manualOverrides:
            plan.items.where((item) => item.userOverridden).length,
        mtimesUntrusted: downgraded,
        engineSkipPaths: rsyncEngineSkipPaths(plan),
        now: now ?? DateTime.now(),
      ),
      permanentDeletions:
          rules.deletions == DeletionPolicy.permanent &&
          rules.backups == BackupPolicy.none,
    );
  }

  /// Bulk override on a multi-selection (§7: same menu). Returns the
  /// rows the action could not apply to — Update/Additive bulk copies
  /// skip type-different rows rather than authorizing a pre-delete the
  /// user never saw per-row.
  List<SyncItem> applyOverrideTo(
    Iterable<SyncItem> items,
    SyncActionType action,
  ) {
    if (_plan == null || isRunning) return const [];
    final skipped = <SyncItem>[];
    var changed = false;
    for (final item in items) {
      if (action == item.suggested) {
        if (item.userOverridden) {
          item.effective = item.suggested;
          item.userOverridden = false;
          changed = true;
        }
        continue;
      }
      if (!availableOverrides(item).contains(action) ||
          (_pair.rules.deletions == DeletionPolicy.none &&
              _isTypeChangePreDelete(item, action))) {
        skipped.add(item);
        continue;
      }
      item.effective = action;
      item.userOverridden = true;
      changed = true;
    }
    if (changed) _reassess();
    return List.unmodifiable(skipped);
  }

  /// Whether the item's EFFECTIVE action carries a §6 rule-4
  /// pre-delete — the Deletes filter bucket and chip count these rows
  /// with their removed-file toll (§7's badge bookkeeping).
  bool itemCarriesPreDelete(SyncItem item) =>
      _isTypeChangePreDelete(item, item.effective);

  /// §6 rule 4's test: the effective action creates/copies over a
  /// destination of a different kind, which the executor will
  /// pre-delete.
  bool _isTypeChangePreDelete(SyncItem item, SyncActionType action) {
    final dest = switch (action) {
      SyncActionType.copyLeftToRight ||
      SyncActionType.updateLeftToRight ||
      SyncActionType.makeDirRight => item.right,
      SyncActionType.copyRightToLeft ||
      SyncActionType.updateRightToLeft ||
      SyncActionType.makeDirLeft => item.left,
      _ => null,
    };
    final src = switch (action) {
      SyncActionType.copyLeftToRight ||
      SyncActionType.updateLeftToRight ||
      SyncActionType.makeDirRight => item.left,
      SyncActionType.copyRightToLeft ||
      SyncActionType.updateRightToLeft ||
      SyncActionType.makeDirLeft => item.right,
      _ => null,
    };
    if (dest == null || src == null) return false;
    final createsDir = src.kind == EntryKind.directory;
    return createsDir
        ? dest.kind != EntryKind.directory
        : dest.kind != EntryKind.file;
  }

  /// Every override-backed mutation lands here: recompute the
  /// override-aware figures and the rails the run button reads.
  void _reassess() {
    final plan = _plan;
    if (plan == null) return;
    _stats = computeSyncEffectiveStats(plan);
    _assessment = assessDeletions(plan);
    notifyListeners();
  }

  // -- Scan → diff -------------------------------------------------------

  Future<void> _scanAndDiff() async {
    final generation = ++_scanGeneration;
    _scanCancellation = ScanCancellation();
    // A rescan renders a NEW plan — the previous run's journal/retry
    // belong to the plan the user is no longer reviewing (rail 1).
    _lastRun = null;
    _binding?.retry = null;
    _phase = SyncPlanPhase.scanning;
    _errorMessage = null;
    _errorKind = null;
    _leftScanned = 0;
    _rightScanned = 0;
    notifyListeners();
    try {
      var left = await _scanSide(SyncSide.left, _scanCancellation!);
      var right = await _scanSide(SyncSide.right, _scanCancellation!);
      if (_disposed || generation != _scanGeneration) return;
      _leftRoot = left.rootPath;
      _rightRoot = right.rootPath;
      _pairId = _computePairId(left, right);
      _pairState = await _environment.states.load(_pairId!);
      // A definition-time override (pair editor) supersedes the stored
      // flags — the editor is the remote side's only sensitivity input.
      _applyPendingCaseOverrides();
      // A stored per-side override that disagrees with the scan's
      // answer rescans that side under the override — once — and the
      // pairId settles on the override answers.
      final leftOverride = _pairState.caseSensitiveOverrideLeft;
      final rightOverride = _pairState.caseSensitiveOverrideRight;
      if ((leftOverride != null && leftOverride != left.caseSensitive) ||
          (rightOverride != null && rightOverride != right.caseSensitive)) {
        left = await _scanSide(
          SyncSide.left,
          _scanCancellation!,
          caseSensitivityOverride: leftOverride,
        );
        right = await _scanSide(
          SyncSide.right,
          _scanCancellation!,
          caseSensitivityOverride: rightOverride,
        );
        if (_disposed || generation != _scanGeneration) return;
        _leftRoot = left.rootPath;
        _rightRoot = right.rootPath;
        _pairId = _computePairId(left, right);
        _pairState = await _environment.states.load(_pairId!);
        // The reload returned a different state record — re-apply the
        // pending overrides so they persist under this pairId.
        _applyPendingCaseOverrides();
      }
      _pairState.touchedAt = DateTime.now().toUtc();
      await _environment.states.save(_pairId!, _pairState);
      _pendingCaseOverrides = null;
      _plan = await _differ.diff(
        left,
        right,
        // §4's automatic fallback lives in sync_state, outside the
        // ruleset — resolve it here exactly as rsyncExport does, so a
        // flagged pair's next plan compares size-only instead of
        // re-proposing every refused stamp as an update forever.
        _downgradesToSizeOnly
            ? _pairWithRules(
                _rulesWith(comparison: ComparisonMode.sizeOnly),
              )
            : _pair,
        mtimeUnreliableLeft: _pairState.mtimeUnreliableLeft,
        mtimeUnreliableRight: _pairState.mtimeUnreliableRight,
      );
      if (_disposed || generation != _scanGeneration) return;
      _suggestHeavyDirectory();
      _phase = SyncPlanPhase.ready;
      _reassess();
    } catch (error) {
      if (_disposed || generation != _scanGeneration) return;
      _phase = SyncPlanPhase.error;
      _errorMessage = error is RemoteFileException
          ? error.message
          : error.toString();
      _errorKind = error is RemoteFileException
          ? error.kind
          : RemoteFileErrorKind.other;
      notifyListeners();
    } finally {
      if (generation == _scanGeneration) _scanCancellation = null;
    }
  }

  Future<ScanResult> _scanSide(
    SyncSide side,
    ScanCancellation cancellation, {
    bool? caseSensitivityOverride,
  }) {
    final endpoint = side == SyncSide.left ? _pair.left : _pair.right;
    return _scanner.scan(
      endpoint,
      side,
      _pair.rules,
      caseSensitivityOverride: caseSensitivityOverride,
      cancellation: cancellation,
      onProgress: (count) {
        if (side == SyncSide.left) {
          _leftScanned = count;
        } else {
          _rightScanned = count;
        }
        if (!_disposed) notifyListeners();
      },
    );
  }

  /// §9: the pairId's fold flags settle from THIS scan's
  /// case-sensitivity answers. Normalization insensitivity rides the
  /// probe record in pair state — the scan reports no form verdict of
  /// its own, so the flags come from the cached record only. One
  /// helper for both call sites so the override-mismatch recompute
  /// cannot drop a flag the first computation passed.
  String _computePairId(ScanResult left, ScanResult right) => syncPairId(
    _pair,
    leftCaseInsensitive: !left.caseSensitive,
    rightCaseInsensitive: !right.caseSensitive,
    leftNormalizationInsensitive: _pairState
            .caseProbe[left.rootPath]
            ?.normalizationInsensitive ??
        false,
    rightNormalizationInsensitive: _pairState
            .caseProbe[right.rootPath]
            ?.normalizationInsensitive ??
        false,
  );

  /// Writes the pending definition-time overrides onto the loaded
  /// pair state — a null side clears the stored flag (the editor's
  /// 'auto' choice is authoritative).
  void _applyPendingCaseOverrides() {
    final pending = _pendingCaseOverrides;
    if (pending == null) return;
    _pairState.caseSensitiveOverrideLeft = pending.left;
    _pairState.caseSensitiveOverrideRight = pending.right;
  }

  /// First-run suggestion (§9): a known heavy name covering more than
  /// half the actionable items.
  void _suggestHeavyDirectory() {
    _heavySuggestion = null;
    final plan = _plan;
    if (plan == null || _pairState.lastRunAt != null) return;
    const names = {'node_modules', '.git', 'build', 'target', '__pycache__'};
    final actionable = plan.items
        .where(
          (item) =>
              item.effective != SyncActionType.skip &&
              item.effective != SyncActionType.conflict,
        )
        .toList();
    if (actionable.length < 10) return;
    final perName = <String, int>{};
    for (final item in actionable) {
      for (final segment in item.relativePath.split('/')) {
        if (names.contains(segment)) {
          perName[segment] = (perName[segment] ?? 0) + 1;
          break;
        }
      }
    }
    for (final entry in perName.entries) {
      if (entry.value * 2 > actionable.length) {
        _heavySuggestion = SyncHeavyDirectorySuggestion(
          name: entry.key,
          itemCount: entry.value,
        );
        return;
      }
    }
  }

  // -- Run ---------------------------------------------------------------

  /// Runs the reviewed plan. The typed confirmation is a VIEW concern:
  /// when [needsTypedConfirmation] the view collects `DELETE` first and
  /// calls [run] with [deleteConfirmed]; a call without it re-surfaces
  /// the gate rather than executing.
  Future<void> run({bool deleteConfirmed = false}) async {
    final plan = _plan;
    if (plan == null || isRunning || _disposed) return;
    _reassess();
    if (_assessment!.gate is SyncRunRefused) return;
    if (_assessment!.gate is SyncRunNeedsConfirmation &&
        !deleteConfirmed) {
      notifyListeners();
      return;
    }
    _phase = SyncPlanPhase.running;
    _pause = SyncRunPause();
    _runCancellation = RemoteTransferCancellation();
    // A fresh run supersedes the previous task row — its retry verb
    // must not keep routing into the newest _lastRun.
    _binding?.retry = null;
    notifyListeners();
    try {
      final executor = _buildExecutor();
      _executor = executor;
      _binding = syncTasks.beginTask(
        spec: _taskSpec(),
        plan: plan,
        pause: _pause!,
        cancellation: _runCancellation!,
        retry: retryFailed,
      );
      final run = await executor.run(
        plan,
        pairId: _pairId ?? _pair.id,
        deleteConfirmationAcknowledged: deleteConfirmed,
        cancellation: _runCancellation,
        pause: _pause,
        onEvent: _onRunEvent,
      );
      _lastRun = run;
      // A cancelled run is not a sync — 'last synced', the heavy-dir
      // suppression, and the 90-day ad-hoc prune all key on real work.
      if (!run.cancelled) {
        _pairState.lastRunAt = DateTime.now().toUtc();
      }
      // §9: the executor's write-back verification refreshes the
      // untrust flags — persist what the run observed, not the inputs.
      _pairState.mtimeUnreliableLeft = run.mtimeUnreliableLeft;
      _pairState.mtimeUnreliableRight = run.mtimeUnreliableRight;
      _pairState.touchedAt = DateTime.now().toUtc();
      await _environment.states.save(_pairId ?? _pair.id, _pairState);
      if (_disposed) return;
      _finishRunPhase(run);
      notifyListeners();
    } on SyncRunRefusedException catch (refused) {
      // Rail 4 re-checked inside the executor — surface the refusal,
      // never a stripped run.
      _phase = SyncPlanPhase.ready;
      _assessment = SyncDeleteAssessment(
        removals: _assessment?.removals ?? const {},
        sideEntries: _assessment?.sideEntries ?? const {},
        gate: refused.gate,
      );
      notifyListeners();
    } on SyncConfirmationRequiredException {
      // The gate tripped between the dialog and the run — re-render
      // the confirmation requirement.
      _phase = SyncPlanPhase.ready;
      _reassess();
    } catch (error) {
      if (_disposed) return;
      _phase = SyncPlanPhase.failed;
      _errorMessage = error is RemoteFileException
          ? error.message
          : error.toString();
      _binding?.emitTaskState(
        TransferTaskState.failed,
        error: _errorMessage,
      );
      notifyListeners();
    }
  }

  /// §8's Retry Failed — same run id's next attempt through
  /// `SyncExecutor.retryFailed`; the panel's retry verb lands here too.
  Future<void> retryFailed() async {
    final executor = _executor;
    final lastRun = _lastRun;
    if (executor == null || lastRun == null || isRunning || _disposed) {
      return;
    }
    _phase = SyncPlanPhase.running;
    _pause = SyncRunPause();
    _runCancellation = RemoteTransferCancellation();
    // The retry mints fresh run controls — rebind so the panel row's
    // pause/cancel drive the live attempt, not the dead run's objects;
    // flip the row back to running so those verbs stay reachable.
    _binding?.rebind(
      pause: _pause!,
      cancellation: _runCancellation!,
    );
    _binding?.emitTaskState(TransferTaskState.running);
    notifyListeners();
    try {
      final run = await executor.retryFailed(
        lastRun,
        pause: _pause,
        cancellation: _runCancellation,
        onEvent: _onRunEvent,
      );
      _lastRun = run;
      if (!run.cancelled) {
        _pairState.lastRunAt = DateTime.now().toUtc();
      }
      _pairState.mtimeUnreliableLeft = run.mtimeUnreliableLeft;
      _pairState.mtimeUnreliableRight = run.mtimeUnreliableRight;
      _pairState.touchedAt = DateTime.now().toUtc();
      await _environment.states.save(_pairId ?? _pair.id, _pairState);
      if (_disposed) return;
      _finishRunPhase(run);
      notifyListeners();
    } catch (error) {
      if (_disposed) return;
      _phase = SyncPlanPhase.failed;
      _errorMessage = error.toString();
      _binding?.emitTaskState(
        TransferTaskState.failed,
        error: _errorMessage,
      );
      notifyListeners();
    }
  }

  /// A run's terminal phase — cancelled beats per-item failures (a
  /// cancelled run's pending items flip skipped, not failed).
  void _finishRunPhase(SyncRun run) {
    final failed = run.plan.items.any(
      (item) =>
          item.status == SyncItemStatus.failed ||
          item.status == SyncItemStatus.conflicted,
    );
    _phase = run.cancelled
        ? SyncPlanPhase.cancelled
        : failed
        ? SyncPlanPhase.failed
        : SyncPlanPhase.completed;
    _binding?.emitTaskState(
      switch (_phase) {
        SyncPlanPhase.completed => TransferTaskState.completed,
        SyncPlanPhase.cancelled => TransferTaskState.cancelled,
        _ => TransferTaskState.failed,
      },
      error: failed ? _firstItemError(run) : null,
    );
  }

  String? _firstItemError(SyncRun run) {
    for (final item in run.plan.items) {
      if (item.status == SyncItemStatus.failed) return item.error;
    }
    return null;
  }

  /// Rail 9's restore: trashed/backed-up files return to their
  /// journaled origins, conflict-checked against post-state.
  Future<SyncRestoreReport> restoreTrashed() async {
    final run = _lastRun;
    if (run == null || isRunning) {
      return const SyncRestoreReport(restored: [], skipped: []);
    }
    return restoreTrashedFiles(
      run.journal,
      fsFor: (side) => _environment.fileSystemFor(
        side == SyncSide.left ? _pair.left : _pair.right,
      ),
      rootFor: (side) =>
          (side == SyncSide.left ? _leftRoot : _rightRoot) ??
          _environment.rootFor(
            side == SyncSide.left ? _pair.left : _pair.right,
          ),
    );
  }

  /// The panel's pause/resume verb → the run's between-items gate.
  void setPaused(bool paused) {
    if (!isRunning || _pause == null) return;
    paused ? _pause!.pause() : _pause!.resume();
    _binding?.emitTaskState(
      paused ? TransferTaskState.paused : TransferTaskState.running,
    );
    notifyListeners();
  }

  /// The panel's cancel verb → sticky run cancellation.
  void cancelRun() {
    _runCancellation?.cancel();
  }

  // -- Executor wiring -----------------------------------------------------

  SyncExecutor _buildExecutor() {
    // Remote endpoints throw the typed `unsupported` refusal inside
    // fileSystemFor — the run surfaces it as a failed state, never a
    // simulated transfer.
    final leftFs = _environment.fileSystemFor(_pair.left);
    final rightFs = _environment.fileSystemFor(_pair.right);
    return SyncExecutor(
      leftFileSystem: leftFs,
      rightFileSystem: rightFs,
      leftRoot: _leftRoot ?? _environment.rootFor(_pair.left),
      rightRoot: _rightRoot ?? _environment.rootFor(_pair.right),
      syncRunsDirectory: _environment.syncRunsDirectory,
      deviceId: deviceId,
      mtimeUnreliableLeft: _pairState.mtimeUnreliableLeft,
      mtimeUnreliableRight: _pairState.mtimeUnreliableRight,
    );
  }

  /// The one-row activity-panel task — a sync session rendered through
  /// the transfer vocabulary (route = left root → right root).
  TransferTaskSpec _taskSpec() {
    FsLocation locationFor(SyncEndpoint endpoint) => switch (endpoint) {
      LocalEndpoint() => const LocalFsLocation(),
      RemoteEndpoint(:final server) => ServerFsLocation(
        server.serverConfigId ?? 'remote',
      ),
    };
    return TransferTaskSpec(
      source: locationFor(_pair.left),
      destination: locationFor(_pair.right),
      rootPaths: [_leftRoot ?? _environment.rootFor(_pair.left)],
      destinationDir: _rightRoot ?? _environment.rootFor(_pair.right),
      policy: ResolvedConflictPolicy(),
    );
  }

  /// Executor events → item rows + notify. The item objects are the
  /// plan's — status reads re-render through the same list.
  void _onRunEvent(SyncRunEvent event) {
    final binding = _binding;
    switch (event.kind) {
      case SyncRunEvent.itemStarted:
        final item = event.item;
        if (item != null) binding?.emitItemStarted(item);
      case SyncRunEvent.itemProgress:
        final item = event.item;
        if (item != null) {
          binding?.emitProgress(
            item.relativePath,
            event.transferred ?? 0,
            event.total,
          );
        }
      case SyncRunEvent.itemFinished:
        final item = event.item;
        if (item != null) binding?.emitItemFinished(item);
      case SyncRunEvent.runFinished:
        break; // the terminal task event lands via _finishRunPhase
    }
    if (!_disposed) notifyListeners();
  }

  // -- Pair/rules rebuilds -------------------------------------------------

  SyncPair _pairWithRules(SyncRuleSet rules) => SyncPair(
    id: _pair.id,
    name: _pair.name,
    left: _pair.left,
    right: _pair.right,
    rules: rules,
    lastRunAt: _pair.lastRunAt,
  );

  /// The few edits the view makes go through this one place: the
  /// package's [SyncRuleSet.copyWith] keeps every other field, and the
  /// bidirectional × deletions invariant collapses here — dropping the
  /// deletion policy when the direction no longer admits it.
  SyncRuleSet _rulesWith({
    SyncDirection? direction,
    DeletionPolicy? deletions,
    List<String>? excludeGlobs,
    ComparisonMode? comparison,
  }) {
    final rules = _pair.rules;
    final nextDirection = direction ?? rules.direction;
    return rules.copyWith(
      direction: nextDirection,
      deletions: nextDirection == SyncDirection.bidirectional
          ? DeletionPolicy.none
          : deletions ?? rules.deletions,
      comparison: comparison,
      excludeGlobs: excludeGlobs,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _scanCancellation?.cancel();
    _runCancellation?.cancel();
    _pause?.resume();
    super.dispose();
  }
}

/// [SyncPairScanner] over the real [TreeScanner] + [SyncEnvironment].
final class _TreeScannerAdapter implements SyncPairScanner {
  _TreeScannerAdapter(this._environment);
  final SyncEnvironment _environment;

  @override
  Future<ScanResult> scan(
    SyncEndpoint endpoint,
    SyncSide side,
    SyncRuleSet rules, {
    bool? caseSensitivityOverride,
    ScanCancellation? cancellation,
    void Function(int entriesScanned)? onProgress,
  }) {
    final fs = _environment.fileSystemFor(endpoint);
    final root = _environment.rootFor(endpoint);
    final trashPath = side == SyncSide.left
        ? rules.trashPathLeft
        : rules.trashPathRight;
    return TreeScanner(fs).scan(
      root,
      side: side,
      rules: rules,
      trashPath: trashPath,
      caseSensitivityOverride: caseSensitivityOverride,
      probeCaseSensitivity: caseSensitivityOverride == null,
      cancellation: cancellation,
      onProgress: onProgress,
    );
  }
}

/// [SyncPlanDiffer] over the engine's `diffScans`.
final class _EngineDiffer implements SyncPlanDiffer {
  _EngineDiffer(this._environment);
  final SyncEnvironment _environment;

  @override
  Future<SyncPlan> diff(
    ScanResult left,
    ScanResult right,
    SyncPair pair, {
    bool mtimeUnreliableLeft = false,
    bool mtimeUnreliableRight = false,
  }) {
    RemoteFileSystem? fsFor(SyncEndpoint endpoint) =>
        _environment.endpointAvailable(endpoint)
        ? _environment.fileSystemFor(endpoint)
        : null;
    return diffScans(
      left: left,
      right: right,
      pair: pair,
      mtimeUnreliableLeft: mtimeUnreliableLeft,
      mtimeUnreliableRight: mtimeUnreliableRight,
      leftFileSystem: fsFor(pair.left),
      rightFileSystem: fsFor(pair.right),
    );
  }
}

/// Recomputes §7's header figures from effective actions — the plan's
/// diff-time [PlanTotals] describe the *suggested* plan; the sentence,
/// the filter chips, and the run button follow what would actually
/// run. Public for tests and the format layer's clause builder.
SyncEffectiveStats computeSyncEffectiveStats(SyncPlan plan) {
  final counts = <SyncActionType, int>{};
  final bytes = <SyncActionType, int>{};
  final replacedBySide = <SyncSide, int>{SyncSide.left: 0, SyncSide.right: 0};
  final replacedRowsBySide = <SyncSide, int>{
    SyncSide.left: 0,
    SyncSide.right: 0,
  };
  final fileDeletes = <SyncSide, int>{SyncSide.left: 0, SyncSide.right: 0};
  final dirDeletes = <SyncSide, int>{SyncSide.left: 0, SyncSide.right: 0};
  var replacedFiles = 0;
  var replacedBytes = 0;
  for (final item in plan.items) {
    counts[item.effective] = (counts[item.effective] ?? 0) + 1;
    // Delete-phase rows split by destination kind: files count on the
    // rails and the delete clause; directories are the zero-weight
    // empty-cleanup clause.
    switch (item.effective) {
      case SyncActionType.deleteLeft:
        final map = item.left?.kind == EntryKind.directory
            ? dirDeletes
            : fileDeletes;
        map[SyncSide.left] = map[SyncSide.left]! + 1;
      case SyncActionType.deleteRight:
        final map = item.right?.kind == EntryKind.directory
            ? dirDeletes
            : fileDeletes;
        map[SyncSide.right] = map[SyncSide.right]! + 1;
      default:
        break;
    }
    final source = switch (item.effective) {
      SyncActionType.copyLeftToRight ||
      SyncActionType.updateLeftToRight ||
      SyncActionType.makeDirRight => item.left,
      SyncActionType.copyRightToLeft ||
      SyncActionType.updateRightToLeft ||
      SyncActionType.makeDirLeft => item.right,
      _ => null,
    };
    if (source != null && source.kind != EntryKind.directory) {
      bytes[item.effective] =
          (bytes[item.effective] ?? 0) + (source.size ?? 0);
    }
    // Rule-4 pre-delete weight — same accounting the rails use, so the
    // replace clause and the confirm dialog agree.
    final destSide = switch (item.effective) {
      SyncActionType.copyLeftToRight ||
      SyncActionType.updateLeftToRight ||
      SyncActionType.makeDirRight => SyncSide.right,
      SyncActionType.copyRightToLeft ||
      SyncActionType.updateRightToLeft ||
      SyncActionType.makeDirLeft => SyncSide.left,
      _ => null,
    };
    if (destSide == null) continue;
    final dest = destSide == SyncSide.left ? item.left : item.right;
    if (dest == null) continue;
    final typeChange = switch (item.effective) {
      SyncActionType.makeDirLeft || SyncActionType.makeDirRight =>
        dest.kind != EntryKind.directory,
      SyncActionType.copyLeftToRight ||
      SyncActionType.copyRightToLeft ||
      SyncActionType.updateLeftToRight ||
      SyncActionType.updateRightToLeft => dest.kind != EntryKind.file,
      _ => false,
    };
    if (!typeChange) continue;
    var weight = 0;
    var weightBytes = 0;
    if (dest.kind == EntryKind.directory) {
      for (final snapshot
          in item.destinationSubtree?.values ?? const <EntrySnapshot>[]) {
        if (snapshot.kind != EntryKind.directory) {
          weight++;
          weightBytes += snapshot.size ?? 0;
        }
      }
    } else {
      weight = 1;
      weightBytes = dest.size ?? 0;
    }
    replacedFiles += weight;
    replacedBytes += weightBytes;
    replacedBySide[destSide] = replacedBySide[destSide]! + weight;
    replacedRowsBySide[destSide] = replacedRowsBySide[destSide]! + 1;
  }
  return SyncEffectiveStats(
    counts: counts,
    bytes: bytes,
    replacedFiles: replacedFiles,
    replacedBytes: replacedBytes,
    replacedBySide: replacedBySide,
    replacedRowsBySide: replacedRowsBySide,
    fileDeletesBySide: fileDeletes,
    dirDeletesBySide: dirDeletes,
  );
}
