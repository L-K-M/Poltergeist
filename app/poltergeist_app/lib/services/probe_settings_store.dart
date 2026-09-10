import 'probe_controller.dart';
import 'settings_store.dart';

/// The persisted probe settings seam (03 §3.4): the global reachability
/// opt-out (02 §4) plus the per-server device-local map inside
/// settings.json, keyed by serverId (03 §6). Probe *results* are never
/// persisted here (D19); only eligibility and device-local facts are.
///
/// The demo session is the only M2 caller; M5's bookmark store supplies
/// the same seam with durable bookmark ids.
abstract interface class ProbeSettings {
  /// The global `Probe server reachability` setting; only a persisted
  /// `false` disables (02 §4: default on, opt-out).
  Future<ProbePreference> loadGlobalPreference();

  /// Device-local facts for [serverId], bound to its current [host]/[port].
  /// Exposure and connection history belong to this device and this
  /// endpoint: a retargeted bookmark resets them at the owning store
  /// (03 §3.4), which persists the reset.
  Future<ProbeServerFacts> loadServerFacts({
    required String serverId,
    required String host,
    required int port,
  });

  /// Records that the bookmark was visible in the server list (02 §4:
  /// the first probe waits for that). Preserves a recorded connection.
  Future<void> markSeen({
    required String serverId,
    required String host,
    required int port,
  });

  /// Records a successful connection from this device; implies seen.
  /// Synced-in favorites become probe-eligible only through this fact.
  Future<void> markConnected({
    required String serverId,
    required String host,
    required int port,
  });

  /// Drops a bookmark's device-local record (deleted or ephemeral id).
  Future<void> removeServer(String serverId);
}

/// Immutable device-local probe facts for one server.
final class ProbeServerFacts {
  const ProbeServerFacts({required this.exposure, required this.connected});

  /// The default for an unknown endpoint: nothing was seen or connected.
  static const unseen = ProbeServerFacts(
    exposure: FavoriteExposure.unseen,
    connected: FavoriteConnection.neverConnected,
  );

  final FavoriteExposure exposure;
  final FavoriteConnection connected;
}

/// The settings.json-backed [ProbeSettings] implementation.
final class ProbeSettingsStore implements ProbeSettings {
  ProbeSettingsStore({required SettingsStore store})
    // Keep the backing store private to the probe facade.
    // ignore: prefer_initializing_formals
    : _store = store;

  static const _probeEnabledKey = 'probe.enabled';
  static const _probeServersKey = 'probe.servers';
  static const _hostKey = 'host';
  static const _portKey = 'port';
  static const _exposureKey = 'exposure';
  static const _connectedKey = 'connected';

  final SettingsStore _store;

  /// Serializes read-modify-write operations on the shared servers map:
  /// concurrent callers must never clobber each other's records (the
  /// coordinator serializes its own calls, but the facade is a shared
  /// settings surface — M5's owner can call it from several places).
  Future<void> _tail = Future.value();

  @override
  Future<ProbePreference> loadGlobalPreference() async {
    final stored = await _store.get<Object>(_probeEnabledKey);
    // Only an explicit opt-out disables; anything else is the 02 §4 default.
    return stored == false ? ProbePreference.disabled : ProbePreference.enabled;
  }

  @override
  Future<ProbeServerFacts> loadServerFacts({
    required String serverId,
    required String host,
    required int port,
  }) => _serialized(() async {
    final servers = await _loadServersMap();
    final stored = servers[serverId];

    final facts = _readFacts(stored, host, port);
    if (facts != null) return facts;

    // Absent records stay absent; any present-but-malformed record (not
    // just a Map with bad fields) is repaired in place so the reset
    // (03 §3.4) is durable and junk never accumulates.
    if (stored != null) {
      await _writeServer(serverId, host, port, seen: false, connected: false);
    }
    return ProbeServerFacts.unseen;
  });

  @override
  Future<void> markSeen({
    required String serverId,
    required String host,
    required int port,
  }) => _serialized(() async {
    final servers = await _loadServersMap();
    final previous = servers[serverId];
    // Only the *same endpoint's* connection survives: a retargeted record
    // must not carry the old endpoint's history into the rebind (03 §3.4).
    final connected =
        _readFacts(previous, host, port)?.connected ==
        FavoriteConnection.connected;
    await _writeServer(serverId, host, port, seen: true, connected: connected);
  });

  @override
  Future<void> markConnected({
    required String serverId,
    required String host,
    required int port,
  }) => _serialized(
    () => _writeServer(serverId, host, port, seen: true, connected: true),
  );

  @override
  Future<void> removeServer(String serverId) => _serialized(() async {
    final servers = await _loadServersMap();
    if (!servers.containsKey(serverId)) return;
    servers.remove(serverId);
    await _store.set(_probeServersKey, servers);
  });

  /// Returns the stored facts when the record's shape is valid and its
  /// endpoint binding matches; null for absent, malformed, or retargeted
  /// records. The host binding ignores case, like probe endpoints (03 §3.4).
  ProbeServerFacts? _readFacts(Object? stored, String host, int port) {
    if (stored is! Map) return null;
    if (stored[_hostKey] is! String ||
        (stored[_hostKey] as String).toLowerCase() != host.toLowerCase() ||
        stored[_portKey] is! int ||
        stored[_portKey] != port) {
      return null;
    }
    final exposure = stored[_exposureKey] == FavoriteExposure.seen.name
        ? FavoriteExposure.seen
        : FavoriteExposure.unseen;
    final connected = stored[_connectedKey] == true
        ? FavoriteConnection.connected
        : FavoriteConnection.neverConnected;
    return ProbeServerFacts(exposure: exposure, connected: connected);
  }

  Future<void> _writeServer(
    String serverId,
    String host,
    int port, {
    required bool seen,
    required bool connected,
  }) async {
    final servers = await _loadServersMap();
    servers[serverId] = {
      _hostKey: host.toLowerCase(),
      _portKey: port,
      _exposureKey: seen
          ? FavoriteExposure.seen.name
          : FavoriteExposure.unseen.name,
      _connectedKey: connected,
    };
    await _store.set(_probeServersKey, servers);
  }

  Future<Map<String, Object?>> _loadServersMap() async {
    final stored = await _store.get<Object>(_probeServersKey);
    if (stored is! Map) return {};
    return {
      for (final entry in stored.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final run = _tail.then((_) => operation());
    _tail = run.then<void>((_) {}, onError: (_, _) {});
    return run;
  }
}
