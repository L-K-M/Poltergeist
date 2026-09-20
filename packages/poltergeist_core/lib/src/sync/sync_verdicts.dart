/// 04 §3.2's durable verdict seams. Both live in **app settings**, never in
/// the §3.1 record store: the corrupt-store quarantine restarts that store
/// empty, and a verdict kept there would be erased by the very failure it
/// guards against — the next `applyPulled` would auto-apply a host key the
/// user removed under MITM suspicion.
library;

/// Durable per-locator pin verdicts.
///
/// A **negative pin** is the local untrust verdict recorded on "forget
/// host" (04 §3.2): while it stands, a pulled `hostkey:` record never
/// auto-applies — it holds until the user explicitly re-trusts, because a
/// still-trusting peer's habitual re-push of the removed pin is not the
/// "genuinely newer pin edit" that should restore it.
///
/// A **kept verdict** records the fingerprint the user rejected when they
/// chose "keep local" on a pin conflict: the same rejected key returning
/// stays resolved (no re-warning), while a *different* conflicting key
/// must still warn. It is replaced only when a genuinely different
/// conflicting fingerprint appears — never merely because the stored
/// record currently matches the kept pin.
abstract interface class PinVerdictStore {
  /// The locators (`host:port`) the user has untrusted.
  Future<Set<String>> negativePins();

  /// Record that [locator] is untrusted. Forgetting the host also drops
  /// its kept verdict: a host the user re-pins later must warn on the
  /// same pulled fingerprint again — the verdict belonged to the
  /// forgotten trust decision.
  Future<void> addNegativePin(String locator);

  /// Clear [locator]'s untrust — the user re-trusted the key.
  Future<void> removeNegativePin(String locator);

  /// The fingerprint rejected by the kept-local verdict for [locator],
  /// or null when no verdict was recorded.
  Future<String?> rejectedFingerprintFor(String locator);

  /// Record that the user kept their local pin over [rejectedFingerprint].
  Future<void> recordKeptVerdict(String locator, String rejectedFingerprint);
}

/// 04 §4.2's durable tripwire: record ids that decrypted but then failed
/// strict decode or decoded as a kind their id prefix forbids — a
/// stale-client, corrupt-record, or newer-schema signature. It is durable:
/// the warning clears when that id next pulls and strict-decodes, never
/// just because a dialog was dismissed.
abstract interface class SyncTripwireStore {
  /// Every record id currently under the tripwire.
  Future<Set<String>> trippedIds();

  /// Flag [id] — a decrypt-success + decode-failure was seen.
  Future<void> trip(String id);

  /// Clear [id] — it pulled and strict-decoded cleanly.
  Future<void> clear(String id);
}

/// In-memory [PinVerdictStore] — tests and a wiring placeholder; the app
/// implements the seam over settings. NOT durable: verdicts evaporate on
/// restart, so wiring this into a production coordinator voids the §3.2
/// untrust/kept-verdict guarantees.
final class InMemoryPinVerdictStore implements PinVerdictStore {
  final _negative = <String>{};
  final _kept = <String, String>{};

  @override
  Future<Set<String>> negativePins() async => Set.of(_negative);

  @override
  Future<void> addNegativePin(String locator) async {
    _negative.add(locator);
    _kept.remove(locator);
  }

  @override
  Future<void> removeNegativePin(String locator) async {
    _negative.remove(locator);
  }

  @override
  Future<String?> rejectedFingerprintFor(String locator) async =>
      _kept[locator];

  @override
  Future<void> recordKeptVerdict(
      String locator, String rejectedFingerprint) async {
    _kept[locator] = rejectedFingerprint;
  }
}

/// In-memory [SyncTripwireStore] — tests and a wiring placeholder; the app
/// implements the seam over settings. NOT durable: tripwire state
/// evaporates on restart, so wiring this into a production coordinator
/// voids the §4.2 durable-warning guarantee.
final class InMemorySyncTripwireStore implements SyncTripwireStore {
  final _ids = <String>{};

  @override
  Future<Set<String>> trippedIds() async => Set.of(_ids);

  @override
  Future<void> trip(String id) async {
    _ids.add(id);
  }

  @override
  Future<void> clear(String id) async {
    _ids.remove(id);
  }
}
