// The differ (05 §5/§6): (ScanResult, ScanResult, SyncRuleSet) →
// SyncPlan. Given the two sides' flat snapshots it emits one SyncItem
// per relative path — the mandatory preview rail 1 executes — applying
// the mode table (Update / Mirror / Additive), the name hazards of §3
// (NFC/case collisions, invalid-on-destination names, symlinks, and the
// scan-error subtree mirror), and §6 rule 4's kind-change semantics.
// Conflict resolution happens here for the automatic ConflictDefault
// paths only; `ask` leaves conflict rows for the plan view.

import 'package:poltergeist_core/poltergeist_core.dart';

import 'compare.dart';
import 'plan.dart';
import 'scan.dart';

/// Builds the [SyncPlan] for [pair] from both sides' scans (05 §5/§6).
///
/// [mtimeUnreliableLeft]/[mtimeUnreliableRight] are the pair's §4
/// per-side flags from sync_state — either flag (or
/// `preserveMtime: false`) puts `ConflictDefault.newerWins` on the
/// `ask` path in every comparison mode, `contentHash` included (§4's
/// degradation keys on mtime trust, not mode).
///
/// For `ComparisonMode.contentHash` the caller must supply
/// [leftFileSystem]/[rightFileSystem]; size-equal file pairs are hashed
/// by streamed download before comparing (sizes already proved the
/// difference for the rest).
Future<SyncPlan> diffScans({
  required ScanResult left,
  required ScanResult right,
  required SyncPair pair,
  bool mtimeUnreliableLeft = false,
  bool mtimeUnreliableRight = false,
  RemoteFileSystem? leftFileSystem,
  RemoteFileSystem? rightFileSystem,
  ScanCancellation? cancellation,
  DateTime? scannedAt,
}) async {
  final rules = pair.rules;
  rules.ensureSupported();

  // §6 rule 8: entries under a path one side could not list are
  // excluded on BOTH sides — the clean side's copies are skip rows
  // (reason scanError), never orphans a Mirror could delete.
  final failedLeft = _erroredSubtrees(left);
  final failedRight = _erroredSubtrees(right);
  bool excludedOn(SyncSide side, String path) {
    // "Excluded on this side" means the OTHER side failed to list the
    // subtree — its entries here can never be verified.
    final prefixes = side == SyncSide.left ? failedRight : failedLeft;
    for (final prefix in prefixes) {
      if (path == prefix || path.startsWith('$prefix/')) return true;
    }
    return false;
  }

  // Content hashing (05 §4): size-equal file pairs stream a SHA-256 on
  // each side before the comparator runs.
  final hashedLeft = <String, String?>{};
  final hashedRight = <String, String?>{};
  if (rules.comparison == ComparisonMode.contentHash) {
    if (leftFileSystem == null || rightFileSystem == null) {
      throw ArgumentError(
        'contentHash comparison requires both side file systems',
      );
    }
    final fold = !left.caseSensitive || !right.caseSensitive;
    String keyOf(String path) => fold ? foldedKey(path) : nfcKey(path);
    final rightByKey = {
      for (final path in right.entries.keys) keyOf(path): path,
    };
    for (final entry in left.entries.entries) {
      if (cancellation?.isCancelled ?? false) throw const ScanCancelled();
      final l = entry.value;
      if (l.kind != EntryKind.file ||
          excludedOn(SyncSide.left, entry.key)) {
        continue;
      }
      final rightPath = rightByKey[keyOf(entry.key)];
      if (rightPath == null) continue;
      final r = right.entries[rightPath];
      if (r == null || r.kind != EntryKind.file || r.size != l.size) {
        continue;
      }
      hashedLeft[entry.key] = await streamedSha256(
        leftFileSystem,
        remoteJoin(left.rootPath, entry.key),
      );
      hashedRight[rightPath] = await streamedSha256(
        rightFileSystem,
        remoteJoin(right.rootPath, rightPath),
      );
    }
  }

  final differ = _Differ(
    left: left,
    right: right,
    pair: pair,
    comparator: EntryComparator(
      comparison: rules.comparison,
      mtimeToleranceSecs: rules.mtimeToleranceSecs,
      acceptedTimeShifts: rules.acceptedTimeShifts,
    ),
    untrustedMtimes: !rules.preserveMtime ||
        mtimeUnreliableLeft ||
        mtimeUnreliableRight,
    excludedOn: excludedOn,
    hashedLeft: hashedLeft,
    hashedRight: hashedRight,
  );
  return differ.build(scannedAt: scannedAt);
}

/// The directories each side failed to list — the §6 rule-8 mirror
/// reads [ScanWarningKind.listingFailure] entries only; every other
/// warning kind is informational.
Set<String> _erroredSubtrees(ScanResult scan) => {
  for (final warning in scan.warnings)
    if (warning.kind == ScanWarningKind.listingFailure &&
        warning.relativePath.isNotEmpty)
      warning.relativePath,
};

final class _Differ {
  _Differ({
    required this.left,
    required this.right,
    required this.pair,
    required this.comparator,
    required this.untrustedMtimes,
    required this.excludedOn,
    required this.hashedLeft,
    required this.hashedRight,
  });

  final ScanResult left;
  final ScanResult right;
  final SyncPair pair;
  final EntryComparator comparator;

  /// §4's mtime-trust verdict: `newerWins` degrades to `ask` whenever
  /// the pair's clocks are untrusted (`mtimeUnreliable` flags or
  /// `preserveMtime: false`), in every comparison mode.
  final bool untrustedMtimes;

  /// Whether [path] on [side] sits under a subtree the OTHER side
  /// failed to list (§6 rule 8).
  final bool Function(SyncSide side, String path) excludedOn;

  final Map<String, String?> hashedLeft;
  final Map<String, String?> hashedRight;

  SyncRuleSet get rules => pair.rules;

  /// Folded matching when either side is case-insensitive (05 §3).
  bool get _fold => !left.caseSensitive || !right.caseSensitive;

  String _matchKey(String path) => _fold ? foldedKey(path) : nfcKey(path);

  Map<String, List<String>> _groupBy(
    ScanResult scan,
    String Function(String) keyOf,
  ) {
    final groups = <String, List<String>>{};
    for (final path in scan.entries.keys) {
      groups.putIfAbsent(keyOf(path), () => []).add(path);
    }
    return groups;
  }

  /// Whether items may flow from [side] toward the other under the
  /// pair's direction.
  bool _directionAllows(SyncSide source) => switch (rules.direction) {
    SyncDirection.leftToRight => source == SyncSide.left,
    SyncDirection.rightToLeft => source == SyncSide.right,
    SyncDirection.bidirectional => true,
  };

  /// Whether [side] is the deletion target under Mirror.
  bool _deletesOn(SyncSide side) {
    if (rules.deletions == DeletionPolicy.none) return false;
    return switch (rules.direction) {
      SyncDirection.leftToRight => side == SyncSide.right,
      SyncDirection.rightToLeft => side == SyncSide.left,
      SyncDirection.bidirectional => false,
    };
  }

  /// Whether [side] is a local endpoint — its names pass through
  /// `validateLocalName` at write time (03 §2.3).
  bool _enforcesNames(SyncSide side) => switch (side) {
    SyncSide.left => pair.left is LocalEndpoint,
    SyncSide.right => pair.right is LocalEndpoint,
  };

  SyncPlan build({DateTime? scannedAt}) {
    final items = <SyncItem>[];
    final leftByMatch = _groupBy(left, _matchKey);
    final rightByMatch = _groupBy(right, _matchKey);

    // ── Hazard classification per side ──────────────────────────────
    // NFC collisions (same normalized key, different byte forms) and
    // case variants (distinct NFC keys, one folded key) are detected on
    // the folded grouping — independent of match keying — so a side
    // treated as assumed-sensitive still flags the variants that would
    // merge if the assumption is wrong (05 §3's ask-class upgrade).
    final hazardLeft = _hazardMap(left, other: right, side: SyncSide.left);
    final hazardRight = _hazardMap(
      right,
      other: left,
      side: SyncSide.right,
    );

    // The other side's entries at a hazard path's match key can never
    // pair safely — they ride the hazard rows as the shared counterpart
    // instead of becoming orphans (or Mirror deletions).
    final absorbedLeft = <String>{};
    final absorbedRight = <String>{};
    for (final path in hazardLeft.keys) {
      absorbedRight.addAll(rightByMatch[_matchKey(path)] ?? const []);
    }
    for (final path in hazardRight.keys) {
      absorbedLeft.addAll(leftByMatch[_matchKey(path)] ?? const []);
    }

    void emitHazards(SyncSide side) {
      final isLeft = side == SyncSide.left;
      final hazards = isLeft ? hazardLeft : hazardRight;
      final scan = isLeft ? left : right;
      final otherScan = isLeft ? right : left;
      final otherByMatch = isLeft ? rightByMatch : leftByMatch;
      for (final path in hazards.keys.toList()..sort()) {
        final reason = hazards[path]!;
        final counterpart = _counterpart(
          otherByMatch[_matchKey(path)],
          otherScan,
        );
        items.add(
          SyncItem(
            relativePath: path,
            left: isLeft ? scan.entries[path] : counterpart,
            right: isLeft ? counterpart : scan.entries[path],
            suggested: reason == SyncReason.caseCollision &&
                    _asksBeforeMerging(otherScan)
                ? SyncActionType.conflict
                : SyncActionType.skip,
            effective: reason == SyncReason.caseCollision &&
                    _asksBeforeMerging(otherScan)
                ? SyncActionType.conflict
                : SyncActionType.skip,
            reason: reason,
          ),
        );
      }
    }

    emitHazards(SyncSide.left);
    emitHazards(SyncSide.right);

    // ── Normal matching over the remaining paths ────────────────────
    final keys = <String>{};
    for (final path in left.entries.keys) {
      if (!hazardLeft.containsKey(path) && !absorbedLeft.contains(path)) {
        keys.add(_matchKey(path));
      }
    }
    for (final path in right.entries.keys) {
      if (!hazardRight.containsKey(path) && !absorbedRight.contains(path)) {
        keys.add(_matchKey(path));
      }
    }

    for (final key in keys.toList()..sort()) {
      final leftPaths = [
        for (final p in leftByMatch[key] ?? const <String>[])
          if (!hazardLeft.containsKey(p) && !absorbedLeft.contains(p)) p,
      ];
      final rightPaths = [
        for (final p in rightByMatch[key] ?? const <String>[])
          if (!hazardRight.containsKey(p) && !absorbedRight.contains(p)) p,
      ];
      // Multi-member remainders cannot occur (every collision class is
      // a hazard above); pair first-to-first and orphan the rest
      // deterministically rather than dropping entries silently.
      final leftPath = leftPaths.isEmpty ? null : leftPaths.first;
      final rightPath = rightPaths.isEmpty ? null : rightPaths.first;
      for (final extra in leftPaths.skip(1)) {
        items.add(_oneSideItem(extra, side: SyncSide.left));
      }
      for (final extra in rightPaths.skip(1)) {
        items.add(_oneSideItem(extra, side: SyncSide.right));
      }
      if (leftPath == null && rightPath == null) continue;
      if (leftPath == null) {
        items.add(_oneSideItem(rightPath!, side: SyncSide.right));
        continue;
      }
      if (rightPath == null) {
        items.add(_oneSideItem(leftPath, side: SyncSide.left));
        continue;
      }
      items.add(_matchedItem(leftPath, rightPath));
    }

    // Deterministic plan order: path-sorted. The executor re-groups by
    // phase (§6's contract) and the view re-sorts for display.
    items.sort((a, b) => a.relativePath.compareTo(b.relativePath));

    return SyncPlan(
      pair: pair,
      scannedAt: scannedAt ?? DateTime.now(),
      items: items,
      warnings: [...left.warnings, ...right.warnings],
      totals: _totals(items),
      leftFileCount: _fileCount(left),
      rightFileCount: _fileCount(right),
    );
  }

  /// §3's second-class-sensitivity rule: a case-variant hazard asks
  /// when the destination's sensitivity claim came from a default or a
  /// skipped probe — a wrong "sensitive" guess would merge the
  /// variants. A probed or overridden answer settles it either way.
  bool _asksBeforeMerging(ScanResult destination) =>
      destination.caseSensitive &&
      destination.caseSensitivityBasis == CaseSensitivityBasis.assumption;

  /// Per-path hazard classification for one side (05 §3): every flagged
  /// path becomes its own plan item, never a silent merge or drop.
  /// Detection reuses compare.dart's hazard helpers — one vocabulary
  /// for "this name cannot plan".
  Map<String, SyncReason> _hazardMap(
    ScanResult scan, {
    required ScanResult other,
    required SyncSide side,
  }) {
    final hazards = <String, SyncReason>{};

    // NFC collisions: byte-different names sharing one normalized key.
    for (final hazard in normalizationCollisions(scan)) {
      for (final path in hazard.collidingPaths) {
        hazards[path] = SyncReason.normalizationCollision;
      }
    }

    // Case variants: distinct NFC keys sharing one folded key. A hazard
    // only while the other side might not host both names — probed or
    // overridden case-sensitivity is authoritative either way (§3's
    // second-class-sensitivity rule; `_asksBeforeMerging` picks the
    // skip-vs-ask class at emit time).
    if (!other.caseSensitive || _asksBeforeMerging(other)) {
      for (final hazard in caseCollisions(
        scan,
        destinationCaseSensitive: false,
      )) {
        for (final path in hazard.collidingPaths) {
          hazards.putIfAbsent(path, () => SyncReason.caseCollision);
        }
      }
    }

    // Scan-error mirror (§6 rule 8): this side's entries under a
    // subtree the other side failed to list are skip rows.
    for (final path in scan.entries.keys) {
      if (excludedOn(side, path)) {
        hazards[path] = SyncReason.scanError;
      }
    }

    // Invalid-on-destination names (05 §3): only when this side's
    // entry could be CREATED on the enforcing side — i.e. the flow
    // permits it, the destination enforces local names, and no entry
    // already exists at the match key (an existing name is written,
    // not created, and stays valid for updates).
    final otherByMatch = _groupBy(other, _matchKey);
    final destination =
        side == SyncSide.left ? SyncSide.right : SyncSide.left;
    if (_directionAllows(side) && _enforcesNames(destination)) {
      for (final hazard in invalidDestinationNames(
        scan,
        destinationEnforcesLocalNames: true,
      )) {
        final path = hazard.relativePath;
        if (hazards.containsKey(path)) continue;
        if ((otherByMatch[_matchKey(path)] ?? const []).isNotEmpty) {
          continue;
        }
        hazards[path] = SyncReason.invalidNameOnDestination;
      }
    }
    return hazards;
  }

  /// The other side's entry at a hazard path's key — shared across the
  /// hazard group so it can never plan as an orphan.
  EntrySnapshot? _counterpart(List<String>? paths, ScanResult scan) =>
      paths == null || paths.isEmpty ? null : scan.entries[paths.first];

  /// An entry existing on [side] only.
  SyncItem _oneSideItem(String path, {required SyncSide side}) {
    final isLeft = side == SyncSide.left;
    final snapshot = (isLeft ? left : right).entries[path];

    // Symlink-only entries plan skip (05 §3): the path is excluded on
    // both sides, never an orphan a Mirror could delete.
    if (snapshot?.kind == EntryKind.symlink) {
      return SyncItem(
        relativePath: path,
        left: isLeft ? snapshot : null,
        right: isLeft ? null : snapshot,
        suggested: SyncActionType.skip,
        effective: SyncActionType.skip,
        reason: SyncReason.excluded,
      );
    }

    // Mirror's destination-only orphans delete; no-delete modes and
    // opposite-direction entries skip or copy per the direction.
    if (_deletesOn(side)) {
      return SyncItem(
        relativePath: path,
        left: isLeft ? snapshot : null,
        right: isLeft ? null : snapshot,
        suggested:
            isLeft ? SyncActionType.deleteLeft : SyncActionType.deleteRight,
        effective:
            isLeft ? SyncActionType.deleteLeft : SyncActionType.deleteRight,
        reason: isLeft ? SyncReason.onlyOnLeft : SyncReason.onlyOnRight,
      );
    }
    if (_directionAllows(side)) {
      final toRight = side == SyncSide.left;
      final isDir = snapshot?.kind == EntryKind.directory;
      final action = isDir
          ? (toRight ? SyncActionType.makeDirRight : SyncActionType.makeDirLeft)
          : (toRight
              ? SyncActionType.copyLeftToRight
              : SyncActionType.copyRightToLeft);
      return SyncItem(
        relativePath: path,
        left: isLeft ? snapshot : null,
        right: isLeft ? null : snapshot,
        suggested: action,
        effective: action,
        reason: isLeft ? SyncReason.onlyOnLeft : SyncReason.onlyOnRight,
      );
    }
    return SyncItem(
      relativePath: path,
      left: isLeft ? snapshot : null,
      right: isLeft ? null : snapshot,
      suggested: SyncActionType.skip,
      effective: SyncActionType.skip,
      reason: isLeft ? SyncReason.onlyOnLeft : SyncReason.onlyOnRight,
    );
  }

  /// A path present on both sides.
  SyncItem _matchedItem(String leftPath, String rightPath) {
    final leftSnap = left.entries[leftPath]!;
    final rightSnap = right.entries[rightPath]!;

    // Symlink involvement (05 §3): plan skip on both sides; a kind
    // mismatch against a link surfaces typeDiffers with suggested
    // skip, never a deletion.
    final symlinkInvolved = leftSnap.kind == EntryKind.symlink ||
        rightSnap.kind == EntryKind.symlink;
    if (symlinkInvolved) {
      final kindMismatch = leftSnap.kind != rightSnap.kind;
      return SyncItem(
        relativePath: leftPath,
        left: leftSnap,
        right: rightSnap,
        suggested: SyncActionType.skip,
        effective: SyncActionType.skip,
        reason: kindMismatch ? SyncReason.typeDiffers : SyncReason.excluded,
      );
    }

    if (leftSnap.kind != rightSnap.kind) {
      return _typeDiffersItem(leftPath, leftSnap, rightSnap);
    }

    if (leftSnap.kind != EntryKind.file) {
      // Directories compare by existence only; other kinds are inert.
      return SyncItem(
        relativePath: leftPath,
        left: leftSnap,
        right: rightSnap,
        suggested: SyncActionType.skip,
        effective: SyncActionType.skip,
        reason: SyncReason.equal,
      );
    }

    final verdict = comparator.compare(
      _withHash(leftSnap, hashedLeft[leftPath]),
      _withHash(rightSnap, hashedRight[rightPath]),
    );
    if (verdict == CompareVerdict.equal) {
      return SyncItem(
        relativePath: leftPath,
        left: leftSnap,
        right: rightSnap,
        suggested: SyncActionType.skip,
        effective: SyncActionType.skip,
        reason: SyncReason.equal,
      );
    }
    final reason = switch (verdict) {
      CompareVerdict.leftNewer => SyncReason.newerOnLeft,
      CompareVerdict.rightNewer => SyncReason.newerOnRight,
      CompareVerdict.sizeDiffers => SyncReason.sizeDiffers,
      _ => SyncReason.contentDiffers,
    };

    if (rules.direction == SyncDirection.bidirectional) {
      // Additive: a differing pair is a bothChanged conflict unless
      // the pair's ConflictDefault resolves it (§5).
      return SyncItem(
        relativePath: leftPath,
        left: leftSnap,
        right: rightSnap,
        suggested: SyncActionType.conflict,
        effective: _resolveConflict(
          leftSnap: leftSnap,
          rightSnap: rightSnap,
          kindChange: false,
        ),
        reason: SyncReason.bothChanged,
      );
    }

    // One-way: the source wins regardless of which side is newer —
    // the backwards-in-time copy stays visible via the reason (§5).
    final toRight = rules.direction == SyncDirection.leftToRight;
    final action = toRight
        ? SyncActionType.updateLeftToRight
        : SyncActionType.updateRightToLeft;
    return SyncItem(
      relativePath: leftPath,
      left: leftSnap,
      right: rightSnap,
      suggested: action,
      effective: action,
      reason: reason,
    );
  }

  EntrySnapshot _withHash(EntrySnapshot snapshot, String? hash) =>
      hash == null
          ? snapshot
          : EntrySnapshot(
              kind: snapshot.kind,
              size: snapshot.size,
              mtimeSecs: snapshot.mtimeSecs,
              mode: snapshot.mode,
              symlinkTarget: snapshot.symlinkTarget,
              sha256: hash,
            );

  /// §6 rule 4's kind-change row: the directory side's recursive
  /// contents are captured while the scans are in hand (the executor's
  /// rail-7 set-match and the per-file deletion counting both read it).
  SyncItem _typeDiffersItem(
    String path,
    EntrySnapshot leftSnap,
    EntrySnapshot rightSnap,
  ) {
    Map<String, EntrySnapshot>? subtree;
    if (leftSnap.kind == EntryKind.directory) {
      subtree = _subtreeOf(left, path);
    } else if (rightSnap.kind == EntryKind.directory) {
      subtree = _subtreeOf(right, path);
    }

    final SyncActionType effective;
    if (rules.deletions == DeletionPolicy.none) {
      // Update/Additive (§6 rule 4): an automatic ConflictDefault
      // resolves to SKIP only — the per-item override is the sole
      // pre-delete authorization in a mode whose header can promise
      // "nothing deleted".
      effective = rules.conflictDefault == ConflictDefault.ask
          ? SyncActionType.conflict
          : SyncActionType.skip;
    } else {
      // Mirror: ConflictDefault may resolve to a copy/mkdir whose
      // embedded pre-delete runs under the trash policy.
      effective = _resolveConflict(
        leftSnap: leftSnap,
        rightSnap: rightSnap,
        kindChange: true,
      );
    }
    return SyncItem(
      relativePath: path,
      left: leftSnap,
      right: rightSnap,
      // `suggested` stays conflict: "Reset to suggested" returns the
      // row to undecided; the diff-time resolution rides `effective`.
      suggested: SyncActionType.conflict,
      effective: effective,
      reason: SyncReason.typeDiffers,
      destinationSubtree: subtree,
    );
  }

  Map<String, EntrySnapshot> _subtreeOf(ScanResult scan, String path) {
    final prefix = '$path/';
    return {
      for (final entry in scan.entries.entries)
        if (entry.key.startsWith(prefix)) entry.key: entry.value,
    };
  }

  /// Resolves a conflict-class item through the pair's
  /// [ConflictDefault] (§5 / §6 rule 4). `newerWins` degrades to `ask`
  /// on untrusted clocks. In one-way modes a resolution that would
  /// write against the direction becomes skip — a one-way pair never
  /// writes its source side.
  SyncActionType _resolveConflict({
    required EntrySnapshot leftSnap,
    required EntrySnapshot rightSnap,
    required bool kindChange,
  }) {
    var fallback = rules.conflictDefault;
    if (fallback == ConflictDefault.newerWins && untrustedMtimes) {
      fallback = ConflictDefault.ask;
    }
    switch (fallback) {
      case ConflictDefault.ask:
        return SyncActionType.conflict;
      case ConflictDefault.skip:
        return SyncActionType.skip;
      case ConflictDefault.keepLeft:
        return _keepSide(SyncSide.left, leftSnap, kindChange: kindChange);
      case ConflictDefault.keepRight:
        return _keepSide(SyncSide.right, rightSnap, kindChange: kindChange);
      case ConflictDefault.newerWins:
        final leftSecs = leftSnap.mtimeSecs;
        final rightSecs = rightSnap.mtimeSecs;
        if (leftSecs == null ||
            rightSecs == null ||
            leftSecs == rightSecs) {
          return SyncActionType.conflict;
        }
        return leftSecs > rightSecs
            ? _keepSide(SyncSide.left, leftSnap, kindChange: kindChange)
            : _keepSide(SyncSide.right, rightSnap, kindChange: kindChange);
    }
  }

  /// The action a `keep<side>` resolution maps to. Bidirectional
  /// writes the kept side's content over the other; a one-way mode
  /// writes only when the kept side is the source — keeping the
  /// destination means leaving it (skip). Kind-change resolutions use
  /// the create-verbs (copy/makeDir over the removed kind); matched
  /// file conflicts use update.
  SyncActionType _keepSide(
    SyncSide keep,
    EntrySnapshot winner, {
    required bool kindChange,
  }) {
    final toRight = keep == SyncSide.left;
    final isDir = winner.kind == EntryKind.directory;
    switch (rules.direction) {
      case SyncDirection.bidirectional:
        if (isDir) {
          return toRight
              ? SyncActionType.makeDirRight
              : SyncActionType.makeDirLeft;
        }
        return kindChange
            ? (toRight
                ? SyncActionType.copyLeftToRight
                : SyncActionType.copyRightToLeft)
            : (toRight
                ? SyncActionType.updateLeftToRight
                : SyncActionType.updateRightToLeft);
      case SyncDirection.leftToRight:
        if (!toRight) return SyncActionType.skip;
        return isDir
            ? SyncActionType.makeDirRight
            : SyncActionType.copyLeftToRight;
      case SyncDirection.rightToLeft:
        if (toRight) return SyncActionType.skip;
        return isDir
            ? SyncActionType.makeDirLeft
            : SyncActionType.copyRightToLeft;
    }
  }

  int _fileCount(ScanResult scan) {
    var count = 0;
    for (final snapshot in scan.entries.values) {
      if (snapshot.kind != EntryKind.directory) count++;
    }
    return count;
  }

  PlanTotals _totals(List<SyncItem> items) {
    final counts = <SyncActionType, int>{};
    final bytes = <SyncActionType, int>{};
    var replacedFiles = 0;
    var replacedBytes = 0;
    for (final item in items) {
      final action = item.effective;
      counts[action] = (counts[action] ?? 0) + 1;
      final payload = _payloadBytes(item);
      if (payload > 0) {
        bytes[action] = (bytes[action] ?? 0) + payload;
      }
      final (files, byteTotal) = _preDeleteToll(item);
      replacedFiles += files;
      replacedBytes += byteTotal;
    }
    return PlanTotals(
      counts: counts,
      bytes: bytes,
      replacedFiles: replacedFiles,
      replacedBytes: replacedBytes,
    );
  }

  int _payloadBytes(SyncItem item) => switch (item.effective) {
    SyncActionType.copyLeftToRight ||
    SyncActionType.updateLeftToRight => item.left?.size ?? 0,
    SyncActionType.copyRightToLeft ||
    SyncActionType.updateRightToLeft => item.right?.size ?? 0,
    _ => 0,
  };

  /// Files/bytes the §6 rule-4 pre-delete removes: the destination
  /// entry itself for non-directories, the captured subtree's
  /// non-directory entries for a replaced directory.
  (int, int) _preDeleteToll(SyncItem item) {
    final dest = switch (item.effective) {
      SyncActionType.copyLeftToRight ||
      SyncActionType.updateLeftToRight ||
      SyncActionType.makeDirRight => item.right,
      SyncActionType.copyRightToLeft ||
      SyncActionType.updateRightToLeft ||
      SyncActionType.makeDirLeft => item.left,
      _ => null,
    };
    if (dest == null) return (0, 0);
    final carries = switch (item.effective) {
      SyncActionType.makeDirLeft ||
      SyncActionType.makeDirRight => dest.kind != EntryKind.directory,
      SyncActionType.copyLeftToRight ||
      SyncActionType.copyRightToLeft ||
      SyncActionType.updateLeftToRight ||
      SyncActionType.updateRightToLeft => dest.kind != EntryKind.file,
      _ => false,
    };
    if (!carries) return (0, 0);
    if (dest.kind != EntryKind.directory) return (1, dest.size ?? 0);
    var files = 0;
    var byteTotal = 0;
    final subtree = item.destinationSubtree;
    if (subtree != null) {
      for (final snapshot in subtree.values) {
        if (snapshot.kind != EntryKind.directory) {
          files++;
          byteTotal += snapshot.size ?? 0;
        }
      }
    }
    return (files, byteTotal);
  }
}
