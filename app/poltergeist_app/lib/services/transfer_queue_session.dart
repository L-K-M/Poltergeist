import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart' show basicLocaleListResolution;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import 'app_transfer_queue.dart';
import 'application_error_reporter.dart';

/// The refusal every remote answer on the app-side queue shares —
/// [_LocalOnlyConnectionManager] fails leases and channel opens with
/// it instead of simulating a pool that cannot exist here. Its message
/// is ARB copy (the failed task row renders it verbatim), resolved at
/// startup with the same locale list resolution the MaterialApp uses.
RemoteFileException _remoteEndpointsUnavailable() => RemoteFileException(
  kind: RemoteFileErrorKind.unsupported,
  operation: 'transfer channel',
  message:
      lookupAppLocalizations(
        basicLocaleListResolution(
          PlatformDispatcher.instance.locales,
          AppLocalizations.supportedLocales,
        ),
      ).activityTaskRemoteUnavailable,
);

/// The app-side queue's connection seam — honest absence, not a stub
/// pool. The engine isolate owns every socket (D8) and the §5 protocol
/// carries no transfer verbs yet (docs/STATUS.md open item 23), so no
/// channel can ever be leased in this isolate. Local↔local tasks never
/// touch [TransferQueue.connections]; a task naming a `ServerFsLocation`
/// fails at its first lease with the typed `unsupported` error — a
/// visible failed row in the panel, never a silent stall or a wedged
/// scan — until the engine-hosted queue lands and this composition
/// moves behind it.
///
/// The queue only ever calls [leaseTransferChannel]; the remaining
/// members answer "no servers exist" — unreachable today, honest if a
/// future caller ever asks.
final class _LocalOnlyConnectionManager implements ConnectionManager {
  const _LocalOnlyConnectionManager();

  @override
  Future<TransferChannelLease> leaseTransferChannel(String serverId) =>
      Future.error(_remoteEndpointsUnavailable());

  @override
  Future<PaneChannel> openBrowseChannel(
    String serverId, {
    required String paneTabId,
  }) =>
      Future.error(_remoteEndpointsUnavailable());

  // Stream.multi, the same mechanism PooledConnectionManager uses:
  // every listener gets the disconnected status and a close — a
  // Stream.value/async* stream would throw on a second listen.
  @override
  Stream<ServerStatus> watchServer(String serverId) => Stream.multi(
    (listener) => listener.add(
      const ServerStatus(ServerConnectionState.disconnected),
    ),
  );

  @override
  Stream<ConnectLogLine> get connectLog => Stream<ConnectLogLine>.empty();

  @override
  Future<Set<String>> connectedServerIds() async => const {};

  @override
  Future<void> disconnectServer(String serverId) async {}

  @override
  Future<void> removeBookmark(String serverId) async {}
}

/// The app's long-lived transfer-queue owner (03 §4, D16): one real
/// [TransferQueue] over the app-support journal
/// ([FileTransferPersistence], 03 §4.6), restored at startup, then
/// shared by every consumer through the [AppTransferQueue] seam — the
/// workspace shell's pane-drop delegate (02 §5.1), the activity panel,
/// and the quit guard's close-time flush (07 §3.5).
///
/// ```
/// FileTransferPersistence.open ──► TransferQueue.restore ──► adapter
///                                        │
///      ┌───────────────┬─────────────────┼──────────────────┐
///      ▼               ▼                 ▼                  ▼
///  pane drops    activity panel    quit guard flush    history tab
/// ```
final class TransferQueueSession {
  TransferQueueSession._(this._queue);

  final TransferQueue _queue;

  /// The app-facing seam handed to `PoltergeistApp.transferQueue` —
  /// widgets and producers name [AppTransferQueue], never the concrete
  /// queue (D16).
  late final AppTransferQueue queue = TransferQueueAdapter(_queue);

  /// Cancels the queue's live tasks and shuts the journal down behind
  /// its writer chain. Production never calls this — the quit guard's
  /// [AppTransferQueue.flushJournal] is the exit durability point and
  /// the process ends with the store still open; tests dispose to free
  /// their temp journal.
  Future<void> dispose() => _queue.dispose();
}

/// Builds the production transfer queue over the app-support directory
/// (main.dart's wiring; tests point it at a temp directory). Returns
/// null — after reporting — when the store cannot open or the journal
/// cannot restore: the app still boots queue-less, matching the engine
/// session's posture rather than dying before its first frame.
Future<TransferQueueSession?> startTransferQueue({
  required String supportDirectoryPath,
  void Function(Object error, StackTrace stackTrace)? onError,
}) async {
  final errors = onError == null
      ? ApplicationErrorReporter()
      : ApplicationErrorReporter(sink: onError);
  final FileTransferPersistence persistence;
  try {
    persistence = await FileTransferPersistence.open(
      Directory(supportDirectoryPath),
      // A torn or corrupt record is a local diagnostic (D19), never
      // telemetry — the same sink every other startup fault lands in.
      onNotice: (message) =>
          errors.report(StateError(message), StackTrace.current),
    );
  } on Object catch (error, stackTrace) {
    errors.report(error, stackTrace);
    return null;
  }
  try {
    final queue = TransferQueue(
      connections: const _LocalOnlyConnectionManager(),
      persistence: persistence,
    );
    // 03 §4.6's boot restore: journaled-paused tasks stay paused,
    // running/scanning/queued survivors replay as queued, and the
    // forced queue-level pause parks all of them behind the activity
    // panel's restored banner.
    await queue.restore();
    return TransferQueueSession._(queue);
  } on Object catch (error, stackTrace) {
    errors.report(error, stackTrace);
    // The queue was never handed out — its store must not leak open.
    try {
      await persistence.shutdown();
    } on Object catch (shutdownError, shutdownStack) {
      errors.report(shutdownError, shutdownStack);
    }
    return null;
  }
}
