// Comparison (05 §4): the three comparison modes plus the name hazards
// §3 makes first-class (normalization collision, case collision,
// invalid-on-destination). The frozen contract: mtimeToleranceSecs=2
// holds at the boundary — a truncated Δmtime of exactly 2 s compares
// equal, 3 s different — and out-of-range mtimes compare CLAMPED, so a
// pre-1970 file and a 2107 file never accidentally read as equal. Both
// sides are stored truncated to whole seconds; the comparison uses the
// originals when both are in range, and switches to clamped values when
// either is not.

import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'plan.dart';
import 'scan.dart';

/// The outcome of comparing one path on both sides.
enum CompareVerdict {
  equal,
  leftNewer,
  rightNewer,
  sizeDiffers,
  contentDiffers,
  typeDiffers,
}

/// Name-match key per 05 §3: byte-different names that normalize equal
/// must be the same logical path for matching and planning, while the
/// plan item keeps the side's original byte form.
String nfcKey(String path) => unorm.nfc(path);

/// Case-folded match key for a case-insensitive destination — NFC first,
/// then case fold (05 §3's NFC/NFD + case-insensitivity rules).
String foldedKey(String path) => nfcKey(path).toLowerCase();

/// Pairwise entry comparison under one [ComparisonMode] (05 §4).
final class EntryComparator {
  const EntryComparator({
    this.comparison = ComparisonMode.sizeAndMtime,
    this.mtimeToleranceSecs = 2,
    this.acceptedTimeShifts = const [],
  });

  final ComparisonMode comparison;

  /// Default 2. Holds at the boundary on whole-second values: |Δ| == 2
  /// compares equal, |Δ| == 3 different (05 §4's boundary fixture).
  final int mtimeToleranceSecs;

  /// Accepted |Δ| values (e.g. [3600] for FAT/DST skew): a delta within
  /// mtimeToleranceSecs of ±N counts as equal.
  final List<int> acceptedTimeShifts;

  /// Compares two same-path snapshots. For [ComparisonMode.contentHash]
  /// both snapshots must carry [EntrySnapshot.sha256] — hash streaming is
  /// a differ concern ([streamedSha256]); this method never performs I/O.
  CompareVerdict compare(EntrySnapshot left, EntrySnapshot right) {
    if (left.kind != right.kind) return CompareVerdict.typeDiffers;
    if (left.kind != EntryKind.file) {
      // Directories compare by existence; symlinks are never followed
      // (v1 SymlinkPolicy.skip) and equal entries plan as skip.
      return CompareVerdict.equal;
    }
    if (left.size != right.size) return CompareVerdict.sizeDiffers;
    switch (comparison) {
      case ComparisonMode.sizeOnly:
        return CompareVerdict.equal;
      case ComparisonMode.sizeAndMtime:
        return _compareMtime(left.mtimeSecs, right.mtimeSecs);
      case ComparisonMode.contentHash:
        final leftHash = left.sha256;
        final rightHash = right.sha256;
        if (leftHash == null || rightHash == null) {
          throw StateError(
            'contentHash comparison requires sha256 on both snapshots '
            '(stream them via streamedSha256 first)',
          );
        }
        return leftHash == rightHash
            ? CompareVerdict.equal
            : CompareVerdict.contentDiffers;
    }
  }

  CompareVerdict _compareMtime(int? leftSecs, int? rightSecs) {
    if (leftSecs == null && rightSecs == null) {
      // No clock evidence on either side: size already matched, nothing
      // distinguishes them.
      return CompareVerdict.equal;
    }
    if (leftSecs == null) return CompareVerdict.rightNewer;
    if (rightSecs == null) return CompareVerdict.leftNewer;
    final (l, r) = _effectiveMtimes(leftSecs, rightSecs);
    final delta = l - r;
    if (_withinTolerance(delta.abs())) return CompareVerdict.equal;
    return delta > 0 ? CompareVerdict.leftNewer : CompareVerdict.rightNewer;
  }

  /// 05 §4: originals when both are in range; when either original lies
  /// outside, comparison switches to the clamped values — a pre-1970 file
  /// and a >2106 file must never accidentally compare equal (they clamp
  /// to different ends unless the other side sits at that end too).
  static (int, int) _effectiveMtimes(int left, int right) {
    if (sftpMtimeInRange(left) && sftpMtimeInRange(right)) {
      return (left, right);
    }
    return (clampSftpMtimeSecs(left), clampSftpMtimeSecs(right));
  }

  bool _withinTolerance(int absDelta) {
    if (absDelta <= mtimeToleranceSecs) return true;
    for (final shift in acceptedTimeShifts) {
      if ((absDelta - shift).abs() <= mtimeToleranceSecs) return true;
    }
    return false;
  }
}

/// Streams one entry's content through [RemoteFileSystem.download] with
/// hashing enabled and returns the computed digest (05 §4's streamed
/// SHA-256 — sizes are compared first, so this only runs on size-equal
/// pairs). Rides core's [remoteContentDigest], so an engine-bridged
/// endpoint hashes engine-side instead of streaming the file across the
/// isolate port (D8).
Future<String?> streamedSha256(
  RemoteFileSystem fileSystem,
  String path,
) async {
  final entry = await remoteContentDigest(fileSystem, path);
  return entry.contentSha256;
}

/// A §3 name hazard — a path whose byte form can collide or fail on the
/// destination. Hazards are first-class plan items (SyncReason), never
/// silent drops.
sealed class NameHazard {
  const NameHazard(this.relativePath);

  /// The flagged path ('/'-separated, byte form preserved).
  final String relativePath;
}

/// Two entries on one side normalize to the same NFC form (05 §3:
/// "Two entries on one side that collide after normalization" — the plan
/// must not silently merge them).
final class NormalizationCollision extends NameHazard {
  const NormalizationCollision(super.relativePath, this.collidingPaths);

  /// Every source path sharing the normalized key, including
  /// [relativePath] itself.
  final List<String> collidingPaths;
}

/// Two entries on one side differ only by case and the destination is
/// case-insensitive — they would overwrite each other there.
final class CaseCollision extends NameHazard {
  const CaseCollision(super.relativePath, this.collidingPaths);

  final List<String> collidingPaths;
}

/// A name component invalid on a Windows-rules destination — flagged via
/// [validateLocalName] (the same local-safety funnel the transfer engine
/// enforces at write time, so a plan never reaches an unwritable name).
final class InvalidNameOnDestination extends NameHazard {
  const InvalidNameOnDestination(
    super.relativePath,
    this.component,
    this.reason,
  );

  final String component;
  final String reason;
}

/// Groups [source]'s paths by their NFC key and reports every collision.
List<NormalizationCollision> normalizationCollisions(ScanResult source) {
  final groups = <String, List<String>>{};
  // Sorted iteration keeps the hazard list (and each group's flagged
  // representative) identical across runs — remote readdir order is
  // arbitrary, and a previewable engine owes a deterministic plan.
  for (final path in source.entries.keys.toList()..sort()) {
    groups.putIfAbsent(nfcKey(path), () => []).add(path);
  }
  return [
    for (final paths in groups.values)
      if (paths.length > 1)
        NormalizationCollision(paths.first, List.unmodifiable(paths)),
  ];
}

/// Groups [source]'s paths by their folded key and reports every
/// collision — only meaningful against a case-insensitive destination;
/// a case-sensitive destination hosts both names fine.
List<CaseCollision> caseCollisions(
  ScanResult source, {
  required bool destinationCaseSensitive,
}) {
  if (destinationCaseSensitive) return const [];
  final groups = <String, List<String>>{};
  for (final path in source.entries.keys.toList()..sort()) {
    groups.putIfAbsent(foldedKey(path), () => []).add(path);
  }
  return [
    for (final paths in groups.values)
      if (paths.length > 1) CaseCollision(paths.first, List.unmodifiable(paths)),
  ];
}

/// Flags every path with a component [validateLocalName] rejects —
/// pass destinationEnforcesLocalNames=true when the destination applies
/// the local-safety funnel (a local side on any platform; a remote
/// Windows side once endpoint detection lands).
List<InvalidNameOnDestination> invalidDestinationNames(
  ScanResult source, {
  required bool destinationEnforcesLocalNames,
}) {
  if (!destinationEnforcesLocalNames) return const [];
  final hazards = <InvalidNameOnDestination>[];
  for (final path in source.entries.keys.toList()..sort()) {
    for (final component in path.split('/')) {
      try {
        validateLocalName(component);
      } on FormatException catch (e) {
        hazards.add(InvalidNameOnDestination(path, component, e.message));
        break;
      }
    }
  }
  return hazards;
}
