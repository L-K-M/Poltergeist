/// The transfer queue's persistence contract (03 §4.6, D16).
///
/// Two append-only JSONL files under the app-provided support directory
/// (`EngineConfig`, 03 §5 — the field lands with the slice that wires the
/// queue into the engine host):
///
/// ```
/// <app-support>/transfer_queue.jsonl     journal of the live queue
/// <app-support>/transfer_history.jsonl   completed/failed task records
/// ```
///
/// Every record is a **versioned document**: a top-level `v` (schema
/// version, currently `1`) and a `type`. Decode is strict on both — a
/// record with an unknown type or a `v` this build does not understand
/// fails to parse, which routes the file through the quarantine path in
/// [FileTransferPersistence] rather than being silently misread. That is
/// the explicit forward/rollback contract: a newer build may add fields
/// (ignored on decode — additive changes stay readable) but must bump `v`
/// for any semantic change, and an older build that meets a `v` it cannot
/// parse quarantines instead of guessing. Rollback to a build older than
/// the schema therefore degrades to "starts empty with the evidence
/// preserved", never to silent corruption.
///
/// Record `type`s are the 03 §4.6 vocabulary: `taskEnqueued`,
/// `planEntry`, `scanComplete`, `taskState`, `fileCompleted`,
/// `fileFailed`, `itemRemoved`, `taskRemoved`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:seance_core/seance_core.dart';

import 'transfer_task.dart';

/// The journal file's basename inside the support directory (03 §4.6).
const String transferJournalFileName = 'transfer_queue.jsonl';

/// The history file's basename inside the support directory (03 §4.6).
const String transferHistoryFileName = 'transfer_history.jsonl';

/// The schema version every journal/history record carries in `v`. Bump
/// on any semantic change to a record shape; additive field additions do
/// not require a bump (decode ignores unknown fields).
const int transferJournalSchemaVersion = 1;

/// Default history retention (03 §4.6): the store rewrites the file once
/// it exceeds the limit by a 10 % slack margin, keeping the newest
/// [transferHistoryLimit] records.
const int transferHistoryLimit = 10000;

// ── Journal records ─────────────────────────────────────────────────────

/// One line in `transfer_queue.jsonl`. Immutable plain data — the queue
/// snapshots state into a record at the transition point, so the journal
/// order always matches the order effects took place in (the
/// write-before-effect rule: the record is submitted to the persistence
/// seam before the in-memory state mutation it describes).
sealed class TransferJournalRecord {
  TransferJournalRecord({required this.taskId, DateTime? at})
    : at = at ?? DateTime.now();

  /// The task this record belongs to — the replay and compaction keys.
  final String taskId;

  /// UTC timestamp of the transition, carried so crash-side compaction
  /// can build an honest history record (duration needs it).
  final DateTime at;

  /// The wire `type` string.
  String get type;

  Map<String, Object?> toJson();

  Map<String, Object?> _baseJson() => {
    'v': transferJournalSchemaVersion,
    'type': type,
    'taskId': taskId,
    'at': at.toUtc().toIso8601String(),
  };

  /// Strict decode of one journal line. Throws [FormatException] on
  /// anything that is not a well-formed v1 record of a known type — the
  /// caller routes that to quarantine, never to a partial read.
  static TransferJournalRecord parse(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      throw FormatException('journal line is not valid JSON');
    }
    if (decoded is! Map) {
      throw const FormatException('journal record is not an object');
    }
    final json = decoded.cast<String, Object?>();
    final v = json['v'];
    if (v != transferJournalSchemaVersion) {
      throw FormatException('unsupported journal schema version: $v');
    }
    final taskId = json['taskId'];
    if (taskId is! String || taskId.isEmpty) {
      throw const FormatException('journal record is missing taskId');
    }
    final at = _parseInstant(json['at']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final type = json['type'];
    switch (type) {
      case TaskEnqueuedRecord.wireType:
        return TaskEnqueuedRecord._fromJson(json, taskId, at);
      case PlanEntryRecord.wireType:
        return PlanEntryRecord._fromJson(json, taskId, at);
      case ScanCompleteRecord.wireType:
        return ScanCompleteRecord._fromJson(json, taskId, at);
      case TaskStateRecord.wireType:
        return TaskStateRecord._fromJson(json, taskId, at);
      case FileCompletedRecord.wireType:
        return FileCompletedRecord._fromJson(json, taskId, at);
      case FileFailedRecord.wireType:
        return FileFailedRecord._fromJson(json, taskId, at);
      case ItemRemovedRecord.wireType:
        return ItemRemovedRecord._fromJson(json, taskId, at);
      case TaskRemovedRecord.wireType:
        return TaskRemovedRecord._fromJson(json, taskId, at);
      default:
        throw FormatException('unknown journal record type: $type');
    }
  }
}

/// `taskEnqueued` — the full task spec (03 §4.6 journals this verbatim;
/// plan contents are runtime state carried by `planEntry` records).
final class TaskEnqueuedRecord extends TransferJournalRecord {
  TaskEnqueuedRecord({
    required super.taskId,
    required this.spec,
    required this.enqueuedAt,
    super.at,
  });

  static const wireType = 'taskEnqueued';

  final TransferTaskSpec spec;
  final DateTime enqueuedAt;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    ..._baseJson(),
    'enqueuedAt': enqueuedAt.toUtc().toIso8601String(),
    'spec': _specToJson(spec),
  };

  static TaskEnqueuedRecord _fromJson(
    Map<String, Object?> json,
    String taskId,
    DateTime at,
  ) {
    final specJson = json['spec'];
    final enqueuedAt = _parseInstant(json['enqueuedAt']);
    if (specJson is! Map || enqueuedAt == null) {
      throw const FormatException('malformed taskEnqueued record');
    }
    return TaskEnqueuedRecord(
      taskId: taskId,
      spec: _specFromJson(specJson.cast<String, Object?>()),
      enqueuedAt: enqueuedAt,
      at: at,
    );
  }
}

/// `planEntry` — one scanned directory or file, appended as the scan
/// produces it. Replay upserts keyed on `(taskId, itemId)` so a re-scan
/// that re-appends an entry collapses onto the journaled one (03 §4.6).
final class PlanEntryRecord extends TransferJournalRecord {
  PlanEntryRecord({
    required super.taskId,
    required this.itemId,
    required this.isDirectory,
    required this.sourcePath,
    required this.destinationPath,
    this.sourceType,
    this.sourceSize,
    this.sourceModifiedAt,
    this.sourceMode,
    this.name,
    this.containerKey,
    this.existing,
    super.at,
  });

  static const wireType = 'planEntry';

  /// The scan-minted uuid — the record's identity within the task (never
  /// the destination path; 03 §4.1/§4.6).
  final String itemId;
  final bool isDirectory;
  final String sourcePath;
  final String destinationPath;

  /// Source-entry detail needed to re-dispatch this item after a
  /// restart. Null on records written for scan-time terminal items that
  /// never become dispatchable (a failed root stat has no source entry).
  final RemoteFileType? sourceType;
  final int? sourceSize;
  final DateTime? sourceModifiedAt;
  final int? sourceMode;

  /// The leaf name the item occupies at the destination.
  final String? name;
  final String? containerKey;

  /// The destination stat at scan time — a UI hint, never trusted by the
  /// executor (03 §4.1).
  final DestinationStat? existing;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    ..._baseJson(),
    'itemId': itemId,
    'kind': isDirectory ? 'directory' : 'file',
    'sourcePath': sourcePath,
    'destinationPath': destinationPath,
    if (sourceType != null) 'sourceType': sourceType!.name,
    if (sourceSize != null) 'sourceSize': sourceSize,
    if (sourceModifiedAt != null)
      'sourceModifiedAt': sourceModifiedAt!.toUtc().toIso8601String(),
    if (sourceMode != null) 'sourceMode': sourceMode,
    if (name != null) 'name': name,
    if (containerKey != null) 'containerKey': containerKey,
    if (existing != null) 'existing': _statToJson(existing!),
  };

  static PlanEntryRecord _fromJson(
    Map<String, Object?> json,
    String taskId,
    DateTime at,
  ) {
    final itemId = json['itemId'];
    final kind = json['kind'];
    final sourcePath = json['sourcePath'];
    final destinationPath = json['destinationPath'];
    if (itemId is! String ||
        itemId.isEmpty ||
        kind is! String ||
        (kind != 'file' && kind != 'directory') ||
        sourcePath is! String ||
        destinationPath is! String) {
      throw const FormatException('malformed planEntry record');
    }
    final sourceSize = json['sourceSize'];
    final sourceMode = json['sourceMode'];
    final name = json['name'];
    final containerKey = json['containerKey'];
    if ((sourceSize != null && sourceSize is! int) ||
        (sourceMode != null && sourceMode is! int) ||
        (name != null && name is! String) ||
        (containerKey != null && containerKey is! String)) {
      throw const FormatException('malformed planEntry record');
    }
    return PlanEntryRecord(
      taskId: taskId,
      itemId: itemId,
      isDirectory: kind == 'directory',
      sourcePath: sourcePath,
      destinationPath: destinationPath,
      sourceType: _parseFileType(json['sourceType']),
      sourceSize: sourceSize as int?,
      sourceModifiedAt: _parseInstant(json['sourceModifiedAt']),
      sourceMode: sourceMode as int?,
      name: name as String?,
      containerKey: containerKey as String?,
      existing: _statFromJson(json['existing']),
      at: at,
    );
  }
}

/// `scanComplete` — the source walk finished; [totalBytes] is final.
/// Without this record a restored task re-scans on resume (03 §4.6's
/// mid-scan crash rule).
final class ScanCompleteRecord extends TransferJournalRecord {
  ScanCompleteRecord({
    required super.taskId,
    required this.totalBytes,
    required this.skippedSymlinks,
    super.at,
  });

  static const wireType = 'scanComplete';

  final int totalBytes;
  final int skippedSymlinks;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    ..._baseJson(),
    'totalBytes': totalBytes,
    'skippedSymlinks': skippedSymlinks,
  };

  static ScanCompleteRecord _fromJson(
    Map<String, Object?> json,
    String taskId,
    DateTime at,
  ) {
    final totalBytes = json['totalBytes'];
    final skippedSymlinks = json['skippedSymlinks'];
    if (totalBytes is! int || skippedSymlinks is! int) {
      throw const FormatException('malformed scanComplete record');
    }
    return ScanCompleteRecord(
      taskId: taskId,
      totalBytes: totalBytes,
      skippedSymlinks: skippedSymlinks,
      at: at,
    );
  }
}

/// `taskState` — a lifecycle transition (queued/scanning/running/paused
/// and the terminal trio). On replay a `paused` survives restart;
/// `running`/`scanning` map to `queued`; a terminal state migrates the
/// task to history (03 §4.6).
final class TaskStateRecord extends TransferJournalRecord {
  TaskStateRecord({
    required super.taskId,
    required this.state,
    this.error,
    this.failureKind,
    super.at,
  });

  static const wireType = 'taskState';

  final TransferTaskState state;
  final String? error;
  final RemoteFileErrorKind? failureKind;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    ..._baseJson(),
    'state': state.name,
    if (error != null) 'error': error,
    if (failureKind != null) 'failureKind': failureKind!.name,
  };

  static TaskStateRecord _fromJson(
    Map<String, Object?> json,
    String taskId,
    DateTime at,
  ) {
    final error = json['error'];
    if (error != null && error is! String) {
      throw const FormatException('malformed taskState record');
    }
    return TaskStateRecord(
      taskId: taskId,
      state: _parseTaskState(json['state']),
      error: error as String?,
      failureKind: _parseErrorKind(json['failureKind']),
      at: at,
    );
  }
}

/// `fileCompleted` — a file reached its committed destination. Also used
/// for a directory whose mkdir resolved (`resolvedPath` carries the
/// keep-both-renamed path so restored children dispatch into it).
final class FileCompletedRecord extends TransferJournalRecord {
  FileCompletedRecord({
    required super.taskId,
    required this.itemId,
    this.resolvedPath,
    super.at,
  });

  static const wireType = 'fileCompleted';

  final String itemId;

  /// The path the item actually committed to, when the conflict decision
  /// relocated it (keep-both numbering). Null when it is the planned path.
  final String? resolvedPath;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    ..._baseJson(),
    'itemId': itemId,
    if (resolvedPath != null) 'resolvedPath': resolvedPath,
  };

  static FileCompletedRecord _fromJson(
    Map<String, Object?> json,
    String taskId,
    DateTime at,
  ) => FileCompletedRecord(
    taskId: taskId,
    itemId: _itemId(json),
    resolvedPath: _optionalString(json['resolvedPath'], 'fileCompleted'),
    at: at,
  );
}

/// `fileFailed` — the item's terminal failure, with the error text the
/// user saw (03 §4.6: a watched failure must not resurrect on resume).
final class FileFailedRecord extends TransferJournalRecord {
  FileFailedRecord({
    required super.taskId,
    required this.itemId,
    this.error,
    this.failureKind,
    super.at,
  });

  static const wireType = 'fileFailed';

  final String itemId;
  final String? error;
  final RemoteFileErrorKind? failureKind;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    ..._baseJson(),
    'itemId': itemId,
    if (error != null) 'error': error,
    if (failureKind != null) 'failureKind': failureKind!.name,
  };

  static FileFailedRecord _fromJson(
    Map<String, Object?> json,
    String taskId,
    DateTime at,
  ) {
    final error = json['error'];
    if (error != null && error is! String) {
      throw const FormatException('malformed fileFailed record');
    }
    return FileFailedRecord(
      taskId: taskId,
      itemId: _itemId(json),
      error: error as String?,
      failureKind: _parseErrorKind(json['failureKind']),
      at: at,
    );
  }
}

/// `itemRemoved` — a per-item cancel or skip (03 §4.4). A deliberately
/// removed item must not resurrect on resume.
final class ItemRemovedRecord extends TransferJournalRecord {
  ItemRemovedRecord({
    required super.taskId,
    required this.itemId,
    this.error,
    super.at,
  });

  static const wireType = 'itemRemoved';

  final String itemId;
  final String? error;

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    ..._baseJson(),
    'itemId': itemId,
    if (error != null) 'error': error,
  };

  static ItemRemovedRecord _fromJson(
    Map<String, Object?> json,
    String taskId,
    DateTime at,
  ) {
    final error = json['error'];
    if (error != null && error is! String) {
      throw const FormatException('malformed itemRemoved record');
    }
    return ItemRemovedRecord(
      taskId: taskId,
      itemId: _itemId(json),
      error: error as String?,
      at: at,
    );
  }
}

/// `taskRemoved` — the row left the queue listing (the activity panel's
/// clear-finished gesture). Replay drops the task's records entirely.
final class TaskRemovedRecord extends TransferJournalRecord {
  TaskRemovedRecord({required super.taskId, super.at});

  static const wireType = 'taskRemoved';

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => _baseJson();

  static TaskRemovedRecord _fromJson(
    Map<String, Object?> json,
    String taskId,
    DateTime at,
  ) => TaskRemovedRecord(taskId: taskId, at: at);
}

// ── History records ─────────────────────────────────────────────────────

/// One record in `transfer_history.jsonl` — the summary the activity
/// panel's History tab renders (03 §4.6): endpoints, root names, byte and
/// item counts, duration, outcome, failure kind.
final class TransferHistoryEntry {
  TransferHistoryEntry({
    required this.taskId,
    required this.source,
    required this.destination,
    required this.rootPaths,
    required this.destinationDir,
    required this.operation,
    required this.outcome,
    required this.startedAt,
    required this.finishedAt,
    required this.completedFiles,
    required this.failedItems,
    required this.skippedItems,
    required this.transferredBytes,
    required this.totalBytes,
    this.error,
    this.failureKind,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  static const wireType = 'transferHistory';

  final String taskId;
  final FsLocation source;
  final FsLocation destination;
  final List<String> rootPaths;
  final String destinationDir;
  final TransferOperation operation;

  /// The terminal task state: completed / failed / cancelled.
  final TransferTaskState outcome;
  final DateTime startedAt;
  final DateTime finishedAt;

  /// UTC timestamp the record was appended (diagnostics only).
  final DateTime at;
  final int completedFiles;
  final int failedItems;
  final int skippedItems;
  final int transferredBytes;

  /// Final planned bytes; null while a task that never finished scanning
  /// is recorded (cancel/fail mid-scan leaves totals partial).
  final int? totalBytes;
  final String? error;
  final RemoteFileErrorKind? failureKind;

  /// The queue-facing builder: snapshots the task at its terminal moment.
  factory TransferHistoryEntry.fromTask(TransferTask task) =>
      TransferHistoryEntry(
        taskId: task.id,
        source: task.source,
        destination: task.destination,
        rootPaths: List.of(task.rootPaths),
        destinationDir: task.destinationDir,
        operation: task.operation,
        outcome: task.state,
        startedAt: task.startedAt ?? task.enqueuedAt,
        finishedAt: task.finishedAt ?? DateTime.now(),
        completedFiles: task.completedFiles,
        failedItems: task.failedItems,
        skippedItems: task.skippedItems,
        transferredBytes: task.transferredBytes,
        totalBytes: task.totalBytes,
        error: task.error,
        failureKind: task.failureKind,
      );

  Duration get duration => finishedAt.difference(startedAt);

  Map<String, Object?> toJson() => {
    'v': transferJournalSchemaVersion,
    'type': wireType,
    'taskId': taskId,
    'at': at.toUtc().toIso8601String(),
    'source': _locationToJson(source),
    'destination': _locationToJson(destination),
    'rootPaths': rootPaths,
    'destinationDir': destinationDir,
    'operation': operation.name,
    'outcome': outcome.name,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'finishedAt': finishedAt.toUtc().toIso8601String(),
    'completedFiles': completedFiles,
    'failedItems': failedItems,
    'skippedItems': skippedItems,
    'transferredBytes': transferredBytes,
    'totalBytes': totalBytes,
    if (error != null) 'error': error,
    if (failureKind != null) 'failureKind': failureKind!.name,
  };

  /// Strict decode — the same contract as [TransferJournalRecord.parse].
  static TransferHistoryEntry parse(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      throw const FormatException('history line is not valid JSON');
    }
    if (decoded is! Map) {
      throw const FormatException('history record is not an object');
    }
    final json = decoded.cast<String, Object?>();
    if (json['v'] != transferJournalSchemaVersion) {
      throw FormatException('unsupported history schema version: '
          '${json['v']}');
    }
    if (json['type'] != wireType) {
      throw FormatException('unknown history record type: ${json['type']}');
    }
    final taskId = json['taskId'];
    final rootPaths = json['rootPaths'];
    final destinationDir = json['destinationDir'];
    final completedFiles = json['completedFiles'];
    final failedItems = json['failedItems'];
    final skippedItems = json['skippedItems'];
    final transferredBytes = json['transferredBytes'];
    final totalBytes = json['totalBytes'];
    final startedAt = _parseInstant(json['startedAt']);
    final finishedAt = _parseInstant(json['finishedAt']);
    final error = json['error'];
    if (taskId is! String ||
        taskId.isEmpty ||
        rootPaths is! List ||
        rootPaths.any((e) => e is! String) ||
        destinationDir is! String ||
        completedFiles is! int ||
        failedItems is! int ||
        skippedItems is! int ||
        transferredBytes is! int ||
        (totalBytes != null && totalBytes is! int) ||
        startedAt == null ||
        finishedAt == null ||
        (error != null && error is! String)) {
      throw const FormatException('malformed history record');
    }
    return TransferHistoryEntry(
      taskId: taskId,
      source: _locationFromJson(json['source']),
      destination: _locationFromJson(json['destination']),
      rootPaths: [for (final root in rootPaths) root as String],
      destinationDir: destinationDir,
      operation: _parseOperation(json['operation']),
      outcome: _parseTaskState(json['outcome']),
      startedAt: startedAt,
      finishedAt: finishedAt,
      completedFiles: completedFiles,
      failedItems: failedItems,
      skippedItems: skippedItems,
      transferredBytes: transferredBytes,
      totalBytes: totalBytes as int?,
      error: error as String?,
      failureKind: _parseErrorKind(json['failureKind']),
      at: _parseInstant(json['at']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

// ── Replay model ────────────────────────────────────────────────────────

/// How one journaled plan item ended before the crash — the outcome a
/// restored task applies instead of re-dispatching (03 §4.6: a file the
/// user watched fail or deliberately removed must not resurrect).
enum RestoredItemOutcome { completed, failed, removed }

/// One journaled plan item as replay rebuilt it — the union of its
/// `planEntry` record and any terminal outcome record.
final class RestoredPlanItem {
  RestoredPlanItem({
    required this.itemId,
    required this.isDirectory,
    required this.sourcePath,
    required this.destinationPath,
    required this.containerKey,
    required this.name,
    required this.source,
    required this.existing,
    required this.outcome,
    required this.error,
    required this.failureKind,
    required this.resolvedPath,
  });

  final String itemId;
  final bool isDirectory;
  final String sourcePath;
  final String destinationPath;
  final String? containerKey;
  final String? name;

  /// The reconstructed source entry; null when the journaled entry
  /// carried no source detail (a scan-time terminal record — such an
  /// item is only restorable in a terminal state).
  final RemoteFileEntry? source;
  final DestinationStat? existing;

  /// The journaled terminal outcome, or null when the item was still in
  /// flight/pending at the crash — it re-dispatches on resume.
  final RestoredItemOutcome? outcome;
  final String? error;
  final RemoteFileErrorKind? failureKind;

  /// The committed path when keep-both relocated the item.
  final String? resolvedPath;
}

/// One non-terminal task reconstructed from the journal.
final class RestoredTransferTask {
  RestoredTransferTask({
    required this.taskId,
    required this.spec,
    required this.enqueuedAt,
    required this.wasPaused,
    required this.scanComplete,
    required this.totalBytes,
    required this.skippedSymlinks,
    required this.items,
    required this.sweepDirectories,
  });

  final String taskId;
  final TransferTaskSpec spec;
  final DateTime enqueuedAt;

  /// The journaled `paused` state survives restart (03 §4.6); any other
  /// live state (queued/scanning/running) restores as `queued`.
  final bool wasPaused;

  /// False means the task crashed mid-scan and re-scans on resume,
  /// merging its journaled terminal outcomes by destination path.
  final bool scanComplete;
  final int? totalBytes;
  final int skippedSymlinks;

  /// Journaled plan items in append order (terminal and pending alike).
  final List<RestoredPlanItem> items;

  /// Destination directories the journal names — the scope of the
  /// crash-orphaned `.poltergeist-*` temp sweep (03 §4.6). Computed at
  /// replay from every journaled item's destination plus the task's
  /// destinationDir.
  final Set<String> sweepDirectories;
}

/// What recovery found while opening the store — the counts the UI banner
/// and logs surface (03 §4.6's no-silent-drop rule).
final class TransferJournalReplay {
  TransferJournalReplay({
    required this.tasks,
    this.tornJournalBytes = 0,
    this.quarantinedJournalPath,
    this.quarantinedJournalRecords = 0,
    this.tornHistoryBytes = 0,
    this.quarantinedHistoryPath,
    this.quarantinedHistoryRecords = 0,
  });

  /// Non-terminal tasks to restore into the queue (empty journal → none).
  final List<RestoredTransferTask> tasks;

  /// Bytes dropped from a torn journal tail (a crash mid-append).
  final int tornJournalBytes;

  /// Where a corrupt journal was quarantined, and how many complete
  /// records after the malformed line survive only in that copy.
  final String? quarantinedJournalPath;
  final int quarantinedJournalRecords;

  final int tornHistoryBytes;
  final String? quarantinedHistoryPath;
  final int quarantinedHistoryRecords;
}

// ── The seam ────────────────────────────────────────────────────────────

/// The queue's persistence seam (03 §4.6). Injectable: a null
/// [TransferQueue] persistence keeps the #147 in-memory behavior exactly;
/// [FileTransferPersistence] is the production store.
///
/// The `append*` calls are synchronous enqueues onto the store's single
/// writer — the queue invokes them *before* the in-memory transition they
/// describe takes effect (write-before-effect ordering) and never awaits
/// them: the hot path is buffered, fsync rides a bounded interval
/// (~64 records / ~250 ms, always fsynced before a history record lands).
/// Ordering, durability, and failure reporting are the implementation's
/// problem; a persistence failure degrades to the disabled mode with a
/// notice, never to a queue crash.
abstract interface class TransferPersistence {
  /// What recovery found at open — the task set [TransferQueue.restore]
  /// adopts plus the corruption accounting the UI surfaces.
  TransferJournalReplay get replay;

  /// Append one journal record. Ordered before the effect it describes.
  void appendJournal(TransferJournalRecord record);

  /// Append one finished-task history record. The implementation fsyncs
  /// the journal first so a crash never shows a completed task whose
  /// journal records were lost (03 §4.6's ordering rule).
  void appendHistory(TransferHistoryEntry entry);

  /// Clean shutdown: flush, fsync, and run the clean-shutdown compaction
  /// (finished tasks migrate to history; the journal rewrites to the
  /// pending set). The queue calls this from `dispose`.
  Future<void> shutdown();
}

// ── Codec helpers ───────────────────────────────────────────────────────

Map<String, Object?> _locationToJson(FsLocation location) =>
    switch (location) {
      ServerFsLocation(:final serverId) => {
        'kind': 'server',
        'serverId': serverId,
      },
      LocalFsLocation() => {'kind': 'local'},
    };

FsLocation _locationFromJson(Object? json) {
  if (json is! Map) {
    throw const FormatException('malformed endpoint');
  }
  switch (json['kind']) {
    case 'local':
      return const LocalFsLocation();
    case 'server':
      final serverId = json['serverId'];
      if (serverId is! String || serverId.isEmpty) {
        throw const FormatException('server endpoint is missing serverId');
      }
      return ServerFsLocation(serverId);
    default:
      throw FormatException('unknown endpoint kind: ${json['kind']}');
  }
}

Map<String, Object?> _specToJson(TransferTaskSpec spec) => {
  'source': _locationToJson(spec.source),
  'destination': _locationToJson(spec.destination),
  'rootPaths': spec.rootPaths,
  'destinationDir': spec.destinationDir,
  'files': spec.policy.files.name,
  'folders': spec.policy.folders.name,
  'operation': spec.operation.name,
};

TransferTaskSpec _specFromJson(Map<String, Object?> json) {
  final rootPaths = json['rootPaths'];
  final destinationDir = json['destinationDir'];
  if (rootPaths is! List ||
      rootPaths.any((e) => e is! String) ||
      destinationDir is! String) {
    throw const FormatException('malformed task spec');
  }
  return TransferTaskSpec(
    source: _locationFromJson(json['source']),
    destination: _locationFromJson(json['destination']),
    rootPaths: [for (final root in rootPaths) root as String],
    destinationDir: destinationDir,
    policy: ResolvedConflictPolicy(
      files: _parseConflictResolution(json['files']),
      folders: _parseConflictResolution(json['folders']),
    ),
    operation: _parseOperation(json['operation']),
  );
}

Map<String, Object?> _statToJson(DestinationStat stat) => {
  'type': stat.type.name,
  if (stat.size != null) 'size': stat.size,
  if (stat.modifiedAt != null)
    'modifiedAt': stat.modifiedAt!.toUtc().toIso8601String(),
};

DestinationStat? _statFromJson(Object? json) {
  if (json == null) return null;
  if (json is! Map) {
    throw const FormatException('malformed destination stat');
  }
  final size = json['size'];
  if (size != null && size is! int) {
    throw const FormatException('malformed destination stat');
  }
  return DestinationStat(
    type: _parseFileType(json['type']) ?? RemoteFileType.other,
    size: size as int?,
    modifiedAt: _parseInstant(json['modifiedAt']),
  );
}

String _itemId(Map<String, Object?> json) {
  final itemId = json['itemId'];
  if (itemId is! String || itemId.isEmpty) {
    throw const FormatException('journal record is missing itemId');
  }
  return itemId;
}

String? _optionalString(Object? value, String record) {
  if (value != null && value is! String) {
    throw FormatException('malformed $record record');
  }
  return value as String?;
}

DateTime? _parseInstant(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}

RemoteFileType? _parseFileType(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const FormatException('malformed file type');
  }
  for (final type in RemoteFileType.values) {
    if (type.name == value) return type;
  }
  throw FormatException('unknown file type: $value');
}

TransferTaskState _parseTaskState(Object? value) {
  if (value is String) {
    for (final state in TransferTaskState.values) {
      if (state.name == value) return state;
    }
  }
  throw FormatException('unknown task state: $value');
}

ConflictResolution _parseConflictResolution(Object? value) {
  if (value is String) {
    for (final resolution in ConflictResolution.values) {
      if (resolution.name == value) return resolution;
    }
  }
  throw FormatException('unknown conflict resolution: $value');
}

TransferOperation _parseOperation(Object? value) {
  if (value is String) {
    for (final operation in TransferOperation.values) {
      if (operation.name == value) return operation;
    }
  }
  throw FormatException('unknown transfer operation: $value');
}

RemoteFileErrorKind? _parseErrorKind(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const FormatException('malformed failure kind');
  }
  for (final kind in RemoteFileErrorKind.values) {
    if (kind.name == value) return kind;
  }
  throw FormatException('unknown failure kind: $value');
}

// ── File primitives (the fault-injection seam) ──────────────────────────

/// The store's file primitives, isolated so tests can count fsyncs,
/// gate rewrites, and inject failures without touching the queue.
/// Subclass and override to script faults.
class TransferJournalIo {
  const TransferJournalIo();

  /// Append one complete line (OS-level flush — survives process death;
  /// fsync rides the store's bounded interval). A fresh open per append
  /// is deliberate: the handle can never point at an inode a rewrite
  /// already replaced (03 §4.6's stale-handle hazard).
  Future<void> appendLine(File file, String line) async {
    await file.parent.create(recursive: true);
    await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  /// fsync — `RandomAccessFile.flush` forces the file's data and metadata
  /// to storage.
  Future<void> fsyncFile(File file) async {
    final raf = await file.open(mode: FileMode.append);
    try {
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  /// Directory fsync after a mutate-the-directory operation (truncate,
  /// rename) — the rename/truncate itself is only power-loss-durable once
  /// the directory entry is flushed (03 §4.6). POSIX-only in practice:
  /// dart:io cannot open a directory handle on Windows, so a failure here
  /// is absorbed — the platform simply lacks the primitive through this
  /// API, not the discipline.
  Future<void> fsyncDirectory(Directory directory) async {
    try {
      final raf = await File(directory.path).open();
      try {
        await raf.flush();
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      // No directory handle on this platform — nothing to fsync.
    }
  }

  /// Truncate [file] to [length] bytes (the torn-tail repair).
  Future<void> truncateTo(File file, int length) async {
    final raf = await file.open(mode: FileMode.writeOnlyAppend);
    try {
      await raf.truncate(length);
      await raf.flush();
    } finally {
      await raf.close();
    }
    await fsyncDirectory(file.parent);
  }

  /// Atomic replacement (the #110 pattern, hardened per 03 §4.6): an
  /// exclusively-created sibling temp is written, fsynced, renamed over
  /// the target, and the containing directory fsynced so the rename
  /// itself survives power loss.
  Future<void> atomicRewrite(File file, String contents) async {
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.tmp-${_randomHexSuffix()}',
    );
    try {
      final raf = await temporary.open(mode: FileMode.writeOnly);
      try {
        await raf.writeString(contents);
        await raf.flush();
      } finally {
        await raf.close();
      }
      await temporary.rename(file.path);
      await fsyncDirectory(file.parent);
    } on Object {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on Object {
        // The original failure is the actionable error.
      }
      rethrow;
    }
  }

  /// Crash debris from [atomicRewrite]: `<name>.tmp-<hex>` siblings older
  /// than one hour are abandoned (the incident store's sweep rule — a
  /// younger temp may belong to a writer in flight).
  Future<void> sweepAbandonedTemps(File target) async {
    final prefix = '${p.basename(target.path)}.tmp-';
    final abandonedBefore = DateTime.now().subtract(
      const Duration(hours: 1),
    );
    try {
      final parent = target.parent;
      if (!await parent.exists()) return;
      await for (final entry in parent.list(followLinks: false)) {
        if (entry is! File) continue;
        if (!p.basename(entry.path).startsWith(prefix)) continue;
        final DateTime modified;
        try {
          modified = await entry.lastModified();
        } on Object {
          continue;
        }
        if (modified.isAfter(abandonedBefore)) continue;
        try {
          await entry.delete();
        } on Object {
          // Retried next startup.
        }
      }
    } on Object {
      // The sweep is hygiene; the open must still proceed.
    }
  }
}

String _randomHexSuffix() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(random.nextInt(16).toRadixString(16));
  }
  return buffer.toString();
}
