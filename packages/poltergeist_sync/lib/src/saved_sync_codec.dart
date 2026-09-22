// The saved-sync codec (05 §6/§9, 04 §2.1): SyncPair ↔ SavedSyncSpec ↔
// Bookmark. The spec's `source`/`destination` map to the pair's
// `left`/`right`; the spec's first-class `ignoreRules` carries
// SyncRuleSet.excludeGlobs so the gitignore list never appears twice
// in one record. Everything else in the ruleset rides the versioned
// `rules` map under the same key names the run journal writes — one
// vocabulary for "rules as JSON" across storage kinds.

import 'package:poltergeist_core/poltergeist_core.dart';

import 'plan.dart';

/// The current rules-map schema version. Older records decode
/// tolerantly (missing keys take SyncRuleSet defaults); newer records
/// decode what this version knows and keep going — execution validates
/// rule semantics, so an unknown key is ignored rather than fatal.
const int savedSyncRulesVersion = 1;

/// SyncRuleSet → the `rules` map of a [SavedSyncSpec]. `excludeGlobs`
/// is deliberately absent: it lives in the spec's first-class
/// `ignoreRules` field instead.
Map<String, Object?> syncRuleSetToJson(SyncRuleSet rules) =>
    <String, Object?>{
      'direction': rules.direction.name,
      'deletions': rules.deletions.name,
      'backups': rules.backups.name,
      'comparison': rules.comparison.name,
      'mtimeToleranceSecs': rules.mtimeToleranceSecs,
      'acceptedTimeShifts': rules.acceptedTimeShifts,
      'conflictDefault': rules.conflictDefault.name,
      'includeHidden': rules.includeHidden,
      'symlinks': rules.symlinks.name,
      'trashPathLeft': rules.trashPathLeft,
      'trashPathRight': rules.trashPathRight,
      'maxDelete': rules.maxDelete,
      'deleteFractionWarn': rules.deleteFractionWarn,
      'preserveMtime': rules.preserveMtime,
      'transferConcurrency': rules.transferConcurrency,
    };

/// Tolerant decode for synced records: absent keys take defaults, so a
/// rules map written before a knob existed still loads — and
/// [SyncRuleSet.ensureSupported] runs before return, the same
/// entry-point check the journal and differ apply.
SyncRuleSet syncRuleSetFromJson(Map<String, Object?> json) {
  T enumOf<T extends Enum>(List<T> values, Object? name, T fallback) {
    if (name is! String) return fallback;
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  const defaults = SyncRuleSet();
  final direction = enumOf(
    SyncDirection.values,
    json['direction'],
    defaults.direction,
  );
  final deletions = enumOf(
    DeletionPolicy.values,
    json['deletions'],
    defaults.deletions,
  );
  // Validate the direction×deletions invariant BEFORE constructing —
  // the constructor's check is an assert that release builds strip;
  // a synced record must fail loudly everywhere.
  SyncRuleSet.validateDirectionDeletions(direction, deletions);
  final rules = SyncRuleSet(
    direction: direction,
    deletions: deletions,
    backups: enumOf(
      BackupPolicy.values,
      json['backups'],
      defaults.backups,
    ),
    comparison: enumOf(
      ComparisonMode.values,
      json['comparison'],
      defaults.comparison,
    ),
    mtimeToleranceSecs:
        (json['mtimeToleranceSecs'] as int?) ?? defaults.mtimeToleranceSecs,
    acceptedTimeShifts: [
      for (final value in (json['acceptedTimeShifts'] as List?) ?? const [])
        if (value is int) value,
    ],
    conflictDefault: enumOf(
      ConflictDefault.values,
      json['conflictDefault'],
      defaults.conflictDefault,
    ),
    excludeGlobs: [
      for (final value in (json['excludeGlobs'] as List?) ?? const [])
        if (value is String) value,
    ],
    includeHidden: (json['includeHidden'] as bool?) ?? defaults.includeHidden,
    symlinks: enumOf(
      SymlinkPolicy.values,
      json['symlinks'],
      defaults.symlinks,
    ),
    trashPathLeft: json['trashPathLeft'] as String?,
    trashPathRight: json['trashPathRight'] as String?,
    maxDelete: (json['maxDelete'] as int?) ?? defaults.maxDelete,
    deleteFractionWarn:
        (json['deleteFractionWarn'] as num?)?.toDouble() ??
            defaults.deleteFractionWarn,
    preserveMtime:
        (json['preserveMtime'] as bool?) ?? defaults.preserveMtime,
    transferConcurrency:
        (json['transferConcurrency'] as int?) ?? defaults.transferConcurrency,
  );
  rules.ensureSupported();
  return rules;
}

/// SyncEndpoint ↔ BookmarkLocation: a null `server` is a local path
/// (04 §2.1's localFolder/remotePath convention applied per side).
BookmarkLocation bookmarkLocationFromEndpoint(SyncEndpoint endpoint) =>
    switch (endpoint) {
      LocalEndpoint(:final path) => BookmarkLocation(path: path),
      RemoteEndpoint(:final server, :final path) =>
        BookmarkLocation(server: server, path: path),
    };

/// The inverse; a null server decodes to [LocalEndpoint].
SyncEndpoint endpointFromBookmarkLocation(BookmarkLocation location) =>
    location.server == null
        ? LocalEndpoint(location.path)
        : RemoteEndpoint(server: location.server!, path: location.path);

/// SyncPair → SavedSyncSpec (04 §2.1): the pair's left/right land in
/// the spec's source/destination — the names differ, the order does
/// not; `ignoreRules` carries the pair's exclude globs so two readers
/// never see divergent copies of one list.
SavedSyncSpec savedSyncSpecFromPair(SyncPair pair) => SavedSyncSpec(
  source: bookmarkLocationFromEndpoint(pair.left),
  destination: bookmarkLocationFromEndpoint(pair.right),
  ignoreRules: pair.rules.excludeGlobs,
  rulesVersion: savedSyncRulesVersion,
  rules: syncRuleSetToJson(pair.rules),
);

/// SavedSyncSpec → SyncPair. [id] and [name] come from the bookmark
/// envelope — the favorite's identity (§9: the bookmark id is the
/// favorite's, never the canonical pairId).
SyncPair syncPairFromSavedSync(
  SavedSyncSpec spec, {
  required String id,
  required String name,
}) => SyncPair(
  id: id,
  name: name,
  left: endpointFromBookmarkLocation(spec.source),
  right: endpointFromBookmarkLocation(spec.destination),
  rules: syncRuleSetFromJson(spec.rules).withExcludeGlobs(spec.ignoreRules),
);

/// SyncPair → a savedSync-kind [Bookmark] (04 §2.1, §9: the bookmark
/// id IS the favorite's SyncPair.id). [createdAt]/[updatedAt] come
/// from the caller — a save stamps "now", an applySynced round-trip
/// preserves the server's values.
Bookmark bookmarkFromSyncPair(
  SyncPair pair, {
  String? group,
  required String sortKey,
  required DateTime createdAt,
  required DateTime updatedAt,
}) => Bookmark(
  id: pair.id,
  kind: BookmarkKind.savedSync,
  label: pair.name,
  group: group,
  sync: savedSyncSpecFromPair(pair),
  sortKey: sortKey,
  createdAt: createdAt,
  updatedAt: updatedAt,
);

/// Bookmark → SyncPair; null when the bookmark is not a savedSync or
/// carries no spec — callers treat null as "malformed favorite" and
/// report rather than silently no-op.
SyncPair? syncPairFromBookmark(Bookmark bookmark) {
  final spec = bookmark.sync;
  if (bookmark.kind != BookmarkKind.savedSync || spec == null) {
    return null;
  }
  return syncPairFromSavedSync(spec, id: bookmark.id, name: bookmark.label);
}

extension _ExcludeGlobs on SyncRuleSet {
  /// Re-attaches the spec's first-class `ignoreRules` onto a decoded
  /// ruleset (the rules map never carries excludeGlobs — see
  /// [syncRuleSetToJson]).
  SyncRuleSet withExcludeGlobs(List<String> globs) => SyncRuleSet(
    direction: direction,
    deletions: deletions,
    backups: backups,
    comparison: comparison,
    mtimeToleranceSecs: mtimeToleranceSecs,
    acceptedTimeShifts: acceptedTimeShifts,
    conflictDefault: conflictDefault,
    excludeGlobs: globs,
    includeHidden: includeHidden,
    symlinks: symlinks,
    trashPathLeft: trashPathLeft,
    trashPathRight: trashPathRight,
    maxDelete: maxDelete,
    deleteFractionWarn: deleteFractionWarn,
    preserveMtime: preserveMtime,
    transferConcurrency: transferConcurrency,
  );
}
