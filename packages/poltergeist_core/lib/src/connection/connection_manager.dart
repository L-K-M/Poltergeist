import 'dart:async';
import 'dart:collection';

import 'package:seance_core/seance_core.dart';

import 'pool_key.dart';
import 'pool_policy.dart';
import 'ssh_transport.dart';

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
  Future<PaneChannel> openBrowseChannel(String serverId,
      {required String paneTabId});

  /// A transfer worker borrows a channel; [TransferChannelLease.release]
  /// returns it to the pool. Blocks while the pool is at capacity.
  Future<TransferChannelLease> leaseTransferChannel(String serverId);

  /// The server's connection state, current value first. A shared pool's
  /// state fans out to every serverId referencing it (03 §3.5).
  Stream<ServerConnectionState> watchServer(String serverId);

  /// ServerIds with live pools — feeds ProbeService so connected servers
  /// are skipped and reported online for free (03 §3.4).
  Future<Set<String>> connectedServerIds();

  /// Drops this serverId's reference to its pool: closes its browse
  /// channels, force-releases its transfer leases. The pool (and its
  /// resolved credentials) survives while sibling serverIds reference it.
  Future<void> disconnectServer(String serverId);
}

/// A browse channel bound to one pane-tab (03 §3.2).
abstract interface class PaneChannel {
  RemoteFileSystem get fs;

  /// `canonicalize('.')` at open — the server-side home, Séance-style.
  String get homePath;

  /// The tab closes its channel when it closes or navigates off the
  /// server.
  Future<void> close();
}

/// A borrowed transfer channel (03 §3.2).
abstract interface class TransferChannelLease {
  RemoteFileSystem get fs;

  /// Returns the channel to the pool.
  Future<void> release();
}

/// Everything the pool needs to connect on behalf of one serverId.
///
/// The app resolves credentials from its vault — prompting when the vault
/// holds no secret — right before the pool's first connect; nothing here is
/// persisted (D18).
class ResolvedServerConnection {
  final ServerConfig config;
  final SshCredentials credentials;

  const ResolvedServerConnection({
    required this.config,
    required this.credentials,
  });
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
  final Future<ResolvedServerConnection> Function(String serverId)
      _resolveServer;
  final TofuVerifier _tofu;
  final HostKeyPrompter _onHostKey;
  final KeyboardInteractiveResponder? _onKeyboardInteractive;
  final PoolPolicy _policy;
  final SshTransportOpener _openTransport;

  final Map<String, _ServerReference> _references = {};
  final Map<String, Future<_ServerReference>> _pendingReferences = {};
  final Map<PoolKey, _EndpointPool> _pools = {};
  final Map<String, StreamController<ServerConnectionState>> _events = {};
  final Map<String, ServerConnectionState> _lastStates = {};

  PooledConnectionManager({
    required this._resolveServer,
    required this._tofu,
    required this._onHostKey,
    this._onKeyboardInteractive,
    this._policy = const PoolPolicy(),
    this._openTransport = openDartSshTransport,
  });

  @override
  Future<PaneChannel> openBrowseChannel(String serverId,
      {required String paneTabId}) =>
      _withReference(serverId, (reference) => _openBrowse(reference, paneTabId));

  Future<PaneChannel> _openBrowse(
      _ServerReference reference, String paneTabId) async {
    final serverId = reference.serverId;
    final pool = reference.pool;
    final clientKey = (serverId, paneTabId);

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

    await _ensureFirstTransport(pool, reference);
    _checkAcquisition(reference);

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
      handle.homePath =
          homePath ?? await handle.channel.fs.canonicalize('.');
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

  Future<TransferChannelLease> _leaseTransfer(_ServerReference reference) async {
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

  Future<T> _withReference<T>(String serverId,
      Future<T> Function(_ServerReference reference) acquire) async {
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
  Stream<ServerConnectionState> watchServer(String serverId) {
    // Current value first, then live updates, with plain async stream
    // semantics (`.first`, `await for`, and `listen` all behave normally).
    // The initial value is computed at listen time — a caller that stores
    // the stream and listens later must not start from a snapshot taken
    // before intermediate state changes.
    return Stream.multi((listener) {
      listener.add(_currentStateOf(serverId));
      final subscription = _eventsFor(serverId).stream
          .listen(listener.add, onError: listener.addError);
      listener.onPause = subscription.pause;
      listener.onResume = subscription.resume;
      listener.onCancel = subscription.cancel;
    });
  }

  /// The server's state derived from the live pool when one exists — more
  /// honest than the emitted-state cache for a serverId that joined an
  /// already-connected shared pool (no emission fires for the joiner) and
  /// for the dead-transport window reconnect (03 §3.3) will own.
  ServerConnectionState _currentStateOf(String serverId) {
    final reference = _references[serverId];
    if (reference != null) {
      final pool = reference.pool;
      if (pool.blocked) return ServerConnectionState.blocked;

      // Transports die asynchronously and are evicted lazily — report
      // connected only while one is actually alive.
      final hasLiveTransport =
          pool.transports.any((slot) => !slot.transport.isClosed);
      if (hasLiveTransport) return ServerConnectionState.connected;
      if (pool.firstConnect != null) return ServerConnectionState.connecting;

      // A reference with no live transport and no in-flight connect is not
      // connected — the emitted-state cache may still say `connected` from
      // before the death, so it must not win here. Reconnect (03 §3.3) will
      // make this window report `reconnecting` instead.
      if (pool.transports.isNotEmpty) return ServerConnectionState.disconnected;
    }

    return _lastStates[serverId] ?? ServerConnectionState.disconnected;
  }

  @override
  Future<Set<String>> connectedServerIds() async {
    final connected = <String>{};

    for (final entry in _references.entries) {
      final pool = entry.value.pool;

      // Transports die asynchronously and are evicted lazily — count only
      // pools that still hold a live one.
      final hasLiveTransport =
          pool.transports.any((slot) => !slot.transport.isClosed);
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
      _emit(serverId, ServerConnectionState.disconnected);
      return;
    }

    final pool = reference.pool;
    pool.references.remove(serverId);
    _emit(serverId, ServerConnectionState.disconnected);
    _lastStates.remove(serverId);

    // A new session must never join this pool's abandoned connect futures.
    if (pool.references.isEmpty && identical(_pools[pool.key], pool)) {
      _pools.remove(pool.key);
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
    for (final key in clientKeys) {
      await _closeBrowseClient(pool, key);
    }

    // Force-release its transfer leases by closing the channels: in-flight
    // work fails with `disconnected`, which is exactly the signal the
    // transfer queue (M4) turns into its queued flip (03 §3.5).
    final leases = [
      for (final handle in pool.leasedTransfer)
        if (handle.leaseServerId == serverId) handle,
    ];
    for (final handle in leases) {
      pool.leasedTransfer.remove(handle);
      handle.leaseServerId = null;
      await _closeHandle(pool, handle);
    }

    if (pool.references.isEmpty) {
      // Last reference out: transports down, resolved credentials wiped.
      await _tearDownPool(pool);
    } else {
      await _pumpWaiters(pool);
    }

  }

  // ── Channel acquisition ────────────────────────────────────────────────

  Future<_ChannelHandle> _acquireBrowseChannel(
      _ServerReference reference) async {
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
        final opened =
            await _openChannelOn(pool, grown, use: _ChannelUse.browse);
        if (opened != null) return opened;
      }
    }

    // Exhausted with no growth possible: never fail, never hang — share
    // the least-recently-used browse channel (03 §3.2).
    if (pool.browseByClient.isNotEmpty) {
      return pool.browseByClient.values.first._handle;
    }

    // No browse channel exists to share (every channel is a leased
    // transfer): queue behind the next release — still queue-don't-fail.
    // A block may have landed mid-open (killing every binding), in which
    // case there is nothing to queue behind.
    _checkAcquisition(reference);
    return _enqueueWaiter(pool, browse: true, serverId: serverId);
  }

  Future<_ChannelHandle> _acquireTransferChannel(
      _ServerReference reference) async {
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
      final opened =
          await _openChannelOn(pool, slot, use: _ChannelUse.transferLeased);
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
        final opened =
            await _openChannelOn(pool, grown, use: _ChannelUse.transferLeased);
        if (opened != null) return opened;
      }
    }

    // At capacity: block until a lease comes back (03 §3.2), unless the
    // requesting session disappeared during an open or growth await.
    _checkAcquisition(reference);
    return _enqueueWaiter(pool, browse: false, serverId: serverId);
  }

  /// A transport with room for one more channel of any kind — browse
  /// channels count only against the total ceiling (03 §3.2 rule 4).
  /// [pendingOpens] is included so concurrent acquisitions cannot each
  /// spend the same last slot while their opens are in flight. Dead
  /// transports are skipped (their eviction is open-failure driven), and
  /// [exclude] skips transports a caller already tried.
  _TransportSlot? _browseSlot(_EndpointPool pool,
      [Set<_TransportSlot>? exclude]) {
    for (final slot in pool.transports) {
      if (slot.transport.isClosed) continue;
      if (exclude != null && exclude.contains(slot)) continue;
      if (slot.channels.length + slot.pendingOpens <
          _policy.maxChannelsPerTransport) {
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
  _TransportSlot? _transferSlot(_EndpointPool pool,
      [Set<_TransportSlot>? exclude]) {
    for (final slot in pool.transports) {
      if (slot.transport.isClosed) continue;
      if (exclude != null && exclude.contains(slot)) continue;
      final total = slot.channels.length + slot.pendingOpens;
      final withinTotal = total < _policy.maxChannelsPerTransport;
      final withinTransfer = total - _browseCount(slot) <
          _policy.maxTransferChannelsPerTransport;
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
      _EndpointPool pool, _TransportSlot slot,
      {required _ChannelUse use}) async {
    if (slot.transport.isClosed) {
      // A dead transport is dropped; revival is the reconnect story
      // (03 §3.3), which lands with keepalive — not this pool's job.
      pool.transports.remove(slot);
      return null;
    }

    slot.pendingOpens++;
    try {
      final channel = await slot.transport.openChannel();

      // The pool may have been hard-blocked while the open was in flight;
      // a channel landing after the block's handle-closing loop would be
      // the one thing on a blocked pool that still looks live.
      if (pool.blocked || !pool.transports.contains(slot)) {
        final orphan = _ChannelHandle(
            slot: slot, channel: channel, use: use);
        slot.channels.add(orphan);
        await _closeHandle(pool, orphan);
        return null;
      }

      final handle = _ChannelHandle(slot: slot, channel: channel, use: use);
      slot.channels.add(handle);
      return handle;
    } on Exception {
      // Channel-open failure falls back to the caller's next strategy
      // (idle steal, LRU share, or queue) — never surfaces raw. A transport
      // that died mid-open is evicted, or its corpse keeps occupying a
      // transport slot (and blocking growth) forever.
      if (slot.transport.isClosed) {
        pool.transports.remove(slot);
      }
      return null;
    } finally {
      slot.pendingOpens--;
    }
  }

  _PaneChannelView _bindBrowse(
      _EndpointPool pool, (String, String) clientKey, _ChannelHandle handle) {
    handle.use = _ChannelUse.browse;
    handle.browseClients++;
    final binding =
        _PaneChannelView(this, pool, clientKey.$1, clientKey.$2, handle);
    pool.browseByClient[clientKey] = binding;
    return binding;
  }

  // ── First connect (growth rule 1) ──────────────────────────────────────

  Future<void> _ensureFirstTransport(
      _EndpointPool pool, _ServerReference reference) async {
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
      _EndpointPool pool, _ServerReference reference) async {
    // A clearing attempt on a blocked pool stays "blocked" until it
    // succeeds — the block is the truth users act on, not the retry.
    if (!pool.blocked) _setState(pool, ServerConnectionState.connecting);
    var changedKeyApproved = false;
    final prompt = _hostKeyPrompterFor(pool, ConnectPrompting.enabled);

    try {
      final transport = await _openTransport(
        config: reference.config,
        credentials: reference.credentials,
        tofu: _tofu,
        onHostKey: (decision) async {
          final accepted = await prompt(decision);
          if (accepted && decision.verdict == HostKeyVerdict.changed) {
            changedKeyApproved = true;
          }
          return accepted;
        },
        onKeyboardInteractive: _onKeyboardInteractive,
        prompting: ConnectPrompting.enabled,
      );

      // Every serverId may have disconnected while the connect was in
      // flight (the disconnect hook tears the pool down immediately). A
      // landed transport must not resurrect a torn-down pool — close it
      // and fail the callers.
      // A trusted key can reappear without invoking the prompter; that is
      // not approval to clear a previously observed changed-key block.
      if (pool.references.isEmpty || (pool.blocked && !changedKeyApproved)) {
        try {
          await transport.close();
        } on Exception {
          // Swallow: the trust/disconnect error below remains authoritative.
        }
        _throwIfBlocked(pool);
        throw const RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: 'connect',
          message: 'The server was disconnected while connecting.',
        );
      }

      pool.resolvedCredentials = reference.credentials;

      // Rule 2: interactive auth caps the pool at one transport from now
      // on — growth must never re-trigger a 2FA prompt (D5).
      pool.interactiveOnly =
          transport.authKind == AuthKind.keyboardInteractive ||
              transport.authKind == AuthKind.promptedPassword;

      pool.transports.add(_TransportSlot(transport));

      // An accepted changed key re-pins inside the opener; reaching here
      // means the user cleared the block (rule 1's only clearing path).
      pool.blocked = false;
      pool.blockDetail = null;
      _setState(pool, ServerConnectionState.connected);
    } on Object {
      if (pool.blocked) {
        // A declined changed key: surface the block, not the raw auth
        // failure behind it.
        _setState(pool, ServerConnectionState.blocked);
        throw _blockedError(pool);
      }
      _setState(pool, ServerConnectionState.disconnected);
      rethrow;
    }
  }

  // ── Growth (rules 2–4) ─────────────────────────────────────────────────

  bool _canGrow(_EndpointPool pool) =>
      !pool.blocked &&
      !pool.interactiveOnly &&
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
      );

      // The pool may have torn down (every reference disconnected) or
      // hard-blocked while this connect was in flight — mirror
      // _firstConnect's guard so growth can never resurrect a dead pool.
      if (pool.references.isEmpty || pool.blocked) {
        try {
          await transport.close();
        } on Exception {
          // Swallow: there is no caller left to receive this failure.
        }
        return;
      }

      pool.transports.add(_TransportSlot(transport));
    } on AuthChallengeRequiredError {
      pool.interactiveOnly = true;
    } on Exception {
      // Transient growth failure: fall back to sharing existing channels;
      // a later attempt may grow again.
    }
  }

  // ── Host-key gate (D18) ────────────────────────────────────────────────

  HostKeyPrompter _hostKeyPrompterFor(
      _EndpointPool pool, ConnectPrompting prompting) {
    return (decision) async {
      switch (decision.verdict) {
        case HostKeyVerdict.trusted:
          return true;

        case HostKeyVerdict.changed:
          // Block at detection, not after the user finishes reviewing it.
          await _blockPool(pool, decision);
          if (prompting == ConnectPrompting.disabled) return false;

          // Only explicit approval permits the opener to re-pin (D18).
          return _onHostKey(decision);

        case HostKeyVerdict.firstUse:
          if (prompting == ConnectPrompting.enabled) {
            return _onHostKey(decision);
          }
          // Growth arrives after a first connect pinned this server; an
          // unexpected first-use there is refused, not prompted.
          return false;
      }
    };
  }

  Future<void> _blockPool(_EndpointPool pool, HostKeyDecision decision) async {
    if (pool.blocked) return;

    pool.blocked = true;
    pool.blockDetail =
        'Host key for ${decision.presented.host}:${decision.presented.port} '
        'has changed (presented ${decision.presented.fingerprintSha256}, '
        'pinned ${decision.pinned?.fingerprintSha256 ?? "none"}). The server '
        'is blocked until the new key is reviewed.';

    // Hard-block the ENTIRE pool: drop every channel and transport so every
    // operation — for every serverId sharing this endpoint — fails. A
    // sibling bookmark must never keep operating over a changed key.
    final slots = List<_TransportSlot>.of(pool.transports);
    pool.transports.clear();
    pool.browseByClient.clear();
    pool.idleTransfer.clear();
    pool.leasedTransfer.clear();
    pool.resolvedCredentials = null;

    _failAllWaiters(pool, message: pool.blockDetail);
    _setState(pool, ServerConnectionState.blocked);

    // Mirror normal teardown exactly on the security-critical path: close
    // every channel handle, then the transports (D18's hard block leaves
    // nothing that looks live).
    for (final slot in slots) {
      for (final handle in List<_ChannelHandle>.of(slot.channels)) {
        await _closeHandle(pool, handle);
      }
      try {
        await slot.transport.close();
      } on Exception {
        // The transport is untrusted now; teardown failures are noise.
      }
    }
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

  // ── Release, teardown, waiters ─────────────────────────────────────────

  Future<void> _closeBrowseClient(
      _EndpointPool pool, (String, String) clientKey) async {
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
    handle.use = _ChannelUse.transferIdle;
    pool.idleTransfer.add(handle);

    await _pumpWaiters(pool);
    await _maybeTearDown(pool);
  }

  Future<void> _closeHandle(_EndpointPool pool, _ChannelHandle handle) async {
    if (handle.closed) return;

    handle.closed = true;
    handle.slot.channels.remove(handle);
    pool.idleTransfer.remove(handle);

    // Structural invariant: a closed handle is never bookkept as leased or
    // bound to a pane-tab — callers remove those first today, and this
    // keeps a future close path from silently breaking that convention.
    pool.leasedTransfer.remove(handle);
    pool.browseByClient
        .removeWhere((_, bound) => identical(bound._handle, handle));

    try {
      await handle.channel.close();
    } on Exception {
      // Best-effort: a half-dead channel's close failure has no audience.
    }
  }

  Future<void> _maybeTearDown(_EndpointPool pool) async {
    // Pending opens and home resolution own demand before binding a channel.
    if (pool.acquisitions != 0) return;
    if (pool.firstConnect != null) return;

    // Same race class as the first-connect guard: a growth connect that
    // lands after teardown would resurrect a transport on a torn-down
    // pool. Deferred teardowns rerun on the next release/close trigger;
    // a grown transport nobody uses is the idle-timeout slice's case
    // (03 §3.3 — lands with keepalive).
    if (pool.growth != null) return;

    if (pool.transports.isEmpty) return;

    // The first transport follows pane lifetime (03 §3.3): it stays while
    // any pane-tab shows the server, and never closes while a channel is
    // leased — closing tabs cannot park a running transfer.
    if (pool.browseByClient.isNotEmpty) return;
    if (pool.leasedTransfer.isNotEmpty) return;

    await _tearDownPool(pool);
  }

  Future<void> _tearDownPool(_EndpointPool pool) async {
    final slots = List<_TransportSlot>.of(pool.transports);
    pool.transports.clear();
    pool.idleTransfer.clear();
    pool.leasedTransfer.clear();
    pool.browseByClient.clear();

    // Credential references drop with the transports (03 §3.2 rule 3) —
    // Dart strings cannot be zeroized; clearing references is the best
    // available. The next first connect re-resolves from the vault.
    pool.resolvedCredentials = null;

    _failAllWaiters(pool);
    _setState(pool, ServerConnectionState.disconnected);

    for (final slot in slots) {
      for (final handle in List<_ChannelHandle>.of(slot.channels)) {
        await _closeHandle(pool, handle);
      }
      try {
        await slot.transport.close();
      } on Exception {
        // Swallow: teardown must complete even for a dead transport.
      }
    }
  }

  Future<_ChannelHandle> _enqueueWaiter(_EndpointPool pool,
      {required bool browse, required String serverId}) {
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

  Future<void> _pumpWaitersOnce(_EndpointPool pool) async {
    while (pool.waiters.isNotEmpty) {
      final waiter = pool.waiters.first;
      if (waiter.completer.isCompleted) {
        pool.waiters.remove(waiter);
        continue;
      }

      var handle = _takeIdleTransfer(pool);
      if (handle == null) {
        final use = waiter.browse
            ? _ChannelUse.browse
            : _ChannelUse.transferLeased;
        var slot = waiter.browse ? _browseSlot(pool) : _transferSlot(pool);
        if (slot == null && _canGrow(pool)) {
          await _growTransport(pool);
          if (pool.blocked) return;
          slot = waiter.browse ? _browseSlot(pool) : _transferSlot(pool);
        }
        if (slot != null) handle = await _openChannelOn(pool, slot, use: use);
      } else if (waiter.browse) {
        handle.use = _ChannelUse.browse;
      }

      // Still at capacity: the FIFO head stays queued — strict FIFO keeps
      // the queue predictable (03 §4.3).
      if (handle == null) return;

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

  void _failWaiters(_EndpointPool pool, String serverId) {
    final remaining = <_ChannelWaiter>[];

    for (final waiter in pool.waiters) {
      if (waiter.completer.isCompleted) {
        remaining.add(waiter);
        continue;
      }
      if (waiter.serverId == serverId) {
        waiter.completer.completeError(RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: waiter.browse
              ? 'open browse channel'
              : 'lease transfer channel',
          message: 'The server was disconnected while waiting for a channel.',
        ));
      } else {
        remaining.add(waiter);
      }
    }

    pool.waiters
      ..clear()
      ..addAll(remaining);
  }

  void _failAllWaiters(_EndpointPool pool, {String? message}) {
    for (final waiter in pool.waiters) {
      if (waiter.completer.isCompleted) continue;
      waiter.completer.completeError(RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'wait for channel',
        message: message ?? 'The connection pool was torn down.',
      ));
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
    unawaited(_resolveReference(serverId, pendingIdentity).then(
      request.complete,
      onError: request.completeError,
    ));
    return pendingIdentity.whenComplete(() {
      if (identical(_pendingReferences[serverId], pendingIdentity)) {
        _pendingReferences.remove(serverId);
      }
    });
  }

  Future<_ServerReference> _resolveReference(
      String serverId, Future<_ServerReference> pendingIdentity) async {
    final resolved = await _resolveServer(serverId);
    // A cancelled resolve must not register or erase a newer session.
    if (!identical(_pendingReferences[serverId], pendingIdentity)) {
      throw _disconnectedAcquisition();
    }

    // Configs are cached per serverId for the session; bookmark edits
    // invalidate them (M5's store owns that).
    final key = PoolKey.of(resolved.config);
    final pool = _pools.putIfAbsent(key, () => _EndpointPool(key));
    final reference = _ServerReference(
        serverId, resolved.config, resolved.credentials, pool);

    _references[serverId] = reference;
    pool.references[serverId] = reference;
    return reference;
  }

  void _setState(_EndpointPool pool, ServerConnectionState state) {
    for (final serverId in pool.references.keys) {
      _emit(serverId, state);
    }
  }

  /// Per-serverId broadcast. Async delivery on purpose: synchronous
  /// emission breaks the standard stream consumers (`.first`, `await for`);
  /// ordering within this controller is FIFO, and watchServer prepends the
  /// current value on subscribe.
  StreamController<ServerConnectionState> _eventsFor(String serverId) =>
      _events.putIfAbsent(
        serverId,
        () => StreamController<ServerConnectionState>.broadcast(),
      );

  void _emit(String serverId, ServerConnectionState state) {
    _lastStates[serverId] = state;

    final controller = _events[serverId];
    if (controller != null && !controller.isClosed) controller.add(state);
  }
}

// ── Internal model ─────────────────────────────────────────────────────

class _ServerReference {
  final String serverId;
  final ServerConfig config;
  final SshCredentials credentials;
  final _EndpointPool pool;

  _ServerReference(this.serverId, this.config, this.credentials, this.pool);
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
  bool blocked = false;
  String? blockDetail;

  int acquisitions = 0;
  Future<void>? firstConnect;
  Future<void>? growth;
  Future<void>? pumping;

  _EndpointPool(this.key);
}

class _TransportSlot {
  final SshTransport transport;
  final Set<_ChannelHandle> channels = {};

  /// Channel opens in flight — reserved against the budgets the moment
  /// their open starts, so concurrent acquisitions cannot oversubscribe.
  int pendingOpens = 0;

  _TransportSlot(this.transport);
}

enum _ChannelUse { browse, transferIdle, transferLeased }

class _ChannelHandle {
  final _TransportSlot slot;
  final SftpChannel channel;

  _ChannelUse use;
  int browseClients = 0;
  String? leaseServerId;
  String? homePath;
  bool closed = false;

  _ChannelHandle({required this.slot, required this.channel, required this.use});
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
  final _ChannelHandle _handle;

  _PaneChannelView(
      this._manager, this._pool, this._serverId, this._paneTabId, this._handle);

  @override
  RemoteFileSystem get fs => _handle.channel.fs;

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
  RemoteFileSystem get fs => _handle.channel.fs;

  @override
  Future<void> release() async {
    // Release belongs to this borrower, not the reusable channel handle.
    if (_released) return;

    _released = true;
    await _manager._releaseLease(_pool, _handle);
  }
}
