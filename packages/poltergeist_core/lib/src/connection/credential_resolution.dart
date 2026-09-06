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
/// The engine isolate's protocol (03 §5) wraps resolvers the same way:
/// its prompt round-trip races the reply future against [dismissed] and
/// cancels the open promptId when it fires, so dismissal crosses the
/// isolate boundary with no second mechanism.
abstract interface class CredentialResolutionScope {
  /// Completes when the requesting pool's lifetime ended before this
  /// resolution completed.
  ///
  /// Never errors; never completes for a resolution that finished first —
  /// the scope dies with its resolution.
  Future<void> get dismissed;
}
