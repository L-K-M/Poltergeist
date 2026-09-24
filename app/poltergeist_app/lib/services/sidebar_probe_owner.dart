import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:poltergeist_core/poltergeist_core.dart';

import 'application_error_reporter.dart';
import 'engine_session.dart' show serverConfigForBookmark;
import 'probe_controller.dart';
import 'probe_settings_store.dart';

/// Binds persisted probe settings to one engine's [ProbeController] for
/// every server-backed favorite the sidebar lists (03 §3.4's owning-store
/// role, M5's durable-id edition): constructs the controller over the
/// bridge — subscribing before any target or activity crosses, the #55
/// ordering rule — supplies device-local facts from the [ProbeSettings]
/// store, and publishes the resulting snapshot truth.
///
/// The owner's lifecycle:
///
/// - [syncFavorites] reconciles the probed set with the bookmark list —
///   call it after every store reload. A favorite that leaves the list
///   drops out of probing but keeps its device-local record (a collapsed
///   group or a transient reload must not erase history; only
///   [noteRemoved] purges).
/// - [noteVisible] marks exposure when a row mounts — 02 §4 defers a
///   favorite's first probe until it is visible in the sidebar.
/// - [noteConnected] records a successful connect from this device — the
///   only fact that makes a sync-origin favorite probe-eligible.
/// - [forwardLifecycle] pauses/resumes probing with the app (02 §4's
///   foreground gating).
final class SidebarProbeOwner extends ChangeNotifier {
  SidebarProbeOwner({
    required ProbeBridge bridge,
    required ProbeSettings settings,
    ApplicationErrorReporter? errors,
  }) : // Keep the store seam private to the owner.
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
  ProbePreference _preference = ProbePreference.enabled;
  final Map<String, ServerConfig> _configs = {};
  final Map<String, ServerConfig> _catalogConfigs = {};
  final Set<String> _seenMarked = {};
  final Set<String> _connectedMarked = {};
  Future<void> _tail = Future.value();
  bool _disposed = false;

  /// Live probe truth per favorite id; unknown for ineligible rows. Live
  /// connection state composes over this in the view and outranks it
  /// (02 §4 — the section dot is the composed indicator).
  Map<String, ProbeStatus> get statuses => _controller.statuses;

  /// Reconciles the probed set with [bookmarks]: only identity-backed
  /// rows have an endpoint to probe — a local folder, workspace, or
  /// saved-sync favorite carries no serverId of its own (a `serverConfigId`
  /// reference has no embedded endpoint to dial, 04 §2.2).
  void syncFavorites(Iterable<Bookmark> bookmarks) {
    if (_disposed) return;
    final configs = <String, ServerConfig>{};
    for (final bookmark in bookmarks) {
      if (bookmark.server?.identity == null) continue;
      try {
        // serverConfigForBookmark derives a stable config from the
        // bookmark — id == bookmark.id, which is the pool's serverId.
        configs[bookmark.id] = serverConfigForBookmark(bookmark);
      } on Object catch (error, stackTrace) {
        _errors.report(error, stackTrace);
      }
    }
    _configs
      ..clear()
      ..addAll(configs);
    _enqueue(_reconfigure);
  }

  /// Reconciles the probed set with the shared-mode catalog (04 §4.2):
  /// pulled `serverConfig` records carry their own endpoints, so they
  /// probe under the config's own id — the same key the catalog rows
  /// read their status by. A catalog row's facts persist under that id;
  /// a record the account drops simply stops being probed.
  void syncCatalog(Iterable<ServerConfig> servers) {
    if (_disposed) return;
    _catalogConfigs
      ..clear()
      ..addAll({for (final server in servers) server.id: server});
    _enqueue(_reconfigure);
  }

  /// The favorite's row mounted: persist exposure and re-apply policy —
  /// the first probe waits for this mark (02 §4). Idempotent per id per
  /// owner lifetime; a re-seeded store re-reads persisted facts anyway.
  void noteVisible(String serverId) {
    if (_disposed) return;
    final config = _configs[serverId] ?? _catalogConfigs[serverId];
    if (config == null) return;
    if (!_seenMarked.add(serverId)) return;
    _enqueue(() async {
      if (_disposed) return;
      try {
        await _settings.markSeen(
          serverId: config.id,
          host: config.host,
          port: config.port,
        );
      } on Object catch (error, stackTrace) {
        // A failed write must not disable probing by itself: the
        // reconfigure below re-reads whatever the store holds.
        _errors.report(error, stackTrace);
      }
      await _reconfigure();
    });
  }

  /// A connection from this device succeeded: persist the fact and
  /// re-apply policy. Deduped per (id, endpoint) per owner lifetime —
  /// the persisted record carries the same answer already.
  void noteConnected(
    String serverId, {
    required String host,
    required int port,
  }) {
    if (_disposed) return;
    final key = '$serverId@${host.toLowerCase()}:$port';
    if (!_connectedMarked.add(key)) return;
    _enqueue(() async {
      if (_disposed) return;
      try {
        await _settings.markConnected(
          serverId: serverId,
          host: host,
          port: port,
        );
      } on Object catch (error, stackTrace) {
        _errors.report(error, stackTrace);
      }
      await _reconfigure();
    });
  }

  /// The favorite was deleted for good: drop it from probing now and
  /// purge its device-local record — a deleted id must not keep a fact
  /// trail in settings.json (03 §3.4's reset rule).
  void noteRemoved(String serverId) {
    if (_disposed) return;
    _configs.remove(serverId);
    _catalogConfigs.remove(serverId);
    _seenMarked.remove(serverId);
    // The dedupe keys too: a re-added favorite with the same id/endpoint
    // must re-persist markConnected — the record was just deleted.
    _connectedMarked.removeWhere((key) => key.startsWith('$serverId@'));
    _enqueue(() async {
      try {
        await _settings.removeServer(serverId);
      } on Object catch (error, stackTrace) {
        // Removal failing must not keep probe truth around: the
        // reconfigure below clears the target regardless.
        _errors.report(error, stackTrace);
      }
      await _reconfigure();
    });
  }

  /// Forwards the app lifecycle: probes run only while foregrounded
  /// (02 §4). Unknown state fails closed inside the controller. Queued
  /// like the store-driven updates so a lifecycle change can never
  /// overtake a pending configuration with the previous set.
  void forwardLifecycle(AppLifecycleState? state) {
    if (_disposed || _lifecycle == state) return;
    _lifecycle = state;
    _enqueue(_reconfigure);
  }

  /// Re-reads facts and re-applies the complete policy snapshot. Fails
  /// closed only when the reads themselves fail: an unreadable store
  /// must never enable probing; an unwritable one may still read.
  Future<void> _reconfigure() async {
    if (_disposed) return;
    try {
      _preference = await _settings.loadGlobalPreference();
    } on Object catch (error, stackTrace) {
      _errors.report(error, stackTrace);
      _preference = ProbePreference.disabled;
    }
    final favorites = <ProbeFavorite>[];
    // A syncFavorites/noteRemoved landing mid-loop mutates the config
    // maps — iterate a snapshot so an awaited read cannot throw
    // ConcurrentModificationError.
    final targets = [
      ..._configs.values,
      ..._catalogConfigs.values,
    ];
    for (final config in targets) {
      ProbeServerFacts facts;
      try {
        facts = await _settings.loadServerFacts(
          serverId: config.id,
          host: config.host,
          port: config.port,
        );
      } on Object catch (error, stackTrace) {
        _errors.report(error, stackTrace);
        facts = ProbeServerFacts.unseen;
      }
      favorites.add(
        ProbeFavorite(
          server: config,
          // Every favorite listed here was created on this device or
          // adopted at import; M6's sync pull marks its rows at apply
          // time. Sync-origin favorites gate on the connection fact.
          origin: FavoriteOrigin.device,
          exposure: facts.exposure,
          connection: facts.connected,
          // Per-favorite probe opt-out persists with the settings slice
          // (02 §4); nothing the store carries today expresses one.
          preference: ProbePreference.enabled,
        ),
      );
    }
    // A dispose landing during the awaited reads must not touch the
    // torn-down controller.
    if (_disposed) return;
    await _controller.update(
      favorites: favorites,
      preference: _preference,
      lifecycle: _lifecycle,
    );
  }

  /// Serializes store reads/writes and the controller updates they feed,
  /// so a stale configuration can never land after a removal.
  void _enqueue(Future<void> Function() operation) {
    final run = _tail.then((_) => operation());
    _tail = run.then<void>((_) {}, onError: (_, _) {});
    _errors.observe(run);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controller.removeListener(notifyListeners);
    _controller.dispose();
    super.dispose();
  }
}
