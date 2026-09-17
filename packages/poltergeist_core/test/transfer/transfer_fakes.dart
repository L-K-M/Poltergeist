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

  /// Currently inside a `download` — the global-cap assertion reads the
  /// peak.
  int activeDownloads = 0;
  int maxActiveDownloads = 0;
  int activeUploads = 0;
  int maxActiveUploads = 0;

  /// Chunking of `download` output; small values exercise the bounded
  /// sink's backpressure.
  int downloadChunkSize = 16 * 1024;

  // Scripting — each hook returns the error to throw, or null to proceed.
  Object? Function(String path)? statFailure;
  Object? Function(String path)? listFailure;
  Object? Function(String path)? downloadFailure;
  Object? Function(String path)? uploadFailure;

  /// Gates — return a completer to stall the operation until it completes.
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
      for (final child in directories[parent] ?? const <RemoteFileEntry>[]) {
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
    for (final child in directories[parent] ?? const <RemoteFileEntry>[]) {
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
  Future<String> canonicalize(String path) async => path;

  @override
  Future<RemoteFileEntry> stat(
    String path, {
    bool followLinks = true,
  }) async {
    statCalls++;
    calls.add('stat:$path');
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
    final children = directories[path];
    if (children == null) throw _notFound('list', path);
    return List.of(children);
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
        for (var offset = 0; offset < bytes.length; offset += downloadChunkSize) {
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
          yield chunk;
          onProgress?.call(sent, bytes.length);
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
      return entryAt(path)!;
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
          onProgress?.call(received, length);
        }
      } finally {
        // Nothing lands: the partial file lives on the (implicit) temp
        // side and is discarded, exactly like the real adapter.
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
    if (!directories.containsKey(parent)) {
      throw _notFound('mkdir', parent);
    }
    addDirectory(path);
  }

  @override
  Future<void> delete(RemoteFileEntry entry) async {
    deleteCalls++;
    calls.add('delete:${entry.path}');
    final existing = entryAt(entry.path);
    if (existing == null) throw _notFound('delete', entry.path);
    if (existing.isDirectory) {
      if ((directories[entry.path] ?? const []).isNotEmpty) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.other,
          operation: 'delete',
          path: entry.path,
          message: 'directory not empty: ${entry.path}',
        );
      }
      directories.remove(entry.path);
    }
    fileBytes.remove(entry.path);
    directories[remoteParent(entry.path)]?.removeWhere(
      (e) => e.path == entry.path,
    );
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

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'FakeTreeFileSystem does not implement ${invocation.memberName}',
  );
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
      if (retryFailure != null) throw retryFailure;
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
