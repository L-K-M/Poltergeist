// 04 §3.2's durable pin verdicts and §4.2's decode tripwire, both over
// SettingsStore (settings.json): the verdicts must survive restarts AND
// the §3.1 record store's corrupt-quarantine — a verdict kept in the
// record store would be erased by the very failure it guards against,
// letting the next applyPulled auto-apply a key the user removed under
// MITM suspicion. Mutations serialize per instance so a read-modify-write
// never loses a concurrent update (same posture as the enrollment state).
import 'dart:async';

import 'package:poltergeist_core/poltergeist_core.dart';

import 'settings_store.dart';

/// Durable per-locator pin verdicts: the "forget host" negative-pin set
/// and the kept-verdict's rejected fingerprints.
final class SettingsPinVerdictStore implements PinVerdictStore {
  SettingsPinVerdictStore({required SettingsStore store})
      : // Keep the collaborator private.
        // ignore: prefer_initializing_formals
        _store = store;

  final SettingsStore _store;

  static const _negativePinsKey = 'poltergeist.sync.negativePins';
  static const _keptVerdictsKey = 'poltergeist.sync.keptPinVerdicts';

  Future<void> _tail = Future.value();

  /// Serializes a read-modify-write on one key so overlapping mutations
  /// cannot lose each other.
  Future<void> _mutate(Future<void> Function() edit) {
    final operation = _tail.then((_) => edit());
    // Heal the chain so one failed write cannot wedge later updates.
    _tail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  Future<Set<String>> _negativeSet() async {
    final raw = await _store.get<List>(_negativePinsKey);
    return {for (final entry in raw ?? const []) '$entry'};
  }

  Future<Map<String, String>> _keptMap() async {
    final raw = await _store.get<Map>(_keptVerdictsKey);
    return {
      for (final entry in raw?.entries ?? const <MapEntry>[])
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }

  @override
  Future<Set<String>> negativePins() => _negativeSet();

  @override
  Future<void> addNegativePin(String locator) => _mutate(() async {
        final next = await _negativeSet();
        if (!next.add(locator)) return;
        await _store.set(_negativePinsKey, next.toList()..sort());
      });

  @override
  Future<void> removeNegativePin(String locator) => _mutate(() async {
        final next = await _negativeSet();
        if (!next.remove(locator)) return;
        await _store.set(_negativePinsKey, next.toList()..sort());
      });

  @override
  Future<String?> rejectedFingerprintFor(String locator) async =>
      (await _keptMap())[locator];

  /// A kept verdict records only the REJECTED fingerprint: while the
  /// stored record still carries it the conflict reads as resolved, and
  /// a genuinely different conflicting fingerprint must still warn.
  @override
  Future<void> recordKeptVerdict(
          String locator, String rejectedFingerprint) =>
      _mutate(() async {
        final next = await _keptMap();
        if (next[locator] == rejectedFingerprint) return;
        next[locator] = rejectedFingerprint;
        await _store.set(_keptVerdictsKey, next);
      });
}

/// 04 §4.2's durable tripwire: record ids that decrypted but failed strict
/// decode — a stale-client, corrupt-record, or newer-schema signature. The
/// warning clears only when the id next pulls and strict-decodes, never on
/// dismissal.
final class SettingsSyncTripwireStore implements SyncTripwireStore {
  SettingsSyncTripwireStore({required SettingsStore store})
      : // Keep the collaborator private.
        // ignore: prefer_initializing_formals
        _store = store;

  final SettingsStore _store;

  static const _trippedKey = 'poltergeist.sync.tripwireIds';

  Future<void> _tail = Future.value();

  Future<Set<String>> _set() async {
    final raw = await _store.get<List>(_trippedKey);
    return {for (final entry in raw ?? const []) '$entry'};
  }

  @override
  Future<Set<String>> trippedIds() => _set();

  @override
  Future<void> trip(String id) {
    final operation = _tail.then((_) async {
      final next = await _set();
      if (!next.add(id)) return;
      await _store.set(_trippedKey, next.toList()..sort());
    });
    _tail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  @override
  Future<void> clear(String id) {
    final operation = _tail.then((_) async {
      final next = await _set();
      if (!next.remove(id)) return;
      await _store.set(_trippedKey, next.toList()..sort());
    });
    _tail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }
}
