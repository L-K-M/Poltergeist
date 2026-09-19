import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show TransferTask, TransferTaskState;

import '../ui/quit_dialog.dart';
import 'app_transfer_queue.dart';

/// The journal flush's bound on the close path (02 §6, 07 §3.5): long
/// enough for the writer chain plus an fsync, short enough that a wedged
/// write warns instead of holding the quit hostage forever — the same
/// budget the session-flush timeouts use.
const _defaultFlushTimeout = Duration(seconds: 2);

/// The window-close quit guard (02 §6/§10, 07 §3.5's prevent-close
/// bullet). Consulted by the intercepted close before the window may
/// destroy: with live queue tasks it warns through the §10 dialog and
/// waits for the answer; then — task set or not — the journal flush is
/// the hard gate. A failed or wedged flush reports, warns, and keeps the
/// window open rather than destroying it with queued/paused/in-flight
/// state still unwritten.
///
/// The queue itself is bound by the workspace shell — the only object
/// that sees the live seam — so a later-arriving or swapped
/// [AppTransferQueue] is always read fresh, and widgets never touch the
/// engine's queue directly.
final class QuitGuard {
  QuitGuard({
    required GlobalKey<NavigatorState> navigatorKey,
    void Function(Object, StackTrace)? onError,
    Duration flushTimeout = _defaultFlushTimeout,
    // Keep the seams private to the guard.
    // ignore: prefer_initializing_formals
  }) : _navigatorKey = navigatorKey,
       // ignore: prefer_initializing_formals
       _onError = onError,
       // ignore: prefer_initializing_formals
       _flushTimeout = flushTimeout;

  final GlobalKey<NavigatorState> _navigatorKey;
  final void Function(Object, StackTrace)? _onError;
  final Duration _flushTimeout;

  /// The bound queue lookup — the shell binds its live `transferQueue`
  /// seam so a didUpdateWidget rebind is always read fresh.
  AppTransferQueue? Function()? _queueLookup;

  /// Concurrent close routes (the intercepted window close and the
  /// framework's exit request) share one in-flight decision: a single
  /// dialog answers both, and the journal flushes once.
  Future<bool>? _inFlight;

  void bindQueue(AppTransferQueue? Function() lookup) =>
      _queueLookup = lookup;

  void unbindQueue(AppTransferQueue? Function() lookup) {
    if (identical(_queueLookup, lookup)) _queueLookup = null;
  }

  /// The close gate: true lets the close proceed to destroy; false
  /// vetoes it and the window stays up.
  Future<bool> confirmClose() =>
      _inFlight ??= _confirmClose().whenComplete(() => _inFlight = null);

  Future<bool> _confirmClose() async {
    var queue = _queueLookup?.call();
    final active = [
      for (final task in queue?.tasks ?? const <TransferTask>[])
        if (!task.isTerminal) task,
    ];

    if (active.isNotEmpty) {
      final choice = await _askQuitChoice(active);
      // The seam may have been rebound while the dialog was open —
      // re-read so the mutations and the flush below hit the live queue.
      queue = _queueLookup?.call() ?? queue;
      switch (choice) {
        case null:
          // Keep Transferring, or a dismissed dialog: the close is
          // vetoed and nothing else happens.
          return false;
        case QuitConfirmChoice.pauseAndQuit:
          for (final task in active) {
            if (task.state != TransferTaskState.paused) {
              queue?.pauseTask(task.id);
            }
          }
        case QuitConfirmChoice.cancelTransfersAndQuit:
          for (final task in active) {
            queue?.cancelTask(task.id);
          }
      }
      // The seam's verbs are synchronous mutations (void on
      // AppTransferQueue and the core queue): by this line the journaled
      // snapshot already reflects the chosen end state.
    }

    assert(
      _queueLookup != null,
      'QuitGuard queue seam was never bound — the shell owns bindQueue',
    );
    if (queue == null) return true;
    try {
      // .timeout abandons the await, not the write: a retried close can
      // overlap the still-running flush. That is safe by seam contract —
      // FileTransferPersistence serializes every flush on its writer
      // chain, so the second call drains behind the first.
      await queue.flushJournal().timeout(_flushTimeout);
    } on Object catch (error, stack) {
      _report(error, stack);
      await _warnFlushFailed(error);
      return false;
    }
    return true;
  }

  Future<QuitConfirmChoice?> _askQuitChoice(
    List<TransferTask> active,
  ) async {
    final context = _dialogContext;
    if (context == null) {
      // No surface left to warn on — the UI is already gone; proceed to
      // the flush so the journal still lands before destroy.
      return QuitConfirmChoice.pauseAndQuit;
    }
    var remaining = 0;
    for (final task in active) {
      // The floor only counts discovered totals — an unknown-total task
      // contributes nothing, so its progress can never subtract from
      // another task's known remaining.
      final total = task.totalBytes;
      if (total != null) remaining += total - task.transferredBytes;
    }
    if (remaining < 0) remaining = 0;
    return showQuitConfirmDialog(
      context,
      activeTasks: active.length,
      remainingBytes: remaining,
    );
  }

  Future<void> _warnFlushFailed(Object error) async {
    final context = _dialogContext;
    if (context == null) return; // already reported via _onError
    await showQuitFlushFailedDialog(context, error: error.toString());
  }

  BuildContext? get _dialogContext {
    final context = _navigatorKey.currentContext;
    return (context != null && context.mounted) ? context : null;
  }

  void _report(Object error, StackTrace stack) {
    try {
      _onError?.call(error, stack);
    } catch (_) {
      // Error reporting must not create an unhandled callback failure.
    }
  }
}
