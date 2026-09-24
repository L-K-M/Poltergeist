// The Sync sheet's "Here's the plan:" sentence (D32 §7): what the
// OPTIONS will do, before any scan — the review tab's
// syncHeaderClauses (sync_plan_format.dart) states what the PLAN will
// do after one. A pure function of the pair (and, when known, its
// stored state), so every wording is golden-testable.
//
// The one hard rule is truthfulness toward the engine (05 §4/§5): a
// one-way pair replaces on ANY size or date difference, even when the
// destination copy is newer, so no clause ever says "older files are
// replaced"; Additive never deletes; and the size-only fallback the
// controller applies for an mtime-untrusted pair is spelled out rather
// than hidden behind the dropdown's stored value.
import 'package:poltergeist_core/poltergeist_core.dart' show RemoteTrash;
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../l10n/app_localizations.dart';
import '../../services/pane_location.dart' show paneLastSegment;

/// How a clause renders: destructive clauses (deletions, backup-less
/// overwrites) are red-tinted with an icon, the no-deletion assurance
/// reads as safe, everything else is plain text.
enum SyncPolicyTone { plain, safe, destructive }

/// One sentence of the plan paragraph — each is a single ARB template.
final class SyncPolicyClause {
  const SyncPolicyClause(this.text, {this.tone = SyncPolicyTone.plain});

  final String text;
  final SyncPolicyTone tone;

  @override
  bool operator ==(Object other) =>
      other is SyncPolicyClause && other.text == text && other.tone == tone;

  @override
  int get hashCode => Object.hash(text, tone);

  @override
  String toString() => '${tone.name}: $text';
}

/// The ICU `select` key an endpoint's kind renders as.
const String _remoteKind = 'remote';
const String _localKind = 'local';

/// The plan paragraph for [pair]'s options. [pairState] carries the
/// §4 untrusted-mtime flags when the caller has loaded them; without
/// it the sentence describes the configured comparison.
List<SyncPolicyClause> syncPolicySentence(
  AppLocalizations l10n,
  SyncPair pair, [
  SyncPairState? pairState,
]) {
  final rules = pair.rules;
  final flaggedClock =
      (pairState?.mtimeUnreliableLeft ?? false) ||
      (pairState?.mtimeUnreliableRight ?? false);
  // The controller's fallback (SyncPlanController._downgradesToSizeOnly):
  // only a sizeAndMtime pair with a flagged side compares size-only.
  final downgraded =
      rules.comparison == ComparisonMode.sizeAndMtime && flaggedClock;
  final comparison = downgraded ? ComparisonMode.sizeOnly : rules.comparison;
  final clauses = rules.direction == SyncDirection.bidirectional
      ? _bothWays(l10n, pair, comparison, flaggedClock)
      : _oneWay(l10n, pair, comparison);
  if (downgraded) {
    clauses.insert(2, SyncPolicyClause(l10n.syncPolicySizeOnlyFallback));
  }
  if (!rules.includeHidden) {
    clauses.add(SyncPolicyClause(l10n.syncPolicyHiddenSkipped));
  }
  if (rules.excludeGlobs.isNotEmpty) {
    clauses.add(
      SyncPolicyClause(l10n.syncPolicyRulesSkipped(rules.excludeGlobs.length)),
    );
  }
  return clauses;
}

/// The paragraph as one string — the clause texts space-joined.
String syncPolicySentenceText(
  AppLocalizations l10n,
  SyncPair pair, [
  SyncPairState? pairState,
]) => syncPolicySentence(
  l10n,
  pair,
  pairState,
).map((clause) => clause.text).join(' ');

List<SyncPolicyClause> _oneWay(
  AppLocalizations l10n,
  SyncPair pair,
  ComparisonMode comparison,
) {
  final rules = pair.rules;
  final toRight = rules.direction == SyncDirection.leftToRight;
  final source = toRight ? pair.left : pair.right;
  final destination = toRight ? pair.right : pair.left;
  final sourceName = syncEndpointFolderName(source);
  final destinationName = syncEndpointFolderName(destination);
  final destinationTrash = toRight ? rules.trashPathRight : rules.trashPathLeft;
  final trashLabel = destinationTrash ?? RemoteTrash.rootDirectoryName;
  return [
    SyncPolicyClause(
      l10n.syncPolicyOneWay(
        _kindOf(destination),
        destinationName,
        _kindOf(source),
        sourceName,
      ),
    ),
    SyncPolicyClause(switch (comparison) {
      ComparisonMode.sizeAndMtime => l10n.syncPolicyReplaceSizeDate(
        sourceName,
        destinationName,
      ),
      ComparisonMode.sizeOnly => l10n.syncPolicyReplaceSize(sourceName),
      ComparisonMode.contentHash => l10n.syncPolicyReplaceChecksum(sourceName),
    }),
    switch ((rules.backups, destinationTrash)) {
      (BackupPolicy.none, _) => SyncPolicyClause(
        l10n.syncPolicyBackupsNone,
        tone: SyncPolicyTone.destructive,
      ),
      (BackupPolicy.trash, null) => SyncPolicyClause(
        l10n.syncPolicyBackupsInRoot(
          RemoteTrash.rootDirectoryName,
          destinationName,
        ),
      ),
      (BackupPolicy.trash, final String path) => SyncPolicyClause(
        l10n.syncPolicyBackupsAt(path),
      ),
    },
    switch (rules.deletions) {
      DeletionPolicy.none => SyncPolicyClause(
        l10n.syncPolicyNoDeletes,
        tone: SyncPolicyTone.safe,
      ),
      DeletionPolicy.trash => SyncPolicyClause(
        l10n.syncPolicyDeleteTrash(destinationName, sourceName, trashLabel),
        tone: SyncPolicyTone.destructive,
      ),
      DeletionPolicy.permanent => SyncPolicyClause(
        l10n.syncPolicyDeletePermanent(destinationName, sourceName),
        tone: SyncPolicyTone.destructive,
      ),
    },
  ];
}

List<SyncPolicyClause> _bothWays(
  AppLocalizations l10n,
  SyncPair pair,
  ComparisonMode comparison,
  bool flaggedClock,
) {
  final rules = pair.rules;
  final leftName = syncEndpointFolderName(pair.left);
  final rightName = syncEndpointFolderName(pair.right);
  // The differ's newerWins guard (diff.dart `_resolveConflict`): an
  // untrusted clock — preserveMtime off or a flagged side — degrades
  // the default to ask, so the sentence must not promise newer-wins.
  final conflictDefault =
      rules.conflictDefault == ConflictDefault.newerWins &&
          (flaggedClock || !rules.preserveMtime)
      ? ConflictDefault.ask
      : rules.conflictDefault;
  final replaces = switch (conflictDefault) {
    ConflictDefault.newerWins ||
    ConflictDefault.keepLeft ||
    ConflictDefault.keepRight => true,
    ConflictDefault.ask || ConflictDefault.skip => false,
  };
  return [
    SyncPolicyClause(
      l10n.syncPolicyBothWays(
        _kindOf(pair.left),
        leftName,
        _kindOf(pair.right),
        rightName,
      ),
    ),
    SyncPolicyClause(switch (comparison) {
      ComparisonMode.sizeAndMtime => l10n.syncPolicyDifferSizeDate,
      ComparisonMode.sizeOnly => l10n.syncPolicyDifferSize,
      ComparisonMode.contentHash => l10n.syncPolicyDifferChecksum,
    }),
    SyncPolicyClause(switch (conflictDefault) {
      ConflictDefault.ask => l10n.syncPolicyConflictAsk,
      ConflictDefault.newerWins => l10n.syncPolicyConflictNewer,
      ConflictDefault.keepLeft => l10n.syncPolicyConflictKeep(leftName),
      ConflictDefault.keepRight => l10n.syncPolicyConflictKeep(rightName),
      ConflictDefault.skip => l10n.syncPolicyConflictSkip,
    }),
    if (replaces)
      rules.backups == BackupPolicy.none
          ? SyncPolicyClause(
              l10n.syncPolicyBackupsNone,
              tone: SyncPolicyTone.destructive,
            )
          : SyncPolicyClause(l10n.syncPolicyBackupsEachSide),
    // 05 §6: deletions live only in one-way Mirror — Additive's
    // default path removes nothing (a rule-4 pre-delete needs an
    // explicit per-row override in the review).
    SyncPolicyClause(l10n.syncPolicyNoDeletes, tone: SyncPolicyTone.safe),
  ];
}

String _kindOf(SyncEndpoint endpoint) =>
    endpoint is RemoteEndpoint ? _remoteKind : _localKind;

/// The folder name a sentence quotes: the endpoint path's last
/// segment (a root names itself).
String syncEndpointFolderName(SyncEndpoint endpoint) => switch (endpoint) {
  LocalEndpoint(:final path) => paneLastSegment(path),
  RemoteEndpoint(:final path) => paneLastSegment(path),
};
