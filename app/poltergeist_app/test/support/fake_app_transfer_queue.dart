import 'dart:async';

import 'package:poltergeist_app/services/app_transfer_queue.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// A scripted [AppTransferQueue] for activity-panel tests: task rows,
/// parked conflicts, history, and limiters are plain mutable state, and
/// every verb records its call so a widget test asserts the panel's
/// reach into the seam instead of simulating the engine. The mutation
/// verbs apply the honest state flip too (a cancelled item reads
/// cancelled), so the mirror sees what the real queue would emit.
class FakeAppTransferQueue implements AppTransferQueue {
  final _events = StreamController<TransferQueueEvent>.broadcast();
  final List<TransferTask> _tasks = [];

  bool _paused = false;
  final pendingConflictList = <PendingConflict>[];
  final historyEntries = <TransferHistoryEntry>[];

  @override
  final downloadLimiter = BandwidthLimiter();

  @override
  final uploadLimiter = BandwidthLimiter();

  // ── Verb call log ───────────────────────────────────────────────────
  final cancelItemCalls = <(String taskId, String itemId)>[];
  final retryItemCalls = <(String taskId, String itemId)>[];
  final retryTaskCalls = <String>[];
  final cancelTaskCalls = <String>[];
  final removeTaskCalls = <String>[];
  final pauseTaskCalls = <String>[];
  final resumeTaskCalls = <String>[];
  final moveTaskCalls = <(String taskId, String? beforeTaskId)>[];
  final resolveConflictCalls =
      <(String, String, ConflictResolution, ConflictResolutionScope)>[];
  var pauseQueueCalls = 0;
  var resumeQueueCalls = 0;
  var clearHistoryCalls = 0;

  /// Items that refuse a retry despite being failed — the journal
  /// lookup-miss case the panel must not offer Retry for.
  final nonRetryableItems = <String>{};

  // ── Scripting helpers ───────────────────────────────────────────────

  /// Mints a task row. [state], counters, and items are all scriptable
  /// — the fake trusts the caller to assemble an honest combination.
  TransferTask addTask({
    TransferOperation operation = TransferOperation.copy,
    FsLocation source = const LocalFsLocation(),
    FsLocation destination = const ServerFsLocation('srv-1'),
    List<String> rootPaths = const ['/home/tester/docs'],
    String destinationDir = '/srv/www',
    TransferTaskState state = TransferTaskState.queued,
    bool scanComplete = true,
    bool wasRestored = false,
    int totalFiles = 0,
    int totalDirectories = 0,
    int completedFiles = 0,
    int completedDirectories = 0,
    int failedItems = 0,
    int skippedItems = 0,
    int transferredBytes = 0,
    int? totalBytes,
    String? error,
    String? id,
  }) {
    final spec = TransferTaskSpec(
      source: source,
      destination: destination,
      rootPaths: rootPaths,
      destinationDir: destinationDir,
      policy: ResolvedConflictPolicy(),
      operation: operation,
      disposition: operation == TransferOperation.delete
          ? DeleteDisposition.trash
          : null,
    );
    final task = wasRestored
        ? TransferTask.restored(
            spec,
            id: id ?? 'task-${_tasks.length + 1}',
            enqueuedAt: DateTime.utc(2026, 1, 1),
          )
        : TransferTask(spec);
    if (id != null && !wasRestored) {
      // TransferTask mints its own id; a scripted non-restored id is
      // only needed when tests key on it — keep the mint otherwise.
    }
    task
      ..state = state
      ..scanComplete = scanComplete
      ..totalFiles = totalFiles
      ..totalDirectories = totalDirectories
      ..completedFiles = completedFiles
      ..completedDirectories = completedDirectories
      ..failedItems = failedItems
      ..skippedItems = skippedItems
      ..transferredBytes = transferredBytes
      ..totalBytes = totalBytes
      ..error = error;
    _tasks.add(task);
    emit(TransferQueueTaskEvent(task.id, task.state));
    return task;
  }

  TransferItem addItem(
    TransferTask task, {
    String? id,
    String name = 'file.txt',
    bool isDirectory = false,
    int? size,
    int transferredBytes = 0,
    TransferItemState state = TransferItemState.pending,
    String? error,
    ItemDisposition? disposition,
  }) {
    final item = TransferItem(
      id: id ?? 'item-${task.items.length + 1}',
      sourcePath: '${task.rootPaths.first}/$name',
      isDirectory: isDirectory,
      destinationPath: '${task.destinationDir}/$name',
      size: size,
    );
    item
      ..state = state
      ..transferredBytes = transferredBytes
      ..error = error
      ..disposition = disposition;
    task.items.add(item);
    emit(TransferQueueItemEvent(task.id, item.id, item.state));
    return item;
  }

  PendingConflict addConflict(
    TransferTask task,
    TransferItem item, {
    bool isDirectory = false,
    int? existingSize = 1024,
    int? incomingSize = 2048,
  }) {
    final conflict = PendingConflict(
      taskId: task.id,
      itemId: item.id,
      isDirectory: isDirectory,
      sourcePath: item.sourcePath,
      destinationPath: item.destinationPath,
      source: RemoteFileEntry(
        path: item.sourcePath,
        name: pathLeaf(item.sourcePath),
        type: isDirectory ? RemoteFileType.directory : RemoteFileType.file,
        size: incomingSize,
        modifiedAt: DateTime.utc(2026, 1, 2),
      ),
      existing: DestinationStat(
        type: isDirectory ? RemoteFileType.directory : RemoteFileType.file,
        size: existingSize,
        modifiedAt: DateTime.utc(2026, 1, 1),
      ),
    );
    pendingConflictList.add(conflict);
    item.state = TransferItemState.conflictPending;
    emit(
      TransferQueueConflictEvent(
        task.id,
        item.id,
        conflict: conflict,
        pending: true,
      ),
    );
    return conflict;
  }

  TransferHistoryEntry addHistory({
    String taskId = 'done-1',
    TransferOperation operation = TransferOperation.copy,
    TransferTaskState outcome = TransferTaskState.completed,
    List<String> rootPaths = const ['/home/tester/report.pdf'],
    String destinationDir = '/srv/www',
    FsLocation source = const LocalFsLocation(),
    FsLocation destination = const ServerFsLocation('srv-1'),
    int transferredBytes = 4096,
    int? totalBytes = 4096,
    int completedFiles = 1,
    int failedItems = 0,
    String? error,
  }) {
    final entry = TransferHistoryEntry(
      taskId: taskId,
      source: source,
      destination: destination,
      rootPaths: rootPaths,
      destinationDir: destinationDir,
      operation: operation,
      outcome: outcome,
      startedAt: DateTime.utc(2026, 1, 1, 12),
      finishedAt: DateTime.utc(2026, 1, 1, 12, 1),
      completedFiles: completedFiles,
      failedItems: failedItems,
      skippedItems: 0,
      transferredBytes: transferredBytes,
      totalBytes: totalBytes,
      error: error,
    );
    historyEntries.add(entry);
    emitRefresh();
    return entry;
  }

  /// Delivers a queue event to listeners.
  void emit(TransferQueueEvent event) => _events.add(event);

  /// A content-free nudge — queue-level state (pause, limits) carries
  /// no event type, so the fake refreshes mirrors with an order event
  /// keyed on a never-matching task id.
  void emitRefresh() =>
      _events.add(const TransferQueueOrderEvent('queue'));

  // ── AppTransferQueue ────────────────────────────────────────────────

  @override
  List<TransferTask> get tasks => List.unmodifiable(_tasks);

  @override
  bool get isPaused => _paused;

  @override
  Stream<TransferQueueEvent> get events => _events.stream;

  @override
  List<PendingConflict> get pendingConflicts =>
      List.unmodifiable(pendingConflictList);

  @override
  PendingConflict? pendingConflictFor(String taskId, String itemId) {
    for (final conflict in pendingConflictList) {
      if (conflict.taskId == taskId && conflict.itemId == itemId) {
        return conflict;
      }
    }
    return null;
  }

  @override
  List<TransferHistoryEntry> get history =>
      List.unmodifiable(historyEntries);

  @override
  void pauseQueue() {
    pauseQueueCalls++;
    _paused = true;
    emitRefresh();
  }

  @override
  void resumeQueue() {
    resumeQueueCalls++;
    _paused = false;
    emitRefresh();
  }

  @override
  void pauseTask(String taskId) {
    pauseTaskCalls.add(taskId);
    _task(taskId)?.state = TransferTaskState.paused;
    emit(TransferQueueTaskEvent(taskId, TransferTaskState.paused));
  }

  @override
  void resumeTask(String taskId) {
    resumeTaskCalls.add(taskId);
    _task(taskId)?.state = TransferTaskState.running;
    emit(TransferQueueTaskEvent(taskId, TransferTaskState.running));
  }

  @override
  void cancelTask(String taskId) {
    cancelTaskCalls.add(taskId);
    final task = _task(taskId);
    if (task == null || task.isTerminal) return;
    for (final item in task.items) {
      if (!item.isTerminal) item.state = TransferItemState.cancelled;
    }
    task.state = TransferTaskState.cancelled;
    emit(TransferQueueTaskEvent(taskId, TransferTaskState.cancelled));
  }

  @override
  bool removeTask(String taskId) {
    removeTaskCalls.add(taskId);
    final task = _task(taskId);
    if (task == null || !task.isTerminal) return false;
    _tasks.remove(task);
    emitRefresh();
    return true;
  }

  @override
  bool moveTask(String taskId, {String? beforeTaskId}) {
    moveTaskCalls.add((taskId, beforeTaskId));
    final task = _task(taskId);
    if (task == null ||
        (task.state != TransferTaskState.queued &&
            task.state != TransferTaskState.scanning)) {
      return false;
    }
    _tasks.remove(task);
    if (beforeTaskId == null) {
      _tasks.add(task);
    } else {
      final index = _tasks.indexWhere((t) => t.id == beforeTaskId);
      if (index < 0) {
        _tasks.add(task);
        return false;
      }
      _tasks.insert(index, task);
    }
    emit(TransferQueueOrderEvent(taskId));
    return true;
  }

  @override
  bool cancelItem(String taskId, String itemId) {
    cancelItemCalls.add((taskId, itemId));
    final item = _item(taskId, itemId);
    if (item == null || item.isTerminal) return false;
    item.state = TransferItemState.cancelled;
    emit(TransferQueueItemEvent(taskId, itemId, item.state));
    return true;
  }

  @override
  bool canRetryItem(String taskId, String itemId) {
    final item = _item(taskId, itemId);
    return item != null &&
        item.state == TransferItemState.failed &&
        !nonRetryableItems.contains(itemId);
  }

  @override
  bool retryItem(String taskId, String itemId) {
    retryItemCalls.add((taskId, itemId));
    if (!canRetryItem(taskId, itemId)) return false;
    final item = _item(taskId, itemId)!;
    item.state = TransferItemState.pending;
    emit(TransferQueueItemEvent(taskId, itemId, item.state));
    return true;
  }

  @override
  bool canRetryTask(String taskId) {
    final task = _task(taskId);
    return task != null &&
        task.state == TransferTaskState.failed &&
        task.items.any((item) => canRetryItem(taskId, item.id));
  }

  @override
  bool retryTask(String taskId) {
    retryTaskCalls.add(taskId);
    if (!canRetryTask(taskId)) return false;
    final task = _task(taskId)!;
    for (final item in task.items) {
      if (item.state == TransferItemState.failed &&
          !nonRetryableItems.contains(item.id)) {
        item.state = TransferItemState.pending;
      }
    }
    task.state = TransferTaskState.queued;
    emit(TransferQueueTaskEvent(taskId, task.state));
    return true;
  }

  @override
  bool resolveConflict(
    String taskId,
    String itemId,
    ConflictResolution verb, {
    ConflictResolutionScope scope = ConflictResolutionScope.item,
  }) {
    final conflict = pendingConflictFor(taskId, itemId);
    if (conflict == null) return false;
    resolveConflictCalls.add((taskId, itemId, verb, scope));
    final targets = scope == ConflictResolutionScope.task
        ? pendingConflictList
            .where((c) => c.taskId == taskId)
            .toList()
        : [conflict];
    for (final target in targets) {
      pendingConflictList.remove(target);
      _item(taskId, target.itemId)?.state = TransferItemState.pending;
      emit(
        TransferQueueConflictEvent(
          taskId,
          target.itemId,
          conflict: target,
          pending: false,
        ),
      );
    }
    return true;
  }

  @override
  Future<void> clearHistory() {
    clearHistoryCalls++;
    historyEntries.clear();
    emitRefresh();
    return Future.value();
  }

  TransferTask? _task(String taskId) {
    for (final task in _tasks) {
      if (task.id == taskId) return task;
    }
    return null;
  }

  TransferItem? _item(String taskId, String itemId) {
    for (final item in _task(taskId)?.items ?? const <TransferItem>[]) {
      if (item.id == itemId) return item;
    }
    return null;
  }

  Future<void> close() => _events.close();
}

String pathLeaf(String path) {
  final cut = path.lastIndexOf('/');
  return cut < 0 ? path : path.substring(cut + 1);
}
