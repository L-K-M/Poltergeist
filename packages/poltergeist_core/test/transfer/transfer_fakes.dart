import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

/// Deterministic pump for the real-async transfer tests: every fake
/// resolves through microtasks and `Duration.zero` boundaries, never real
/// timers, so pumping the event queue drives the queue engine.
Future<void> pump([int times = 8]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Pumps until [condition] holds; fails the test (rather than hanging) when
/// it never does.
///
/// The pump budget counts event-loop turns, not wall-clock — but tests
/// whose destination is the real [LocalFileSystem] spend turns waiting on
/// the dart:io threadpool, and a turn loop outruns real disk I/O (Windows
/// CI: create/write/rename ops are an order of magnitude slower than the
/// fake VFS and the loop finishes its budget before the first write
/// lands). A small real delay per unmet iteration gives the threadpool
/// wall-clock to deliver.
Future<void> pumpUntil(
  bool Function() condition, {
  String reason = '',
  int maxPumps = 400,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (condition()) return;
    await pump();
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('pumpUntil timed out${reason.isEmpty ? '' : ': $reason'}');
}

/// Waits for a task to reach a terminal state — reads the mutable task
/// fields directly (they are the queue's public surface).
Future<void> awaitTaskDone(TransferTask task) =>
    pumpUntil(() => task.isTerminal, reason: 'task ${task.id} never settled');

/// An in-memory [RemoteFileSystem] over a posix-style tree — the remote
/// side of every transfer test (the local side uses a real temp dir and
/// the production [LocalFileSystem], which is honest and deterministic).
///
/// Faithful to the pinned VFS contract where it matters:
/// - `upload` commits only after the whole stream is consumed — a
///   cancelled or failed consume leaves no partial destination (the real
///   adapter's temp-then-rename shape).
/// - `download` streams through `destination.addStream` and checks the
///   cancellation token between chunks, matching the adapter's
///   "checked between entries" reality.
/// - `upload` honours `overwrite` and `expectedTarget` (size+mtime) so
///   commit-level conflict races are observable.
class FakeTreeFileSystem implements RemoteFileSystem {
  /// dirPath → child entries.
  final Map<String, List<RemoteFileEntry>> directories = {};

  final Map<String, List<int>> fileBytes = {};

  /// Destinations written by `setTimes` — assertions read them back.
  final Map<String, DateTime> mtimes = {};

  /// Destinations written by `upload(preserveMode:)`.
  final Map<String, int> modes = {};

  final List<String> calls = [];
  int statCalls = 0;
  int listCalls = 0;
  int downloadCalls = 0;
  int uploadCalls = 0;
  int mkdirCalls = 0;
  int deleteCalls = 0;
  int setTimesCalls = 0;
  int setModeCalls = 0;
  int renameCalls = 0;

  /// The entry type of every rename source — the queue's contract is
  /// file-only renames, so tests can assert this never saw a directory
  /// instead of relying on the [UnimplementedError] being loud enough.
  final List<RemoteFileType> renameSourceTypes = [];

  /// Currently inside a `download` — the global-cap assertion reads the
  /// peak.
  int activeDownloads = 0;
  int maxActiveDownloads = 0;
  int activeUploads = 0;
  int maxActiveUploads = 0;

  /// Chunking of `download` output; small values exercise the bounded
  /// sink's backpressure.
  int downloadChunkSize = 16 * 1024;

  /// When false, `download` reports no progress — models a source VFS
  /// that stays silent so the pipe's progress must come from the
  /// destination side (03 §4.5's counted-once rule).
  bool downloadReportsProgress = true;

  /// Optional shared byte probe: `download` credits each emitted chunk,
  /// `upload` debits each received chunk — [PipeProbe.peak] is the
  /// largest byte count ever in flight through the pipe.
  PipeProbe? pipeProbe;

  // Scripting — each hook returns the error to throw, or null to proceed.
  Object? Function(String path)? statFailure;
  Object? Function(String path)? listFailure;
  Object? Function(String path)? downloadFailure;
  Object? Function(String path)? uploadFailure;
  Object? Function(RemoteFileEntry entry)? deleteFailure;
  Object? Function(String oldPath, String newPath)? renameFailure;

  /// `setMode` refusals — e.g. a server that cannot chmod, which the
  /// remote-trash 0700 rule must refuse rather than absorb.
  Object? Function(String path)? setModeFailure;

  /// Gates — return a completer to stall the operation until it completes.
  Completer<void>? Function(String path)? statGate;
  Completer<void>? Function(String path)? listGate;
  Completer<void>? Function(String path)? downloadGate;
  Completer<void>? Function(String path)? uploadGate;

  /// Runs before each downloaded chunk — mid-transfer mutation hooks.
  void Function(String path)? beforeDownloadChunk;

  /// When true, [entryAt] matches case-insensitively — models a
  /// case-insensitive remote destination (e.g. a Windows server) so the
  /// queue's folded-name collision rules are observable.
  bool caseInsensitive = false;

  bool _matches(String a, String b) =>
      caseInsensitive ? a.toLowerCase() == b.toLowerCase() : a == b;

  /// The real map key for a directory path — folds when [caseInsensitive]
  /// models a case-insensitive remote (e.g. a Windows server).
  String? _dirKey(String path) {
    if (directories.containsKey(path)) return path;
    if (!caseInsensitive) return null;
    for (final key in directories.keys) {
      if (_matches(key, path)) return key;
    }
    return null;
  }

  FakeTreeFileSystem() {
    directories['/'] = [];
  }

  // ---------------------------------------------------------------------
  // Tree construction helpers (test-side)
  // ---------------------------------------------------------------------

  void addDirectory(String path, {DateTime? modifiedAt}) {
    final normalized = path == '/' ? path : path.replaceAll(RegExp(r'/+$'), '');
    directories.putIfAbsent(normalized, () => <RemoteFileEntry>[]);
    if (normalized == '/') return;
    final parent = remoteParent(normalized);
    addDirectory(parent);
    directories[parent]!
      ..removeWhere((e) => e.path == normalized)
      ..add(
        RemoteFileEntry(
          path: normalized,
          name: remoteBasename(normalized),
          type: RemoteFileType.directory,
          modifiedAt: modifiedAt,
        ),
      );
  }

  void addFile(
    String path,
    List<int> bytes, {
    DateTime? modifiedAt,
    int? mode,
  }) {
    addDirectory(remoteParent(path));
    fileBytes[path] = bytes;
    directories[remoteParent(path)]!
      ..removeWhere((e) => e.path == path)
      ..add(
        RemoteFileEntry(
          path: path,
          name: remoteBasename(path),
          type: RemoteFileType.file,
          size: bytes.length,
          modifiedAt: modifiedAt,
          mode: mode,
        ),
      );
  }

  void addSymlink(String path) {
    addDirectory(remoteParent(path));
    directories[remoteParent(path)]!
      ..removeWhere((e) => e.path == path)
      ..add(
        RemoteFileEntry(
          path: path,
          name: remoteBasename(path),
          type: RemoteFileType.symbolicLink,
        ),
      );
  }

  RemoteFileEntry? entryAt(String path) {
    if (path == '/') {
      return const RemoteFileEntry(
        path: '/',
        name: '',
        type: RemoteFileType.directory,
      );
    }
    if (directories.keys.any((k) => _matches(k, path))) {
      final parent = remoteParent(path);
      for (final child
          in directories[_dirKey(parent) ?? parent] ??
              const <RemoteFileEntry>[]) {
        if (_matches(child.path, path)) return child;
      }
      // An ancestor-created directory nobody listed into a parent (e.g. a
      // destination root created before its parent existed) still stats.
      return RemoteFileEntry(
        path: path,
        name: remoteBasename(path),
        type: RemoteFileType.directory,
      );
    }
    final parent = remoteParent(path);
    for (final child
        in directories[_dirKey(parent) ?? parent] ??
            const <RemoteFileEntry>[]) {
      if (_matches(child.path, path)) return child;
    }
    return null;
  }

  RemoteFileException _notFound(String operation, String path) =>
      RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: operation,
        path: path,
        message: 'no such path: $path',
      );

  RemoteFileException _conflict(String operation, String path) =>
      RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: operation,
        path: path,
        message: 'already exists: $path',
      );

  // ---------------------------------------------------------------------
  // RemoteFileSystem
  // ---------------------------------------------------------------------

  @override
  Future<String> canonicalize(String path) async =>
      // A case-insensitive volume resolves both spellings to one entry —
      // the fake folds like the queue's `_isSelfTarget` probe expects.
      caseInsensitive ? path.toLowerCase() : path;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    statCalls++;
    calls.add('stat:$path');
    await statGate?.call(path)?.future;
    final failure = statFailure?.call(path);
    if (failure != null) throw failure;
    final entry = entryAt(path);
    if (entry == null) throw _notFound('stat', path);
    return entry;
  }

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    listCalls++;
    calls.add('list:$path');
    await listGate?.call(path)?.future;
    final failure = listFailure?.call(path);
    if (failure != null) throw failure;
    final dirKey = _dirKey(path);
    if (dirKey == null) throw _notFound('list', path);
    return List.of(directories[dirKey]!);
  }

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    downloadCalls++;
    calls.add('download:$path');
    activeDownloads++;
    maxActiveDownloads = maxActiveDownloads < activeDownloads
        ? activeDownloads
        : maxActiveDownloads;
    try {
      final failure = downloadFailure?.call(path);
      if (failure != null) throw failure;
      final bytes = fileBytes[path];
      if (bytes == null) throw _notFound('download', path);
      var sent = 0;
      Stream<List<int>> chunks() async* {
        for (
          var offset = 0;
          offset < bytes.length;
          offset += downloadChunkSize
        ) {
          if (cancellation?.isCancelled ?? false) {
            throw RemoteFileException(
              kind: RemoteFileErrorKind.cancelled,
              operation: 'download',
              path: path,
              message: 'Transfer cancelled.',
            );
          }
          await downloadGate?.call(path)?.future;
          beforeDownloadChunk?.call(path);
          final end = offset + downloadChunkSize;
          final chunk = bytes.sublist(
            offset,
            end > bytes.length ? bytes.length : end,
          );
          sent += chunk.length;
          pipeProbe?.sent(chunk.length);
          yield chunk;
          if (downloadReportsProgress) onProgress?.call(sent, bytes.length);
        }
      }

      try {
        await destination.addStream(chunks());
      } catch (_) {
        if (cancellation?.isCancelled ?? false) {
          throw RemoteFileException(
            kind: RemoteFileErrorKind.cancelled,
            operation: 'download',
            path: path,
            message: 'Transfer cancelled.',
          );
        }
        rethrow;
      }
      if (cancellation?.isCancelled ?? false) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.cancelled,
          operation: 'download',
          path: path,
          message: 'Transfer cancelled.',
        );
      }
      // A mid-transfer deletion hook may have removed the source —
      // surface the typed error a real adapter produces, not a null-check.
      return entryAt(path) ?? (throw _notFound('download', path));
    } finally {
      activeDownloads--;
    }
  }

  /// Commits [path] only after the stream is fully consumed — the
  /// temp-then-rename contract: cancellation or a poisoned stream leaves
  /// no partial file behind.
  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    uploadCalls++;
    calls.add('upload:$path');
    activeUploads++;
    maxActiveUploads = maxActiveUploads < activeUploads
        ? activeUploads
        : maxActiveUploads;
    try {
      final failure = uploadFailure?.call(path);
      if (failure != null) throw failure;
      final existing = entryAt(path);
      if (existing != null && !overwrite) throw _conflict('upload', path);
      if (overwrite && expectedTarget != null && existing != null) {
        final sameSize = expectedTarget.size == existing.size;
        final sameMtime = expectedTarget.modifiedAt == existing.modifiedAt;
        if (!sameSize || !sameMtime) throw _conflict('upload', path);
      }
      await uploadGate?.call(path)?.future;
      final collected = BytesBuilder(copy: false);
      var received = 0;
      try {
        await for (final chunk in content) {
          if (cancellation?.isCancelled ?? false) {
            throw RemoteFileException(
              kind: RemoteFileErrorKind.cancelled,
              operation: 'upload',
              path: path,
              message: 'Transfer cancelled.',
            );
          }
          collected.add(chunk);
          received += chunk.length;
          pipeProbe?.received(chunk.length);
          onProgress?.call(received, length);
        }
      } finally {
        // Nothing lands: the partial file lives on the (implicit) temp
        // side and is discarded, exactly like the real adapter.
      }
      if (length != null && received != length) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.other,
          operation: 'upload',
          path: path,
          message: 'length mismatch: sent $received of $length',
        );
      }
      // Commit-time re-verification: the target may have changed while
      // the stream was gated or being consumed — the open-time checks
      // above are advisory, the real adapter re-checks at commit.
      final atCommit = entryAt(path);
      if (atCommit != null && !overwrite) throw _conflict('upload', path);
      if (overwrite &&
          expectedTarget != null &&
          atCommit != null &&
          (expectedTarget.size != atCommit.size ||
              expectedTarget.modifiedAt != atCommit.modifiedAt)) {
        throw _conflict('upload', path);
      }
      addFile(path, collected.toBytes());
      if (preserveMode != null) modes[path] = preserveMode;
      return entryAt(path)!;
    } finally {
      activeUploads--;
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    mkdirCalls++;
    calls.add('mkdir:$path');
    if (entryAt(path) != null) throw _conflict('mkdir', path);
    final parent = remoteParent(path);
    final parentKey = _dirKey(parent);
    if (parentKey == null) {
      throw _notFound('mkdir', parent);
    }
    directories.putIfAbsent(path, () => <RemoteFileEntry>[]);
    directories[parentKey]!
      ..removeWhere((e) => _matches(e.path, path))
      ..add(
        RemoteFileEntry(
          path: path,
          name: remoteBasename(path),
          type: RemoteFileType.directory,
        ),
      );
  }

  /// rename(2) over the in-memory tree — the same-device move the D26
  /// path drives, and the directory move the D15 remote-trash path
  /// drives (the queue's transfer side still never renames a directory;
  /// tests assert that via [renameSourceTypes]). [renameFailure]
  /// scripts the refusals — an EXDEV stands in for a cross-device mount.
  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) async {
    renameCalls++;
    calls.add('rename:$oldPath->$newPath');
    final failure = renameFailure?.call(oldPath, newPath);
    if (failure != null) throw failure;
    final source = entryAt(oldPath);
    if (source == null) throw _notFound('rename', oldPath);
    renameSourceTypes.add(source.type);
    if (source.isDirectory) {
      _renameDirectory(oldPath, newPath, overwrite: overwrite);
      return;
    }
    // rename(2) succeeds as a no-op when old and new name the same
    // entry (identical paths, or case variants on a case-insensitive
    // volume — where it also refreshes the stored spelling). Treating
    // the source as its own occupant would raise a bogus conflict or,
    // under overwrite, delete the file's bytes before re-adding them.
    final occupant = _matches(oldPath, newPath) ? null : entryAt(newPath);
    // Real rename(file → dir) fails with EISDIR regardless of
    // overwrite — an occupant directory must never be clobbered.
    if (occupant != null && occupant.isDirectory) {
      throw _conflict('rename', newPath);
    }
    if (occupant != null && !overwrite) throw _conflict('rename', newPath);
    final destinationParentKey = _dirKey(remoteParent(newPath));
    if (destinationParentKey == null) {
      throw _notFound('rename', remoteParent(newPath));
    }
    final sourceParentKey = _dirKey(remoteParent(oldPath));
    if (sourceParentKey != null) {
      directories[sourceParentKey]!.removeWhere(
        (e) => _matches(e.path, source.path),
      );
    }
    if (occupant != null) {
      directories[destinationParentKey]!.removeWhere(
        (e) => _matches(e.path, occupant.path),
      );
      fileBytes.remove(occupant.path);
      // The overwritten entry's metadata must not bleed onto the moved
      // file if the source carried none of its own.
      mtimes.remove(occupant.path);
      modes.remove(occupant.path);
    }
    directories[destinationParentKey]!.add(
      RemoteFileEntry(
        path: newPath,
        name: remoteBasename(newPath),
        type: source.type,
        size: source.size,
        modifiedAt: source.modifiedAt,
        mode: source.mode,
      ),
    );
    final bytes = fileBytes.remove(source.path);
    if (bytes != null) fileBytes[newPath] = bytes;
    final mtime = mtimes.remove(source.path);
    if (mtime != null) mtimes[newPath] = mtime;
    final mode = modes.remove(source.path);
    if (mode != null) modes[newPath] = mode;
  }

  /// Directory rename — moves the whole subtree: every directory table
  /// entry, listing path, and byte/mode/mtime key under [oldPath]
  /// re-roots at [newPath], the way a server-side SFTP rename moves a
  /// directory intact (the D15 remote-trash path relies on it).
  void _renameDirectory(
    String oldPath,
    String newPath, {
    required bool overwrite,
  }) {
    final sourceKey = _dirKey(oldPath);
    if (sourceKey == null) throw _notFound('rename', oldPath);
    if (newPath.startsWith('$oldPath/')) {
      // POSIX rename() fails up front (EINVAL) when the destination sits
      // inside the source subtree; without this the rebase rewrites the
      // key destinationParentKey resolved to and crashes mid-move.
      throw _conflict('rename', newPath);
    }
    final occupant = _matches(oldPath, newPath) ? null : entryAt(newPath);
    if (occupant != null) {
      if (!overwrite) throw _conflict('rename', newPath);
      // POSIX rename(dir → dir) replaces only an empty occupant;
      // anything else is ENOTEMPTY/EEXIST — never a silent clobber.
      if (!occupant.isDirectory) throw _conflict('rename', newPath);
      final occupantKey = _dirKey(occupant.path);
      if ((occupantKey != null ? directories[occupantKey]! : const [])
          .isNotEmpty) {
        throw _conflict('rename', newPath);
      }
      directories.remove(occupantKey ?? occupant.path);
      final occupantParentKey = _dirKey(remoteParent(occupant.path));
      if (occupantParentKey != null) {
        directories[occupantParentKey]!.removeWhere(
          (e) => _matches(e.path, occupant.path),
        );
      }
    }
    final destinationParentKey = _dirKey(remoteParent(newPath));
    if (destinationParentKey == null) {
      throw _notFound('rename', remoteParent(newPath));
    }
    String rebase(String path) =>
        path == oldPath ? newPath : '$newPath${path.substring(oldPath.length)}';

    // Re-root the directory tables and every entry path beneath them.
    final movedDirs = <String, List<RemoteFileEntry>>{};
    for (final key in directories.keys.toList()) {
      if (key == oldPath || key.startsWith('$oldPath/')) {
        movedDirs[rebase(key)] = [
          for (final child in directories.remove(key)!)
            RemoteFileEntry(
              path: rebase(child.path),
              name: child.name,
              type: child.type,
              size: child.size,
              uid: child.uid,
              gid: child.gid,
              accessedAt: child.accessedAt,
              modifiedAt: child.modifiedAt,
              contentSha256: child.contentSha256,
              mode: child.mode,
            ),
        ];
      }
    }
    directories.addAll(movedDirs);
    void rebaseTable<T extends Object>(Map<String, T> table) {
      final moved = <String, T>{};
      for (final key in table.keys.toList()) {
        if (key == oldPath || key.startsWith('$oldPath/')) {
          final value = table.remove(key);
          if (value != null) moved[rebase(key)] = value;
        }
      }
      table.addAll(moved);
    }

    rebaseTable(fileBytes);
    rebaseTable(mtimes);
    rebaseTable(modes);
    final sourceParentKey = _dirKey(remoteParent(oldPath));
    if (sourceParentKey != null) {
      directories[sourceParentKey]!.removeWhere(
        (e) => _matches(e.path, oldPath),
      );
    }
    directories[destinationParentKey]!.add(
      RemoteFileEntry(
        path: newPath,
        name: remoteBasename(newPath),
        type: RemoteFileType.directory,
        modifiedAt: mtimes[newPath],
        mode: modes[newPath],
      ),
    );
  }

  @override
  Future<void> delete(RemoteFileEntry entry) async {
    deleteCalls++;
    calls.add('delete:${entry.path}');
    final failure = deleteFailure?.call(entry);
    if (failure != null) throw failure;
    final existing = entryAt(entry.path);
    if (existing == null) throw _notFound('delete', entry.path);
    if (existing.isDirectory) {
      final dirKey = _dirKey(entry.path);
      if ((dirKey != null ? directories[dirKey]! : const []).isNotEmpty) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.other,
          operation: 'delete',
          path: entry.path,
          message: 'directory not empty: ${entry.path}',
        );
      }
      directories.remove(dirKey ?? entry.path);
    }
    fileBytes.remove(entry.path);
    final parentKey = _dirKey(remoteParent(entry.path));
    if (parentKey != null) {
      directories[parentKey]!.removeWhere((e) => _matches(e.path, entry.path));
    }
  }

  @override
  Future<void> setTimes(
    String path, {
    DateTime? accessedAt,
    DateTime? modifiedAt,
  }) async {
    setTimesCalls++;
    final existing = entryAt(path);
    if (existing == null) throw _notFound('setTimes', path);
    if (modifiedAt != null) {
      mtimes[path] = modifiedAt;
      // Reflect the new mtime in the parent's listing so later
      // replace-if-newer checks observe it.
      final parent = remoteParent(path);
      final children = directories[parent];
      if (children != null) {
        final index = children.indexWhere((e) => e.path == path);
        if (index >= 0) {
          final e = children[index];
          children[index] = RemoteFileEntry(
            path: e.path,
            name: e.name,
            type: e.type,
            size: e.size,
            uid: e.uid,
            gid: e.gid,
            accessedAt: e.accessedAt,
            modifiedAt: modifiedAt,
            mode: e.mode,
          );
        }
      }
    }
  }

  /// chmod over the in-memory tree — the remote-trash 0700 rule's
  /// lever. Records into [modes] and reflects the new mode on the
  /// parent's listing entry.
  @override
  Future<void> setMode(String path, int permissions) async {
    setModeCalls++;
    calls.add('setMode:$path=$permissions');
    final failure = setModeFailure?.call(path);
    if (failure != null) throw failure;
    final existing = entryAt(path);
    if (existing == null) throw _notFound('setMode', path);
    modes[path] = permissions;
    final parent = remoteParent(path);
    final children = directories[_dirKey(parent) ?? parent];
    if (children != null) {
      final index = children.indexWhere((e) => _matches(e.path, path));
      if (index >= 0) {
        final e = children[index];
        children[index] = RemoteFileEntry(
          path: e.path,
          name: e.name,
          type: e.type,
          size: e.size,
          uid: e.uid,
          gid: e.gid,
          accessedAt: e.accessedAt,
          modifiedAt: e.modifiedAt,
          mode: permissions,
        );
      }
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeTreeFileSystem does not implement ${invocation.memberName}',
  );
}

/// Shared in-flight byte counter for the remote→remote pipe tests: the
/// source fake's `download` credits every produced chunk and the
/// destination fake's `upload` debits every consumed chunk, so [peak] is
/// the largest number of bytes ever between the two VFS calls — the
/// quantity 03 §4.5's bounded buffer must keep small.
class PipeProbe {
  int inFlight = 0;
  int peak = 0;

  void sent(int bytes) {
    inFlight += bytes;
    if (inFlight > peak) peak = inFlight;
  }

  void received(int bytes) => inFlight -= bytes;
}

/// A persistence seam that records every call — the ordering tests read
/// what the queue's in-memory state looked like *at append time*.
class RecordingPersistence implements TransferPersistence {
  final List<TransferJournalRecord> journal = [];
  final List<TransferHistoryEntry> historyEntries = [];
  TransferJournalReplay replayValue = TransferJournalReplay(tasks: []);
  bool shutdownCalled = false;

  /// Runs inside `appendJournal` — captures state before the caller's
  /// mutation lands.
  void Function(TransferJournalRecord record)? onAppend;

  @override
  TransferJournalReplay get replay => replayValue;

  @override
  void appendJournal(TransferJournalRecord record) {
    onAppend?.call(record);
    journal.add(record);
  }

  @override
  void appendHistory(TransferHistoryEntry entry) => historyEntries.add(entry);

  @override
  Future<void> shutdown() async {
    shutdownCalled = true;
  }
}

/// A transfer-channel lease over [FakeTreeFileSystem]; [releaseCount]
/// makes the deterministic-release contract observable.
class FakeTransferLease implements TransferChannelLease {
  FakeTransferLease(this.fs, this._onRelease);

  final void Function() _onRelease;
  int releaseCount = 0;
  final List<RemoteFileException> reportedFailures = [];

  @override
  final FakeTreeFileSystem fs;

  @override
  Future<void> release() async {
    // A lease is single-release: a second call is a queue-side bug the
    // fake must surface, not silently absorb into the pool accounting.
    assert(releaseCount == 0, 'transfer lease released more than once');
    releaseCount++;
    _onRelease();
  }

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {
    reportedFailures.add(error);
  }
}

/// A [ConnectionManager] stand-in: `leaseTransferChannel` hands out
/// leases over named [FakeTreeFileSystem]s with an optional per-server
/// concurrency cap — enough to prove the queue blocks where the real
/// pool would block and releases deterministically. Every other member
/// fails loudly.
class FakeQueueConnectionManager implements ConnectionManager {
  FakeQueueConnectionManager(this.filesystems);

  final Map<String, FakeTreeFileSystem> filesystems;

  /// Per-server cap on simultaneously held leases — models the pool's
  /// `effectiveTransports × maxTransferChannelsPerTransport` bound.
  int? leaseCap;

  /// Blocks lease acquisition while set.
  Completer<void>? leaseGate;

  /// Scripted lease failure (e.g. a dropped server reference).
  Object? Function(String serverId)? leaseFailure;

  int leaseCalls = 0;

  /// Server ids in the order `leaseTransferChannel` was invoked — the
  /// sorted-acquisition-order assertion (03 §4.3/§4.5's deadlock rule).
  final List<String> leaseOrder = [];
  final List<FakeTransferLease> allLeases = [];
  final Map<String, int> _active = {};
  final Map<String, int> _peak = {};
  final Map<String, ListQueue<Completer<void>>> _waiters = {};

  int activeLeases(String serverId) => _active[serverId] ?? 0;

  /// Peak simultaneously held leases — the per-server cap assertion.
  int maxActiveLeases(String serverId) => _peak[serverId] ?? 0;

  int get totalReleased =>
      allLeases.fold(0, (sum, lease) => sum + lease.releaseCount);

  @override
  Future<TransferChannelLease> leaseTransferChannel(String serverId) async {
    leaseCalls++;
    leaseOrder.add(serverId);
    await leaseGate?.future;
    final failure = leaseFailure?.call(serverId);
    if (failure != null) throw failure;
    final fs = filesystems[serverId];
    if (fs == null) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'lease transfer channel',
        message: 'no such server: $serverId',
      );
    }
    while (leaseCap != null && (_active[serverId] ?? 0) >= leaseCap!) {
      final waiter = Completer<void>();
      _waiters.putIfAbsent(serverId, ListQueue.new).add(waiter);
      await waiter.future;
      final retryFailure = leaseFailure?.call(serverId);
      if (retryFailure != null) {
        // The wake was consumed but the slot wasn't taken — pass it to
        // the next waiter or the freed capacity is stranded.
        final queue = _waiters[serverId];
        if (queue != null && queue.isNotEmpty) {
          queue.removeFirst().complete();
        }
        throw retryFailure;
      }
    }
    _active[serverId] = (_active[serverId] ?? 0) + 1;
    if (_active[serverId]! > (_peak[serverId] ?? 0)) {
      _peak[serverId] = _active[serverId]!;
    }
    final lease = FakeTransferLease(fs, () {
      _active[serverId] = (_active[serverId] ?? 1) - 1;
      final queue = _waiters[serverId];
      if (queue != null && queue.isNotEmpty) {
        queue.removeFirst().complete();
      }
    });
    allLeases.add(lease);
    return lease;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeQueueConnectionManager does not implement ${invocation.memberName}',
  );
}
