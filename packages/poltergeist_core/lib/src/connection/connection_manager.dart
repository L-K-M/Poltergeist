import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:seance_core/seance_core.dart';

import 'credential_resolution.dart';
import 'incident_store.dart';
import 'pool_key.dart';
import 'pool_policy.dart';
import 'ssh_cleanup.dart';
import 'ssh_transport.dart';

part 'reconnect.dart';

/// Lifecycle of one server as the connection layer sees it (03 §3.2).
enum ServerConnectionState {
  connecting,

  /// Authenticated transports exist.
  connected,

  /// A live pool lost its transport and is retrying (03 §3.3).
  reconnecting,

  /// No transports (never connected, torn down, or connect failed).
  disconnected,

  /// Host key changed — every operation fails until the user reviews the
  /// key at the next connect prompt (D18: never auto-repinned).
  blocked,
}

/// One connection observation for a serverId: the state plus, when the
/// state explains a failure, the user-facing one-liner that [watchServer]
/// delivers with it (03 §3.2). Cancellation outcomes carry no detail —
/// there is nothing to diagnose.
class ServerStatus {
  final ServerConnectionState state;

  /// E.g. the summarized connect-failure line or the host-key block
  /// reason; null for healthy and cancelled states.
  final String? detail;

  const ServerStatus(this.state, {this.detail});

  @override
  bool operator ==(Object other) =>
      other is ServerStatus && other.state == state && other.detail == detail;

  @override
  int get hashCode => Object.hash(state, detail);

  @override
  String toString() =>
      'ServerStatus(${state.name}${detail == null ? '' : ', $detail'})';
}

/// One appended line of a live connect-attempt transcript (03 §3.3),
/// forwarded to every serverId referencing the pool that opened the
/// attempt; the engine host coalesces these into port batches.
class ConnectLogLine {
  final String serverId;
  final String line;

  const ConnectLogLine({required this.serverId, required this.line});

  @override
  bool operator ==(Object other) =>
      other is ConnectLogLine &&
      other.serverId == serverId &&
      other.line == line;

  @override
  int get hashCode => Object.hash(serverId, line);

  @override
  String toString() => 'ConnectLogLine($serverId, $line)';
}

/// The engine-side connection layer (03 §3.2). `serverId` strings are
/// bookmark-derived server identities (03 §3.5).
abstract interface class ConnectionManager {
  /// One dedicated SFTP browse channel per pane-tab. Listings stay snappy
  /// while transfers saturate other channels — except on interactive-auth
  /// servers, where the single-transport cap (growth rule 2) shares one TCP
  /// connection and saturation slows listings: the accepted D5 cost.
  ///
  /// Budget exhaustion (every transport at `maxChannelsPerTransport`) never
  /// fails and never blocks the caller: transport growth where rule 3
  /// allows it, then re-use of the least-recently-used backgrounded
  /// pane-tab's channel — the queue-don't-fail guarantee generalized to
  /// every exhaustion path.
  Future<PaneChannel> openBrowseChannel(
    String serverId, {
    required String paneTabId,
  });

  /// A transfer worker borrows a channel; [TransferChannelLease.release]
  /// returns it to the pool. Blocks while the pool is at capacity.
  Future<TransferChannelLease> leaseTransferChannel(String serverId);

  /// The server's connection status — state, current value first, plus
  /// the failure one-liner when the state explains one. A shared pool's
  /// status fans out to every serverId referencing it (03 §3.5).
  Stream<ServerStatus> watchServer(String serverId);

  /// Live connect-attempt transcript lines, one event per appended line
  /// in attempt order. Not batched here: the engine host bounds port
  /// traffic (03 §5); in-process callers get every line as written.
  ///
  /// Live-only: lines emitted before subscription are not replayed. Attach
  /// before connecting when the complete attempt transcript is required.
  /// One stream multiplexes every server; filter events by `serverId`.
  /// Equality is structural, but repeated equal lines remain transcript data:
  /// never apply `distinct()` to this stream.
  Stream<ConnectLogLine> get connectLog;

  /// ServerIds with live pools — feeds ProbeService so connected servers
  /// are skipped and reported online for free (03 §3.4).
  Future<Set<String>> connectedServerIds();

  /// Drops this serverId's reference to its pool: closes its browse
  /// channels, force-releases its transfer leases. The pool (and its
  /// resolved credentials) survives while sibling serverIds reference it.
  Future<void> disconnectServer(String serverId);

  /// Deletes the bookmark's connection state: drops its pool reference
  /// like [disconnectServer], then cascades deletion of its trust-incident
  /// records (owner decision 2026-09-09, option 3a). The endpoint's block
  /// ends when its last bookmark's records are gone; a later connect
  /// re-detects whatever key the server presents (D18 unchanged).
  ///
  /// The id is gone for good, so the watches it had complete — unlike
  /// [disconnectServer], which keeps them open for a reconnect. The manager
  /// keeps no tombstone: watching the id again afterwards behaves like
  /// watching any id it never saw.
  Future<void> removeBookmark(String serverId);
}

/// A browse channel bound to one pane-tab (03 §3.2).
abstract interface class PaneChannel {
  /// The current VFS, or this binding's permanent recovery error. A failed
  /// binding requires an explicit open; healthy siblings stay connected.
  RemoteFileSystem get fs;

  /// `canonicalize('.')` at open — the server-side home, Séance-style.
  String get homePath;

  /// The tab closes its channel when it closes or navigates off the
  /// server.
  Future<void> close();

  /// Pass the VFS used by the failed operation; its identity rejects stale
  /// failures after rebinding. Only disconnected failures trigger recovery.
  void reportFailure(RemoteFileSystem source, RemoteFileException error);
}

/// A borrowed transfer channel (03 §3.2).
abstract interface class TransferChannelLease {
  RemoteFileSystem get fs;

  /// Returns the channel to the pool.
  Future<void> release();

  /// Reports transport loss without retrying the interrupted operation.
  void reportFailure(RemoteFileSystem source, RemoteFileException error);
}

/// A supplied password does not tell SSH whether the vault resolver prompted.
enum CredentialOrigin { stored, prompted }

/// Pool-owned secrets and their prompt provenance (03 §3.2, D18).
class ResolvedCredentials {
  final SshCredentials credentials;
  final CredentialOrigin origin;

  const ResolvedCredentials({required this.credentials, required this.origin});
}

/// [ConnectionManager] over per-endpoint transport pools.
///
/// ```
/// serverId (bookmark) ─► reference ─┐
/// serverId (bookmark) ─► reference ─┼─► pool keyed by (host, port,
///                                    │   username, jump host) — 03 §3.5
///                                    │     transport 1: browse + transfer ch
///                                    │     transport 2: transfer ch (growth)
///                                    └─► one shared TOFU verifier, one
///                                        first-connect prompt per pool
/// ```
///
/// The growth rules below are the part that must never be improvised
/// (03 §3.2):
/// 1. the first connect is serialized per pool — one TOFU prompt;
/// 2. interactive auth caps the pool at one transport — never a second
///    2FA prompt (D5);
/// 3. non-interactive auth grows up to `maxTransports` reusing the
///    resolved credentials, with all prompting disabled;
/// 4. transports are created on demand and torn down when idle; budget
///    exhaustion queues or shares instead of failing.
class PooledConnectionManager implements ConnectionManager {
  final Future<ServerConfig> Function(String serverId) _resolveServer;
  final Future<ResolvedCredentials> Function(
    ServerConfig config,
    CredentialResolutionScope scope,
  )
  _resolveCredentials;
  final TofuVerifier _tofu;
  final HostKeyPrompter _onHostKey;
  final KeyboardInteractiveResponder? _onKeyboardInteractive;
  final PoolPolicy _policy;
  final SshTransportOpener _openTransport;
  final Prober _prober;
  final Random _reconnectRandom;
  final IncidentStore? _incidentStore;
  final void Function(Object error)? _onIncidentStoreError;
  final void Function(String, RemoteFileException, {String? paneTabId})?
  _onRecoveryFailure;

  final Map<String, _ServerReference> _references = {};
  final Map<String, Future<_ServerReference>> _pendingReferences = {};
  final Map<PoolKey, _EndpointPool> _pools = {};
  final Map<PoolKey, _HostKeyIncident> _incidents = {};

  /// Which bookmark ids own the incident for each blocked endpoint — the
  /// 3a cascade keys (each owning bookmark also holds a persisted record
  /// when a store is configured). Populated from the store at load and
  /// kept in sync with it; the endpoint's block ends when the last owner
  /// leaves.
  final Map<PoolKey, Set<String>> _incidentOwners = {};
  bool _incidentsLoaded = false;
  Future<void>? _incidentsLoading;
  final Map<String, StreamController<ServerStatus>> _events = {};
  final Map<String, ServerStatus> _lastStatuses = {};
  final StreamController<ConnectLogLine> _connectLog =
      StreamController<ConnectLogLine>.broadcast();

  /// [resolveServer] loads config only; [resolveCredentials] may access the
  /// vault or prompt and runs once inside each pool's first connect. It
  /// receives the resolution's dismissal scope: the manager trips it when
  /// the pool's lifetime ends mid-resolution, so a resolver-owned prompt
  /// closes instead of parking on an answer the pool rejects as stale.
  /// [onRecoveryFailure] receives terminal background failures even without
  /// an awaiting acquisition. A pane id limits the failure to that binding;
  /// null means the whole pool failed. Observer errors cannot affect recovery.
  /// The observer runs synchronously during cleanup; it must not re-enter
  /// this manager. Forward diagnostics to the owning service instead.
  ///
  /// [incidentStore] persists declined trust incidents across restarts
  /// (owner decision 2a); null keeps them session-only. The store is
  /// loaded lazily at the first reference resolution — an unreadable
  /// store means no incidents, never a crash, never auto-trust.
  ///
  /// [onIncidentStoreError] observes persistence failures without affecting
  /// them: writes and deletes are best-effort, so the wiring slice can
  /// surface a local notice (like vault-save failures) without the pool
  /// changing behavior. The observer must not throw.
  PooledConnectionManager({
    required this._resolveServer,
    required this._resolveCredentials,
    required this._tofu,
    required this._onHostKey,
    this._onKeyboardInteractive,
    this._policy = const PoolPolicy(),
    this._openTransport = openDartSshTransport,
    this._prober = const TcpBannerProber(),
    Random? reconnectRandom,
    this._incidentStore,
    this._onIncidentStoreError,
    this._onRecoveryFailure,
  }) : _reconnectRandom = reconnectRandom ?? Random() {
    // A nonpositive cap turns an outage into a zero-delay retry loop.
    if (_policy.reconnectBackoffCap <= Duration.zero) {
      throw ArgumentError.value(
        _policy.reconnectBackoffCap,
        'reconnectBackoffCap',
        'Must be positive.',
      );
    }
    // A zero keepalive interval would spin the event loop with periodic
    // pings; the cadence must be a real interval.
    if (_policy.keepAliveInterval <= Duration.zero) {
      throw ArgumentError.value(
        _policy.keepAliveInterval,
        'keepAliveInterval',
        'Must be positive.',
      );
    }
  }

  @override
  Future<PaneChannel> openBrowseChannel(
    String serverId, {
    required String paneTabId,
  }) => _withReference(
    serverId,
    (reference) => _openBrowse(reference, paneTabId),
  );

  Future<PaneChannel> _openBrowse(
    _ServerReference reference,
    String paneTabId,
  ) async {
    final serverId = reference.serverId;
    final pool = reference.pool;
    final clientKey = (serverId, paneTabId);

    // Recovery preserves bindings; new callers must not take a dead handle.
    await _ensureFirstTransport(pool, reference);
    _checkAcquisition(reference);

    // Idempotent per pane-tab: re-opening re-uses the channel and refreshes
    // its LRU position (navigation within the server keeps its channel).
    // A blocked pool has no bindings — `_blockPool` clears them with the
    // transports — so this fast path can never bypass the blocked check.
    final existing = pool.browseByClient[clientKey];
    if (existing != null) {
      pool.browseByClient.remove(clientKey);
      pool.browseByClient[clientKey] = existing;
      return existing;
    }

    final handle = await _acquireBrowseChannel(reference);

    // Count against the browse budget from the moment the handle is ours —
    // an idle-transfer steal stays `transferIdle` until `_bindBrowse`, and
    // the home resolution below awaits inside that window.
    handle.use = _ChannelUse.browse;

    // A failed home resolution must not strand a budget-counted handle —
    // and the cleanup must never mask the original failure.
    try {
      _checkAcquisition(reference, handle);
      final homePath = handle.homePath;
      handle.homePath = homePath ?? await handle.channel.fs.canonicalize('.');
      _checkAcquisition(reference, handle);
    } on Object {
      try {
        if (handle.browseClients == 0) await _closeHandle(pool, handle);
      } on Object {
        // Best-effort cleanup on the error path.
      }
      rethrow;
    }

    // A concurrent openBrowseChannel for the same tab may have bound a
    // channel while this one was opening — the loser closes its handle so
    // the binding map never orphans one.
    final raced = pool.browseByClient[clientKey];
    if (raced != null) {
      // `handle` may be a channel another pane-tab still shares (the LRU
      // path) — only an exclusively-owned channel may close here.
      if (!identical(raced._handle, handle) && handle.browseClients == 0) {
        await _closeHandle(pool, handle);
      }
      return raced;
    }

    return _bindBrowse(pool, clientKey, handle);
  }

  @override
  Future<TransferChannelLease> leaseTransferChannel(String serverId) =>
      _withReference(serverId, _leaseTransfer);

  Future<TransferChannelLease> _leaseTransfer(
    _ServerReference reference,
  ) async {
    final serverId = reference.serverId;
    final pool = reference.pool;

    // A worker request is not the explicit changed-key review action.
    _throwIfBlocked(pool);
    await _ensureFirstTransport(pool, reference);
    _checkAcquisition(reference);

    final handle = await _acquireTransferChannel(reference);
    try {
      _checkAcquisition(reference, handle);
    } on Object {
      try {
        await _closeHandle(pool, handle);
      } on Object {
        // Preserve the acquisition failure, even if cleanup is broken.
      }
      rethrow;
    }
    handle.use = _ChannelUse.transferLeased;
    handle.leaseServerId = serverId;
    pool.leasedTransfer.add(handle);

    return _LeaseView(this, pool, handle);
  }

  Future<T> _withReference<T>(
    String serverId,
    Future<T> Function(_ServerReference reference) acquire,
  ) async {
    final reference = await _referenceFor(serverId);
    _checkReference(reference);
    final pool = reference.pool;
    pool.acquisitions++;
    try {
      return await acquire(reference);
    } finally {
      pool.acquisitions--;
      try {
        await _maybeTearDown(pool);
      } on Object {
        // Teardown must not replace the acquisition's outcome.
      }
    }
  }

  void _checkReference(_ServerReference reference) {
    if (identical(_references[reference.serverId], reference)) return;
    throw _disconnectedAcquisition();
  }

  void _checkAcquisition(_ServerReference reference, [_ChannelHandle? handle]) {
    _checkReference(reference);
    _throwIfBlocked(reference.pool);
    if (handle == null) return;
    if (!handle.closed &&
        !handle.slot.transport.isClosed &&
        reference.pool.transports.contains(handle.slot)) {
      return;
    }
    throw _disconnectedAcquisition();
  }

  RemoteFileException _disconnectedAcquisition() => const RemoteFileException(
    kind: RemoteFileErrorKind.disconnected,
    operation: 'acquire channel',
    message: 'The server was disconnected while acquiring a channel.',
  );

  @override
  Stream<ServerStatus> watchServer(String serverId) {
    // Current value first, then live updates, with plain async stream
    // semantics (`.first`, `await for`, and `listen` all behave normally).
    // The initial value is computed at listen time — a caller that stores
    // the stream and listens later must not start from a snapshot taken
    // before intermediate state changes.
    return Stream.multi((listener) {
      listener.add(_currentStatusOf(serverId));
      final subscription = _eventsFor(serverId).stream.listen(
        listener.add,
        onError: listener.addError,
        // The controller closes when its bookmark is removed: complete the
        // watcher instead of leaving it on a stream that can never emit.
        onDone: listener.close,
      );
      listener.onPause = subscription.pause;
      listener.onResume = subscription.resume;
      listener.onCancel = subscription.cancel;
    });
  }

  @override
  Stream<ConnectLogLine> get connectLog => _connectLog.stream;

  /// Use live pool state for snapshots and joins: cached emissions can
  /// predate registration or transport death (03 §3.3). The detail rides
  /// along only where the live pool knows one (a block reason); otherwise
  /// a cached status whose state still matches supplies the last detail.
  ServerStatus _currentStatusOf(String serverId) {
    final reference = _references[serverId];
    if (reference != null) {
      final pool = reference.pool;
      if (pool.blocked) {
        return ServerStatus(
          ServerConnectionState.blocked,
          detail: pool.blockDetail,
        );
      }
      if (pool._reconnect != null) {
        return const ServerStatus(ServerConnectionState.reconnecting);
      }

      // Transports die asynchronously and are evicted lazily — report
      // connected only while one is actually alive.
      final hasLiveTransport = pool.transports.any(
        (slot) => !slot.transport.isClosed,
      );
      if (hasLiveTransport) {
        return const ServerStatus(ServerConnectionState.connected);
      }
      if (pool.firstConnect != null) {
        return const ServerStatus(ServerConnectionState.connecting);
      }

      // A reference with no live transport and no in-flight connect is not
      // connected — the emitted-status cache may still say `connected` from
      // before the death, so it must not win here. Reconnect (03 §3.3) will
      // make this window report `reconnecting` instead.
      if (pool.transports.isNotEmpty) {
        final cached = _lastStatuses[serverId];
        if (cached != null &&
            cached.state == ServerConnectionState.disconnected) {
          return cached;
        }

        return const ServerStatus(ServerConnectionState.disconnected);
      }
    }

    final cached = _lastStatuses[serverId];
    if (cached != null) return cached;
    return const ServerStatus(ServerConnectionState.disconnected);
  }

  @override
  Future<Set<String>> connectedServerIds() async => liveServerIds();

  /// Current transport truth for the engine's synchronous probe callback.
  /// Each read returns a fresh set; delayed state events cannot stale it.
  /// Matching targets prevent an edited bookmark borrowing its old pool's
  /// reachability while that transport still serves an existing pane.
  Set<String> liveServerIds({List<ServerConfig>? matchingTargets}) {
    final connected = <String>{};
    final targets = matchingTargets == null
        ? null
        : {for (final target in matchingTargets) target.id: target};

    for (final entry in _references.entries) {
      final pool = entry.value.pool;
      if (targets != null) {
        final target = targets[entry.key];
        if (target == null ||
            pool.key.host != target.host.trim().toLowerCase() ||
            pool.key.port != target.port) {
          continue;
        }
      }

      // Transports die asynchronously and are evicted lazily — count only
      // pools that still hold a live one.
      final hasLiveTransport = pool.transports.any(
        (slot) => !slot.transport.isClosed,
      );
      if (hasLiveTransport && !pool.blocked) connected.add(entry.key);
    }

    return connected;
  }

  @override
  Future<void> disconnectServer(String serverId) async {
    final pending = _pendingReferences.remove(serverId);
    final reference = _references.remove(serverId);
    if (reference == null) {
      if (pending == null) return;

      // Removing the pending identity invalidates its eventual resolution.
      _emit(serverId, const ServerStatus(ServerConnectionState.disconnected));
      return;
    }

    final pool = reference.pool;
    pool.references.remove(serverId);
    _emit(serverId, const ServerStatus(ServerConnectionState.disconnected));
    _lastStatuses.remove(serverId);

    // Abandon the pool before cleanup: new sessions must not join its
    // pending connects, and idle timers must not outlive its last reference.
    if (pool.references.isEmpty) {
      _cancelReconnect(pool);
      _cancelKeepAlive(pool);
      for (final slot in pool.transports) {
        _cancelIdleTimer(slot);
      }
      if (identical(_pools[pool.key], pool)) _pools.remove(pool.key);

      // An in-flight first connect cannot serve anyone anymore: dismiss
      // its resolution so the resolver's prompt closes instead of parking
      // on an answer the pool will reject as stale.
      pool._resolution?.dismiss();
    }

    // Fail this server's queued waiters before any await below: closing
    // channels frees capacity and can resume a waiter for this serverId
    // mid-teardown, letting it acquire a channel the disconnect must
    // release.
    _failWaiters(pool, serverId);

    // Close this id's browse bindings (shared channels outlive one tab).
    final clientKeys = [
      for (final key in pool.browseByClient.keys)
        if (key.$1 == serverId) key,
    ];

    // Force-release its transfer leases by closing the channels: in-flight
    // work fails with `disconnected`, which is exactly the signal the
    // transfer queue (M4) turns into its queued flip (03 §3.5).
    final leases = [
      for (final handle in pool.leasedTransfer)
        if (handle.leaseServerId == serverId) handle,
    ];

    // Start every independent close before waiting: a stalled channel must
    // not postpone cleanup of its siblings by another grace period each.
    await Future.wait([
      for (final key in clientKeys) _closeBrowseClient(pool, key),
      for (final handle in leases) _closeHandle(pool, handle),
    ]);

    if (pool.references.isEmpty) {
      // Last reference out: transports down, resolved credentials wiped.
      await _tearDownPool(pool);
    } else {
      await _pumpWaiters(pool);
    }
  }

  @override
  Future<void> removeBookmark(String serverId) async {
    // Load before touching owners: a delete racing the lazy store load
    // could otherwise let the in-flight load re-register the removed
    // bookmark as an owner from the record it already read, leaving a
    // block no live bookmark owns.
    await _ensureIncidentsLoaded();

    // The bookmark is gone entirely: its pool reference goes first, then
    // its incident records (3a). The cascade runs in a `finally` so a
    // thrown teardown cannot strand records or owner stakes for an id the
    // app has already deleted from its store (audit finding F) — removeBookmark
    // may never be retried after that.
    try {
      await disconnectServer(serverId);
    } finally {
      _withdrawIncidentStakes(serverId);
      // Fan-out teardown before the awaited delete: the id can emit nothing
      // from here on, and the delete's outcome cannot skip it.
      // (`_deleteStoredBookmark` catches and reports its own failures — a
      // stale record must not fail a removal the app cannot retry.)
      _forgetStateFanOut(serverId);
      await _deleteStoredBookmark(serverId);
    }
  }

  /// Drops the removed bookmark's state fan-out (audit finding C): a
  /// deleted id can never emit again, so its controller closes instead of
  /// accumulating per-id state in a long-lived engine. `disconnectServer`
  /// deliberately keeps it — a disconnected bookmark may reconnect.
  void _forgetStateFanOut(String serverId) {
    _lastStatuses.remove(serverId);
    unawaited(_events.remove(serverId)?.close());
  }

  /// Withdraws this bookmark's stake in every blocked endpoint. The block
  /// survives while any other bookmark still carries a record — deleting
  /// one bookmark of a shared server must not unblock its siblings.
  void _withdrawIncidentStakes(String serverId) {
    for (final key in _incidentOwners.keys.toList()) {
      final owners = _incidentOwners[key]!;
      if (!owners.remove(serverId)) continue;
      if (owners.isNotEmpty) continue;

      // Last owner out: the endpoint's block ends. A live pool drops the
      // block (it has no transports); later connects re-detect whatever
      // key the server presents — the verifier, never this cascade, is
      // the trust authority (D18).
      _incidentOwners.remove(key);
      _incidents.remove(key);
      final pool = _pools[key];
      if (pool != null && pool._incident != null) {
        pool._incident = null;
        _setState(pool, ServerConnectionState.disconnected);
      }
    }
  }

  // ── Channel acquisition ────────────────────────────────────────────────

  Future<_ChannelHandle> _acquireBrowseChannel(
    _ServerReference reference, {
    _BrowseAcquisition origin = _BrowseAcquisition.caller,
  }) async {
    final pool = reference.pool;
    final serverId = reference.serverId;

    // Cheapest first: steal an idle transfer channel (no roundtrip).
    final idle = _takeIdleTransfer(pool);
    if (idle != null) return idle;

    // Growth first when no existing transport has room; then one slot per
    // transport — an open refusal (a fake or real MaxSessions ceiling)
    // tries the next transport with capacity before sharing or queueing,
    // mirroring the transfer acquire.
    if (_browseSlot(pool) == null && _canGrow(pool)) {
      await _growTransport(pool);
      _throwIfBlocked(pool);
    }

    final attempted = <_TransportSlot>{};
    var slot = _browseSlot(pool, attempted);
    while (slot != null && attempted.add(slot)) {
      final opened = await _openChannelOn(pool, slot, use: _ChannelUse.browse);
      if (opened != null) return opened;

      // Mirrors the transfer loop: a block that landed mid-open surfaces
      // here instead of after two more fallback steps.
      _throwIfBlocked(pool);
      slot = _browseSlot(pool, attempted);
    }

    // Every existing transport refused or filled: one growth attempt
    // before sharing or queueing.
    if (attempted.isNotEmpty && _canGrow(pool)) {
      await _growTransport(pool);
      _throwIfBlocked(pool);

      final grown = _browseSlot(pool, attempted);
      if (grown != null) {
        final opened = await _openChannelOn(
          pool,
          grown,
          use: _ChannelUse.browse,
        );
        if (opened != null) return opened;
      }
    }

    // Exhausted with no growth possible: never fail, never hang — share
    // the least-recently-used browse channel (03 §3.2).
    final shared = _liveBrowseHandle(pool);
    if (shared != null) return shared;

    // No browse channel exists to share (every channel is a leased
    // transfer): queue behind the next release — still queue-don't-fail.
    // A block may have landed mid-open (killing every binding), in which
    // case there is nothing to queue behind.
    _checkAcquisition(reference);
    if (origin == _BrowseAcquisition.recovery && !_hasLiveTransport(pool)) {
      // Recovery cannot wait for the transport it is responsible for opening.
      throw _disconnectedAcquisition();
    }
    _failIfStranded(pool);
    return _enqueueWaiter(pool, browse: true, serverId: serverId);
  }

  Future<_ChannelHandle> _acquireTransferChannel(
    _ServerReference reference,
  ) async {
    final pool = reference.pool;
    final serverId = reference.serverId;
    final idle = _takeIdleTransfer(pool);
    if (idle != null) return idle;

    // Growth first when no existing transport has room; then one slot per
    // transport — an open refusal (a fake or real MaxSessions ceiling)
    // tries the next transport with capacity before queueing.
    if (_transferSlot(pool) == null && _canGrow(pool)) {
      await _growTransport(pool);
      _throwIfBlocked(pool);
    }

    final attempted = <_TransportSlot>{};
    var slot = _transferSlot(pool);
    while (slot != null && attempted.add(slot)) {
      final opened = await _openChannelOn(
        pool,
        slot,
        use: _ChannelUse.transferLeased,
      );
      if (opened != null) return opened;

      _throwIfBlocked(pool);
      slot = _transferSlot(pool, attempted);
    }

    // Every existing transport refused or filled: one growth attempt
    // before queueing — a fresh transport is the MaxSessions remedy.
    if (attempted.isNotEmpty && _canGrow(pool)) {
      await _growTransport(pool);
      _throwIfBlocked(pool);

      final grown = _transferSlot(pool, attempted);
      if (grown != null) {
        final opened = await _openChannelOn(
          pool,
          grown,
          use: _ChannelUse.transferLeased,
        );
        if (opened != null) return opened;
      }
    }

    // At capacity, wait only while a channel or pending open can supply it.
    _checkAcquisition(reference);
    _failIfStranded(pool);
    return _enqueueWaiter(pool, browse: false, serverId: serverId);
  }

  /// Server-side channel budget already spent on this transport: live
  /// channels, in-flight opens, and closes the server has not confirmed —
  /// a closing channel still occupies MaxSessions until its close
  /// settles, so a fresh open in that window would be refused. A settling
  /// close (even of a browse channel) transiently counts against the
  /// transfer ceiling too: conservative by design, the server has not
  /// freed the session yet — demand arriving in that window may grow a
  /// transport the settle would have made unnecessary.
  int _channelBudgetUsed(_TransportSlot slot) =>
      slot.channels.length + slot.pendingOpens + slot._pendingCloses;

  /// A transport with room for one more channel of any kind — browse
  /// channels count only against the total ceiling (03 §3.2 rule 4).
  /// [pendingOpens] is included so concurrent acquisitions cannot each
  /// spend the same last slot while their opens are in flight. Dead
  /// transports are skipped (their eviction is open-failure driven), and
  /// [exclude] skips transports a caller already tried.
  _TransportSlot? _browseSlot(
    _EndpointPool pool, [
    Set<_TransportSlot>? exclude,
  ]) {
    for (final slot in pool.transports) {
      if (slot.transport.isClosed) continue;
      if (exclude != null && exclude.contains(slot)) continue;
      if (_channelBudgetUsed(slot) < _policy.maxChannelsPerTransport) {
        return slot;
      }
    }
    return null;
  }

  /// A transport with room for one more *transfer* channel: both the
  /// per-transport transfer budget and the shared total ceiling must hold —
  /// browse + transfer channels draw on one MaxSessions budget.
  /// [exclude] skips transports a caller already tried and whose open was
  /// refused, so a multi-transport pool rotates instead of retrying the
  /// same refusing transport forever.
  _TransportSlot? _transferSlot(
    _EndpointPool pool, [
    Set<_TransportSlot>? exclude,
  ]) {
    for (final slot in pool.transports) {
      if (slot.transport.isClosed) continue;
      if (exclude != null && exclude.contains(slot)) continue;
      final total = _channelBudgetUsed(slot);
      final withinTotal = total < _policy.maxChannelsPerTransport;
      final withinTransfer =
          total - _browseCount(slot) < _policy.maxTransferChannelsPerTransport;
      if (withinTotal && withinTransfer) return slot;
    }
    return null;
  }

  int _browseCount(_TransportSlot slot) {
    var count = 0;
    for (final handle in slot.channels) {
      if (handle.use == _ChannelUse.browse) count++;
    }
    return count;
  }

  _ChannelHandle? _takeIdleTransfer(_EndpointPool pool) {
    if (pool.idleTransfer.isEmpty) return null;

    // Most recently parked first — the warmer channel.
    return pool.idleTransfer.removeLast();
  }

  /// Opens one channel on [slot], reserving the capacity slot synchronously
  /// before the await — otherwise two concurrent acquisitions each see the
  /// same free slot and both open (a MaxSessions violation). [use] is set
  /// before the handle is visible so capacity accounting never miscounts an
  /// in-flight browse channel as a transfer one.
  Future<_ChannelHandle?> _openChannelOn(
    _EndpointPool pool,
    _TransportSlot slot, {
    required _ChannelUse use,
  }) async {
    _cancelIdleTimer(slot);
    if (slot.transport.isClosed) {
      _handleTransportDeath(pool, slot);
      return null;
    }

    slot.pendingOpens++;
    try {
      final channel = await slot.transport.openChannel();

      // The pool may have been hard-blocked while the open was in flight;
      // a channel landing after the block's handle-closing loop would be
      // the one thing on a blocked pool that still looks live.
      if (pool.blocked || !pool.transports.contains(slot)) {
        final orphan = _ChannelHandle(slot: slot, channel: channel, use: use);
        slot.channels.add(orphan);
        await _closeHandle(pool, orphan);
        return null;
      }

      final handle = _ChannelHandle(slot: slot, channel: channel, use: use);
      slot.channels.add(handle);

      // A recovered open must not label a later disconnect as SFTP refusal.
      slot._openFailure = null;
      return handle;
    } on Exception catch (error) {
      slot._openFailure = error is RemoteFileException
          ? error
          : RemoteFileException(
              kind: RemoteFileErrorKind.other,
              operation: 'open SFTP',
              message: 'Could not open SFTP on this server: $error',
              cause: error,
            );
      // Channel-open failure falls back to the caller's next strategy
      // (idle steal, LRU share, or queue) — never surfaces raw. A transport
      // that died mid-open is evicted, or its corpse keeps occupying a
      // transport slot (and blocking growth) forever.
      if (slot.transport.isClosed ||
          slot._openFailure?.kind == RemoteFileErrorKind.disconnected) {
        _handleTransportDeath(pool, slot);
      }
      return null;
    } finally {
      slot.pendingOpens--;
      _updateIdleTimer(pool, slot);
    }
  }

  _PaneChannelView _bindBrowse(
    _EndpointPool pool,
    (String, String) clientKey,
    _ChannelHandle handle,
  ) {
    handle.use = _ChannelUse.browse;
    handle.browseClients++;
    final binding = _PaneChannelView(
      this,
      pool,
      clientKey.$1,
      clientKey.$2,
      handle,
    );
    pool.browseByClient[clientKey] = binding;

    // Opens queued before any browse binding existed can now share it.
    // Transfer waiters do not block sharing: no capacity is consumed.
    for (final waiter in List<_ChannelWaiter>.of(pool.waiters)) {
      if (!waiter.browse || waiter.completer.isCompleted) continue;
      pool.waiters.remove(waiter);
      waiter.completer.complete(handle);
    }
    return binding;
  }

  // ── First connect (growth rule 1) ──────────────────────────────────────

  Future<void> _ensureFirstTransport(
    _EndpointPool pool,
    _ServerReference reference,
  ) async {
    for (final slot in List<_TransportSlot>.of(pool.transports)) {
      if (slot.transport.isClosed) _handleTransportDeath(pool, slot);
    }
    final recovery = pool._reconnect;
    if (recovery != null) {
      await recovery._done.future;
      return;
    }
    if (pool.transports.isNotEmpty) return;

    final inFlight = pool.firstConnect;
    if (inFlight != null) {
      // Fold concurrent callers into the running connect: one connect, one
      // TOFU prompt per pool (growth rule 1).
      await inFlight;
      return;
    }

    final connect = _firstConnect(pool, reference);
    pool.firstConnect = connect;
    try {
      await connect;
    } finally {
      pool.firstConnect = null;
    }
  }

  Future<void> _firstConnect(
    _EndpointPool pool,
    _ServerReference reference,
  ) async {
    // A replacement session must publish the inherited block before review.
    _setState(
      pool,
      pool.blocked
          ? ServerConnectionState.blocked
          : ServerConnectionState.connecting,
      detail: pool.blocked ? pool.blockDetail : null,
    );

    // Dead-slot eviction can leave a cached secret. A fresh attempt must
    // neither retain it on failure nor lend it to growth while resolving.
    pool.resolvedCredentials = null;

    // The resolution may own a prompt that outlives this connect attempt.
    // Register its scope on the pool so the last reference out can dismiss
    // it — late results are already rejected; this closes the prompt too.
    final resolution = _PoolResolution();
    pool._resolution = resolution;

    try {
      // Serialize vault access with first connect; joining bookmarks need
      // only metadata. Never open with a secret returned to a retired pool.
      final trustEpoch = pool._trustEpoch;
      final observation = _TrustObservation();
      final resolved = await _resolveCredentials(reference.config, resolution);
      // The resolution finished — retire its scope now, not at the end of
      // the whole connect: a last-reference disconnect during the transport
      // handshake must not fire `dismissed` for a resolution that already
      // completed (the scope's contract). The `finally` below covers the
      // path where the resolver itself throws.
      if (identical(pool._resolution, resolution)) pool._resolution = null;
      if (!_isCurrentTrustEpoch(pool, trustEpoch) || pool.references.isEmpty) {
        _throwIfBlocked(pool);
        throw _disconnectedAcquisition();
      }

      final transport = await _openTransport(
        config: reference.config,
        credentials: resolved.credentials,
        tofu: _observingTofu(observation),
        onHostKey: _hostKeyPrompterFor(pool, ConnectPrompting.enabled),
        onKeyboardInteractive: _onKeyboardInteractive,
        prompting: ConnectPrompting.enabled,
        log: _forwardingLogFor(pool),
      );

      // Owner decision 1a: a presented key that returns to the pinned one
      // lifts a declined changed-key block. The opener never invokes the
      // prompter for a trusted key, so this attempt observes its verdict
      // through the wrapper — nothing is re-verdict'd, nothing is pinned,
      // and only this exact match unblocks (D18's changed-key block is
      // otherwise unchanged).
      if (pool.blocked &&
          _isCurrentTrustEpoch(pool, trustEpoch) &&
          observation.decision?.isTrusted == true) {
        _forgetIncident(pool);
      }

      // Every serverId may have disconnected while the connect was in
      // flight (the disconnect hook tears the pool down immediately). A
      // landed transport must not resurrect a torn-down pool — close it
      // and fail the callers.
      if (!_isCurrentPool(pool) || pool.references.isEmpty || pool.blocked) {
        await closeSshResource(transport.close);
        _throwIfBlocked(pool);
        throw const RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: 'connect',
          message: 'The server was disconnected while connecting.',
        );
      }

      pool.resolvedCredentials = resolved.credentials;

      // Rule 2: interactive auth caps the pool at one transport from now
      // on — growth must never re-trigger a 2FA prompt (D5).
      pool.interactiveOnly =
          resolved.origin == CredentialOrigin.prompted ||
          transport.authKind == AuthKind.keyboardInteractive ||
          transport.authKind == AuthKind.promptedPassword;

      final slot = _TransportSlot(transport, _TransportRole.primary);
      pool.transports.add(slot);
      _watchTransport(pool, slot);

      _setState(pool, ServerConnectionState.connected);
    } on Object catch (error) {
      // A rejected stale prompt is cancellation, not an authentication failure.
      if (pool.references.isEmpty) throw _disconnectedAcquisition();
      if (pool.blocked) {
        // A declined changed key: surface the block, not the raw auth
        // failure behind it.
        _setState(
          pool,
          ServerConnectionState.blocked,
          detail: pool.blockDetail,
        );
        throw _blockedError(pool);
      }
      _setState(
        pool,
        ServerConnectionState.disconnected,
        detail: _failureSummary(error),
      );
      rethrow;
    } finally {
      if (identical(pool._resolution, resolution)) pool._resolution = null;
    }
  }

  // ── Growth (rules 2–4) ─────────────────────────────────────────────────

  bool _canGrow(_EndpointPool pool) =>
      !pool.blocked &&
      !pool.interactiveOnly &&
      (pool._reconnect == null || _hasLiveTransport(pool)) &&
      // Dead-but-not-yet-evicted transports must not consume a growth slot.
      pool.transports.where((slot) => !slot.transport.isClosed).length <
          _policy.maxTransports;

  Future<void> _growTransport(_EndpointPool pool) async {
    final inFlight = pool.growth;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final attempt = _growTransportOnce(pool);
    pool.growth = attempt;
    try {
      await attempt;
    } finally {
      pool.growth = null;
    }
  }

  Future<void> _growTransportOnce(_EndpointPool pool) async {
    if (pool.references.isEmpty || pool.resolvedCredentials == null) return;

    final reference = pool.references.values.first;
    final trustEpoch = pool._trustEpoch;

    try {
      final transport = await _openTransport(
        config: reference.config,
        credentials: pool.resolvedCredentials!,
        tofu: _tofu,
        onHostKey: _hostKeyPrompterFor(pool, ConnectPrompting.disabled),
        // Rule 3: growth connects with prompting disabled — a server that
        // demands interaction per TCP connection must never pop a second
        // concurrent 2FA prompt from a background growth attempt.
        onKeyboardInteractive: null,
        prompting: ConnectPrompting.disabled,
        log: _forwardingLogFor(pool),
      );

      // Approval cannot revive an older handshake. A concurrent first connect
      // may also have imposed a stricter interactive-auth cap.
      if (!_isCurrentTrustEpoch(pool, trustEpoch) || !_canGrow(pool)) {
        await closeSshResource(transport.close);
        return;
      }

      final slot = _TransportSlot(transport, _TransportRole.extra);
      pool.transports.add(slot);
      _watchTransport(pool, slot);
      _updateIdleTimer(pool, slot);
    } on AuthChallengeRequiredError {
      if (!_isCurrentTrustEpoch(pool, trustEpoch)) return;
      pool.interactiveOnly = true;
    } on Exception {
      // Transient growth failure: fall back to sharing existing channels;
      // a later attempt may grow again.
    }
  }

  // ── Host-key gate (D18) ────────────────────────────────────────────────

  bool _isCurrentPool(_EndpointPool pool) => identical(_pools[pool.key], pool);

  bool _isCurrentTrustEpoch(_EndpointPool pool, Object epoch) =>
      _isCurrentPool(pool) && identical(pool._trustEpoch, epoch);

  bool _isCurrentIncident(_EndpointPool pool, _HostKeyIncident? incident) =>
      _isCurrentPool(pool) && identical(_incidents[pool.key], incident);

  HostKeyPrompter _hostKeyPrompterFor(
    _EndpointPool pool,
    ConnectPrompting prompting,
  ) {
    var trustEpoch = pool._trustEpoch;
    return (decision) async {
      if (!_isCurrentTrustEpoch(pool, trustEpoch)) return false;

      switch (decision.verdict) {
        case HostKeyVerdict.trusted:
          return true;

        case HostKeyVerdict.changed:
          // Every detection gets a fresh identity, even for the same key.
          final incident = _HostKeyIncident(pool.key, decision);
          final blocking = _blockPool(pool, incident);
          // Installation is synchronous; only this detector adopts the epoch.
          trustEpoch = pool._trustEpoch;
          await blocking;
          if (prompting == ConnectPrompting.disabled) return false;
          if (!_isCurrentIncident(pool, incident)) return false;

          final accepted = await _onHostKey(decision);
          if (!accepted || !_isCurrentIncident(pool, incident)) return false;

          // Approval resolves trust before auth. The opener persists the pin;
          // an auth failure afterward must not recreate the resolved incident.
          _forgetIncident(pool);
          _setState(
            pool,
            pool.firstConnect == null
                ? ServerConnectionState.disconnected
                : ServerConnectionState.connecting,
          );
          return true;

        case HostKeyVerdict.firstUse:
          if (prompting == ConnectPrompting.disabled) return false;
          // Removing a pin does not authorize first-use approval of a hard block.
          if (pool.blocked) return false;
          final incident = pool._incident;
          final accepted = await _onHostKey(decision);
          return accepted &&
              _isCurrentTrustEpoch(pool, trustEpoch) &&
              _isCurrentIncident(pool, incident);
      }
    };
  }

  Future<void> _blockPool(_EndpointPool pool, _HostKeyIncident incident) async {
    final wasBlocked = pool.blocked;
    pool._trustEpoch = Object();
    _incidents[pool.key] = incident;
    pool._incident = incident;
    _cancelReconnect(pool);
    _cancelKeepAlive(pool);

    // Persist the decline (2a): every bookmark currently referencing the
    // endpoint owns a record — the 3a cascade key. Existing owners
    // re-write so a repeated decline updates the stored payload.
    final owners = _incidentOwners.putIfAbsent(pool.key, () => <String>{});
    owners.addAll(pool.references.keys);
    for (final serverId in List.of(owners)) {
      _persistIncidentRecord(serverId, incident);
    }

    // The first block detached all slots; late opens cannot reattach them.
    if (wasBlocked) return;

    // Hard-block the ENTIRE pool: drop every channel and transport so every
    // operation — for every serverId sharing this endpoint — fails. A
    // sibling bookmark must never keep operating over a changed key.
    final slots = List<_TransportSlot>.of(pool.transports);
    for (final slot in slots) {
      _cancelIdleTimer(slot);
    }
    pool.transports.clear();
    pool.browseByClient.clear();
    pool.idleTransfer.clear();
    pool.leasedTransfer.clear();
    pool.resolvedCredentials = null;

    _failAllWaiters(pool, message: pool.blockDetail);
    _setState(pool, ServerConnectionState.blocked, detail: pool.blockDetail);

    await _closeSlots(pool, slots);
  }

  void _throwIfBlocked(_EndpointPool pool) {
    if (!pool.blocked) return;
    throw _blockedError(pool);
  }

  RemoteFileException _blockedError(_EndpointPool pool) => RemoteFileException(
    kind: RemoteFileErrorKind.other,
    operation: 'connect',
    message: pool.blockDetail ?? 'The server is blocked.',
  );

  // ── Incident persistence (owner decision 2a/3a) ────────────────────────

  Future<void> _ensureIncidentsLoaded() {
    if (_incidentsLoaded) return Future<void>.value();
    return _incidentsLoading ??= _loadIncidents().then((_) {
      _incidentsLoaded = true;
    });
  }

  Future<void> _loadIncidents() async {
    final store = _incidentStore;
    if (store == null) return;
    try {
      final records = await store.load();
      for (final record in records) {
        final match = await _pinMatchOf(record);
        if (match != _PinMatch.names) {
          // Audit finding A: a record that no longer names the endpoint's
          // pin carries a block with no escape, so it is not restored — the
          // next connect re-detects against the real pin. Deleting it is
          // safe only when the pin store definitively answered.
          if (match == _PinMatch.differs) {
            await _deleteStaleRecord(store, record);
          }
          continue;
        }
        _incidents.putIfAbsent(
          record.poolKey,
          () => _HostKeyIncident.fromRecord(record),
        );
        _incidentOwners
            .putIfAbsent(record.poolKey, () => <String>{})
            .add(record.serverId);
      }
    } on Object catch (error) {
      // Fail-safe: an unreadable store means no persisted incidents —
      // never a crash, never auto-trust. The next connect re-detects
      // whatever key the server presents.
      _reportIncidentStoreError(error);
    }
  }

  /// What the record's pinned half means against the pin the verifier holds
  /// for the record's own endpoint — the invariant a restored block needs to
  /// stay honest and escapable (audit finding A).
  ///
  /// Only [_PinMatch.names] restores the block. Otherwise the block would
  /// outlive both of D18's escapes: with no pin every connect verifies
  /// `firstUse`, which a blocked pool refuses to prompt for, and 1a's
  /// restored-key match has nothing to match; with a different pin the
  /// block's detail would name a fingerprint the store no longer holds, and
  /// 1a would lift it on a key this record never recorded.
  ///
  /// Skipping costs no protection: the next connect re-detects against the
  /// real pin, and the verifier — never a persisted record — is the trust
  /// authority (D18).
  Future<_PinMatch> _pinMatchOf(IncidentRecord record) async {
    // The verifier's own lookup key: the opener passes the config's host and
    // port to it verbatim, and the record stored them the same way. The same
    // fingerprint pinned at ANOTHER endpoint (a cloned machine, a shared jump
    // host) says nothing about this one.
    final key = await _tofu.store.get(record.host, record.port);
    if (key == null) return _PinMatch.absent;
    return key.fingerprintSha256 == record.pinnedFingerprintSha256
        ? _PinMatch.names
        : _PinMatch.differs;
  }

  Future<void> _deleteStaleRecord(
    IncidentStore store,
    IncidentRecord record,
  ) async {
    try {
      await store.removeFor(record.serverId, record.poolKey);
    } on Object catch (error) {
      // Best-effort cleanup: an undeleted stale record is still skipped in
      // memory, and the next load skips it again.
      _reportIncidentStoreError(error);
    }
  }

  /// Removes the endpoint's incident everywhere: the manager map, the live
  /// pool, the owner bookkeeping, and the persistent store. Emits nothing —
  /// the caller owns the state transition it already emits (approval
  /// re-emits connecting/disconnected, the trusted-key path emits connected
  /// next, the cascade emits disconnected).
  void _forgetIncident(_EndpointPool pool) {
    _incidents.remove(pool.key);
    pool._incident = null;
    final owners = _incidentOwners.remove(pool.key);
    if (owners == null) return;
    for (final serverId in owners) {
      // Scoped to the endpoint this incident belongs to: a bookmark
      // re-pointed to a new endpoint (whose record now holds the new
      // endpoint's block) keeps it, while a stale payload of this same
      // endpoint is still removed.
      unawaited(_deleteStoredRecord(serverId, pool.key));
    }
  }

  void _persistIncidentRecord(String serverId, _HostKeyIncident incident) {
    final store = _incidentStore;
    if (store == null) return;
    unawaited(
      store.put(incident.recordFor(serverId)).catchError((Object error) {
        // Best-effort: persistence failure must not affect the live block
        // — the incident still applies in memory, and the next decline
        // re-writes the record. The observer makes the failure visible.
        _reportIncidentStoreError(error);
      }),
    );
  }

  Future<void> _deleteStoredRecord(String serverId, PoolKey endpoint) async {
    final store = _incidentStore;
    if (store == null) return;
    try {
      await store.removeFor(serverId, endpoint);
    } on Object catch (error) {
      // Best-effort: a failed delete must not affect the live pool; a
      // stale record only re-blocks after the next restart.
      _reportIncidentStoreError(error);
    }
  }

  Future<void> _deleteStoredBookmark(String serverId) async {
    final store = _incidentStore;
    if (store == null) return;
    try {
      await store.removeAllFor(serverId);
    } on Object catch (error) {
      // Best-effort: a failed delete must not affect the live pool; a
      // stale record only re-blocks after the next restart.
      _reportIncidentStoreError(error);
    }
  }

  /// Observer errors cannot replace or interrupt persistence handling.
  void _reportIncidentStoreError(Object error) {
    try {
      _onIncidentStoreError?.call(error);
    } on Object {
      // The observer is diagnostics, not control flow.
    }
  }

  /// The opener never invokes the prompter for a trusted key (the pinned
  /// Séance verifier returns early), so the block-lifting observation (1a)
  /// rides this wrapper instead.
  TofuVerifier _observingTofu(_TrustObservation observation) =>
      _ObservingTofu(_tofu, observation);

  // ── Release, teardown, waiters ─────────────────────────────────────────

  Future<void> _closeBrowseClient(
    _EndpointPool pool,
    (String, String) clientKey,
  ) async {
    final binding = pool.browseByClient.remove(clientKey);
    if (binding == null) return;

    final handle = binding._handle;
    handle.browseClients--;
    if (handle.browseClients > 0) return;

    await _closeHandle(pool, handle);
    await _pumpWaiters(pool);
    await _maybeTearDown(pool);
  }

  Future<void> _releaseLease(_EndpointPool pool, _ChannelHandle handle) async {
    // Idempotent: a double release (or one after a force-release) no-ops.
    if (!pool.leasedTransfer.remove(handle)) return;

    handle.leaseServerId = null;
    if (handle.closed || !pool.transports.contains(handle.slot)) {
      await _closeHandle(pool, handle);
      await _maybeTearDown(pool);
      return;
    }
    handle.use = _ChannelUse.transferIdle;
    pool.idleTransfer.add(handle);

    await _pumpWaiters(pool);

    // Queued work gets first refusal; unused extra channels must not keep
    // their transport alive forever. The first transport keeps its cache.
    if (identical(_pools[pool.key], pool) &&
        _isExtra(pool, handle.slot) &&
        pool.idleTransfer.contains(handle)) {
      await _closeHandle(pool, handle);

      // An acquisition may have queued while the server still counted the
      // closing channel against MaxSessions. Its capacity is available now.
      await _pumpWaiters(pool);
    }
    await _maybeTearDown(pool);
  }

  Future<void> _closeHandle(_EndpointPool pool, _ChannelHandle handle) async {
    if (handle.closed) return;

    handle.closed = true;
    handle.slot._pendingCloses++;
    handle.slot.channels.remove(handle);
    pool.idleTransfer.remove(handle);

    // Structural invariant: a closed handle is never bookkept as leased or
    // bound to a pane-tab — callers remove those first today, and this
    // keeps a future close path from silently breaking that convention.
    pool.leasedTransfer.remove(handle);
    handle.leaseServerId = null;
    pool.browseByClient.removeWhere(
      (_, bound) => identical(bound._handle, handle),
    );

    // Bounded cleanup (05 s cap) so a half-dead channel's close failure
    // cannot strand the caller; idle bookkeeping resumes once it settles.
    try {
      await closeSshResource(handle.channel.close);
    } finally {
      handle.slot._pendingCloses--;
      _updateIdleTimer(pool, handle.slot);
      // Budget frees at settle (not at close start), so waiters queued on
      // the per-transport budget get their pump at every settle site —
      // browse closes and error paths included, not just lease release.
      _pumpWaitersEnsured(pool);
    }
  }

  // ── Keepalive (03 §3.3) ──────────────────────────────────────────────

  // One clock per pool pings its idle transports; the opener's built-in
  // keepalive timer is disabled (03 §3.3), so this is the only keepalive
  // mechanism — no second timer, no VFS wrapper (D3).

  void _armKeepAlive(_EndpointPool pool) {
    // Armed whenever a transport joins (recovery re-arms after reconnect);
    // the tick self-cancels once the last live transport is gone.
    pool._keepAliveTimer ??= Timer.periodic(
      _policy.keepAliveInterval,
      (_) => _pingPoolTransports(pool),
    );
  }

  void _cancelKeepAlive(_EndpointPool pool) {
    pool._keepAliveTimer?.cancel();
    pool._keepAliveTimer = null;
  }

  void _pingPoolTransports(_EndpointPool pool) {
    // A detached or blocked pool has nothing to keep alive; teardown and
    // blocking cancel eagerly, this is the backstop.
    if (!_isCurrentPool(pool) || pool.blocked) {
      _cancelKeepAlive(pool);
      return;
    }

    var live = 0;
    for (final slot in List.of(pool.transports)) {
      if (slot.transport.isClosed) continue;
      live++;
      _pingIdleTransport(pool, slot);
    }
    // Zero live transports: recovery owns the pool and re-arms the clock
    // when its transport joins — a clock with nothing to ping is noise.
    if (live == 0) _cancelKeepAlive(pool);
  }

  void _pingIdleTransport(_EndpointPool pool, _TransportSlot slot) {
    // One outstanding ping per transport: a tick inside a previous ping's
    // timeout window must not stack a second one.
    if (slot._pingOutstanding) return;
    // Idle means no in-flight operation: the transport's aggregated
    // adapter activity plus this pool's pending channel opens and closes
    // (03 §3.3). Held leases and open browse channels do not count.
    if (slot.transport.hasActiveOperations) return;
    if (slot.pendingOpens != 0 || slot._pendingCloses != 0) return;

    slot._pingOutstanding = true;
    unawaited(
      Future.sync(slot.transport.ping)
          .timeout(SshTransport.pingOperationTimeout)
          .then(
            (_) => slot._pingOutstanding = false,
            onError: (Object error) {
              if (error is TimeoutException) {
                // Silence outlived the operation timeout: the transport is
                // dead. Closing it completes `done`, whose watcher runs the
                // ordinary transport-death path — recovery fires on closure
                // exactly as it does for an externally dropped socket. The
                // ping stays outstanding: the slot is dying, and its close
                // may itself be wedged, so no later tick may stack a second
                // ping onto it.
                if (pool.transports.contains(slot)) {
                  unawaited(closeSshResource(slot.transport.close));
                }
                return;
              }
              // Non-timeout failures are the done watcher's business: the
              // socket's own closure drives the ordinary death path.
              slot._pingOutstanding = false;
            },
          ),
    );
  }

  // ── Idle extra-transport retirement (03 §3.3) ────────────────────────

  // Evicting the primary must not promote an extra out of idle retirement.
  bool _isExtra(_EndpointPool pool, _TransportSlot slot) =>
      slot._role == _TransportRole.extra && pool.transports.contains(slot);

  // An empty slot still owns demand while its channel open/close awaits.
  bool _isIdleExtra(_EndpointPool pool, _TransportSlot slot) =>
      identical(_pools[pool.key], pool) &&
      !pool.blocked &&
      _isExtra(pool, slot) &&
      !slot.transport.isClosed &&
      slot.pendingOpens == 0 &&
      slot._pendingCloses == 0 &&
      slot.channels.isEmpty;

  void _cancelIdleTimer(_TransportSlot slot) {
    slot._idleTimer?.cancel();
    slot._idleTimer = null;
  }

  void _updateIdleTimer(_EndpointPool pool, _TransportSlot slot) {
    if (!_isIdleExtra(pool, slot)) {
      _cancelIdleTimer(slot);
      return;
    }
    if (slot._idleTimer != null) return;

    late final Timer timer;
    timer = Timer(_policy.idleExtraTransportTimeout, () {
      if (!identical(slot._idleTimer, timer)) return;
      slot._idleTimer = null;
      if (!_isIdleExtra(pool, slot)) return;

      if (pool.growth != null) {
        // A growth connect is in flight for queued demand; retiring the
        // last live transport under it would emit a transient disconnect.
        // Re-arm: growth settles through an open that cancels this timer,
        // or the next fire finds growth settled and retires for good.
        _updateIdleTimer(pool, slot);
        return;
      }

      // Nulling the timer before this re-check is safe: every transient
      // gate below is paired with a re-arm when it clears — pendingOpens
      // and channels re-arm from _openChannelOn/_closeHandle finallys, and
      // a blocked pool synchronously detaches every slot, so no timer
      // survives into a block to fire there.

      // Remove capacity before awaiting close so a new acquisition cannot
      // bind to the retiring transport or be removed by its late completion.
      pool.transports.remove(slot);
      if (!pool.transports.any((other) => !other.transport.isClosed)) {
        _setState(pool, ServerConnectionState.disconnected);
      }
      unawaited(_closeIdleTransport(slot));
      // Retirement is the last capacity change on this pool: re-drive
      // queued demand so it can grow a replacement (or fail) instead of
      // waiting forever on a pool whose spare capacity just left.
      _pumpWaitersEnsured(pool);
    });
    slot._idleTimer = timer;
  }

  Future<void> _closeIdleTransport(_TransportSlot slot) async {
    // Timer-driven cleanup has no caller: the bounded helper guarantees it
    // can neither hang nor emit an unhandled error.
    await closeSshResource(slot.transport.close);
  }

  Future<void> _maybeTearDown(_EndpointPool pool) async {
    // Pending opens and home resolution own demand before binding a channel.
    if (pool.acquisitions != 0) return;
    if (!_hasDemand(pool) && pool._reconnect != null) {
      _cancelReconnect(pool);
      pool.resolvedCredentials = null;
      if (!pool.blocked) _setState(pool, ServerConnectionState.disconnected);
    }
    if (pool.firstConnect != null) return;
    if (pool._reconnect != null) return;

    // Same race class as the first-connect guard: a growth connect that
    // lands after teardown would resurrect a transport on a torn-down
    // pool. Deferred teardowns rerun when the pending acquisition settles.
    if (pool.growth != null) return;
    if (pool.transports.isEmpty) return;

    // The first transport follows pane lifetime (03 §3.3): it stays while
    // any pane-tab shows the server, and never closes while a channel is
    // leased — closing tabs cannot park a running transfer.
    if (pool.browseByClient.isNotEmpty) return;
    if (pool.leasedTransfer.isNotEmpty) return;

    await _tearDownPool(pool);
  }

  Future<void> _tearDownPool(_EndpointPool pool, {String? detail}) async {
    _cancelReconnect(pool);
    _cancelKeepAlive(pool);
    final slots = List<_TransportSlot>.of(pool.transports);
    for (final slot in slots) {
      _cancelIdleTimer(slot);
    }
    pool.transports.clear();
    pool.idleTransfer.clear();
    pool.leasedTransfer.clear();
    pool.browseByClient.clear();

    // Credential references drop with the transports (03 §3.2 rule 3) —
    // Dart strings cannot be zeroized; clearing references is the best
    // available. The next first connect re-resolves from the vault.
    pool.resolvedCredentials = null;

    _failAllWaiters(pool, message: detail);
    _setState(pool, ServerConnectionState.disconnected, detail: detail);

    await _closeSlots(pool, slots);
    await Future.wait(List<Future<void>>.of(pool._retiring));
  }

  Future<void> _closeSlots(
    _EndpointPool pool,
    List<_TransportSlot> slots,
  ) async {
    // Retired slots are detached before entry. Bound each phase regardless
    // of channel count, then close transports even if channels stalled.
    await Future.wait([
      for (final slot in slots)
        for (final handle in List<_ChannelHandle>.of(slot.channels))
          _closeHandle(pool, handle),
    ]);
    await Future.wait([
      for (final slot in slots) closeSshResource(slot.transport.close),
    ]);
  }

  void _failIfStranded(_EndpointPool pool) {
    final failure = _failStrandedWaiters(pool);
    if (failure != null) throw failure;
  }

  RemoteFileException? _failStrandedWaiters(_EndpointPool pool) {
    if (pool.growth != null) return null;
    if (pool._reconnect != null && !_hasLiveTransport(pool)) return null;
    RemoteFileException? liveFailure;
    for (final slot in pool.transports) {
      if (slot.pendingOpens != 0) return null;
      if (slot.transport.isClosed) continue;
      if (slot.channels.isNotEmpty) return null;
      liveFailure = slot._openFailure ?? liveFailure;
    }

    // Only a still-attached, live transport can explain a current refusal.
    final failure =
        liveFailure ??
        const RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: 'open SFTP',
          message: 'No SFTP channel is available.',
        );
    _failAllWaiters(pool, error: failure);
    final recovery = pool._reconnect;
    if (recovery != null && _isCurrentReconnect(pool, recovery)) {
      // Teardown cancels the cycle before its first await, so the recovery
      // catch cannot report this refusal again (diagnostics test pins one).
      _reportRecoveryFailure(pool, failure);
    }
    // Teardown detaches transports synchronously; slow closes must not
    // delay or replace the open failure returned to callers.
    unawaited(
      _tearDownPool(pool, detail: failure.message).catchError((Object _) {}),
    );
    return failure;
  }

  Future<_ChannelHandle> _enqueueWaiter(
    _EndpointPool pool, {
    required bool browse,
    required String serverId,
  }) {
    final waiter = _ChannelWaiter(browse: browse, serverId: serverId);
    pool.waiters.add(waiter);
    return waiter.completer.future;
  }

  Future<void> _pumpWaiters(_EndpointPool pool) {
    // Fold concurrent pumps (several releases racing) into one pass — two
    // pumps could otherwise serve the same FIFO head twice.
    final inFlight = pool.pumping;
    if (inFlight != null) return inFlight;

    final pump = _pumpWaitersOnce(pool);
    pool.pumping = pump;
    return pump.whenComplete(() {
      if (identical(pool.pumping, pump)) pool.pumping = null;
    });
  }

  /// Ensures a waiter pump runs without the caller awaiting it. A close
  /// can settle inside a running pump's own call chain (a raced cleanup or
  /// an orphaned open): awaiting the in-flight pump from there would
  /// deadlock the pump on itself. Instead, one follow-up pass is chained
  /// after the running pump, so capacity that frees mid-pump is served
  /// even once the loop has moved past the queue head.
  void _pumpWaitersEnsured(_EndpointPool pool) {
    final running = pool.pumping;
    if (running == null) {
      unawaited(_pumpWaiters(pool));
      return;
    }

    final chained = running.then((_) => _pumpWaitersOnce(pool));
    pool.pumping = chained;
    unawaited(
      chained.whenComplete(() {
        if (identical(pool.pumping, chained)) pool.pumping = null;
      }),
    );
  }

  Future<void> _pumpWaitersOnce(_EndpointPool pool) async {
    if (pool._reconnect != null && !_hasLiveTransport(pool)) return;
    while (pool.waiters.isNotEmpty) {
      final waiter = pool.waiters.first;
      if (waiter.completer.isCompleted) {
        pool.waiters.remove(waiter);
        continue;
      }

      var handle = _takeIdleTransfer(pool);
      if (handle == null) {
        handle = await _openForWaiter(pool, waiter);
      } else if (waiter.browse) {
        handle.use = _ChannelUse.browse;
      }

      if (handle == null) {
        if (waiter.completer.isCompleted) continue;
        // Capacity waits stay FIFO; terminal failures go to the waiters,
        // not to the pane/lease whose release triggered this pump.
        _failStrandedWaiters(pool);
        return;
      }

      // The awaits above can race a disconnect-driven fail: this waiter
      // may already be completed and dequeued. Completing it twice throws,
      // and removeFirst would drop the *new* head instead.
      if (waiter.completer.isCompleted || pool.waiters.first != waiter) {
        await _closeHandle(pool, handle);
        continue;
      }

      pool.waiters.remove(waiter);
      waiter.completer.complete(handle);
    }
  }

  Future<_ChannelHandle?> _openForWaiter(
    _EndpointPool pool,
    _ChannelWaiter waiter,
  ) async {
    final use = waiter.browse ? _ChannelUse.browse : _ChannelUse.transferLeased;
    final attempted = <_TransportSlot>{};
    _TransportSlot? nextSlot() => waiter.browse
        ? _browseSlot(pool, attempted)
        : _transferSlot(pool, attempted);

    // Match direct acquisitions: a refusal must not hide a healthy sibling.
    for (var slot = nextSlot(); slot != null; slot = nextSlot()) {
      attempted.add(slot);
      final opened = await _openChannelOn(pool, slot, use: use);
      if (opened != null) return opened;
      if (waiter.completer.isCompleted || pool.blocked) return null;
    }

    if (!_canGrow(pool)) return null;
    await _growTransport(pool);
    if (waiter.completer.isCompleted || pool.blocked) return null;

    final grown = nextSlot();
    if (grown == null) return null;
    return _openChannelOn(pool, grown, use: use);
  }

  void _failWaiters(_EndpointPool pool, String serverId) {
    final remaining = <_ChannelWaiter>[];

    for (final waiter in pool.waiters) {
      if (waiter.completer.isCompleted) {
        remaining.add(waiter);
        continue;
      }
      if (waiter.serverId == serverId) {
        waiter.completer.completeError(
          RemoteFileException(
            kind: RemoteFileErrorKind.disconnected,
            operation: waiter.browse
                ? 'open browse channel'
                : 'lease transfer channel',
            message: 'The server was disconnected while waiting for a channel.',
          ),
        );
      } else {
        remaining.add(waiter);
      }
    }

    pool.waiters
      ..clear()
      ..addAll(remaining);
  }

  void _failAllWaiters(
    _EndpointPool pool, {
    String? message,
    RemoteFileException? error,
  }) {
    for (final waiter in pool.waiters) {
      if (waiter.completer.isCompleted) continue;
      waiter.completer.completeError(
        error ??
            RemoteFileException(
              kind: RemoteFileErrorKind.disconnected,
              operation: 'wait for channel',
              message: message ?? 'The connection pool was torn down.',
            ),
      );
    }
    pool.waiters.clear();
  }

  // ── References and state fan-out ───────────────────────────────────────

  Future<_ServerReference> _referenceFor(String serverId) {
    final existing = _references[serverId];
    if (existing != null) return Future.value(existing);

    final pending = _pendingReferences[serverId];
    if (pending != null) return pending;

    final request = Completer<_ServerReference>();
    final pendingIdentity = request.future;
    _pendingReferences[serverId] = pendingIdentity;
    unawaited(
      _resolveReference(
        serverId,
        pendingIdentity,
      ).then(request.complete, onError: request.completeError),
    );
    return pendingIdentity.whenComplete(() {
      if (identical(_pendingReferences[serverId], pendingIdentity)) {
        _pendingReferences.remove(serverId);
      }
    });
  }

  Future<_ServerReference> _resolveReference(
    String serverId,
    Future<_ServerReference> pendingIdentity,
  ) async {
    await _ensureIncidentsLoaded();
    final config = await _resolveServer(serverId);
    // A cancelled resolve must not register or erase a newer session.
    if (!identical(_pendingReferences[serverId], pendingIdentity)) {
      throw _disconnectedAcquisition();
    }

    // Configs are cached per serverId for the session; bookmark edits
    // invalidate them (M5's store owns that).
    final key = PoolKey.of(config);
    final pool = _pools.putIfAbsent(
      key,
      () => _EndpointPool(key, _incidents[key]),
    );
    final reference = _ServerReference(serverId, config, pool);

    // A bookmark joining a blocked endpoint carries the block's record:
    // the endpoint stays blocked while any of its bookmarks still exists
    // (3a's identity rule for shared servers).
    final incident = _incidents[key];
    if (incident != null) {
      final owners = _incidentOwners.putIfAbsent(key, () => <String>{});
      if (owners.add(serverId)) {
        _persistIncidentRecord(serverId, incident);
      }
    }

    final previousState = _currentStatusOf(serverId);
    _references[serverId] = reference;
    pool.references[serverId] = reference;

    // Joining an existing pool may skip every connect emission. Publish
    // the joiner's transition without repeating states for its siblings.
    final state = _currentStatusOf(serverId);
    if (state != previousState) _emit(serverId, state);
    return reference;
  }

  void _setState(
    _EndpointPool pool,
    ServerConnectionState state, {
    String? detail,
  }) {
    for (final serverId in pool.references.keys) {
      _emit(serverId, ServerStatus(state, detail: detail));
    }
  }

  /// Per-serverId broadcast. Async delivery on purpose: synchronous
  /// emission breaks the standard stream consumers (`.first`, `await for`);
  /// ordering within this controller is FIFO, and watchServer prepends the
  /// current value on subscribe.
  StreamController<ServerStatus> _eventsFor(String serverId) => _events
      .putIfAbsent(serverId, () => StreamController<ServerStatus>.broadcast());

  void _emit(String serverId, ServerStatus status) {
    _lastStatuses[serverId] = status;

    final controller = _events[serverId];
    if (controller != null && !controller.isClosed) controller.add(status);
  }

  /// The user-facing one-liner for a terminal failure (03 §3.2 detail), or
  /// null for local cancellation — there is nothing to diagnose when the
  /// user or a teardown ended the attempt.
  static String? _failureSummary(Object error) {
    if (error is _ReconnectResolutionFailure) {
      return _failureSummary(error._cause);
    }
    if (error is RemoteFileException) {
      if (error.kind == RemoteFileErrorKind.cancelled) return null;
      return error.message;
    }
    return switch (error) {
      final SshConnectException e => e.message,
      final AuthChallengeRequiredError e => e.message,
      _ => 'Connection failed.',
    };
  }

  /// One transcript source per open attempt, fanning each line out to the
  /// serverIds referencing the pool *when the line is appended* — the set
  /// can change mid-attempt as references join or leave.
  SshConnectionLog _forwardingLogFor(_EndpointPool pool) {
    return _ForwardingConnectionLog((line) {
      for (final serverId in pool.references.keys.toList()) {
        _connectLog.add(ConnectLogLine(serverId: serverId, line: line));
      }
    });
  }
}

/// A [SshConnectionLog] that forwards every appended line until the
/// attempt freezes. `onUpdate` doubles as the frozen flag: `freeze()` clears
/// it (the class's own contract), and a frozen attempt must forward nothing
/// even if a late writer calls `add`.
class _ForwardingConnectionLog extends SshConnectionLog {
  final void Function(String line) _onLine;

  /// Whether the last `super.add` actually appended. Upstream invokes
  /// `onUpdate` exactly once per stored record (never for the frozen no-op),
  /// which is the one signal an override gets for "storage recorded this" —
  /// a length delta cannot say it (the 400-line bound trims on the same add
  /// that appends), and content comparison cannot either (identical records
  /// are legal).
  var _appendedByLastAdd = false;

  _ForwardingConnectionLog(this._onLine) {
    onUpdate = () => _appendedByLastAdd = true;
  }

  @override
  void add(String line) {
    if (onUpdate == null) return;
    _appendedByLastAdd = false;
    super.add(line);
    // If storage did not record the record, the stream must not emit one —
    // neither a crash on an empty transcript nor a stale last line replayed
    // as new. At this pin the only no-append path is frozen (excluded
    // above); this holds the invariant across future re-pins.
    if (!_appendedByLastAdd) {
      // Debug tripwire, stripped in release: reaching here means the
      // per-append onUpdate contract drifted on a re-pin (or onUpdate was
      // reassigned), silently disabling the live fan-out. The regressions
      // in pool_diagnostics_test.dart run with asserts on, so this fires
      // the moment any such path is exercised.
      assert(
        false,
        'SshConnectionLog.add stored no record while unfrozen; live '
        'connectLog forwarding skipped. Re-verify the onUpdate-per-stored-'
        'record contract after any Séance re-pin.',
      );
      return;
    }
    // Forward the record as upstream stored it, not the raw argument:
    // `SshConnectionLog.add` is where credential records are redacted, and
    // forwarding the argument would bypass it — the live stream would carry
    // what `redactConnectionTrace` exists to withhold. After `super.add` the
    // stored copy is the last line; the 400-line bound trims from the front,
    // so the newest record is always `lines.last`.
    _onLine(lines.last);
  }
}

// ── Internal model ─────────────────────────────────────────────────────

/// Manager-owned [CredentialResolutionScope]: one dismissal per
/// first-connect resolution.
class _PoolResolution implements CredentialResolutionScope {
  final Completer<void> _dismissed = Completer<void>();

  @override
  Future<void> get dismissed => _dismissed.future;

  void dismiss() {
    if (!_dismissed.isCompleted) _dismissed.complete();
  }
}

class _ServerReference {
  final String serverId;
  final ServerConfig config;
  final _EndpointPool pool;

  _ServerReference(this.serverId, this.config, this.pool);
}

/// Unresolved review state survives pool retirement without retaining secrets.
class _HostKeyIncident {
  /// The presented (declined) key's endpoint, verbatim for the block detail.
  final String host;
  final int port;

  /// The endpoint identity the record re-keys under ([PoolKey]).
  final String username;
  final String? jumpHostId;

  final String presentedFingerprintSha256;
  final String? pinnedFingerprintSha256;

  _HostKeyIncident(PoolKey key, HostKeyDecision decision)
    : host = decision.presented.host,
      port = decision.presented.port,
      username = key.username,
      jumpHostId = key.jumpHostId,
      presentedFingerprintSha256 = decision.presented.fingerprintSha256,
      pinnedFingerprintSha256 = decision.pinned?.fingerprintSha256;

  _HostKeyIncident.fromRecord(IncidentRecord record)
    : host = record.host,
      port = record.port,
      username = record.username,
      jumpHostId = record.jumpHostId,
      presentedFingerprintSha256 = record.presentedFingerprintSha256,
      pinnedFingerprintSha256 = record.pinnedFingerprintSha256;

  String get _detail {
    final pinned = pinnedFingerprintSha256 ?? 'none';
    return 'Host key for $host:$port '
        'has changed (presented $presentedFingerprintSha256, '
        'pinned $pinned). The server is blocked until the new key '
        'is reviewed.';
  }

  IncidentRecord recordFor(String serverId) => IncidentRecord(
    serverId: serverId,
    host: host,
    port: port,
    username: username,
    jumpHostId: jumpHostId,
    presentedFingerprintSha256: presentedFingerprintSha256,
    pinnedFingerprintSha256: pinnedFingerprintSha256,
  );
}

/// What a restored incident record's pinned half means against the pin the
/// verifier holds for that record's own endpoint.
enum _PinMatch {
  /// The endpoint is pinned to exactly this record's key: restore the block.
  names,

  /// The endpoint is pinned to a different key, so the record is stale. The
  /// store definitively answered, which makes deleting it safe.
  differs,

  /// No pin at all. Ambiguous by nature: a pin store that failed to load
  /// reads the same way, so the record is skipped but never deleted —
  /// erasing a user's persisted declines over a transient read is
  /// irreversible, and the block returns if the pin does.
  absent,
}

/// The TOFU verdict of one connect attempt. The opener never invokes the
/// prompter for a trusted key, so first-connect unblocking (1a) reads the
/// observed verdict after the transport lands.
class _TrustObservation {
  HostKeyDecision? decision;
}

/// A [TofuVerifier] decorator that records each check's verdict and
/// delegates every other overridable member (pin) to the wrapped verifier,
/// so a wrapped verifier's overrides are never bypassed on the connect path
/// that can lift blocks.
class _ObservingTofu extends TofuVerifier {
  final TofuVerifier _inner;
  final _TrustObservation _observation;

  _ObservingTofu(this._inner, this._observation) : super(_inner.store);

  @override
  Future<HostKeyDecision> check(HostKey presented) async {
    final decision = await _inner.check(presented);
    _observation.decision = decision;
    return decision;
  }

  @override
  Future<void> pin(HostKey key) => _inner.pin(key);
}

class _EndpointPool {
  final PoolKey key;

  /// serverIds currently referencing this pool (03 §3.5 refcount).
  final Map<String, _ServerReference> references = {};

  final List<_TransportSlot> transports = [];

  /// Browse bindings in LRU order: the first entry is the
  /// least-recently-used pane-tab channel — the exhaustion-sharing victim.
  final Map<(String, String), _PaneChannelView> browseByClient = {};

  final List<_ChannelHandle> idleTransfer = [];
  final Set<_ChannelHandle> leasedTransfer = {};
  final Queue<_ChannelWaiter> waiters = Queue();

  SshCredentials? resolvedCredentials;
  bool interactiveOnly = false;
  _HostKeyIncident? _incident;
  Object _trustEpoch = Object();

  /// The in-flight first-connect resolution, when one exists. Tripped by
  /// the last reference out (abandonment) — the only pool-lifetime end
  /// that can race a resolution: teardown paths bail out while
  /// `firstConnect` is set, and a block lands only after the resolver
  /// completes (handshakes happen inside `_openTransport`).
  _PoolResolution? _resolution;

  bool get blocked => _incident != null;
  String? get blockDetail => _incident?._detail;

  int acquisitions = 0;
  Future<void>? firstConnect;
  Future<void>? growth;
  Future<void>? pumping;
  _ReconnectCycle? _reconnect;
  Timer? _keepAliveTimer;
  final Set<Future<void>> _retiring = {};

  _EndpointPool(this.key, this._incident);
}

enum _TransportRole { primary, extra }

class _TransportSlot {
  final SshTransport transport;
  final _TransportRole _role;
  final Set<_ChannelHandle> channels = {};

  // Diagnostics belong to this transport, never to its replacements.
  RemoteFileException? _openFailure;

  /// Channel opens in flight — reserved against the budgets the moment
  /// their open starts, so concurrent acquisitions cannot oversubscribe.
  int pendingOpens = 0;

  int _pendingCloses = 0;
  Timer? _idleTimer;

  /// A keepalive roundtrip in flight — at most one per transport (03 §3.3).
  bool _pingOutstanding = false;

  _TransportSlot(this.transport, this._role);
}

enum _ChannelUse { browse, transferIdle, transferLeased }

enum _BrowseAcquisition { caller, recovery }

class _ChannelHandle {
  final _TransportSlot slot;
  final SftpChannel channel;

  _ChannelUse use;
  int browseClients = 0;
  String? leaseServerId;
  String? homePath;
  bool closed = false;

  _ChannelHandle({
    required this.slot,
    required this.channel,
    required this.use,
  });
}

class _ChannelWaiter {
  final bool browse;
  final String serverId;
  final completer = Completer<_ChannelHandle>();

  _ChannelWaiter({required this.browse, required this.serverId});
}

class _PaneChannelView implements PaneChannel {
  final PooledConnectionManager _manager;
  final _EndpointPool _pool;
  final String _serverId;
  final String _paneTabId;
  _ChannelHandle _handle;
  RemoteFileException? _failure;

  _PaneChannelView(
    this._manager,
    this._pool,
    this._serverId,
    this._paneTabId,
    this._handle,
  );

  @override
  RemoteFileSystem get fs {
    _manager._throwIfBlocked(_pool);
    final failure = _failure;
    if (failure != null) throw failure;
    return _manager._liveFileSystem(_pool, _handle);
  }

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {
    if (!identical(_pool.browseByClient[(_serverId, _paneTabId)], this)) return;
    _manager._reportFailure(_pool, _handle, source, error);
  }

  @override
  String get homePath => _handle.homePath!;

  @override
  Future<void> close() async {
    final key = (_serverId, _paneTabId);

    // A tab can rebind to the same shared channel; only this binding owns it.
    if (!identical(_pool.browseByClient[key], this)) return;

    await _manager._closeBrowseClient(_pool, key);
  }
}

class _LeaseView implements TransferChannelLease {
  final PooledConnectionManager _manager;
  final _EndpointPool _pool;
  final _ChannelHandle _handle;

  bool _released = false;

  _LeaseView(this._manager, this._pool, this._handle);

  @override
  RemoteFileSystem get fs => _manager._liveFileSystem(_pool, _handle);

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {
    if (_released) return;
    _manager._reportFailure(_pool, _handle, source, error);
  }

  @override
  Future<void> release() async {
    // Release belongs to this borrower, not the reusable channel handle.
    if (_released) return;

    _released = true;
    await _manager._releaseLease(_pool, _handle);
  }
}
