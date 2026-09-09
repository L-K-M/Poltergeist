import 'dart:async';

import 'package:seance_core/seance_core.dart';

import 'protocol.dart' show ProbeActivity;

// 02 §4 specifies the cadence and timeout; 03 §3.4 caps concurrency.
const _probeInterval = Duration(seconds: 60);
const _probeTimeout = Duration(seconds: 3);
const _maxConcurrentProbes = 6;
const _minimumPort = 1;
const _maximumPort = 65535;
final _invalidHostCharacters = RegExp(r'[\s\x00-\x1f\x7f]');

/// Owns the pinned probe service inside the engine isolate (D8).
///
/// Callers supply only eligible, already-seen bookmarks. Multiple bookmarks
/// for one endpoint share a probe; results retain their bookmark identities.
/// No socket starts until an explicit [ProbeActivity.running] request.
final class EngineProbes {
  final void Function(Map<String, ProbeStatus>) _emit;
  final Set<String> Function(List<ServerConfig>) _connectedServerIds;
  late final ProbeService _service;
  StreamSubscription<Map<String, ProbeStatus>>? _subscription;

  Map<String, (String, int)> _targets = {};
  List<ServerConfig> _configs = const [];
  Map<(String, int), ServerConfig> _endpoints = {};
  Map<String, ProbeStatus> _statuses = {};
  ProbeActivity _activity = ProbeActivity.paused;
  int _nextEndpointId = 0;
  int _subscriptionGeneration = 0;
  bool _disposed = false;
  Future<void>? _disposal;

  /// [connectedServerIds] must match both id and current host/port against
  /// live pools: a bookmark edited mid-connection may still own its old pool.
  EngineProbes({
    required this._emit,
    required this._connectedServerIds,
    Prober prober = const TcpBannerProber(),
  }) {
    _service = ProbeService(
      prober: prober,
      interval: _probeInterval,
      timeout: _probeTimeout,
      maxConcurrentProbes: _maxConcurrentProbes,
      connectedServerIds: _connectedEndpointIds,
    );
    _service.pause();
    _service.start(const []);
  }

  /// Replaces eligibility atomically. Removed ids disappear; new endpoints
  /// start unknown so an old result cannot follow a bookmark edit.
  void updateTargets(List<ServerConfig> targets) {
    _requireActive();
    _validateTargets(targets);

    // Match PoolKey's DNS normalization so case aliases share the rate limit.
    final nextTargets = {
      for (final target in targets)
        target.id: (target.host.toLowerCase(), target.port),
    };
    if (_sameTargets(nextTargets)) return;

    final nextEndpoints = <(String, int), ServerConfig>{};
    for (final target in targets) {
      final endpoint = nextTargets[target.id]!;
      nextEndpoints.putIfAbsent(
        endpoint,
        // Stable internal ids preserve an endpoint's pending result when
        // its representative bookmark disappears or the list is reordered.
        () =>
            _endpoints[endpoint] ??
            ServerConfig(
              id: 'probe-${_nextEndpointId++}',
              label: target.label,
              host: endpoint.$1,
              port: target.port,
              username: target.username,
              authMethod: target.authMethod,
              createdAt: target.createdAt,
              updatedAt: target.updatedAt,
            ),
      );
    }

    _statuses = {
      for (final entry in nextTargets.entries)
        entry.key: _targets[entry.key] == entry.value
            ? _statuses[entry.key] ?? ProbeStatus.unknown
            : ProbeStatus.unknown,
    };
    _targets = nextTargets;
    _configs = List.unmodifiable(targets);
    _endpoints = nextEndpoints;
    _service.updateServers(_endpoints.values.toList());

    // Upstream invalidates in-flight work; replacing this subscription also
    // discards results already queued in its asynchronous broadcast stream.
    _cancelSubscription();
    _syncActivity();
    _emit(Map.unmodifiable(_statuses));
  }

  void setActivity(ProbeActivity activity) {
    _requireActive();
    if (_activity == activity) return;
    _activity = activity;
    _syncActivity();
  }

  void _syncActivity() {
    if (_activity == ProbeActivity.paused || _endpoints.isEmpty) {
      _service.pause();
      _cancelSubscription();
      return;
    }

    if (_subscription == null) {
      final generation = ++_subscriptionGeneration;
      _subscription = _service.statuses.listen((statuses) {
        if (_disposed ||
            _activity != ProbeActivity.running ||
            generation != _subscriptionGeneration) {
          return;
        }
        _acceptStatuses(statuses);
      });
    }
    _service.resume();
  }

  void _acceptStatuses(Map<String, ProbeStatus> statuses) {
    final connected = _connectedEndpointIds();
    _statuses = {
      for (final entry in _targets.entries)
        entry.key: connected.contains(_endpoints[entry.value]!.id)
            ? ProbeStatus.online
            : statuses[_endpoints[entry.value]!.id] ?? ProbeStatus.unknown,
    };
    _emit(Map.unmodifiable(_statuses));
  }

  Set<String> _connectedEndpointIds() {
    final connected = _connectedServerIds(_configs);
    return {
      for (final entry in _targets.entries)
        if (connected.contains(entry.key)) _endpoints[entry.value]!.id,
    };
  }

  bool _sameTargets(Map<String, (String, int)> targets) =>
      targets.length == _targets.length &&
      targets.entries.every((entry) => _targets[entry.key] == entry.value);

  static void _validateTargets(List<ServerConfig> targets) {
    final ids = <String>{};
    for (final target in targets) {
      if (target.id.trim().isEmpty || !ids.add(target.id)) {
        throw ArgumentError('Probe target ids must be nonempty and unique.');
      }
      if (target.host.isEmpty || _invalidHostCharacters.hasMatch(target.host)) {
        throw ArgumentError(
          'Probe hosts must contain no whitespace or controls.',
        );
      }
      if (target.port < _minimumPort || target.port > _maximumPort) {
        throw ArgumentError('Probe ports must be between 1 and 65535.');
      }
    }
  }

  void _cancelSubscription() {
    _subscriptionGeneration++;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void _requireActive() {
    if (_disposed) throw StateError('The engine probe service is disposed.');
  }

  /// Invalidates queued work before awaiting cleanup; late probe completions
  /// cannot publish or launch another queued probe after engine shutdown.
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _service.pause();
    _cancelSubscription();
    await _service.dispose();
  }
}
