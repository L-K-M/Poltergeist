/// 06 §3.3's dirty-prompt guards, kept for the whole app rather than per
/// window (00 D38): every window hears the checkout session, only the
/// active one prompts, and whichever window that is must know what an
/// earlier one already asked and what any window is uploading.
final class CheckoutPromptLedger {
  /// Record ids already toasted: one prompt per dirty edge, and an expired
  /// toast never re-fires (the persistent indicators are the §3.7 review
  /// surface's slice).
  final prompted = <String>{};

  /// `serverId|remotePath` keys with an upload in flight, so a built-in
  /// save-and-upload racing the watcher never shows a stale prompt.
  final uploading = <String>{};
}
