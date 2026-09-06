/// Cancellation surface for one in-flight credential resolution (03 §3.2).
///
/// The pool passes a scope with every first-connect resolution. A
/// resolution may own a prompt — the credential dialog the vault shows
/// when no stored secret exists — and the manager cannot dismiss external
/// UI itself: when the pool's lifetime ends mid-resolution (the last
/// serverId disconnects while the dialog is open), it trips the scope so
/// the prompt owner closes its dialog instead of waiting for an answer
/// the pool will reject as stale.
///
/// The engine isolate's protocol (03 §5) will wrap resolvers the same
/// way when that slice lands: its prompt round-trip races the reply
/// future against [dismissed] and cancels the open promptId when it
/// fires, so dismissal crosses the isolate boundary with no second
/// mechanism.
abstract interface class CredentialResolutionScope {
  /// Completes when the requesting pool's lifetime ended before this
  /// resolution completed.
  ///
  /// Never errors; never completes once the pool has *observed* the
  /// resolution finishing — the scope dies with its resolution. The
  /// guarantee is at pool-observation granularity: a resolver that
  /// completes its future and lets the pool disconnect in the same
  /// microtask turn can still see [dismissed] fire in that window, so a
  /// resolver racing [dismissed] against its answer must guard on the
  /// answer's own completion (an already-completed answer tolerates the
  /// firing; the pool discards the late result regardless).
  Future<void> get dismissed;
}
