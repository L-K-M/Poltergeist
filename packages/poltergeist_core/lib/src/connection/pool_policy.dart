/// Pool policy for the connection layer — the one file every transport and
/// channel budget constant lives in (03 §3.2).
///
/// The defaults are not guesses: they are the M0 measurements frozen into
/// D9's rung-4 verdict. Changing a default means re-measuring first.
class PoolPolicy {
  /// Authenticated SSH connections (transports) per endpoint pool.
  ///
  /// Two transports nearly doubled LAN aggregate throughput in M0, and four
  /// transports could not raise v1 dispatch concurrency any further: the
  /// global transfer cap (03 §4.3) is already saturated by 2 × 4 channels.
  final int maxTransports;

  /// Transfer channels each transport may carry.
  ///
  /// Four transfer channels beat three by 23.9 % on LAN and were the shaped
  /// link's maximum; eight regressed there. Eight is the total channel
  /// ceiling instead (see [maxChannelsPerTransport]).
  final int maxTransferChannelsPerTransport;

  /// Total SFTP channels (browse + transfer) per transport.
  ///
  /// OpenSSH's `MaxSessions` defaults to 10 session channels per TCP
  /// connection and every SFTP channel is one; 8 leaves headroom below the
  /// server-side ceiling.
  final int maxChannelsPerTransport;

  /// `client.ping()` cadence on idle transports (03 §3.3). A ping that times
  /// out marks the transport disconnected and triggers reconnect.
  final Duration keepAliveInterval;

  /// Extra transports (beyond the first) close after holding no channel for
  /// this long. The first transport follows pane lifetime instead of a
  /// timer (03 §3.3).
  final Duration idleExtraTransportTimeout;

  /// Upper bound of the exponential reconnect backoff (03 §3.3). Jitter is
  /// applied downward-only, after the clamp, so retries can never exceed
  /// this cap synchronized.
  final Duration reconnectBackoffCap;

  /// Consecutive failed reconnect cycles a transfer task tolerates before
  /// failing with its summarized error (03 §3.3). Counts reconnect cycles
  /// only — never per-item failures.
  final int taskRetryLimit;

  const PoolPolicy({
    this.maxTransports = 2,
    this.maxTransferChannelsPerTransport = 4,
    this.maxChannelsPerTransport = 8,
    this.keepAliveInterval = const Duration(seconds: 30),
    this.idleExtraTransportTimeout = const Duration(seconds: 60),
    this.reconnectBackoffCap = const Duration(seconds: 30),
    this.taskRetryLimit = 5,
  })  : assert(maxTransports >= 1, 'maxTransports must be positive'),
        assert(
          maxTransferChannelsPerTransport >= 1,
          'maxTransferChannelsPerTransport must be positive',
        ),
        assert(
          maxChannelsPerTransport >= maxTransferChannelsPerTransport,
          'the total channel ceiling must cover the transfer budget',
        ),
        assert(taskRetryLimit >= 0, 'taskRetryLimit must not be negative');
}
