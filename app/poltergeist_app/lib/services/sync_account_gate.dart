/// 04 §4.2's shared-account gate constants (D4). Shared-account mode
/// requires the PR-S1 RecordKind forward-compatibility fix shipped in a
/// tagged Séance release AND running on every device the user syncs with
/// Séance — there is no in-band way to detect old clients, so the gate is
/// the recorded tag here plus the user's §4.3 fleet assertion, never a
/// version probe.
library;

/// The literal tag of the first Séance release containing PR-S1 (Séance
/// #58, merge 599ff936b8222e6cd77920495dcdcc4a50643f44): `v0.9.0` was
/// verified at its tag tree to carry the record.dart `bookmark`/`unknown`
/// kinds, the `orElse: unknown` decoder, and the record_codec
/// encrypt-refusal/tombstone-placeholder halves of the fix. `null` while
/// no such tag has been recorded — the shared-account option then has
/// nothing to render: the §4.3 copy interpolates this tag and there is no
/// sanctioned fallback string. The type stays nullable on purpose: it is
/// the gate, not a fact.
// ignore: unnecessary_nullable_for_final_variable_declarations
const String? kMinimumSharedAccountSeanceVersion = 'v0.9.0';

/// Whether the recorded tag also carries the Séance #56 pin-conflict fix.
/// `v0.9.0` predates it (the issue is still open), so this is `false` and
/// §4.3's auto-trust disclosure renders under option 2 — Séance devices
/// accept synced host-key pins without a conflict warning, including pins
/// this app pushes. Set by hand when the constant above is updated: a bare
/// tag string carries no order a renderer can evaluate.
const bool kMinSharedVersionIncludesSeance56Fix = false;

/// The gate as the UI consumes it — injectable so tests bind fakes both
/// ways (no tag recorded → shared account cannot be continued into; a tag
/// that includes Séance #56's fix → the disclosure disappears). Widgets
/// default to [SyncAccountGate.production]; nothing else may read the
/// constants, so a fake can never disagree with production by accident.
final class SyncAccountGate {
  const SyncAccountGate({
    required this.minimumSharedVersion,
    required this.sharedIncludesSeance56Fix,
  });

  /// The shipped gate — the recorded tag and its fix contents.
  const SyncAccountGate.production()
      : minimumSharedVersion = kMinimumSharedAccountSeanceVersion,
        sharedIncludesSeance56Fix = kMinSharedVersionIncludesSeance56Fix;

  /// The first Séance release tag carrying PR-S1, or null while none is
  /// recorded. §4.3's shared-account copy interpolates this tag — with
  /// none recorded the option cannot render its mandated text, so the UI
  /// shows it disabled rather than paraphrasing.
  final String? minimumSharedVersion;

  /// Whether [minimumSharedVersion] carries the Séance #56 pin-conflict
  /// fix — controls §4.3's auto-trust disclosure, not enablement.
  final bool sharedIncludesSeance56Fix;

  /// The shared-account option's master switch: a recorded tag AND the
  /// user's fleet assertion must both hold before Continue arms (04
  /// §4.3's checkbox is the second half — this getter is the first).
  bool get sharedAccountOffered => minimumSharedVersion != null;
}
