import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:poltergeist_core/poltergeist_core.dart';

import 'application_error_reporter.dart';

enum ProbePreference { enabled, disabled }

enum FavoriteOrigin { device, sync }

enum FavoriteExposure { unseen, seen }

enum FavoriteConnection { neverConnected, connected }

/// Device-local facts for this bookmark's current host/port (02 §4).
///
/// The owner supplies persisted facts; retargeting must reset exposure and
/// connection history. These facts must never be imported from sync records.
final class ProbeFavorite {
  const ProbeFavorite({
    required this._server,
    required this._origin,
    required this._exposure,
    required this._connection,
    this._preference = ProbePreference.enabled,
  });

  final ServerConfig _server;
  final FavoriteOrigin _origin;
  final FavoriteExposure _exposure;
  final FavoriteConnection _connection;
  final ProbePreference _preference;

  bool get _eligible =>
      _preference == ProbePreference.enabled &&
      _exposure == FavoriteExposure.seen &&
      (_origin == FavoriteOrigin.device ||
          _connection == FavoriteConnection.connected);
}

/// Mirrors probe truth without owning sockets, timers, or bookmark storage.
///
/// One controller owns the bridge's probe configuration. The composition root
/// forwards lifecycle/settings changes and disposes it before the engine.
/// Recreate it with each engine; updates after stream closure are ignored.
/// Live connection state is composed separately and outranks these results.
final class ProbeController extends ChangeNotifier {
  ProbeController(this._bridge, {ApplicationErrorReporter? errors})
    : _errors = errors ?? ApplicationErrorReporter() {
    // A target replacement can publish synchronously, before acknowledging.
    _subscription = _bridge.probeStatuses.listen(
      _receive,
      onError: _streamFailed,
      onDone: _engineStopped,
    );
  }

  final ProbeBridge _bridge;
  final ApplicationErrorReporter _errors;
  late final StreamSubscription<ProbeStatusesEvent> _subscription;
  Map<String, (String, int)> _targets = const {};
  Map<String, ProbeStatus> _statuses = const {};
  ProbeActivity _activity = ProbeActivity.paused;
  Object _revision = Object();
  ProbeStatusesEvent? _buffered;
  Future<void> _pending = Future.value();
  bool _ready = false;
  bool _configured = false;
  bool _failed = false;
  bool _engineClosed = false;
  bool _disposed = false;

  /// Complete immutable snapshot, including unknown for ineligible favorites.
  /// Lifecycle pause retains the last observation; settings opt-out clears it.
  Map<String, ProbeStatus> get statuses => _statuses;

  /// Applies a complete policy snapshot. Unknown lifecycle state fails closed.
  /// Bridge failures are reported locally; a later explicit update may retry.
  /// Throws [ArgumentError] synchronously for duplicate favorite ids.
  Future<void> update({
    required List<ProbeFavorite> favorites,
    required ProbePreference preference,
    required AppLifecycleState? lifecycle,
  }) {
    if (_disposed || _engineClosed) return Future.value();

    final ids = <String>{};
    final configs = <ServerConfig>[];
    for (final favorite in favorites) {
      final server = favorite._server;
      if (!ids.add(server.id)) throw ArgumentError.value(server.id);
      if (preference == ProbePreference.enabled && favorite._eligible) {
        configs.add(server);
      }
    }

    final targets = {
      for (final config in configs)
        config.id: (config.host.toLowerCase(), config.port),
    };
    final activity =
        preference == ProbePreference.enabled &&
            lifecycle == AppLifecycleState.resumed &&
            targets.isNotEmpty
        ? ProbeActivity.running
        : ProbeActivity.paused;
    final targetsChanged = !mapEquals(targets, _targets);
    final needsUpdate =
        !_configured || _failed || targetsChanged || activity != _activity;

    final statuses = {
      for (final id in ids)
        id: targets.containsKey(id) && targets[id] == _targets[id] && !_failed
            ? _statuses[id] ?? ProbeStatus.unknown
            : ProbeStatus.unknown,
    };
    _targets = targets;
    _activity = activity;
    final changed = !mapEquals(statuses, _statuses);
    _statuses = Map.unmodifiable(statuses);

    var result = _pending;
    if (needsUpdate) {
      _configured = true;
      _failed = false;
      _ready = false;
      _buffered = null;
      final revision = _revision = Object();
      result = _pending = _configure(
        revision,
        List.unmodifiable(configs),
        activity,
      );
    }

    // Listeners may immediately opt out. Establish the request's
    // identity first, so their newer configuration always wins.
    if (changed && !_disposed) notifyListeners();
    return result;
  }

  Future<void> _configure(
    Object revision,
    List<ServerConfig> configs,
    ProbeActivity activity,
  ) async {
    try {
      // Send restrictions now, never behind an older request's pending ack.
      // Observe both completions to avoid unhandled errors; report only the first.
      await Future.wait([
        if (activity == ProbeActivity.paused)
          Future.sync(() => _bridge.setProbeActivity(ProbeActivity.paused)),
        Future.sync(() => _bridge.setProbeTargets(configs)),
      ]);
      if (!_isCurrent(revision)) return;

      _ready = true;
      final buffered = _buffered;
      _buffered = null;
      if (buffered != null) _receive(buffered);
      if (!_isCurrent(revision) || activity != ProbeActivity.running) return;

      await _bridge.setProbeActivity(ProbeActivity.running);
      if (!_isCurrent(revision)) return;
    } catch (error, stack) {
      if (!_isCurrent(revision)) return;
      _failed = true;
      _ready = false;
      _buffered = null;
      _stopProbes();
      _publishUnknown();
      _errors.report(error, stack);
    }
  }

  bool _isCurrent(Object revision) =>
      !_disposed && !_engineClosed && identical(_revision, revision);

  void _receive(ProbeStatusesEvent event) {
    if (_disposed || _engineClosed || _failed) return;
    if (!_ready) {
      _buffered = event;
      return;
    }
    if (_activity != ProbeActivity.running) return;

    _publish({
      for (final id in _statuses.keys)
        id: _targets.containsKey(id)
            ? event.statuses[id] ?? ProbeStatus.unknown
            : ProbeStatus.unknown,
    });
  }

  void _publish(Map<String, ProbeStatus> statuses) {
    if (_disposed || mapEquals(statuses, _statuses)) return;
    _statuses = Map.unmodifiable(statuses);
    notifyListeners();
  }

  void _publishUnknown() =>
      _publish({for (final id in _statuses.keys) id: ProbeStatus.unknown});

  void _streamFailed(Object error, StackTrace stack) {
    if (_disposed || _engineClosed) return;
    _engineStopped();
    _stopProbes();
    _errors.report(error, stack);
  }

  void _engineStopped() {
    if (_disposed || _engineClosed) return;
    _engineClosed = true;
    _buffered = null;
    _publishUnknown();
  }

  void _stopProbes() {
    _errors.observe(
      Future.sync(() => _bridge.setProbeActivity(ProbeActivity.paused)),
    );
    _errors.observe(Future.sync(() => _bridge.setProbeTargets(const [])));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _buffered = null;
    if (!_engineClosed) _stopProbes();
    _errors.observe(_subscription.cancel());
    super.dispose();
  }
}
