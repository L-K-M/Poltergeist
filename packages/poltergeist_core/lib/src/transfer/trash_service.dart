import 'dart:async';
import 'dart:io' show Platform, Process, ProcessException, ProcessResult;

import 'package:seance_core/seance_core.dart';

import 'transfer_task.dart';

/// The D15 trash layer (03 §7.1/§7.3, 07 §3.5) — the service every
/// destructive delete flows through, above the VFS's raw `delete`
/// primitive (`LocalFileSystem.delete` is one-entry, non-recursive, and
/// permanent by design; the trash/confirm decision is this file's).
///
/// Local deletes go to the OS trash with undo where the platform gives
/// it — **Put Back is best-effort OS behavior** (Finder's Put Back,
/// Explorer's Ctrl+Z stack): the app guarantees only delivery to the OS
/// trash, never a restorable anchor. Remote deletes are
/// confirm-then-permanent by default; the per-server opt-in moves the
/// entry to `.poltergeist-trash/<runId>/<seq>-<name>` (00 D15 — the
/// same per-run layout sync uses, so it ages and purges under the
/// identical rule).
///
/// Nothing here silently unlinks: an unsupported platform is an explicit
/// [TrashErrorKind.unsupportedPlatform], an absent/failed backend is
/// [TrashErrorKind.unavailable]/[TrashErrorKind.failed], and the
/// permanent fallback always routes through the confirmed-delete path —
/// never an unconfirmed unlink.

/// The trash layer's explicit failure taxonomy (03 §7.3): callers branch
/// on the kind — `unsupportedPlatform`/`unavailable` mean "offer the
/// confirm-then-permanent fallback" (D15's pre-authorized cut line, 07
/// §6 risk 10); `failed` means the backend tried and lost.
enum TrashErrorKind {
  /// No trash mechanism exists on this platform — never a silent unlink.
  unsupportedPlatform,

  /// The platform's mechanism exists but is not present right now
  /// (no `gio` binary, no wired channel handler).
  unavailable,

  /// The mechanism ran and reported a failure (`gio trash` nonzero exit,
  /// a channel-side `IFileOperation`/`trashItem` error).
  failed,
}

/// A trash-layer failure. [path] is the entry that could not be trashed.
class TrashException implements Exception {
  const TrashException({
    required this.kind,
    required this.message,
    this.path,
    this.cause,
  });

  final TrashErrorKind kind;
  final String message;
  final String? path;
  final Object? cause;

  @override
  String toString() => message;
}

// ── Local trash ─────────────────────────────────────────────────────────

/// The `poltergeist/trash` channel name (03 §7.1). The native side lives
/// in the app target; core only declares the contract.
const String trashChannelName = 'poltergeist/trash';

/// The channel's single method. Arguments: `{'path': <absolute path>}`.
/// Result: `null`, or a map `{'trashedPath': <path>}` on platforms that
/// report one (macOS `FileManager.trashItem` returns the trashed URL —
/// the Put Back anchor).
const String trashChannelMethod = 'trash';

/// Invokes the `poltergeist/trash` channel — the seam the engine host
/// (or a test fake) wires to a `MethodChannel`. A throw is a native-side
/// failure and surfaces as [TrashErrorKind.failed].
typedef TrashChannelInvoker =
    Future<Object?> Function(String method, Map<String, Object?> arguments);

/// One local OS-trash mechanism. Implementations are per-platform; the
/// [LocalTrashService] dispatcher picks one.
abstract interface class LocalTrashBackend {
  /// Whether this backend can serve right now — cheap and cached where
  /// the plan asks for a detected-once probe (Linux's `gio` check).
  /// `false` routes the caller to confirm-then-permanent, never to a
  /// silent delete.
  Future<bool> isAvailable();

  /// Moves one path to the OS trash. Returns the trashed location when
  /// the platform reports one (the macOS Put Back anchor), else null.
  /// Throws [TrashException] on failure — callers never interpret other
  /// error types as "trash failed".
  Future<String?> trash(String path);
}

/// The macOS/Windows backend: the `poltergeist/trash` channel (03 §7.1).
///
/// Native contract per platform:
/// - macOS: `FileManager.trashItem(at:to:)` — returns the trashed URL so
///   the caller can anchor Put Back. Put Back itself is Finder's, not
///   ours.
/// - Windows: `IFileOperation.DeleteItem` with `FOF_ALLOWUNDO |
///   FOFX_ADDUNDORECORD` — `FOF_ALLOWUNDO` routes to the Recycle Bin and
///   `FOFX_ADDUNDORECORD` (via `SetOperationFlags`) lands the op on
///   Explorer's Ctrl+Z stack. COM must run apartment-threaded
///   (`CoInitializeEx(COINIT_APARTMENTTHREADED)`) and Dart FFI calls
///   land on arbitrary VM threads, so the native side marshals the call
///   onto a dedicated STA thread — the thin C++ helper §7.1 allows when
///   pure-Dart STA handling proves unworkable.
///
/// With no [invoker] wired (core alone, or a build where the app has not
/// bound the channel) the backend reports unavailable — the caller's
/// confirm-then-permanent fallback, never a silent unlink.
class ChannelTrashBackend implements LocalTrashBackend {
  ChannelTrashBackend({this.invoker});

  /// The channel invoker the engine host wires — null means the app has
  /// not bound `poltergeist/trash` on this build, so the backend reports
  /// unavailable.
  final TrashChannelInvoker? invoker;

  @override
  Future<bool> isAvailable() => Future.value(invoker != null);

  @override
  Future<String?> trash(String path) async {
    final invoker = this.invoker;
    if (invoker == null) {
      throw TrashException(
        kind: TrashErrorKind.unavailable,
        path: path,
        message: 'the $trashChannelName channel is not wired on this build',
      );
    }
    final Object? reply;
    try {
      reply = await invoker(trashChannelMethod, {'path': path});
    } catch (error) {
      throw TrashException(
        kind: TrashErrorKind.failed,
        path: path,
        message: 'the OS trash refused "$path": $error',
        cause: error,
      );
    }
    if (reply is Map) {
      final trashed = reply['trashedPath'];
      if (trashed is String && trashed.isNotEmpty) return trashed;
    }
    return null;
  }
}

/// A process spawn seam — `Process.run` with an argument list, never a
/// shell (03 §7.3). Injectable so tests script exits without spawning.
typedef TrashProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

/// The Linux backend: `gio trash` (03 §7.3). The capability probe is
/// detected once — `gio --version` — and cached; a `gio` binary that is
/// absent (minimal/GNOME-less distros, some WSL setups) reports
/// [TrashErrorKind.unavailable], and a runtime `gio trash` failure (no
/// writable trash dir, read-only home, a volume with no usable trash)
/// reports [TrashErrorKind.failed]. Both route the user to the
/// confirm-then-permanent fallback at confirmation time; a mid-task
/// failure fails the item honestly — never an unconfirmed unlink.
class GioTrashBackend implements LocalTrashBackend {
  GioTrashBackend({TrashProcessRunner? runner})
    : _runner = runner ?? _defaultRunner;

  final TrashProcessRunner _runner;
  bool? _available;

  static Future<ProcessResult> _defaultRunner(
    String executable,
    List<String> args,
  ) => Process.run(executable, args);

  /// Detected-once capability probe (03 §7.3): the first call runs
  /// `gio --version` through the arg-list spawn and caches the answer —
  /// a missing binary is a [ProcessException] (ENOENT), never a shell's
  /// "command not found".
  @override
  Future<bool> isAvailable() async {
    final probed = _available;
    if (probed != null) return probed;
    try {
      final result = await _runner('gio', const ['--version']);
      return _available = result.exitCode == 0;
    } on ProcessException {
      return _available = false;
    }
  }

  @override
  Future<String?> trash(String path) async {
    if (!await isAvailable()) {
      throw TrashException(
        kind: TrashErrorKind.unavailable,
        path: path,
        message: 'gio is not installed; the OS trash is unavailable',
      );
    }
    final ProcessResult result;
    try {
      // `--` keeps a dash-prefixed filename out of GOption parsing.
      result = await _runner('gio', ['trash', '--', path]);
    } on ProcessException catch (error) {
      throw TrashException(
        kind: TrashErrorKind.unavailable,
        path: path,
        message: 'gio could not run: ${error.message}',
        cause: error,
      );
    }
    if (result.exitCode != 0) {
      final stderr = '${result.stderr}'.trim();
      throw TrashException(
        kind: TrashErrorKind.failed,
        path: path,
        message:
            'gio trash failed for "$path"'
            '${stderr.isEmpty ? '' : ': $stderr'}',
      );
    }
    // gio trash does not report the trash:// URI — the restore story
    // (`gio trash --restore`, or the FreeDesktop .trashinfo fallback)
    // belongs to the restore slice; trash delivery is what D15
    // guarantees.
    return null;
  }
}

/// One trash service, one dispatch (03 §7.3): picks the platform's
/// backend once. Unsupported platforms get an explicit
/// [TrashErrorKind.unsupportedPlatform] — the answer is never a silent
/// unlink.
class LocalTrashService {
  LocalTrashService({
    String? operatingSystem,
    LocalTrashBackend? macOS,
    LocalTrashBackend? windows,
    LocalTrashBackend? linux,
    TrashProcessRunner? processRunner,
  }) : _operatingSystem = operatingSystem ?? Platform.operatingSystem,
       _backend = switch (operatingSystem ?? Platform.operatingSystem) {
         'macos' => macOS ?? ChannelTrashBackend(),
         'windows' => windows ?? ChannelTrashBackend(),
         'linux' => linux ?? GioTrashBackend(runner: processRunner),
         _ => null,
       };

  final String _operatingSystem;

  /// The platform's backend, or null on an unsupported OS.
  final LocalTrashBackend? _backend;

  /// Test seam: swaps in a backend without spoofing the platform.
  LocalTrashService.withBackend(LocalTrashBackend backend)
    : _operatingSystem = 'test',
      _backend = backend;

  /// Whether the OS trash can serve right now — `false` routes callers
  /// to the confirm-then-permanent fallback (D15).
  Future<bool> isAvailable() async {
    final backend = _backend;
    if (backend == null) return false;
    return backend.isAvailable();
  }

  /// Moves [path] to the OS trash. Returns the trashed location when the
  /// platform reports one (the macOS Put Back anchor), else null.
  /// Throws [TrashException] — [TrashErrorKind.unsupportedPlatform] when
  /// no backend exists for [_operatingSystem].
  Future<String?> trash(String path) async {
    final backend = _backend;
    if (backend == null) {
      throw TrashException(
        kind: TrashErrorKind.unsupportedPlatform,
        path: path,
        message:
            'OS trash is not supported on $_operatingSystem; '
            'confirm permanent deletion instead',
      );
    }
    return backend.trash(path);
  }
}

// ── Remote trash ────────────────────────────────────────────────────────

/// The remote `.poltergeist-trash/<runId>/` mover (00 D15, 03 §7.3).
///
/// One directory name everywhere — the same per-run layout sync's trash
/// uses (05 §8 rail 5), so remote-trashed entries age and purge under
/// the identical 30-day rule rather than an unretained flat folder.
/// Entries are flat `<seq>-<basename>` names uniquified by a per-run
/// sequence prefix (`000042-index.html`): same-basename items from
/// different source directories cannot collide, and the rename stays the
/// one cheap same-filesystem path even against SFTP v3's
/// fail-when-target-exists. `rename(overwrite: false)` on an occupied
/// name bumps the sequence rather than ever overwriting trash contents —
/// trashed data is never clobbered by a later gesture.
///
/// `.poltergeist-trash/` and each `<runId>/` are created `0700` — the
/// local `.Trash-$UID` requirement applied server-side: a default `0022`
/// umask would otherwise yield a world-readable `0755` directory,
/// widening exposure of files moved out of a possibly-`0700` source
/// directory on a shared multi-user host. A pre-existing looser-mode
/// directory is chmod'ed `0700`; when the server cannot set modes the
/// trash operation is refused with a per-server error rather than
/// widening the exposure silently.
///
/// Trashed entries remain readable by anything that can read the folder
/// until purged — a move is not safe disposal, and the copy-then-delete
/// fallback for a genuine cross-filesystem/permission rename failure is
/// 05's sync rail (out of this slice); a failed rename surfaces as the
/// item's error, not a hidden copy.
class RemoteTrash {
  RemoteTrash({String Function()? runIdMinter})
    : _runIdMinter = runIdMinter ?? uuidV4;

  /// `.poltergeist-trash` — the one name, excluded by the default
  /// `.poltergeist*` ignore rules.
  static const String rootDirectoryName = '.poltergeist-trash';

  /// The mode both levels are created (and repaired) to (03 §7.3).
  static const int directoryMode = 0x1C0; // 0700

  /// Upper bound for sequence-prefix collision retries — a pathological
  /// foreign-write flood into the run dir fails the item honestly
  /// instead of spinning.
  static const int maxNameAttempts = 99;

  final String Function() _runIdMinter;

  /// The run-id minter. 05 §6's full shape is
  /// `<first 8 hex of sha256(deviceId)>-<uuidV4>` — the device prefix
  /// lets a remote listing tell this machine's run dirs from a sibling
  /// machine's; the engine supplies the prefixed form once D4's
  /// deviceId lands, until then a bare uuid keeps runs collision-free.
  String newRunId() => _runIdMinter();

  /// Ensures `<base>/.poltergeist-trash/<runId>` exists at mode
  /// [directoryMode], repairing a looser pre-existing mode (or refusing
  /// when the server cannot chmod). [base] is the common parent of the
  /// deleted roots — same-directory placement keeps the rename on one
  /// filesystem and writable wherever the delete itself was allowed.
  /// Returns the run directory's path.
  Future<String> ensureRunDirectory(
    RemoteFileSystem fs,
    String base,
    String runId,
  ) async {
    final runDirectory = remoteJoin(remoteJoin(base, rootDirectoryName), runId);
    await ensureExistingRunDirectory(fs, runDirectory);
    return runDirectory;
  }

  /// Ensures a previously-minted run directory (and the
  /// `.poltergeist-trash` level above it) exists at [directoryMode] —
  /// the journaled form a restored delete task re-derives from its
  /// spec's `destinationDir`.
  Future<void> ensureExistingRunDirectory(
    RemoteFileSystem fs,
    String runDirectory,
  ) async {
    await _ensure0700(fs, remoteParent(runDirectory));
    await _ensure0700(fs, runDirectory);
  }

  /// Moves [entry] into [runDirectory] under the next sequence-prefixed
  /// name. [nextSequence] is the per-run monotonic counter shared by the
  /// whole delete task — each attempt (collision retries included)
  /// consumes a fresh value, so names can never collide within a run and
  /// a foreign occupant just costs a bump. Returns the trash path the
  /// entry moved to.
  Future<String> moveToTrash(
    RemoteFileSystem fs,
    RemoteFileEntry entry,
    String runDirectory,
    int Function() nextSequence,
  ) async {
    for (var attempt = 0; attempt < maxNameAttempts; attempt++) {
      final sequence = nextSequence();
      final target = remoteJoin(
        runDirectory,
        '${sequence.toString().padLeft(6, '0')}-${entry.name}',
      );
      try {
        // overwrite: false — a collision is a bump, never a clobber
        // (SFTP v3's fail-when-target-exists is the common path).
        await fs.rename(entry.path, target);
        return target;
      } on RemoteFileException catch (error) {
        if (error.kind != RemoteFileErrorKind.conflict) rethrow;
        // A foreign name in the run dir — take the next sequence.
      }
    }
    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'trash',
      path: entry.path,
      message:
          'no free trash name after $maxNameAttempts attempts for '
          '"${entry.name}" in $runDirectory',
    );
  }

  /// Creates [path] at 0700 or repairs a looser pre-existing mode;
  /// refuses (per-server error) when the directory exists as a
  /// non-directory or the mode cannot be set (03 §7.3's exposure rule —
  /// never let trashed data sit world-readable by default).
  Future<void> _ensure0700(RemoteFileSystem fs, String path) async {
    RemoteFileEntry? existing;
    try {
      existing = await fs.stat(path, followLinks: false);
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.notFound) rethrow;
    }
    if (existing != null) {
      // A symlink or non-directory at the trash path is refused — never
      // followed, never replaced.
      if (!existing.isDirectory) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'trash',
          path: path,
          message:
              '"$path" exists and is not a directory; refusing to use it '
              'as trash',
        );
      }
    } else {
      try {
        await fs.createDirectory(path);
      } on RemoteFileException catch (error) {
        if (error.kind != RemoteFileErrorKind.conflict) rethrow;
        // Lost the create race — the winner's entry must still be a
        // directory and get the same chmod below.
        existing = await fs.stat(path, followLinks: false);
        if (!existing.isDirectory) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.conflict,
            operation: 'trash',
            path: path,
            message:
                '"$path" exists and is not a directory; refusing to use '
                'it as trash',
          );
        }
      }
    }
    // The VFS's createDirectory takes no mode, so even a fresh directory
    // lands at the server umask — chmod to 0700 unless the entry already
    // reports it. `unsupported`/`permissionDenied` propagate as the
    // per-server refusal the section prescribes.
    if (existing != null && existing.mode == directoryMode) return;
    await fs.setMode(path, directoryMode);
  }
}

// ── Delete confirmation (the state-level §10 copy model) ────────────────

/// What a destructive delete's confirmation must disclose (02 §10, §13)
/// — the engine-side model the dialog renders. No UI strings live here;
/// the dialog's ARB copy is the UI slice's (D20).
class DeleteConfirmation {
  const DeleteConfirmation({
    required this.source,
    required this.rootPaths,
    required this.names,
    required this.effectiveDisposition,
    required this.quantified,
    required this.remoteTrashOptIn,
    required this.trashUnavailable,
    this.totalItems,
    this.totalBytes,
    this.flaggedCount = 0,
  });

  /// The endpoint the delete runs on.
  final FsLocation source;

  /// The normalized roots the gesture selected.
  final List<String> rootPaths;

  /// Up to three leading root names — §10's "names are listed for up to
  /// three items; otherwise count and total size" rule.
  final List<String> names;

  /// The disposition the confirmed action runs: `trash` when the OS
  /// trash serves (local) or the server's `.poltergeist-trash/` opt-in
  /// is on, else `permanent` — the dialog wordings ("Move N Items" vs
  /// "Delete permanently") key off this, never off the request.
  final DeleteDisposition effectiveDisposition;

  /// False when the quantifying walk timed out or errored — the dialog
  /// falls back to unquantified copy ("permanently?" without counts).
  final bool quantified;

  /// The per-server remote-trash opt-in — drives the dialog's
  /// `Move to .poltergeist-trash/ instead` checkbox availability
  /// (prechecked when this and [effectiveDisposition] say trash;
  /// unchecking reverts to permanent wording).
  final bool remoteTrashOptIn;

  /// True when trash was requested but cannot serve (no gio, unwired
  /// channel, unsupported OS, opt-in off) — the one-time "trash
  /// unavailable, this will delete permanently" notice (D15's fallback).
  final bool trashUnavailable;

  /// Total enumerated items (files + directories + links + other leaf
  /// types) — null when [quantified] is false.
  final int? totalItems;

  /// Total enumerated bytes — null when [quantified] is false.
  final int? totalBytes;

  /// §13 flagged (undecodable-name) entries seen during the walk. When
  /// [quantified] is false the count is a floor — the dialog says "may
  /// include items with undecodable names"; otherwise it is exact
  /// ("includes N items with an undecodable name"). Ancestor deletes
  /// never silently omit flagged descendants.
  final int flaggedCount;
}

/// The enqueue-time delete request — plain data the caller builds from a
/// confirmed [DeleteConfirmation] (02 §2.6/§10).
class DeleteRequest {
  const DeleteRequest({
    required this.source,
    required this.rootPaths,
    required this.disposition,
    this.confirmed = false,
  });

  final FsLocation source;
  final List<String> rootPaths;

  /// The final disposition — [DeleteDisposition.trash] requires the
  /// destination's trash to actually serve (OS backend present, or the
  /// server's `.poltergeist-trash/` opt-in on); [permanent] requires
  /// [confirmed].
  final DeleteDisposition disposition;

  /// The user's explicit confirmation. Permanent deletes may never run
  /// unconfirmed (D15's "never an unconfirmed permanent delete" rule,
  /// enforced here so menu/shortcut/drag entry points share the guard);
  /// trash deletes confirm through the move-worded dialog.
  final bool confirmed;
}
