import 'package:seance_core/seance_core.dart';

/// The direction a managed-checkout task moves bytes (06 §3.2/§3.4):
/// [download] materializes a checkout into the store; [upload] writes the
/// frozen save snapshot back to the remote path under CAS.
enum ManagedCheckoutDirection { download, upload }

/// The caller-supplied half of a managed-checkout task (06 §3.4, 03 §4.7's
/// produce-task consumer): the queue executes exactly one file hop whose
/// parameters a generic `TransferTaskSpec` cannot express —
///
/// - a download whose destination is the store's exclusive-created
///   checkout file rather than a user-picked directory;
/// - an upload whose destination is the record's original `remotePath`,
///   `preserveMode` is the recorded remote mode, and `expectedTarget` is
///   the record's snapshot — carrying `contentSha256`, which makes the
///   destination adapter's mandatory hash re-read the conflict
///   authority (D7).
///
/// The spec is journaled with the task (03 §4.6): a crash mid-save
/// replays the upload under the same CAS, and a swept `.upload` snapshot
/// simply fails the replayed item honestly.
final class ManagedCheckoutSpec {
  const ManagedCheckoutSpec({
    required this.checkoutId,
    required this.serverId,
    required this.remotePath,
    required this.localPath,
    required this.direction,
    this.displayLocalPath,
    this.expectedSize,
    this.expectedTarget,
    this.preserveMode,
  });

  /// The `ManagedRemoteFile` id — correlates queue rows with checkout
  /// records for the manager's completion handling.
  final String checkoutId;

  /// The remote endpoint the bytes cross.
  final String serverId;

  /// The checkout's current remote target (migrated by `migrateRename`
  /// while a download was in flight).
  final String remotePath;

  /// The local path the transfer actually reads or writes — the
  /// exclusive-created checkout file for a download, the frozen
  /// `.poltergeist-<uuid>.upload` snapshot for an upload.
  final String localPath;

  /// What the activity row shows for the local side when it differs from
  /// [localPath] — an upload row names the checkout, not its frozen
  /// snapshot temp.
  final String? displayLocalPath;

  final ManagedCheckoutDirection direction;

  /// Declared byte count: the remote entry's size for a download, the
  /// snapshot length for an upload. Drives the row's totals and the
  /// destination's length check.
  final int? expectedSize;

  /// Upload only: the recorded remote snapshot the destination must still
  /// match at commit — `null` only on the explicit overwrite-remote
  /// resolution (06 §3.4 step 4).
  final RemoteFileEntry? expectedTarget;

  /// Upload only: the recorded remote mode re-applied by the destination
  /// adapter — the local checkout file's own mode is never authoritative.
  final int? preserveMode;
}
