import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:poltergeist_core/poltergeist_core.dart';

import 'application_error_reporter.dart';

/// The app-wide managed-checkout seam (06 §3, 03 §6): one
/// [CheckoutManager] over the durable [ManagedRemoteFileStore] inside
/// the app-support directory, driving every byte through the composed
/// [TransferQueue] — the same instance the activity panel mirrors, so
/// a checkout download and an upload-on-save each land as a
/// queue-visible row (progress, pause/cancel, the honest `unsupported`
/// failure while the engine protocol still lacks transfer verbs —
/// docs/STATUS.md item 23).
///
/// This session is the future editor UI's only handle to the pipeline
/// (no editor UI exists yet — this is the service wiring it will
/// consume). `copiesFor`/`checkoutFor`/`displacedFor`/
/// `recoveredCheckouts` answer its record reads and [notifyListeners]
/// rebuilds them; the verbs — [checkout], [uploadLocalCopy],
/// [discard], [acceptLocalCopy], [forgetRecovered], [migrateRename] —
/// are the whole §3 surface. No pane or tab identity ever reaches it:
/// `editSessionId` is the per-server constant (D17), so checkouts
/// survive pane/tab churn by construction.
final class CheckoutSession extends ChangeNotifier {
  CheckoutSession._(this._store, this._manager) {
    _subscription = _manager.changes.listen((_) => notifyListeners());
  }

  final ManagedRemoteFileStore _store;
  final CheckoutManager _manager;
  late final StreamSubscription<void> _subscription;
  Future<void>? _shutdown;
  Future<void>? _reconcileInFlight;

  /// Every tracked record across servers — the §3.3 dirty-prompt scan's
  /// input (the toast is app-wide, not pane-scoped).
  List<ManagedRemoteFile> get records => _manager.records;

  /// Live checkouts of one server keyed by remote path — the editor's
  /// "is this already open as a managed copy" lookup.
  Map<String, ManagedRemoteFile> copiesFor(String serverId) =>
      _manager.copiesFor(serverId);

  /// The live record for one remote path, or null.
  ManagedRemoteFile? checkoutFor(String serverId, String remotePath) =>
      _manager.checkoutFor(serverId, remotePath);

  /// Re-keyed records whose remotePath a rename arrival claimed — the
  /// §3.7 review surface lists these as recovered edits.
  List<ManagedRemoteFile> displacedFor(String serverId) =>
      _manager.displacedFor(serverId);

  /// Preserved recordless checkout payloads — reviewable, never
  /// uploadable (06 §3.7).
  Future<List<RecoveredCheckout>> recoveredCheckouts() =>
      _manager.recoveredCheckouts();

  /// The local file a record's bytes live in — the editor's open
  /// target, validated by the store and never caller-constructed.
  File localFile(ManagedRemoteFile record) => _manager.localFile(record);

  /// Downloads [entry] into the managed store, or returns the
  /// existing/in-flight record for the same (serverId, remotePath) —
  /// the §3.1 focus-the-existing-tab rule enforced at the service
  /// layer. Fails honestly (`unsupported`) while remote endpoints are
  /// unavailable in this isolate.
  Future<ManagedRemoteFile> checkout({
    required String serverId,
    required RemoteFileEntry entry,
    int? maximumBytes,
  }) => _manager.checkout(
    serverId: serverId,
    entry: entry,
    maximumBytes: maximumBytes,
  );

  /// The explicit save (06 §3.4): frozen `.upload` snapshot → remote
  /// preflight → queue-visible CAS-guarded upload. Throws
  /// [RemoteFileException] `conflict` when the remote moved under the
  /// checkout — the caller's conflict flow decides between
  /// `overwriteRemoteChanges: true` and discard.
  Future<bool> uploadLocalCopy(
    ManagedRemoteFile copy, {
    bool overwriteRemoteChanges = false,
  }) => _manager.uploadLocalCopy(
    copy,
    overwriteRemoteChanges: overwriteRemoteChanges,
  );

  /// The editor's `onSaved` hook (06 §2.4): a per-copy local re-hash —
  /// dirty/missing flags and the §2.1 save-temp sweep — plus the §3.4
  /// stat-only repair when the record needs it. Never touches content
  /// and never throws: `onSaved` runs inside the save's `finally`, where
  /// an escaping error would replace the original upload error, so
  /// failures report through the manager's `onError` instead.
  Future<void> reconcile(ManagedRemoteFile copy) => _manager.reconcile(copy);

  /// Discard: plaintext first, then the record (06 §3.6).
  Future<void> discard(ManagedRemoteFile copy) => _manager.discard(copy);

  /// Accept the local copy's current contents as the baseline.
  Future<void> acceptLocalCopy(ManagedRemoteFile copy) =>
      _manager.acceptLocalCopy(copy);

  /// Explicitly delete a preserved recordless directory — the only
  /// verb recovered plaintext ever gets.
  Future<void> forgetRecovered(RecoveredCheckout recovered) =>
      _manager.forgetRecovered(recovered);

  /// 06 §3.7's per-row `Discard…` for a recovered payload: one file
  /// inside the recovered directory — siblings an external editor left
  /// beside the plaintext are preserved until their own row is
  /// discarded.
  Future<void> forgetRecoveredFile(RecoveredCheckout recovered, String name) =>
      _manager.forgetRecoveredFile(recovered, name);

  /// The local file a recovered payload's bytes live in — the review
  /// dialog's `Open` target. Recovered files are never uploadable
  /// through the checkout lane (the record that would carry the
  /// upload's `expectedTarget` is gone).
  File recoveredFile(RecoveredCheckout recovered, String name) =>
      _manager.recoveredFile(recovered, name);

  /// Re-keys managed records — and in-flight checkouts — when a remote
  /// path is renamed (06 §3.5). The pane's rename command calls this;
  /// the local checkout file never moves.
  Future<void> migrateRename({
    required String serverId,
    required String oldPath,
    required String newPath,
  }) => _manager.migrateRename(
    serverId: serverId,
    oldPath: oldPath,
    newPath: newPath,
  );

  /// Foreground/resume entry point (06 §3.3): rehashes every record
  /// and repairs degraded snapshots against the remote. The app's
  /// lifecycle listener calls this on `resumed`. Serialized: a resume
  /// while a previous reconcile still runs joins it instead of racing
  /// a second rehash/repair pass.
  Future<void> reconcileOnResume() => _reconcileInFlight ??= _manager
      .reconcileOnResume()
      .whenComplete(() => _reconcileInFlight = null);

  /// Async teardown — production never calls it (the store lock is
  /// process-scoped and app exit owns it); tests shut down to release
  /// the lock and watchers. Idempotent: repeat calls — including one
  /// racing a [dispose]-triggered teardown — await the same future.
  Future<void> shutdown() => _shutdown ??= _doShutdown();

  Future<void> _doShutdown() async {
    await _subscription.cancel();
    await _manager.dispose();
    await _store.close();
  }

  @override
  void dispose() {
    // ChangeNotifier's sync contract cannot await the store's release —
    // drop the listener and let the OS lock fall with the process. Tests
    // that need the release await [shutdown] instead.
    unawaited(
      shutdown().catchError((Object error, StackTrace stackTrace) {
        ApplicationErrorReporter().report(error, stackTrace);
      }),
    );
    super.dispose();
  }
}

/// Builds the production checkout session over the app-support
/// directory (main.dart's wiring; tests point it at a temp directory).
/// The store layout is pinned by 06 §3.1: `managed_remote_files.json`
/// plus `checkouts/<sha256(record id)>/`.
///
/// [queue] is the app's one composed [TransferQueue] and [connections]
/// the seam it was built over — the session must share both so
/// checkout bytes ride the same journal and fail the same way.
/// Returns null — after reporting — when the store cannot open or the
/// startup reconcile throws: the app still boots checkout-less,
/// matching the queue session's posture.
Future<CheckoutSession?> startCheckoutSession({
  required String supportDirectoryPath,
  required TransferQueue queue,
  required ConnectionManager connections,
  void Function(Object error, StackTrace stackTrace)? onError,
}) async {
  final errors = onError == null
      ? ApplicationErrorReporter()
      : ApplicationErrorReporter(sink: onError);
  final store = ManagedRemoteFileStore(
    indexFile: File(
      '$supportDirectoryPath${Platform.pathSeparator}'
      'managed_remote_files.json',
    ),
    checkoutRoot: Directory(
      '$supportDirectoryPath${Platform.pathSeparator}checkouts',
    ),
  );
  CheckoutManager? manager;
  try {
    manager = CheckoutManager(
      store: store,
      connections: connections,
      queue: queue,
      freeSpaceBytes: _freeSpaceBytes,
      onError: errors.report,
    );
    await manager.start();
    return CheckoutSession._(store, manager);
  } on Object catch (error, stackTrace) {
    errors.report(error, stackTrace);
    // The manager never handed out — its watchers and store must not
    // leak open.
    try {
      await manager?.dispose();
    } on Object catch (disposeError, disposeStack) {
      errors.report(disposeError, disposeStack);
    }
    try {
      await store.close();
    } on Object catch (closeError, closeStack) {
      errors.report(closeError, closeStack);
    }
    return null;
  }
}

/// The §3.2 free-space preflight over the app-support volume — `df -k`'s
/// available column on POSIX, null (degrade to the write failure) on
/// platforms without it or when the probe itself fails.
Future<int?> _freeSpaceBytes(String path) async {
  if (Platform.isWindows) return null;
  try {
    final result = await Process.run('df', ['-k', path]);
    if (result.exitCode != 0) return null;
    // A wrapped df line still ends with one row whose fields split as
    // <fs> <blocks> <used> <avail> … — the last line's fourth field.
    final lines = (result.stdout as String)
        .trim()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    final fields = lines.last.trim().split(RegExp(r'\s+'));
    if (fields.length < 4) return null;
    final kibibytes = int.tryParse(fields[3]);
    return kibibytes == null ? null : kibibytes * 1024;
  } on Object {
    return null;
  }
}
