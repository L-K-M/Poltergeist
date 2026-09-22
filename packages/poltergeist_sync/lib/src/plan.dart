// The sync plan model (05 §6) — the shared vocabulary the scanner,
// differ, executor, journal, and preview all speak. Data only: no scan,
// diff, or execution behavior lives here.

import 'package:poltergeist_core/poltergeist_core.dart';

/// A saved, bookmarkable sync definition. Persisted as the savedSync
/// bookmark kind (04) and synced via Séance's E2E server like bookmarks.
class SyncPair {
  SyncPair({
    required this.id,
    required this.name,
    required this.left,
    required this.right,
    required this.rules,
    this.lastRunAt,
  });

  /// uuidV4() from seance_protocol.
  final String id;

  /// e.g. "Blog -> webserver".
  final String name;
  final SyncEndpoint left;
  final SyncEndpoint right;
  final SyncRuleSet rules;

  /// Local metadata (sync_state), not synced.
  final DateTime? lastRunAt;
}

sealed class SyncEndpoint {
  const SyncEndpoint();
}

class LocalEndpoint extends SyncEndpoint {
  const LocalEndpoint(this.path);
  final String path;
}

class RemoteEndpoint extends SyncEndpoint {
  const RemoteEndpoint({required this.server, required this.path});

  /// 04 §2.1 — BookmarkServerRef is serverConfigId XOR
  /// EmbeddedHostIdentity; creds resolve via the vault, never embedded.
  /// Ad-hoc pairs (built from the panes, 05 §7/§9) always carry the
  /// EmbeddedHostIdentity form.
  final BookmarkServerRef server;
  final String path;
}

enum SyncDirection { leftToRight, rightToLeft, bidirectional }

/// trash = D15, 05 §8.
enum DeletionPolicy { none, trash, permanent }

/// Overwrite backups, 05 §8.
enum BackupPolicy { trash, none }

enum ComparisonMode { sizeAndMtime, sizeOnly, contentHash }

enum ConflictDefault { ask, newerWins, keepLeft, keepRight, skip }

/// v1 ships `skip` only; `copyAsLink`/`follow` are reserved for v2.
enum SymlinkPolicy { skip, copyAsLink, follow }

enum EntryKind { file, directory, symlink, other }

/// Which side of a pair a warning or journal line belongs to.
enum SyncSide { left, right }

enum SyncActionType {
  /// Create at destination.
  copyLeftToRight,
  copyRightToLeft,

  /// Overwrite (backs up per policy).
  updateLeftToRight,
  updateRightToLeft,
  makeDirLeft,
  makeDirRight,

  /// Honors DeletionPolicy.
  deleteLeft,
  deleteRight,

  /// Equal, excluded, symlink (v1 SymlinkPolicy), or user-skipped —
  /// rule 3's delete gate exempts them all.
  skip,

  /// Needs a decision (or default).
  conflict,
}

enum SyncReason {
  onlyOnLeft,
  onlyOnRight,
  newerOnLeft,
  newerOnRight,
  sizeDiffers,
  contentDiffers,

  /// File vs dir vs symlink at one path.
  typeDiffers,
  excluded,
  equal,
  bothChanged,
  caseCollision,
  normalizationCollision,
  invalidNameOnDestination,
  scanError,
}

enum SyncItemStatus {
  pending,
  running,
  done,
  failed,
  skipped,

  /// Rail 7's changed-since-preview flip — a race, not a hard error, but
  /// it gates rule 3's delete phase like a failure.
  conflicted,
}

class SyncRuleSet {
  const SyncRuleSet({
    this.direction = SyncDirection.leftToRight,
    this.deletions = DeletionPolicy.none,
    this.backups = BackupPolicy.trash,
    this.comparison = ComparisonMode.sizeAndMtime,
    int mtimeToleranceSecs = 2,
    this.acceptedTimeShifts = const [],
    this.conflictDefault = ConflictDefault.ask,
    this.excludeGlobs = const [],
    this.includeHidden = true,
    this.symlinks = SymlinkPolicy.skip,
    this.trashPathLeft,
    this.trashPathRight,
    int maxDelete = 500,
    double deleteFractionWarn = 0.5,
    this.preserveMtime = true,
    int transferConcurrency = 4,
  }) : assert(
         direction != SyncDirection.bidirectional ||
             deletions == DeletionPolicy.none,
         'bidirectional pairs cannot delete (05 §6: deletions live only '
         'in one-way Mirror)',
       ),
       mtimeToleranceSecs = mtimeToleranceSecs < 0 ? 0 : mtimeToleranceSecs,
       maxDelete = maxDelete < 1 ? 1 : maxDelete,
       deleteFractionWarn = deleteFractionWarn < 0
           ? 0.0
           : (deleteFractionWarn > 1 ? 1.0 : deleteFractionWarn),
       transferConcurrency = transferConcurrency < 1
           ? 1
           : (transferConcurrency > 8 ? 8 : transferConcurrency);

  final SyncDirection direction;

  /// != none only in Mirror.
  final DeletionPolicy deletions;

  /// Default trash; independent of the deletion policy (05 §8 rail 5).
  final BackupPolicy backups;
  final ComparisonMode comparison;
  final int mtimeToleranceSecs;

  /// e.g. [3600] for FAT/DST; default empty.
  final List<int> acceptedTimeShifts;

  /// Default ask. Bidirectional conflicts generally; in the one-way modes
  /// it participates only in §6 rule 4's typeDiffers resolution (where the
  /// no-delete modes force it to skip).
  final ConflictDefault conflictDefault;

  /// gitignore-style (05 §3).
  final List<String> excludeGlobs;

  /// Default true (it's a file manager).
  final bool includeHidden;

  /// v1: skip.
  final SymlinkPolicy symlinks;

  /// Per SIDE, resolved on that side's host: null = in-root
  /// .poltergeist-trash under that side's sync root; set = out-of-root
  /// trash there (§8 rail 5 — one shared string could not be
  /// same-filesystem on both hosts). The engine always excludes the
  /// effective trash roots from scans, regardless of
  /// excludeGlobs/includeHidden.
  final String? trashPathLeft;
  final String? trashPathRight;

  /// Hard cap; default 500.
  final int maxDelete;

  /// Default 0.5 -> typed confirm (§8).
  final double deleteFractionWarn;

  /// Default true; false forces a sizeAndMtime pair to sizeOnly (§4;
  /// contentHash is never downgraded) — sizeAndMtime never converges
  /// without preserved mtimes.
  final bool preserveMtime;

  /// Default 4, clamped to 1..8.
  final int transferConcurrency;

  /// The mode check as a runtime validation — the constructor's assert
  /// is stripped in release builds, so a stored set the journal
  /// reconstructs must not carry an invalid direction × deletions
  /// combination to the planner. Call at deserialization and before
  /// handing a set to the differ/executor.
  void ensureSupported() => validateDirectionDeletions(direction, deletions);

  /// The same invariant the constructor asserts, in a form tests (and
  /// release builds) can execute directly.
  static void validateDirectionDeletions(
    SyncDirection direction,
    DeletionPolicy deletions,
  ) {
    if (direction == SyncDirection.bidirectional &&
        deletions != DeletionPolicy.none) {
      throw ArgumentError(
        'bidirectional pairs cannot delete (05 §6: deletions live only '
        'in one-way Mirror)',
      );
    }
  }

  // Value equality: the journal stores this set at run time and §9's
  // rulesChangedSincePreview compares a later set against it — identity
  // equality would report every structurally identical set as changed.
  @override
  bool operator ==(Object other) =>
      other is SyncRuleSet &&
      other.direction == direction &&
      other.deletions == deletions &&
      other.backups == backups &&
      other.comparison == comparison &&
      other.mtimeToleranceSecs == mtimeToleranceSecs &&
      _listEquals(other.acceptedTimeShifts, acceptedTimeShifts) &&
      other.conflictDefault == conflictDefault &&
      _listEquals(other.excludeGlobs, excludeGlobs) &&
      other.includeHidden == includeHidden &&
      other.symlinks == symlinks &&
      other.trashPathLeft == trashPathLeft &&
      other.trashPathRight == trashPathRight &&
      other.maxDelete == maxDelete &&
      other.deleteFractionWarn == deleteFractionWarn &&
      other.preserveMtime == preserveMtime &&
      other.transferConcurrency == transferConcurrency;

  @override
  int get hashCode => Object.hash(
    direction,
    deletions,
    backups,
    comparison,
    mtimeToleranceSecs,
    Object.hashAll(acceptedTimeShifts),
    conflictDefault,
    Object.hashAll(excludeGlobs),
    includeHidden,
    symlinks,
    trashPathLeft,
    trashPathRight,
    maxDelete,
    deleteFractionWarn,
    preserveMtime,
    transferConcurrency,
  );

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class EntrySnapshot {
  const EntrySnapshot({
    required this.kind,
    this.size,
    this.mtimeSecs,
    this.mode,
    this.symlinkTarget,
    this.sha256,
  });

  final EntryKind kind;
  final int? size;

  /// Whole seconds (SFTP v3 precision), pre-clamp original (05 §4).
  final int? mtimeSecs;
  final int? mode;
  final String? symlinkTarget;

  /// Only when comparison == contentHash.
  final String? sha256;
}

class SyncItem {
  SyncItem({
    required this.relativePath,
    required this.left,
    required this.right,
    required this.suggested,
    required this.effective,
    required this.reason,
    this.userOverridden = false,
    this.status = SyncItemStatus.pending,
    this.error,
    this.destinationSubtree,
  });

  /// Relative to the sync root, '/'-separated, no trailing separator, byte
  /// form preserved (NFC only for matching, §3). "Byte form" = the side's
  /// NFC/NFD choice among valid UTF-8, never arbitrary bytes: names that
  /// don't decode as UTF-8 are flagged per 02 §13 and never enter a plan.
  /// The one normalization rule for every relativePath in 05, journal
  /// included.
  final String relativePath;

  /// Null = absent on that side.
  final EntrySnapshot? left;
  final EntrySnapshot? right;

  /// The engine's proposal.
  final SyncActionType suggested;

  /// After override / conflict pick.
  SyncActionType effective;
  final SyncReason reason;

  /// Renders the "manual" dot (§7).
  bool userOverridden;
  SyncItemStatus status;

  /// Side-neutral message: RemoteFileException.message for a remote-side
  /// failure, the local filesystem error's message (03 §2.2's funnel
  /// wording) for a local commit/trash failure.
  String? error;

  /// For a `typeDiffers` item whose destination is a directory: the
  /// scan-captured recursive contents of that directory — '/'-separated
  /// paths strictly below [relativePath], mapped to their snapshots. The
  /// differ subsumes those entries into this item (§6 rule 4) instead of
  /// emitting child rows; the executor needs the snapshot for the
  /// rail-7 "entry set still matches" precondition and to count every
  /// removed file against `maxDelete` and the delete-fraction rail.
  /// Null for every other item shape.
  final Map<String, EntrySnapshot>? destinationSubtree;
}

/// Why a [ScanWarning] exists — the differ needs to tell subtree
/// exclusions (which mirror onto the other side, §6 rule 8) apart from
/// informational warnings, which cannot be done by matching message
/// text.
enum ScanWarningKind {
  /// A directory listing failed; the subtree under [ScanWarning.relativePath]
  /// is excluded on BOTH sides (05 §3/§6 rule 8).
  listingFailure,

  /// The case-sensitivity write probe could not run; the side is treated
  /// as case-sensitive by assumption.
  caseProbeFailed,

  /// An entry's mtime is outside the SFTP v3 range and compares clamped.
  mtimeClamped,

  /// One aggregated line reporting this side's skipped symlink count.
  symlinksSkipped,

  /// A malformed entry name was skipped during the walk.
  malformedName,
}

class ScanWarning {
  const ScanWarning({
    required this.relativePath,
    required this.side,
    required this.message,
    required this.kind,
  });

  final String relativePath;

  /// Serialized into the JSONL journal as `side.name`.
  final SyncSide side;

  /// e.g. 'Could not list "logs/"…'.
  final String message;

  /// The warning's category — see [ScanWarningKind].
  final ScanWarningKind kind;
}

class SyncPlan {
  const SyncPlan({
    required this.pair,
    required this.scannedAt,
    required this.items,
    required this.warnings,
    required this.totals,
    this.leftFileCount,
    this.rightFileCount,
  });

  final SyncPair pair;
  final DateTime scannedAt;

  /// Ordering contract in 05 §6.
  final List<SyncItem> items;
  final List<ScanWarning> warnings;

  /// Counts + bytes per action class, computed by the differ while it
  /// still holds the scan maps — an ad-hoc walk over items cannot see the
  /// destination entries a rule-4 pre-delete subsumes (05 §6).
  final PlanTotals totals;

  /// Non-directory entries the scan counted on each side — rail 3's
  /// denominator (05 §8: planned deletions included, the trash root
  /// already excluded by the scan). The differ fills these while it
  /// holds the scan maps; null tolerates plans built without scan data,
  /// where the executor derives a lower bound from the items.
  final int? leftFileCount;
  final int? rightFileCount;
}

class PlanTotals {
  const PlanTotals({
    required this.counts,
    required this.bytes,
    required this.replacedFiles,
    required this.replacedBytes,
  });

  /// Items per action class.
  final Map<SyncActionType, int> counts;

  /// Payload bytes per action class.
  final Map<SyncActionType, int> bytes;

  /// §6 rule 4 pre-delete removals — first-class here because the §7
  /// replace clause, the Deletes chip, and rails 3–4 all count them, and
  /// they are not payload bytes of any action class.
  final int replacedFiles;
  final int replacedBytes;
}

/// Journal header, JSONL (§8).
class SyncRunRecord {
  const SyncRunRecord({
    required this.runId,
    required this.pairId,
    required this.startedAt,
    required this.rules,
    required this.totals,
    required this.warnings,
  });

  /// `<first 8 hex of sha256(04 §3.1 deviceId)>-<uuidV4>` — hashed so the
  /// remote-visible trash names carry no slice of the raw deviceId (a
  /// stable cross-pair fingerprint on shared hosts otherwise); still
  /// deterministic per device, which is all the classification needs. The
  /// prefix lets §8 rail 5 tell this machine's trash directories from a
  /// sibling machine's without remote journal access; no layout change,
  /// the prefix rides inside the `<runId>` path segment.
  final String runId;

  /// The canonical state key (§9), never a bookmark id — and for ad-hoc
  /// pairs it is §9's endpoint-derived hash, never the fresh uuidV4
  /// SyncPair.id, so mtimeUnreliable and the rest of sync_state persist
  /// across ⌥⌘Y invocations.
  final String pairId;
  final DateTime startedAt;

  /// Snapshot at run time.
  final SyncRuleSet rules;

  /// §8 rail 9's header contents — totals plus the warnings the run
  /// produced.
  final PlanTotals totals;

  /// The post-run report reads these. Followed by per-item lines:
  /// relativePath, side, action, outcome, bytes, durationMs,
  /// userOverridden, trashLocation?, trashContentSha256? (rail 5
  /// copy-fallback entries only — rail 9's restore hash-verifies those),
  /// observedMtimeAfterWrite?, setstatIgnored? — side and userOverridden
  /// are what §7's override dot and §8's per-side accounting read back.
  final List<ScanWarning> warnings;
}
