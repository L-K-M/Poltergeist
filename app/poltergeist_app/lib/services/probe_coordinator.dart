import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:poltergeist_core/poltergeist_core.dart';

import 'application_error_reporter.dart';
import 'probe_controller.dart';
import 'probe_settings_store.dart';

/// Binds persisted probe settings to one engine's [ProbeController]
/// (03 §3.4's owning-store role): constructs the controller over the
/// bridge — subscribing before any target or activity is sent, the #55
/// ordering rule — supplies device-local facts from the [ProbeSettings]
/// store, and publishes the resulting snapshot truth.
///
/// The interim server list's session is the only caller today; the same
/// seam serves M5's bookmark-backed owner with durable bookmark ids.
final class ProbeCoordinator extends ChangeNotifier {
  ProbeCoordinator({
    required ProbeBridge bridge,
    required ProbeSettings settings,
    ApplicationErrorReporter? errors,
  }) : // Keep the store seam private to the coordinator.
       // ignore: prefer_initializing_formals
       _settings = settings,
       // Keep the reporter private while allowing test-only injection.
       // ignore: prefer_initializing_formals
       _errors = errors ?? ApplicationErrorReporter() {
    // Construction subscribes: replacement snapshots precede the ack, and
    // nothing may send targets before a listener exists.
    _controller = ProbeController(bridge, errors: _errors);
    _controller.addListener(notifyListeners);
  }

  final ProbeSettings _settings;
  final ApplicationErrorReporter _errors;
  late final ProbeController _controller;

  AppLifecycleState? _lifecycle;
  ServerConfig? _server;
  ProbeFavorite? _favorite;
  ProbePreference _preference = ProbePreference.enabled;
  Future<void> _tail = Future.value();
  bool _disposed = false;

  /// Live probe truth per server id; unknown for ineligible rows.
  Map<String, ProbeStatus> get statuses => _controller.statuses;

  /// The interim list now shows [config]: persist exposure and configure
  /// the controller with the store's device-local facts.
  void showServer(ServerConfig config) {
    if (_disposed) return;
    _server = config;
    _enqueue(() => _markSeenAndConfigure(config));
  }

  /// A successful connection from this device: persist the fact and
  /// re-apply policy (02 §4 — a synced-in favorite becomes eligible only
  /// after connecting here).
  void markConnected(ServerConfig config) {
    if (_disposed || !_isCurrent(config)) return;
    _enqueue(() => _markConnectedAndConfigure(config));
  }

  /// The server left the interim list: clear targets and drop its
  /// device-local record — an ephemeral bookmark id can never recur.
  void hideServer(String serverId) {
    if (_disposed || _server?.id != serverId) return;
    _server = null;
    _favorite = null;
    _enqueue(() async {
      try {
        await _settings.removeServer(serverId);
      } catch (error, stackTrace) {
        // Removal must not keep probe truth around: the controller update
        // below clears targets regardless.
        _errors.report(error, stackTrace);
      }
      await _controller.update(
        favorites: const [],
        preference: _preference,
        lifecycle: _lifecycle,
      );
    });
  }

  /// Forwards the app lifecycle: probes run only while foregrounded
  /// (02 §4). Unknown state fails closed inside the controller.
  void forwardLifecycle(AppLifecycleState? state) {
    if (_disposed || _lifecycle == state) return;
    _lifecycle = state;
    _errors.observe(
      _controller.update(
        favorites: _favorite == null ? const [] : [_favorite!],
        preference: _preference,
        lifecycle: state,
      ),
    );
  }

  Future<void> _markSeenAndConfigure(ServerConfig config) async {
    try {
      await _settings.markSeen(
        serverId: config.id,
        host: config.host,
        port: config.port,
      );
      final global = await _settings.loadGlobalPreference();
      final facts = await _settings.loadServerFacts(
        serverId: config.id,
        host: config.host,
        port: config.port,
      );
      await _configure(config, global, facts);
    } catch (error, stackTrace) {
      // An unreadable store must never enable probing: fail closed.
      _errors.report(error, stackTrace);
      await _configure(config, ProbePreference.disabled, ProbeServerFacts.unseen);
    }
  }

  Future<void> _markConnectedAndConfigure(ServerConfig config) async {
    try {
      await _settings.markConnected(
        serverId: config.id,
        host: config.host,
        port: config.port,
      );
      final global = await _settings.loadGlobalPreference();
      final facts = await _settings.loadServerFacts(
        serverId: config.id,
        host: config.host,
        port: config.port,
      );
      await _configure(config, global, facts);
    } catch (error, stackTrace) {
      _errors.report(error, stackTrace);
      await _configure(config, ProbePreference.disabled, ProbeServerFacts.unseen);
    }
  }

  Future<void> _configure(
    ServerConfig config,
    ProbePreference global,
    ProbeServerFacts facts,
  ) async {
    if (_disposed || !_isCurrent(config)) return;
    _preference = global;
    _favorite = ProbeFavorite(
      server: config,
      origin: FavoriteOrigin.device,
      exposure: facts.exposure,
      connection: facts.connected,
      // Per-favorite opt-out persists with M5's bookmark store (02 §4);
      // the interim surface's bookmarks cannot carry one.
      preference: ProbePreference.enabled,
    );
    await _controller.update(
      favorites: [_favorite!],
      preference: global,
      lifecycle: _lifecycle,
    );
  }

  bool _isCurrent(ServerConfig config) =>
      !_disposed && identical(_server, config);

  /// Serializes store reads/writes and the controller updates they feed,
  /// so a stale configuration can never land after a hide or replacement.
  void _enqueue(Future<void> Function() operation) {
    final run = _tail.then((_) => operation());
    _tail = run.then<void>((_) {}, onError: (_, _) {});
    _errors.observe(run);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final server = _server;
    _server = null;
    _favorite = null;
    if (server != null) {
      _enqueue(() async {
        try {
          await _settings.removeServer(server.id);
        } catch (error, stackTrace) {
          _errors.report(error, stackTrace);
        }
      });
    }
    _controller.dispose();
    super.dispose();
  }
}
