part of 'connection_manager.dart';

const _reconnectBaseDelay = Duration(seconds: 1);
const _reconnectJitterFraction = 0.3;

/// Recovery owns bindings, not operations: interrupted work is never replayed.
extension _PoolRecovery on PooledConnectionManager {
  bool _hasLiveTransport(_EndpointPool pool) =>
      pool.transports.any((slot) => !slot.transport.isClosed);

  bool _hasDemand(_EndpointPool pool) =>
      pool.browseByClient.isNotEmpty ||
      pool.leasedTransfer.isNotEmpty ||
      pool.acquisitions != 0;

  RemoteFileSystem _liveFileSystem(_EndpointPool pool, _ChannelHandle handle) {
    _throwIfBlocked(pool);
    if (handle.closed ||
        !pool.transports.contains(handle.slot) ||
        handle.slot.transport.isClosed) {
      throw _disconnectedAcquisition();
    }
    return handle.channel.fs;
  }

  _ChannelHandle? _liveBrowseHandle(_EndpointPool pool) {
    for (final binding in pool.browseByClient.values) {
      final handle = binding._handle;
      if (!handle.closed &&
          pool.transports.contains(handle.slot) &&
          !handle.slot.transport.isClosed) {
        return handle;
      }
    }
    return null;
  }

  void _reportFailure(
    _EndpointPool pool,
    _ChannelHandle handle,
    RemoteFileSystem source,
    RemoteFileException error,
  ) {
    if (error.kind != RemoteFileErrorKind.disconnected ||
        handle.closed ||
        !identical(handle.channel.fs, source)) {
      return;
    }
    _handleTransportDeath(pool, handle.slot);
  }

  void _watchTransport(_EndpointPool pool, _TransportSlot slot) {
    // Pool-initiated closes detach first, making their completion a no-op.
    unawaited(
      slot.transport.done.then<void>(
        (_) => _handleTransportDeath(pool, slot),
        onError: (Object _) => _handleTransportDeath(pool, slot),
      ),
    );
  }

  void _handleTransportDeath(_EndpointPool pool, _TransportSlot slot) {
    if (!pool.transports.remove(slot)) return;
    _cancelIdleTimer(slot);
    pool._trustEpoch = Object(); // Reject growth handshakes from before loss.

    // Preserve pane and lease identities as demand, but never lend dead VFSs.
    final handles = List<_ChannelHandle>.of(slot.channels);
    slot.channels.clear();
    for (final handle in handles) {
      handle.closed = true;
      pool.idleTransfer.remove(handle);
    }
    final cleanup = _closeDeadSlot(slot, handles);
    pool._retiring.add(cleanup);
    unawaited(cleanup.then((_) => pool._retiring.remove(cleanup)));

    if (!_isCurrentPool(pool) || pool.blocked || pool.references.isEmpty) {
      return;
    }
    if (!_hasDemand(pool)) {
      unawaited(_maybeTearDown(pool));
      return;
    }
    if (pool._reconnect != null) return;

    final cycle = _ReconnectCycle(
      pool.interactiveOnly
          ? ConnectPrompting.enabled
          : ConnectPrompting.disabled,
    );
    pool._reconnect = cycle;
    _setState(pool, ServerConnectionState.reconnecting);
    unawaited(
      _runReconnect(
        pool,
        cycle,
      ).then(cycle._done.complete, onError: cycle._done.completeError),
    );
  }

  Future<void> _closeDeadSlot(
    _TransportSlot slot,
    List<_ChannelHandle> handles,
  ) async {
    await Future.wait([
      for (final handle in handles) closeSshResource(handle.channel.close),
    ]);
    await closeSshResource(slot.transport.close);
  }

  bool _isCurrentReconnect(_EndpointPool pool, _ReconnectCycle cycle) =>
      identical(pool._reconnect, cycle) &&
      _isCurrentPool(pool) &&
      pool.references.isNotEmpty &&
      _hasDemand(pool) &&
      !pool.blocked;

  void _checkReconnect(_EndpointPool pool, _ReconnectCycle cycle) {
    _throwIfBlocked(pool);
    if (!_isCurrentReconnect(pool, cycle)) throw _disconnectedAcquisition();
  }

  void _cancelReconnect(_EndpointPool pool) {
    final cycle = pool._reconnect;
    if (cycle == null) return;
    pool._reconnect = null;
    pool._resolution?.dismiss();
    cycle._cancel();
  }

  Future<void> _runReconnect(_EndpointPool pool, _ReconnectCycle cycle) async {
    var failures = 0;
    try {
      // Death can arrive before the initial connect's callers resume.
      final first = pool.firstConnect;
      if (first != null) await cycle._wait(first);
      while (true) {
        _checkReconnect(pool, cycle);
        try {
          if (!_hasLiveTransport(pool)) {
            await cycle._delay(_reconnectDelay(failures));
            _checkReconnect(pool, cycle);
            await cycle._wait(_attemptReconnect(pool, cycle));
          }
          _checkReconnect(pool, cycle);
          await cycle._wait(_rebindBrowse(pool, cycle));
          _checkReconnect(pool, cycle);
          pool._reconnect = null;
          _setState(pool, ServerConnectionState.connected);
          _pumpWaitersEnsured(pool);
          return;
        } on Exception catch (error) {
          _checkReconnect(pool, cycle);
          // Cancellation and permanent VFS failures need explicit user retry.
          if (error is RemoteFileException &&
              error.kind != RemoteFileErrorKind.disconnected) {
            rethrow;
          }
          failures++;
        }
      }
    } on Object {
      if (_isCurrentReconnect(pool, cycle)) await _tearDownPool(pool);
      rethrow;
    } finally {
      if (identical(pool._reconnect, cycle)) pool._reconnect = null;
      unawaited(_maybeTearDown(pool));
    }
  }

  Duration _reconnectDelay(int failures) {
    var micros = _reconnectBaseDelay.inMicroseconds;
    final cap = _policy.reconnectBackoffCap.inMicroseconds;
    // Stop doubling at the cap: long outages cannot overflow the exponent.
    for (var i = 0; i < failures && micros < cap; i++) {
      micros *= 2;
    }
    return Duration(
      microseconds:
          (min(micros, cap) *
                  (1 -
                      _reconnectJitterFraction * _reconnectRandom.nextDouble()))
              .round(),
    );
  }

  Future<void> _attemptReconnect(
    _EndpointPool pool,
    _ReconnectCycle cycle,
  ) async {
    final config = pool.references.values.first.config;
    final status = await _prober.probe(config.host, config.port);
    _checkReconnect(pool, cycle);
    if (status != ProbeStatus.online) throw const _ReconnectUnavailable();
    if (_hasLiveTransport(pool)) return;

    final prompting = cycle._prompting;
    ResolvedCredentials? resolved;
    if (prompting == ConnectPrompting.enabled ||
        pool.resolvedCredentials == null) {
      final scope = _PoolResolution();
      pool._resolution = scope;
      pool.resolvedCredentials = null;
      try {
        resolved = await _resolveCredentials(config, scope);
        _checkReconnect(pool, cycle);
      } finally {
        if (identical(pool._resolution, scope)) pool._resolution = null;
      }
    }

    final credentials = resolved?.credentials ?? pool.resolvedCredentials!;
    final hostKey = _hostKeyPrompterFor(pool, ConnectPrompting.disabled);
    final attempt = cycle._authAttempt = Object();
    final SshTransport transport;
    try {
      transport = await _openTransport(
        config: config,
        credentials: credentials,
        tofu: _tofu,
        // Even an auth-prompting reconnect cannot approve an unknown key.
        onHostKey: (decision) async =>
            _isCurrentAuth(pool, cycle, attempt) ? hostKey(decision) : false,
        onKeyboardInteractive: _reconnectResponder(pool, cycle, attempt),
        prompting: prompting,
      );
    } on AuthChallengeRequiredError {
      if (_isCurrentReconnect(pool, cycle)) {
        cycle._prompting = ConnectPrompting.enabled;
        pool.resolvedCredentials = null;
      }
      rethrow;
    } finally {
      if (identical(cycle._authAttempt, attempt)) cycle._authAttempt = null;
    }

    if (!_isCurrentReconnect(pool, cycle)) {
      await closeSshResource(transport.close);
      _checkReconnect(pool, cycle);
    }
    if (_hasLiveTransport(pool)) {
      await closeSshResource(transport.close);
      return;
    }

    pool.resolvedCredentials = credentials;
    pool.interactiveOnly =
        pool.interactiveOnly ||
        resolved?.origin == CredentialOrigin.prompted ||
        transport.authKind == AuthKind.keyboardInteractive ||
        transport.authKind == AuthKind.promptedPassword;
    // The first transport's cache role never migrates after failure (§3.3).
    final slot = _TransportSlot(transport, _TransportRole.extra);
    pool.transports.add(slot);
    _watchTransport(pool, slot);
    _updateIdleTimer(pool, slot);
  }

  bool _isCurrentAuth(
    _EndpointPool pool,
    _ReconnectCycle cycle,
    Object attempt,
  ) =>
      _isCurrentReconnect(pool, cycle) &&
      identical(cycle._authAttempt, attempt);

  KeyboardInteractiveResponder? _reconnectResponder(
    _EndpointPool pool,
    _ReconnectCycle cycle,
    Object attempt,
  ) {
    final responder = _onKeyboardInteractive;
    if (responder == null || cycle._prompting == ConnectPrompting.disabled) {
      return null;
    }
    return (prompts, name, instruction) async {
      // A handshake can outlive both its pool and its retry attempt. Neither
      // a late challenge nor a late answer may interact with that old socket.
      if (!_isCurrentAuth(pool, cycle, attempt)) {
        throw _disconnectedAcquisition();
      }
      final answers = await responder(prompts, name, instruction);
      if (!_isCurrentAuth(pool, cycle, attempt)) {
        throw _disconnectedAcquisition();
      }
      return answers;
    };
  }

  Future<void> _rebindBrowse(_EndpointPool pool, _ReconnectCycle cycle) async {
    for (final binding in List<_PaneChannelView>.of(
      pool.browseByClient.values,
    )) {
      _checkReconnect(pool, cycle);
      final key = (binding._serverId, binding._paneTabId);
      if (!identical(pool.browseByClient[key], binding)) continue;
      if (!binding._handle.closed &&
          pool.transports.contains(binding._handle.slot)) {
        continue;
      }
      final reference = pool.references[binding._serverId];
      if (reference == null) continue;

      final handle = await _acquireBrowseChannel(
        reference,
        origin: _BrowseAcquisition.recovery,
      );
      try {
        _checkReconnect(pool, cycle);
        if (!identical(pool.browseByClient[key], binding)) continue;
        _checkAcquisition(reference, handle);
        handle.use = _ChannelUse.browse;
        handle.homePath ??= await handle.channel.fs.canonicalize('.');
        _checkReconnect(pool, cycle);
        if (!identical(pool.browseByClient[key], binding)) continue;
        _checkAcquisition(reference, handle);
        binding._handle.browseClients--;
        binding._handle = handle;
        handle.browseClients++;
      } on RemoteFileException catch (error) {
        // A removed binding is local cancellation, not transport loss.
        if (!identical(pool.browseByClient[key], binding)) continue;
        if (error.kind == RemoteFileErrorKind.disconnected) {
          _handleTransportDeath(pool, handle.slot);
        }
        rethrow;
      } finally {
        // A close/replacement can win while canonicalize awaits.
        if (handle.browseClients == 0) await _closeHandle(pool, handle);
      }
    }
  }
}

class _ReconnectUnavailable implements Exception {
  const _ReconnectUnavailable();
}

/// One cancellable wait at a time, without accumulating cancellation listeners
/// across an unbounded outage. Late operations still have an error observer.
class _ReconnectCycle {
  final _done = Completer<void>();
  ConnectPrompting _prompting;
  Object? _authAttempt;
  bool _cancelled = false;
  void Function()? _interrupt;

  _ReconnectCycle(this._prompting) {
    _done.future.ignore(); // Recovery may have no folded acquisition caller.
  }

  Future<T> _wait<T>(Future<T> work) {
    final result = Completer<T>();
    void interrupt() {
      if (result.isCompleted) return;
      result.completeError(
        const RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: 'reconnect',
          message: 'Reconnect cancelled.',
        ),
      );
    }

    _interrupt = interrupt;
    work
        .then<void>(
          (value) {
            if (!result.isCompleted) result.complete(value);
          },
          onError: (Object error, StackTrace stack) {
            if (!result.isCompleted) result.completeError(error, stack);
          },
        )
        .whenComplete(() {
          if (identical(_interrupt, interrupt)) _interrupt = null;
        });
    if (_cancelled) interrupt();
    return result.future;
  }

  Future<void> _delay(Duration duration) async {
    final ready = Completer<void>();
    final timer = Timer(duration, ready.complete);
    try {
      await _wait(ready.future);
    } finally {
      timer.cancel();
    }
  }

  void _cancel() {
    _cancelled = true;
    _interrupt?.call();
  }
}
