/// The file-backed transfer persistence (03 §4.6, D16): the write-ahead
/// journal `transfer_queue.jsonl` plus the capped history store
/// `transfer_history.jsonl`, under the app-provided support directory.
///
/// Ordering and durability rules implemented here:
///
/// - Every append to either file funnels through one single-writer async
///   chain, so no append can interleave with a rewrite of the same file
///   (a `fileCompleted` completing mid-compaction queues behind the
///   rename and lands on the new inode — never on the unlinked one).
/// - Journal appends are flushed per line (process-death durable) and
///   fsynced on a bounded interval — every [fsyncEveryRecords] records or
///   [fsyncInterval] of pending writes, and always before a task's
///   history record is appended. The accepted residue of a power loss is
///   re-transfer of files whose completion had not reached an fsync
///   boundary; a lost completion the UI already showed is impossible
///   because the history append forces the fsync first.
/// - Recovery distinguishes a torn tail (a crash mid-append — dropped and
///   truncated before reopen) from a complete-but-unparseable line
///   (quarantine the file timestamped, replay the intact prefix,
///   atomically rewrite the live file to that prefix so later appends
///   never land behind the malformed line). Both mutations fsync the
///   containing directory.
/// - Compaction runs at startup replay, on clean shutdown, and mid-session
///   once the journal crosses a finished-task/size threshold: finished
///   tasks append to history first (idempotent by task id — ids already
///   in history are skipped), history is flushed and fsynced, then the
///   journal is atomically rewritten to the pending tasks' full record
///   sets. A crash between the steps loses nothing: the next replay
///   re-reads the old journal and skips the already-recorded ids.
library;

// The private constructor groups its eight policy fields in the
// initializer list deliberately — the parameter map reads as one block.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:seance_core/seance_core.dart';

import 'transfer_journal.dart';
import 'transfer_task.dart';

/// The default journal fsync policy (03 §4.6): fsync every ~64 records
/// or ~250 ms of pending writes, whichever comes first.
const int journalFsyncEveryRecords = 64;
const Duration journalFsyncInterval = Duration(milliseconds: 250);

/// Mid-session compaction triggers: once this many tasks have finished
/// since the last rewrite, or the live journal has grown past this many
/// bytes, finished tasks migrate to history and the journal rewrites to
/// the pending set (03 §4.6 — a long session must not grow an unbounded
/// journal, and post-crash replay stays short).
const int journalCompactFinishedTasks = 32;
const int journalCompactBytes = 4 * 1024 * 1024;

/// JSONL journal + history store. Construct through [open], which performs
/// recovery and the startup compaction before returning — the store is
/// never usable while its files are in an unrepaired state.
///
/// Persistence failures degrade honestly: a failed append/flush/rewrite
/// reports through [onNotice] and the writer chain keeps running (the
/// queue keeps its in-memory behavior — the same posture as persistence
/// disabled — with the failure surfaced rather than wedging the queue on
/// disk trouble).
class FileTransferPersistence implements TransferPersistence {
  FileTransferPersistence._({
    required Directory directory,
    required TransferJournalIo io,
    required void Function(String message)? onNotice,
    required int historyLimit,
    required int compactFinishedTasks,
    required int compactBytes,
    required int fsyncEveryRecords,
    required Duration fsyncInterval,
    required this.replay,
    required Map<String, _LiveTask> liveTasks,
    required List<TransferHistoryEntry> historyRecords,
  }) : journalFile = File(
         p.join(directory.path, transferJournalFileName),
       ).absolute,
       historyFile = File(
         p.join(directory.path, transferHistoryFileName),
       ).absolute,
       _io = io,
       _onNotice = onNotice,
       _historyLimit = historyLimit,
       _compactFinishedTasks = compactFinishedTasks,
       _compactBytes = compactBytes,
       _fsyncEveryRecords = fsyncEveryRecords,
       _fsyncInterval = fsyncInterval,
       _liveTasks = liveTasks,
       _historyRecords = historyRecords {
    _historyIds = {for (final entry in historyRecords) entry.taskId};
    _journalBytes = liveTasks.values.fold(
      0,
      (sum, task) => sum + task.encodedBytes,
    );
  }

  /// The live-queue journal file.
  final File journalFile;

  /// The finished-task history file.
  final File historyFile;

  /// The file primitives — the fault-injection seam for tests.
  final TransferJournalIo _io;

  /// Live-failure surface: torn/corrupt/dropped records and write
  /// failures are reported here (diagnostics, never telemetry — D19).
  final void Function(String message)? _onNotice;

  /// Retention cap (03 §4.6): the history file rewrites to the newest
  /// [historyLimit] records once it exceeds the cap by a 10 % slack
  /// margin.
  final int _historyLimit;
  final int _compactFinishedTasks;
  final int _compactBytes;
  final int _fsyncEveryRecords;
  final Duration _fsyncInterval;

  /// What recovery found at [open] — task set plus corruption counts.
  @override
  final TransferJournalReplay replay;

  /// Replay model of the journal, kept current by [appendJournal] so
  /// compaction can re-derive pending sets and history rows without
  /// re-reading the file.
  final Map<String, _LiveTask> _liveTasks;
  final List<TransferHistoryEntry> _historyRecords;
  late final Set<String> _historyIds;

  /// The single-writer chain (03 §4.6): every append and every rewrite of
  /// either file queues here.
  Future<void> _pending = Future<void>.value();
  bool _closed = false;

  int _journalBytes = 0;
  int _recordsSinceFsync = 0;
  int _finishedSinceCompact = 0;
  Timer? _fsyncTimer;

  /// Opens the store, repairing torn/corrupt logs and running the
  /// startup replay + compaction (03 §4.6). [directory] is the
  /// app-provided support directory.
  static Future<FileTransferPersistence> open(
    Directory directory, {
    TransferJournalIo io = const TransferJournalIo(),
    void Function(String message)? onNotice,
    int historyLimit = transferHistoryLimit,
    int compactFinishedTasks = journalCompactFinishedTasks,
    int compactBytes = journalCompactBytes,
    int fsyncEveryRecords = journalFsyncEveryRecords,
    Duration fsyncInterval = journalFsyncInterval,
  }) async {
    final dir = directory.absolute;
    await dir.create(recursive: true);
    final journalFile = File(p.join(dir.path, transferJournalFileName));
    final historyFile = File(p.join(dir.path, transferHistoryFileName));
    await io.sweepAbandonedTemps(journalFile);
    await io.sweepAbandonedTemps(historyFile);

    final journal = await _recoverLog(
      journalFile,
      io,
      TransferJournalRecord.parse,
    );
    final history = await _recoverLog(
      historyFile,
      io,
      TransferHistoryEntry.parse,
    );

    final liveTasks = _replayJournal(journal.entries);
    final tasks = <RestoredTransferTask>[];
    var orphaned = 0;
    for (final live in liveTasks.values) {
      if (live.removed || live.isTerminal) continue;
      final spec = live.spec;
      if (spec == null) {
        orphaned += live.records.length;
        continue;
      }
      tasks.add(_restoredTask(live));
    }

    final store = FileTransferPersistence._(
      directory: dir,
      io: io,
      onNotice: onNotice,
      historyLimit: historyLimit,
      compactFinishedTasks: compactFinishedTasks,
      compactBytes: compactBytes,
      fsyncEveryRecords: fsyncEveryRecords,
      fsyncInterval: fsyncInterval,
      liveTasks: liveTasks,
      historyRecords: [for (final (entry, _) in history.entries) entry],
      replay: TransferJournalReplay(
        tasks: tasks,
        tornJournalBytes: journal.tornBytes,
        quarantinedJournalPath: journal.quarantinedTo,
        quarantinedJournalRecords: journal.quarantinedRecords,
        tornHistoryBytes: history.tornBytes,
        quarantinedHistoryPath: history.quarantinedTo,
        quarantinedHistoryRecords: history.quarantinedRecords,
      ),
    );
    if (orphaned > 0) {
      store._notice(
        'journal held $orphaned records for tasks whose taskEnqueued '
        'was lost; they cannot be restored',
      );
    }

    // Startup compaction: crash-recovered finished tasks migrate to
    // history, then the journal rewrites to the pending set (03 §4.6).
    await store._compact();
    return store;
  }

  // ── TransferPersistence ────────────────────────────────────────────

  @override
  void appendJournal(TransferJournalRecord record) {
    if (_closed) {
      _notice(
        'journal record dropped: persistence is shut down '
        '(${record.type} for ${record.taskId})',
      );
      return;
    }
    _enqueue(() async {
      final line = jsonEncode(record.toJson());
      await _io.appendLine(journalFile, line);
      // Byte-accurate accounting: String.length is UTF-16 code units and
      // journaled paths are commonly non-ASCII.
      _journalBytes += utf8.encode(line).length + 1;
      _recordsSinceFsync++;
      _applyToLive(record, line);
      if (record is TaskStateRecord &&
          (record.state == TransferTaskState.completed ||
              record.state == TransferTaskState.failed ||
              record.state == TransferTaskState.cancelled)) {
        _finishedSinceCompact++;
      }
      if (_recordsSinceFsync >= _fsyncEveryRecords) {
        await _fsyncJournal();
      } else {
        _armFsyncTimer();
      }
      if (_shouldCompact()) await _compact();
    });
  }

  @override
  void appendHistory(TransferHistoryEntry entry) {
    if (_closed) {
      _notice(
        'history record dropped: persistence is shut down '
        '(${entry.taskId})',
      );
      return;
    }
    _enqueue(() async {
      // 03 §4.6's ordering rule: the journal is fsynced before a task's
      // history record lands, so a power loss can never leave a
      // "completed" the UI showed without its journal records.
      await _fsyncJournal();
      await _appendHistoryLine(entry);
      await _trimHistoryIfNeeded();
    });
  }

  @override
  Future<void> shutdown() {
    if (_closed) return _pending;
    _closed = true;
    _fsyncTimer?.cancel();
    _fsyncTimer = null;
    // Shutdown must not fail the caller (the queue's dispose is not a
    // place disk trouble may crash); failures still surface via onNotice.
    return _enqueue(() async {
      // Clean-shutdown compaction (03 §4.6): history first, journal
      // rewrite second — a crash between the steps loses nothing.
      await _compact();
      if (await journalFile.exists()) await _io.fsyncFile(journalFile);
      if (await historyFile.exists()) await _io.fsyncFile(historyFile);
    }).then((_) {}, onError: (Object _) {});
  }

  /// Awaits every queued write and fsyncs the journal now — the
  /// deterministic synchronization point tests (and any caller that must
  /// observe a durable boundary) use instead of the interval timer.
  Future<void> flush() {
    // Post-shutdown a flush must not reopen a handle — the same
    // discipline `_armFsyncTimer` guards.
    if (_closed) return _pending;
    _fsyncTimer?.cancel();
    _fsyncTimer = null;
    return _enqueue(() async {
      if (await journalFile.exists()) await _fsyncJournal();
    });
  }

  /// Read-only view of the loaded history (the activity panel's History
  /// tab reads this file; the in-memory copy is what the cap trims).
  List<TransferHistoryEntry> get history => List.unmodifiable(_historyRecords);

  // ── Internals ──────────────────────────────────────────────────────

  /// Runs [operation] after every write queued before it; a failed op
  /// reports and frees the chain — one disk error must not wedge the
  /// store (the queue then runs in the persistence-disabled posture with
  /// the failure surfaced).
  Future<void> _enqueue(Future<void> Function() operation) {
    final run = _pending.then((_) => operation());
    _pending = run.then<void>((_) {}, onError: (Object _) {});
    unawaited(
      run.catchError((Object error) {
        _notice('transfer persistence write failed: $error');
      }),
    );
    return run;
  }

  void _notice(String message) {
    try {
      _onNotice?.call(message);
    } on Object {
      // Diagnostics must never feed back into the store.
    }
  }

  /// Keeps the replay model current with each appended record so
  /// compaction never re-reads the file mid-session.
  void _applyToLive(TransferJournalRecord record, String line) {
    final task = _liveTasks.putIfAbsent(
      record.taskId,
      () => _LiveTask(record.taskId),
    );
    task.records.add((record, line));
    _applyRecord(task, record);
  }

  /// The one record→model mapping, shared by the live append path and
  /// the open-time replay so both interpret the journal identically.
  static void _applyRecord(_LiveTask task, TransferJournalRecord record) {
    switch (record) {
      case TaskEnqueuedRecord(:final spec, :final enqueuedAt):
        task.spec = spec;
        task.enqueuedAt = enqueuedAt;
      case PlanEntryRecord():
        // Upsert keyed on (taskId, itemId): a re-scan re-appends the same
        // item — keep the entry, retain any outcome already journaled.
        final existing = task.entries[record.itemId];
        task.entries[record.itemId] = _RestoredItemMutable(
          itemId: record.itemId,
          isDirectory: record.isDirectory,
          sourcePath: record.sourcePath,
          destinationPath: record.destinationPath,
          containerKey: record.containerKey,
          name: record.name,
          source: _entryFromRecord(record),
          existing: record.existing,
          outcome: existing?.outcome,
          error: existing?.error,
          failureKind: existing?.failureKind,
          resolvedPath: existing?.resolvedPath,
          disposition: existing?.disposition,
        );
      case ScanCompleteRecord():
        task.scanComplete = true;
        task.totalBytes = record.totalBytes;
        task.skippedSymlinks = record.skippedSymlinks;
      case TaskStateRecord():
        task.lastState = record.state;
        task.lastStateAt = record.at;
        task.error = record.error;
        task.failureKind = record.failureKind;
      case FileCompletedRecord():
        _applyOutcome(
          task,
          record.itemId,
          RestoredItemOutcome.completed,
          resolvedPath: record.resolvedPath,
          disposition: record.disposition,
        );
      case FileFailedRecord():
        _applyOutcome(
          task,
          record.itemId,
          RestoredItemOutcome.failed,
          error: record.error,
          failureKind: record.failureKind,
        );
      case ItemRemovedRecord():
        _applyOutcome(
          task,
          record.itemId,
          RestoredItemOutcome.removed,
          error: record.error,
        );
      case TaskRemovedRecord():
        task.removed = true;
    }
  }

  static void _applyOutcome(
    _LiveTask task,
    String itemId,
    RestoredItemOutcome outcome, {
    String? error,
    RemoteFileErrorKind? failureKind,
    String? resolvedPath,
    ItemDisposition? disposition,
  }) {
    // An outcome can arrive for an item whose planEntry never journaled
    // (the record landed in a quarantined tail): a placeholder keeps the
    // outcome — the item is terminal either way, so the missing source
    // detail can never send it back to dispatch.
    final item = task.entries.putIfAbsent(
      itemId,
      () => _RestoredItemMutable(
        itemId: itemId,
        isDirectory: false,
        sourcePath: '',
        destinationPath: '',
        containerKey: null,
        name: null,
        source: null,
        existing: null,
      ),
    );
    item.outcome = outcome;
    item.error = error;
    item.failureKind = failureKind;
    item.resolvedPath = resolvedPath;
    item.disposition = disposition;
  }

  Future<void> _fsyncJournal() async {
    _fsyncTimer?.cancel();
    _fsyncTimer = null;
    if (!await journalFile.exists()) return;
    await _io.fsyncFile(journalFile);
    _recordsSinceFsync = 0;
  }

  void _armFsyncTimer() {
    // A closed store must not arm — and a timer fired before shutdown
    // must not enqueue — or a post-shutdown fsync would open a file
    // handle against a store whose owner already walked away (on
    // Windows that open handle fails a racing directory delete with
    // ERROR_SHARING_VIOLATION).
    if (_closed) return;
    _fsyncTimer ??= Timer(_fsyncInterval, () {
      _fsyncTimer = null;
      if (_closed) return;
      _enqueue(() async {
        if (await journalFile.exists()) await _fsyncJournal();
      });
    });
  }

  bool _shouldCompact() =>
      _finishedSinceCompact >= _compactFinishedTasks ||
      _journalBytes >= _compactBytes;

  /// 03 §4.6's compaction: finished tasks append to history first
  /// (idempotent — ids already present are skipped), history flushes and
  /// fsyncs, then the journal rewrites to the pending tasks' full record
  /// sets. Never narrower per task: dropping a still-pending task's
  /// item-level terminal records would let the next replay resurrect
  /// files it already completed or the user already removed.
  Future<void> _compact() async {
    final finished = _liveTasks.values.where((t) => t.isFinished).toList();
    var migrated = false;
    for (final task in finished) {
      if (_historyIds.contains(task.taskId)) continue;
      await _appendHistoryLine(_historyFromLive(task));
      migrated = true;
    }
    if (migrated) await _io.fsyncFile(historyFile);
    await _trimHistoryIfNeeded();

    final content = StringBuffer();
    for (final task in _liveTasks.values) {
      if (task.isFinished) continue;
      for (final (_, line) in task.records) {
        content.write(line);
        content.write('\n');
      }
    }
    final text = content.toString();
    await _io.atomicRewrite(journalFile, text);
    _journalBytes = utf8.encode(text).length;
    _liveTasks.removeWhere((_, task) => task.isFinished);
    _finishedSinceCompact = 0;
    _recordsSinceFsync = 0;
  }

  Future<void> _appendHistoryLine(TransferHistoryEntry entry) async {
    await _io.appendLine(historyFile, jsonEncode(entry.toJson()));
    _historyIds.add(entry.taskId);
    _historyRecords.add(entry);
  }

  /// The 10 000-record cap with 10 % slack (03 §4.6): the trim rewrites
  /// only once the file exceeds the cap by the margin, so the completion
  /// hot path stays a bare append. The rewrite is atomic — a crash
  /// mid-trim never leaves a torn history file.
  Future<void> _trimHistoryIfNeeded() async {
    final slack = _historyLimit ~/ 10;
    if (_historyRecords.length <= _historyLimit + slack) return;
    final kept = _historyRecords.sublist(
      _historyRecords.length - _historyLimit,
    );
    final content = kept
        .map((entry) => '${jsonEncode(entry.toJson())}\n')
        .join();
    await _io.atomicRewrite(historyFile, content);
    _historyRecords
      ..clear()
      ..addAll(kept);
    _historyIds
      ..clear()
      ..addAll(kept.map((entry) => entry.taskId));
  }

  /// A finished task's history row derived from its journaled records —
  /// the compaction path (the live path snapshots the task directly via
  /// [TransferHistoryEntry.fromTask]).
  TransferHistoryEntry _historyFromLive(_LiveTask task) {
    var completedFiles = 0;
    var failedItems = 0;
    var skippedItems = 0;
    var transferredBytes = 0;
    for (final item in task.entries.values) {
      switch (item.outcome) {
        case RestoredItemOutcome.completed:
          if (!item.isDirectory) {
            completedFiles++;
            transferredBytes += item.source?.size ?? 0;
          }
        case RestoredItemOutcome.failed:
          failedItems++;
        case RestoredItemOutcome.removed:
          skippedItems++;
        case null:
          break;
      }
    }
    final spec = task.spec;
    return TransferHistoryEntry(
      taskId: task.taskId,
      source: spec?.source ?? const LocalFsLocation(),
      destination: spec?.destination ?? const LocalFsLocation(),
      rootPaths: spec?.rootPaths ?? const [],
      destinationDir: spec?.destinationDir ?? '',
      operation: spec?.operation ?? TransferOperation.copy,
      outcome: _terminalOutcome(task.lastState),
      startedAt: task.enqueuedAt ?? task.firstRecordAt,
      finishedAt: task.lastStateAt ?? DateTime.now(),
      completedFiles: completedFiles,
      failedItems: failedItems,
      skippedItems: skippedItems,
      transferredBytes: transferredBytes,
      totalBytes: task.scanComplete ? task.totalBytes : null,
      error: task.error,
      failureKind: task.failureKind,
      disposition: spec?.disposition,
    );
  }

  /// A history row's outcome is always terminal — a task `taskRemoved`
  /// before its terminal state journaled reports cancelled rather than
  /// leaving the History tab showing a transient state forever.
  static TransferTaskState _terminalOutcome(TransferTaskState? state) =>
      switch (state) {
        TransferTaskState.completed => TransferTaskState.completed,
        TransferTaskState.failed => TransferTaskState.failed,
        _ => TransferTaskState.cancelled,
      };

  // ── Recovery ───────────────────────────────────────────────────────

  /// One recovered JSONL log: the intact parsed prefix plus what recovery
  /// had to drop or quarantine (03 §4.6's no-silent-drop accounting).
  static Future<_RecoveredLog<T>> _recoverLog<T>(
    File file,
    TransferJournalIo io,
    T Function(String line) parse,
  ) async {
    if (!await file.exists()) {
      return const _RecoveredLog(entries: []);
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return const _RecoveredLog(entries: []);

    // Strict-decode first. A crash mid-append commonly ends inside a
    // multi-byte UTF-8 sequence, so a failed whole-file decode retries
    // on the intact line prefix — byte-level, to the last newline —
    // before the damage is treated as file corruption.
    String? decoded;
    try {
      decoded = utf8.decode(bytes);
    } on FormatException {
      decoded = null;
    }
    var tornBytes = 0;
    if (decoded == null) {
      final lastNewline = bytes.lastIndexOf(0x0a);
      if (lastNewline >= 0) {
        try {
          decoded = utf8.decode(bytes.sublist(0, lastNewline + 1));
        } on FormatException {
          decoded = null;
        }
        if (decoded != null) {
          tornBytes = bytes.length - lastNewline - 1;
          await io.truncateTo(file, lastNewline + 1);
        }
      }
    }
    if (decoded == null) {
      // Invalid UTF-8 beyond the last complete line is mid-file
      // corruption, not a torn append: quarantine the whole file rather
      // than guess at a decode boundary.
      final quarantinedTo = await _quarantine(file, io);
      return _RecoveredLog(
        entries: const [],
        quarantinedTo: quarantinedTo,
        quarantinedRecords: '\n'
            .allMatches(utf8.decode(bytes, allowMalformed: true))
            .length,
      );
    }

    // A crash mid-append leaves a torn tail (no terminating newline):
    // drop it and truncate before the log reopens so malformed bytes are
    // never buried mid-log. Offsets are BYTES — String.length counts
    // UTF-16 code units and non-ASCII paths desynchronize the two, so
    // the truncate length comes from re-encoding the kept prefix.
    var content = decoded;
    if (!content.endsWith('\n')) {
      final lastNewline = content.lastIndexOf('\n');
      final prefix = content.substring(0, lastNewline + 1);
      final prefixBytes = utf8.encode(prefix).length;
      tornBytes = bytes.length - prefixBytes;
      content = prefix;
      await io.truncateTo(file, prefixBytes);
    }

    final rawLines = [
      for (final line in const LineSplitter().convert(content))
        if (line.trim().isNotEmpty) line,
    ];
    final entries = <(T, String)>[];
    for (var i = 0; i < rawLines.length; i++) {
      try {
        entries.add((parse(rawLines[i]), rawLines[i]));
      } on FormatException {
        // A complete-but-unparseable line quarantines the file: the
        // intact prefix replays and is atomically rewritten into the live
        // file, and the rest survives only in the quarantine copy —
        // never a silent drop, never a quarantine loop.
        final quarantinedTo = await _quarantine(file, io);
        await io.atomicRewrite(file, '${rawLines.take(i).join('\n')}\n');
        return _RecoveredLog(
          entries: entries,
          tornBytes: tornBytes,
          quarantinedTo: quarantinedTo,
          quarantinedRecords: rawLines.length - i,
        );
      }
    }
    return _RecoveredLog(entries: entries, tornBytes: tornBytes);
  }

  /// Moves a corrupt log aside with a UTC stamp (the 06 §3.6 pattern),
  /// then fsyncs the directory so the rename is durable. Returns the
  /// quarantine path, or null when the file could not be moved — the
  /// caller still replays the intact prefix and rewrites the live file,
  /// so a failed quarantine never blocks recovery.
  static Future<String?> _quarantine(File file, TransferJournalIo io) async {
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll('-', '')
        .replaceAll(':', '')
        .replaceAll('.', '');
    final destination = '${file.path}.corrupt-$stamp';
    try {
      await file.rename(destination);
      await io.fsyncDirectory(file.parent);
      return destination;
    } on Object {
      return null;
    }
  }

  // ── Replay ─────────────────────────────────────────────────────────

  static Map<String, _LiveTask> _replayJournal(
    List<(TransferJournalRecord, String)> entries,
  ) {
    final tasks = <String, _LiveTask>{};
    for (final (record, line) in entries) {
      final task = tasks.putIfAbsent(
        record.taskId,
        () => _LiveTask(record.taskId),
      );
      // Keep the raw line so a journal rewrite replays the record
      // verbatim — fields a newer build added (and this build's strict
      // decode ignored) are not silently stripped by re-encoding.
      task.records.add((record, line));
      _applyRecord(task, record);
    }
    return tasks;
  }

  static RestoredTransferTask _restoredTask(_LiveTask live) {
    // `open` already routed spec-less tasks into the orphaned-record
    // count — the `!` documents that filter, not a blind unwrap.
    final spec = live.spec!;
    final items = [
      for (final item in live.entries.values)
        RestoredPlanItem(
          itemId: item.itemId,
          isDirectory: item.isDirectory,
          sourcePath: item.sourcePath,
          destinationPath: item.destinationPath,
          containerKey: item.containerKey,
          name: item.name,
          source: item.source,
          existing: item.existing,
          outcome: item.outcome,
          error: item.error,
          failureKind: item.failureKind,
          resolvedPath: item.resolvedPath,
          disposition: item.disposition,
        ),
    ];
    return RestoredTransferTask(
      taskId: live.taskId,
      spec: spec,
      enqueuedAt: live.enqueuedAt ?? live.firstRecordAt,
      wasPaused: live.lastState == TransferTaskState.paused,
      scanComplete: live.scanComplete,
      totalBytes: live.totalBytes,
      skippedSymlinks: live.skippedSymlinks,
      items: items,
      sweepDirectories: _sweepDirectories(spec, items),
    );
  }

  /// The journal-scoped temp-sweep set (03 §4.6): every destination
  /// directory a journaled item names, plus the task's destinationDir —
  /// never a general directory sweep.
  static Set<String> _sweepDirectories(
    TransferTaskSpec spec,
    List<RestoredPlanItem> items,
  ) {
    String parent(String path) => spec.destination is ServerFsLocation
        ? remoteParent(path)
        : p.dirname(path);
    final dirs = <String>{spec.destinationDir};
    for (final item in items) {
      if (item.destinationPath.isEmpty) continue;
      dirs.add(parent(item.destinationPath));
      if (item.isDirectory) dirs.add(item.destinationPath);
    }
    return dirs;
  }

  static RemoteFileEntry? _entryFromRecord(PlanEntryRecord record) {
    final type = record.sourceType;
    if (type == null) return null;
    return RemoteFileEntry(
      path: record.sourcePath,
      name: record.name ?? remoteBasename(record.sourcePath),
      type: type,
      size: record.sourceSize,
      modifiedAt: record.sourceModifiedAt,
      mode: record.sourceMode,
    );
  }
}

/// Mutable per-task replay state (append path and open path share it).
class _LiveTask {
  _LiveTask(this.taskId);

  final String taskId;
  final List<(TransferJournalRecord, String)> records = [];
  final Map<String, _RestoredItemMutable> entries = {};

  TransferTaskSpec? spec;
  DateTime? enqueuedAt;
  TransferTaskState? lastState;
  DateTime? lastStateAt;
  String? error;
  RemoteFileErrorKind? failureKind;
  bool scanComplete = false;
  int? totalBytes;
  int skippedSymlinks = 0;
  bool removed = false;

  /// Every `_LiveTask` carries at least the record that created it —
  /// an empty list is an invariant violation, not a wall-clock guess.
  DateTime get firstRecordAt => records.first.$1.at;

  /// A removed or terminal task migrates to history at compaction.
  bool get isFinished =>
      removed ||
      lastState == TransferTaskState.completed ||
      lastState == TransferTaskState.failed ||
      lastState == TransferTaskState.cancelled;

  /// A terminal taskState does not exit the journal until compaction —
  /// "terminal" for restore purposes is the same set.
  bool get isTerminal => isFinished;

  int get encodedBytes =>
      records.fold(0, (sum, record) => sum + utf8.encode(record.$2).length + 1);
}

class _RestoredItemMutable {
  _RestoredItemMutable({
    required this.itemId,
    required this.isDirectory,
    required this.sourcePath,
    required this.destinationPath,
    required this.containerKey,
    required this.name,
    required this.source,
    required this.existing,
    this.outcome,
    this.error,
    this.failureKind,
    this.resolvedPath,
    this.disposition,
  });

  final String itemId;
  final bool isDirectory;
  final String sourcePath;
  final String destinationPath;
  final String? containerKey;
  final String? name;
  final RemoteFileEntry? source;
  final DestinationStat? existing;
  RestoredItemOutcome? outcome;
  String? error;
  RemoteFileErrorKind? failureKind;
  String? resolvedPath;

  /// D15: the journaled per-item delete outcome (osTrash/remoteTrash/
  /// permanent) — carried so a restored task's items keep their
  /// trashed-vs-permanent record.
  ItemDisposition? disposition;
}

class _RecoveredLog<T> {
  const _RecoveredLog({
    required this.entries,
    this.tornBytes = 0,
    this.quarantinedTo,
    this.quarantinedRecords = 0,
  });

  /// The intact parsed prefix as (record, raw line) pairs — compaction
  /// rewrites raw lines verbatim so fields this build does not know
  /// survive the journal's own rewrite.
  final List<(T, String)> entries;
  final int tornBytes;
  final String? quarantinedTo;
  final int quarantinedRecords;
}
