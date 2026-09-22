// §9's local, non-synced pair state: the `<pairId>.json` MODEL —
// lastRunAt, mtimeUnreliable flags, the case-sensitivity inputs that
// feed the canonical pairId (probe cache and remote overrides), and
// the trashCache that §8 rail 5's unreachable-side fallback reads.
// The file IO lives in the app layer (05 §11 bans dart:io here); this
// file is the schema both sides of that boundary agree on.

import 'dart:convert';

/// Local, non-synced state for one canonical `pairId` (05 §9). Every
/// field is optional-or-defaulted so the file never forks old readers.
final class SyncPairState {
  SyncPairState({
    this.lastRunAt,
    this.mtimeUnreliableLeft = false,
    this.mtimeUnreliableRight = false,
    this.caseSensitiveOverrideLeft,
    this.caseSensitiveOverrideRight,
    Map<String, CaseProbeRecord>? caseProbe,
    this.trashCacheLeft,
    this.trashCacheRight,
    this.touchedAt,
  }) : caseProbe = caseProbe ?? <String, CaseProbeRecord>{};

  /// Last completed run start (drives the pair editor's "last synced"
  /// line and the 90-day ad-hoc-pair prune).
  DateTime? lastRunAt;

  /// §4's per-side untrusted-mtime flags — set by the executor's
  /// write-back verification, read by the differ's `newerWins`
  /// degradation. Either flag (or `preserveMtime: false`) drops a
  /// pair to `sizeOnly`+`ask` semantics in every comparison mode.
  bool mtimeUnreliableLeft;
  bool mtimeUnreliableRight;

  /// The pair editor's explicit per-side overrides (§3). Null means
  /// "no override": local sides probe, remote sides assume sensitive.
  bool? caseSensitiveOverrideLeft;
  bool? caseSensitiveOverrideRight;

  /// §3's probe cache: `canonical root path` → cached probe outcome.
  /// Steady-state scans stay read-only; the probe reruns only when the
  /// recorded volume identity changes.
  final Map<String, CaseProbeRecord> caseProbe;

  /// Per-side trash-root summary — the newest state §8 rail 5's
  /// unreachable-side fallback may show. Never authoritative for a
  /// purge.
  TrashCacheEntry? trashCacheLeft;
  TrashCacheEntry? trashCacheRight;

  /// The 90-day ad-hoc prune reads this, not lastRunAt, so a pair that
  /// is only planned (never run) still ages out.
  DateTime? touchedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'lastRunAt': lastRunAt?.toUtc().toIso8601String(),
    'mtimeUnreliableLeft': mtimeUnreliableLeft,
    'mtimeUnreliableRight': mtimeUnreliableRight,
    'caseSensitiveOverrideLeft': caseSensitiveOverrideLeft,
    'caseSensitiveOverrideRight': caseSensitiveOverrideRight,
    'caseProbe': {
      for (final entry in caseProbe.entries)
        entry.key: entry.value.toJson(),
    },
    'trashCacheLeft': trashCacheLeft?.toJson(),
    'trashCacheRight': trashCacheRight?.toJson(),
    'touchedAt': touchedAt?.toUtc().toIso8601String(),
  };

  factory SyncPairState.fromJson(Map<String, Object?> json) =>
      SyncPairState(
        lastRunAt: _date(json['lastRunAt']),
        mtimeUnreliableLeft: json['mtimeUnreliableLeft'] == true,
        mtimeUnreliableRight: json['mtimeUnreliableRight'] == true,
        caseSensitiveOverrideLeft:
            json['caseSensitiveOverrideLeft'] as bool?,
        caseSensitiveOverrideRight:
            json['caseSensitiveOverrideRight'] as bool?,
        caseProbe: {
          for (final entry
              in ((json['caseProbe'] as Map?)?.cast<String, Object?>() ??
                      const <String, Object?>{})
                  .entries)
            entry.key: CaseProbeRecord.fromJson(
              (entry.value as Map).cast<String, Object?>(),
            ),
        },
        trashCacheLeft: TrashCacheEntry.maybeFromJson(
          json['trashCacheLeft'],
        ),
        trashCacheRight: TrashCacheEntry.maybeFromJson(
          json['trashCacheRight'],
        ),
        touchedAt: _date(json['touchedAt']),
      );

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;
}

/// One cached case-sensitivity probe (§3): keyed by the canonical root
/// path, valid only while the recorded volume identity still matches —
/// a re-imaged volume re-probes rather than trusting a stale answer.
final class CaseProbeRecord {
  const CaseProbeRecord({
    required this.caseSensitive,
    required this.volumeIdentity,
    required this.probedAt,
    required this.normalizationInsensitive,
  });

  final bool caseSensitive;

  /// Whatever stable volume identifier the platform exposes (local
  /// sides); an empty string means "identity unknown — always valid".
  final String volumeIdentity;

  final DateTime probedAt;

  /// Normalization (NFC/NFD) sensitivity rides the same probe —
  /// a case-sensitive APFS volume is still normalization-insensitive
  /// and the pairId folds the two axes independently (§9).
  final bool normalizationInsensitive;

  Map<String, Object?> toJson() => <String, Object?>{
    'caseSensitive': caseSensitive,
    'volumeIdentity': volumeIdentity,
    'probedAt': probedAt.toUtc().toIso8601String(),
    'normalizationInsensitive': normalizationInsensitive,
  };

  factory CaseProbeRecord.fromJson(Map<String, Object?> json) =>
      CaseProbeRecord(
        caseSensitive: json['caseSensitive'] == true,
        volumeIdentity: (json['volumeIdentity'] as String?) ?? '',
        probedAt:
            DateTime.tryParse((json['probedAt'] as String?) ?? '')
                ?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0),
        normalizationInsensitive:
            json['normalizationInsensitive'] == true,
      );
}

/// The per-side newest-known trash-root summary (§9): what §8 rail 5
/// shows when a side is unreachable — `as of <lastListedAt>` plus one
/// run entry per observed `<runId>` directory.
final class TrashCacheEntry {
  const TrashCacheEntry({
    required this.lastListedAt,
    required this.runs,
  });

  /// When the trash root was last listed successfully — the notice's
  /// staleness label ("as of 3 days ago").
  final DateTime lastListedAt;

  /// One entry per `<runId>` directory observed in the listing.
  final List<TrashCacheRun> runs;

  Map<String, Object?> toJson() => <String, Object?>{
    'lastListedAt': lastListedAt.toUtc().toIso8601String(),
    'runs': [for (final run in runs) run.toJson()],
  };

  factory TrashCacheEntry.fromJson(Map<String, Object?> json) =>
      TrashCacheEntry(
        lastListedAt:
            DateTime.tryParse((json['lastListedAt'] as String?) ?? '')
                ?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0),
        runs: [
          for (final run in (json['runs'] as List?) ?? const [])
            TrashCacheRun.fromJson(
              (run as Map).cast<String, Object?>(),
            ),
        ],
      );

  static TrashCacheEntry? maybeFromJson(Object? value) => value is Map
      ? TrashCacheEntry.fromJson(value.cast<String, Object?>())
      : null;
}

/// One observed `<runId>` trash directory (§9). [fileCount] is null for
/// journal-less directories — a crash orphan or a future export dir —
/// because counts come from local journals only (rail 5).
final class TrashCacheRun {
  const TrashCacheRun({
    required this.runId,
    required this.ageBasis,
    required this.fileCount,
  });

  final String runId;

  /// The timestamp the crash-orphan aging reads — the run's
  /// `startedAt` when a journal covers it, the directory's mtime
  /// otherwise.
  final DateTime ageBasis;

  final int? fileCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'runId': runId,
    'ageBasis': ageBasis.toUtc().toIso8601String(),
    'fileCount': fileCount,
  };

  factory TrashCacheRun.fromJson(Map<String, Object?> json) =>
      TrashCacheRun(
        runId: json['runId']! as String,
        ageBasis:
            DateTime.tryParse((json['ageBasis'] as String?) ?? '')
                ?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0),
        fileCount: json['fileCount'] as int?,
      );
}

/// Validates [pairId] as a state-file key — the app-side store calls
/// this before joining it to a path (it is a sha256 hex digest by
/// construction, but it becomes a file name, so reject anything that
/// could escape the directory).
void validateSyncPairId(String pairId) {
  if (pairId.isEmpty ||
      pairId.contains('/') ||
      pairId.contains('\\') ||
      pairId == '.' ||
      pairId == '..') {
    throw ArgumentError.value(pairId, 'pairId', 'invalid state key');
  }
}

/// [SyncPairState] ↔ JSON text — the codec the app-side store wraps
/// with atomic file writes. Corrupt JSON decodes to a fresh state:
/// the file is a cache — losing it costs a re-probe, never data.
SyncPairState syncPairStateFromJsonText(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map) return SyncPairState();
    return SyncPairState.fromJson(decoded.cast<String, Object?>());
  } on FormatException {
    return SyncPairState();
  }
}

String syncPairStateToJsonText(SyncPairState state) =>
    const JsonEncoder.withIndent('  ').convert(state.toJson());
