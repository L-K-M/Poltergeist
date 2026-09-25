import 'dart:async';
import 'dart:collection' show LinkedHashMap;
import 'dart:io' show Directory;
import 'dart:ui' show Color, Offset;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';

import 'app_transfer_queue.dart';
import 'drag_out_producer.dart';
import 'os_drag_out.dart';
import 'pane_drop.dart';
import 'pane_permissions.dart' show nameIsFlagged;

/// How [DragOutController.handOff] ended; the pane acts on it.
enum DragOutHandOff {
  /// A native session is running: the pane ends its Flutter drag.
  started,

  /// Remote rows on a platform without promises: the pane shows the
  /// "use Download To…" hint and the drag continues in-app.
  remoteUnsupported,

  /// Nothing the OS could carry (no backend, only flagged or linked
  /// remote names): the drag continues in-app. When rows were left out,
  /// the result's [DragOutHandOffResult.leftOut] says which kinds.
  unavailable,

  /// The native side refused (button already up, no recorded press):
  /// the drag continues in-app.
  notStarted,
}

/// The dragged rows a hand-off could not offer the OS, by reason. The
/// pane's notice says how many stayed behind and why, so no row is left
/// out silently (00 D14's drag-out amendment).
@immutable
final class DragOutLeftOut {
  const DragOutLeftOut({
    this.links = 0,
    this.flaggedNames = 0,
    this.unlisted = 0,
  });

  static const none = DragOutLeftOut();

  /// Symbolic links: never transferred (the queue's own rule).
  final int links;

  /// Names flagged unsafe (02 §13): no local file name can be built
  /// from them.
  final int flaggedNames;

  /// Roots the payload holds no listing entry for, so neither name nor
  /// type is known. A pane row drag always snapshots its entries; this
  /// only keeps the count honest.
  final int unlisted;

  int get count => links + flaggedNames + unlisted;

  bool get isEmpty => count == 0;
}

/// [DragOutController.handOff]'s answer.
@immutable
final class DragOutHandOffResult {
  const DragOutHandOffResult(
    this.outcome, {
    this.leftOut = DragOutLeftOut.none,
  });

  /// What the pane does next.
  final DragOutHandOff outcome;

  /// The rows the OS was not offered: for [DragOutHandOff.started], the
  /// ones the session does not carry; for [DragOutHandOff.unavailable],
  /// why nothing could go. Empty otherwise, since the in-app drag still
  /// carries every row.
  final DragOutLeftOut leftOut;
}

/// A drag-out stop that no queue task reports as a failure, shown in
/// the Alerts tab: a refusal before any transfer ran, or a pause that
/// cancelled the download midway. A failed produce or folder download
/// needs none: its failed Transfers row already raises
/// `TransferFailedAlert`.
enum DragOutNoticeKind {
  /// A folder promise arrived while the transfer queue was paused.
  paused,

  /// A pause stopped a promise's download midway: the queue pause
  /// (folder downloads; file hops are exempt from it) or a Pause on the
  /// task's own Transfers row (either kind). The task was cancelled so
  /// nothing lands after the drop gave up.
  pausedMidway,

  /// The drop asked for a different folder name than the folder's own.
  renamed,

  /// Nothing can produce remote items (no queue composed).
  unavailable,
}

/// One Alerts-tab row's data; the view localizes it.
@immutable
final class DragOutNotice {
  const DragOutNotice({
    required this.id,
    required this.kind,
    required this.itemName,
    required this.destinationDir,
  });

  /// Stable per notice, for the alert key.
  final String id;
  final DragOutNoticeKind kind;

  /// The remote item's name.
  final String itemName;

  /// The folder the item was dropped on.
  final String destinationDir;
}

/// The colors the drag image paints with (the pane's theme at the edge).
@immutable
final class DragOutImagePalette {
  const DragOutImagePalette({
    required this.background,
    required this.foreground,
    required this.badge,
    required this.onBadge,
  });

  final Color background;
  final Color foreground;
  final Color badge;
  final Color onBadge;
}

/// What the pane knows about how the image should look.
@immutable
final class DragOutImageStyle {
  const DragOutImageStyle({
    required this.palette,
    required this.devicePixelRatio,
    required this.itemCountLabel,
  });

  final DragOutImagePalette palette;
  final double devicePixelRatio;

  /// The localized "N items" label (`dropItemCount`).
  final String Function(int count) itemCountLabel;
}

/// The renderer's input: one image per session.
@immutable
final class DragOutImageSpec {
  const DragOutImageSpec({
    required this.label,
    required this.count,
    required this.isDirectory,
    required this.palette,
    required this.devicePixelRatio,
  });

  /// The item's name, or "N items".
  final String label;
  final int count;

  /// Whether the first item is a folder (the glyph).
  final bool isDirectory;
  final DragOutImagePalette palette;
  final double devicePixelRatio;
}

/// Renders the native session's drag image; null when it cannot.
typedef DragOutImageRenderer =
    Future<DragOutImage?> Function(DragOutImageSpec spec);

/// OS drag-out's Dart half (00 D14, 2026-09-25 amendment): starts native
/// sessions for pane rows whose drag left the window, fulfils remote
/// file promises through the transfer queue, and recognizes its own
/// drags when they come back into the window through `desktop_drop`.
///
/// Promise fulfilment:
///
/// * A remote **file** is one exclusive produce hop into the path the
///   OS gave ([DragOutProducer]): a Transfers row with progress and
///   Cancel, exempt from the queue pause like every produce, never
///   replacing a file already there (`exists`). A Pause on that row
///   cancels the hop and fails the promise with an Alert: a paused hop
///   would park until a resume, and the OS would wait on it.
/// * A remote **folder** is an ordinary recursive download task into the
///   promised path's parent, conflict-aware and journaled, awaited to
///   its terminal state. It does NOT bypass the queue pause: a paused
///   queue fails the promise at once (and a pause mid-download cancels
///   the task) with an Alert, so the OS never waits on a pause nobody
///   may lift. A Pause on the task's own row does the same. It also
///   needs the promised name to be the folder's own (the queue lands
///   each root under its basename); a receiver that renames fails with
///   an Alert rather than landing elsewhere.
/// * A promise whose destination is `desktop_drop`'s staging folder is
///   the drag coming back into Poltergeist: it fails fast (`ownDrop`)
///   and the pane routes the drop in-app from the stored payload.
///
/// Cancelling in the OS cancels the task; a failed task fails the
/// promise and keeps its failed Transfers row (and so its Alert).
class DragOutController extends ChangeNotifier
    implements DragOutBackendDelegate {
  DragOutController({
    required DragOutBackend backend,
    this._files,
    this._queue,
    ConflictPolicy Function()? conflictPolicy,
    this.renderImage,
    String? dropStagingDirectory,
    DateTime Function()? clock,
    this.echoGrace = const Duration(seconds: 3),
    this.sessionRetention = const Duration(minutes: 5),
    this.pausePollInterval = const Duration(milliseconds: 500),
    this.progressInterval = const Duration(milliseconds: 150),
  }) : _backend = backend,
       _conflictPolicy = conflictPolicy ?? ConflictPolicy.new,
       _dropStagingDirectory =
           dropStagingDirectory ?? desktopDropStagingDirectory(),
       _clock = clock ?? DateTime.now {
    backend.delegate = this;
  }

  final DragOutBackend _backend;
  DragOutProducer? _files;
  AppTransferQueue? _queue;
  final ConflictPolicy Function() _conflictPolicy;
  final String _dropStagingDirectory;
  final DateTime Function() _clock;

  /// Paints the native drag image; null sends none (the native side
  /// then uses its own, e.g. the file icons on macOS).
  final DragOutImageRenderer? renderImage;

  /// How long after a session ends a drop into the window still counts
  /// as its echo (macOS reports the session's end before
  /// `desktop_drop` delivers the drop).
  final Duration echoGrace;

  /// How long an ended session's promises stay answerable.
  final Duration sessionRetention;

  /// How often a folder promise checks the queue pause and reports
  /// progress.
  final Duration pausePollInterval;

  /// The minimum gap between progress reports for one promise.
  final Duration progressInterval;

  static const int _maxSessions = 16;
  static const int _maxNotices = 8;

  final LinkedHashMap<String, _Session> _sessions = LinkedHashMap();
  final List<DragOutNotice> _notices = [];
  int _sequence = 0;
  bool _disposed = false;

  /// Rebinds the remote-file seam (a later-arriving queue session).
  set files(DragOutProducer? value) => _files = value;

  /// Rebinds the queue folder promises ride.
  set queue(AppTransferQueue? value) => _queue = value;

  /// What a hand-off can carry here: promises need both the produce
  /// seam (files) and the queue (folders).
  DragOutSupport get support {
    final native = _backend.support;
    if (native == DragOutSupport.localFilesAndPromises &&
        (_files == null || _queue == null)) {
      return DragOutSupport.localFiles;
    }
    return native;
  }

  /// The Alerts tab's drag-out rows, oldest first (bounded).
  List<DragOutNotice> get notices => List.unmodifiable(_notices);

  /// The payload of a native session that is still running: while it
  /// hovers the window, the pane labels the drop with the in-app verb
  /// rules instead of the OS-drop copy.
  PaneEntryDrag? get activeEchoPayload {
    for (final session in _sessions.values.toList().reversed) {
      if (session.running) return session.payload;
    }
    return null;
  }

  /// Hands [drag] to a native session at [position] (the pointer,
  /// already outside the window). Resolves once the native side
  /// answered; see [DragOutHandOff] for what the pane does next.
  Future<DragOutHandOffResult> handOff(
    PaneEntryDrag drag, {
    required Offset position,
    required DragOutImageStyle style,
  }) async {
    const unavailable = DragOutHandOffResult(DragOutHandOff.unavailable);
    if (_disposed || support == DragOutSupport.none) return unavailable;
    final items = <DragOutItem>[];
    final promises = <String, _Promise>{};
    var leftOut = DragOutLeftOut.none;
    switch (drag.source) {
      case LocalFsLocation():
        for (final path in drag.rootPaths) {
          final entry = drag.entryFor(path);
          items.add(
            LocalDragOutItem(
              path: path,
              name: entry?.name ?? p.basename(path),
              isDirectory: entry?.type == RemoteFileType.directory,
            ),
          );
        }
      case ServerFsLocation(:final serverId):
        if (support != DragOutSupport.localFilesAndPromises) {
          return const DragOutHandOffResult(DragOutHandOff.remoteUnsupported);
        }
        var links = 0;
        var flaggedNames = 0;
        var unlisted = 0;
        for (final path in drag.rootPaths) {
          final entry = drag.entryFor(path);
          // A promise needs the listing's name and type. Links are never
          // transferred (the queue's own rule), and flagged names cannot
          // become local names, so neither is offered; the result counts
          // them for the pane's notice.
          if (entry == null) {
            unlisted++;
            continue;
          }
          if (entry.type == RemoteFileType.symbolicLink) {
            links++;
            continue;
          }
          if (nameIsFlagged(entry.name)) {
            flaggedNames++;
            continue;
          }
          final promise = _Promise(
            id: 'p${promises.length + 1}',
            serverId: serverId,
            remotePath: path,
            name: entry.name,
            isDirectory: entry.type == RemoteFileType.directory,
            size: entry.type == RemoteFileType.directory ? null : entry.size,
          );
          promises[promise.id] = promise;
          items.add(
            PromisedDragOutItem(
              promiseId: promise.id,
              name: promise.name,
              isDirectory: promise.isDirectory,
              size: promise.size,
            ),
          );
        }
        leftOut = DragOutLeftOut(
          links: links,
          flaggedNames: flaggedNames,
          unlisted: unlisted,
        );
    }
    if (items.isEmpty) {
      return DragOutHandOffResult(DragOutHandOff.unavailable, leftOut: leftOut);
    }

    // The OS runs one drag at a time: a session still marked running
    // lost its end report, and must not keep claiming hovers and drops.
    final now = _clock();
    for (final stale in _sessions.values) {
      if (!stale.running) continue;
      stale
        ..running = false
        ..endedAt = now;
    }
    final session = _Session(
      id: 'dragout-${++_sequence}',
      payload: drag,
      items: items,
      promises: promises,
    );
    _sessions[session.id] = session;
    _prune();

    DragOutImage? image;
    try {
      image = await renderImage?.call(
        DragOutImageSpec(
          label: items.length == 1
              ? items.first.name
              : style.itemCountLabel(items.length),
          count: items.length,
          isDirectory: items.first.isDirectory,
          palette: style.palette,
          devicePixelRatio: style.devicePixelRatio,
        ),
      );
    } on Object {
      // A drag image is decoration; the session still starts without.
      image = null;
    }
    if (_disposed) return unavailable;

    final result = await _backend.startDrag(
      DragOutRequest(
        sessionId: session.id,
        items: items,
        position: position,
        // Local items: the destination picks copy or link, never move
        // (no trash may take the source; see DragOutOffer). Remote
        // promises can only ever be copies.
        allowedOperations: promises.isEmpty
            ? const {DragOutOffer.copy, DragOutOffer.link}
            : const {DragOutOffer.copy},
        image: image,
      ),
    );
    if (result is! DragOutStarted || _disposed) {
      _sessions.remove(session.id);
      return const DragOutHandOffResult(DragOutHandOff.notStarted);
    }
    session.running = true;
    notifyListeners();
    return DragOutHandOffResult(DragOutHandOff.started, leftOut: leftOut);
  }

  /// A drop that reached a pane through `desktop_drop` while (or just
  /// after) one of our sessions ran: returns that session's payload when
  /// the drop is its echo, so the pane applies the in-app verb rules
  /// (a same-volume move stays a move) instead of the OS-drop copy.
  /// Local sessions match on the dropped paths; remote sessions match
  /// when their promise was called into the staging folder. Each
  /// session's echo is claimed at most once.
  PaneEntryDrag? claimEcho(List<String> droppedPaths) {
    final now = _clock();
    for (final session in _sessions.values.toList().reversed) {
      if (session.echoClaimed) continue;
      final endedAt = session.endedAt;
      final live =
          session.running ||
          (endedAt != null && now.difference(endedAt) <= echoGrace);
      if (!live) continue;
      final stagedAt = session.stagingEchoAt;
      final matches = switch (session.payload.source) {
        LocalFsLocation() => _samePaths(droppedPaths, session.localPaths),
        ServerFsLocation() =>
          stagedAt != null &&
              now.difference(stagedAt) <= echoGrace &&
              droppedPaths.every(isDropStagingPath),
      };
      if (!matches) continue;
      session.echoClaimed = true;
      return session.payload;
    }
    return null;
  }

  /// Whether [path] lies in `desktop_drop`'s staging folder. macOS
  /// spells the temp root both as `/var/…` and `/private/var/…` (and
  /// `/tmp` as `/private/tmp`), so both sides compare without the
  /// `/private` prefix.
  bool isDropStagingPath(String path) =>
      p.isWithin(_canonical(_dropStagingDirectory), _canonical(path));

  static String _canonical(String path) {
    const prefix = '/private';
    if (path.startsWith('$prefix/var/') || path.startsWith('$prefix/tmp/')) {
      return path.substring(prefix.length);
    }
    return path;
  }

  static bool _samePaths(List<String> dropped, Set<String> expected) {
    if (dropped.isEmpty) return false;
    final normalized = {for (final path in dropped) p.normalize(path)};
    return normalized.length == expected.length &&
        normalized.containsAll(expected);
  }

  // -------------------------------------------------------------------
  // DragOutBackendDelegate
  // -------------------------------------------------------------------

  /// [operation] changes nothing here: a copy or a link needs no
  /// follow-up, and a reported move (never offered) is not acted on, so
  /// nothing on the source side ever deletes.
  @override
  void sessionEnded(String sessionId, DragOutOperation? operation) {
    final session = _sessions[sessionId];
    if (session == null) return;
    session
      ..running = false
      ..endedAt = _clock();
    _prune();
    notifyListeners();
  }

  @override
  void cancelPromise(String sessionId, String promiseId) {
    final promise = _sessions[sessionId]?.promises[promiseId];
    if (promise == null || !promise.inFlight) return;
    promise.cancelled = true;
    promise.cancel?.call();
  }

  @override
  Future<void> fulfilPromise(DragOutPromiseRequest request) async {
    final session = _sessions[request.sessionId];
    final promise = session?.promises[request.promiseId];
    if (session == null || promise == null || _disposed) {
      throw const DragOutPromiseException(
        DragOutPromiseFailure.unknown,
        'unknown drag-out session or promise',
      );
    }
    if (isDropStagingPath(request.destinationPath)) {
      session.stagingEchoAt = _clock();
      throw const DragOutPromiseException(
        DragOutPromiseFailure.ownDrop,
        'the drag came back into Poltergeist',
      );
    }
    if (promise.inFlight) {
      throw const DragOutPromiseException(
        DragOutPromiseFailure.failed,
        'the promise is already being fulfilled',
      );
    }
    promise
      ..inFlight = true
      ..cancelled = false;
    try {
      if (promise.isDirectory) {
        await _fulfilFolder(session, promise, request.destinationPath);
      } else {
        await _fulfilFile(session, promise, request.destinationPath);
      }
    } finally {
      promise
        ..inFlight = false
        ..cancel = null;
      _prune();
    }
  }

  Future<void> _fulfilFile(
    _Session session,
    _Promise promise,
    String destinationPath,
  ) async {
    final files = _files;
    if (files == null) {
      _notice(DragOutNoticeKind.unavailable, promise, destinationPath);
      throw const DragOutPromiseException(
        DragOutPromiseFailure.unavailable,
        'no transfer queue to produce remote files',
      );
    }
    final ticket = files.produceFile(
      serverId: promise.serverId,
      remotePath: promise.remotePath,
      destinationPath: destinationPath,
      expectedSize: promise.size,
      onProgress: (transferred, total) =>
          _reportProgress(session, promise, transferred, total ?? promise.size),
    );
    promise.cancel = () => files.cancel(ticket.taskId);
    // A cancel that raced the start still lands.
    if (promise.cancelled) files.cancel(ticket.taskId);
    // The hop is a row on the same queue (main.dart composes both seams
    // over one queue session), so its row's Pause arrives on [_queue].
    var paused = false;
    final pauseWatch = _onTaskPaused(_queue, ticket.taskId, () {
      paused = true;
      files.cancel(ticket.taskId);
    });
    try {
      await ticket.result;
    } on RemoteFileException catch (error) {
      if (paused && error.kind == RemoteFileErrorKind.cancelled) {
        _notice(DragOutNoticeKind.pausedMidway, promise, destinationPath);
        throw const DragOutPromiseException(
          DragOutPromiseFailure.paused,
          _pausedMidwayMessage,
        );
      }
      throw DragOutPromiseException(switch (error.kind) {
        RemoteFileErrorKind.cancelled => DragOutPromiseFailure.cancelled,
        RemoteFileErrorKind.conflict => DragOutPromiseFailure.exists,
        _ => DragOutPromiseFailure.failed,
      }, error.message);
    } on Object catch (error) {
      throw DragOutPromiseException(
        DragOutPromiseFailure.failed,
        error.toString(),
      );
    } finally {
      if (pauseWatch != null) unawaited(pauseWatch.cancel());
    }
    final size = promise.size;
    if (size != null) {
      _reportProgress(session, promise, size, size, force: true);
    }
  }

  Future<void> _fulfilFolder(
    _Session session,
    _Promise promise,
    String destinationPath,
  ) async {
    final queue = _queue;
    if (queue == null) {
      _notice(DragOutNoticeKind.unavailable, promise, destinationPath);
      throw const DragOutPromiseException(
        DragOutPromiseFailure.unavailable,
        'no transfer queue to download remote folders',
      );
    }
    // The queue lands a root under its own basename; a receiver that
    // renamed the promise would get the folder somewhere it never asked.
    if (p.basename(destinationPath) != promise.name) {
      _notice(DragOutNoticeKind.renamed, promise, destinationPath);
      throw const DragOutPromiseException(
        DragOutPromiseFailure.renamed,
        'the drop asked for a different folder name',
      );
    }
    if (queue.isPaused) {
      _notice(DragOutNoticeKind.paused, promise, destinationPath);
      throw const DragOutPromiseException(
        DragOutPromiseFailure.paused,
        'transfers are paused',
      );
    }
    const destination = LocalFsLocation();
    final source = ServerFsLocation(promise.serverId);
    final task = queue.enqueue(
      TransferTaskSpec(
        source: source,
        destination: destination,
        rootPaths: [promise.remotePath],
        destinationDir: p.dirname(destinationPath),
        policy: _conflictPolicy().policyFor(source, destination),
      ),
    );
    promise.cancel = () => queue.cancelTask(task.id);
    if (promise.cancelled) queue.cancelTask(task.id);
    // The OS would otherwise wait on a pause that may never lift;
    // cancelling means nothing lands after the drop gave up.
    var pausedMidway = false;
    void giveUpOnPause() {
      if (pausedMidway) return;
      pausedMidway = true;
      queue.cancelTask(task.id);
    }

    final poll = Timer.periodic(pausePollInterval, (_) {
      if (task.isTerminal) return;
      _reportProgress(session, promise, task.transferredBytes, task.totalBytes);
      // The queue pause carries no event, so it is polled here; the
      // task's own Pause arrives on the event stream below.
      if (queue.isPaused) giveUpOnPause();
    });
    final pauseWatch = _onTaskPaused(queue, task.id, giveUpOnPause);
    final TransferTask? settled;
    try {
      settled = await awaitTransferTaskTerminal(
        events: queue.events,
        tasks: () => queue.tasks,
        taskId: task.id,
      );
    } finally {
      poll.cancel();
      if (pauseWatch != null) unawaited(pauseWatch.cancel());
    }
    if (settled?.state == TransferTaskState.completed) {
      _reportProgress(
        session,
        promise,
        settled!.transferredBytes,
        settled.totalBytes,
        force: true,
      );
      return;
    }
    if (pausedMidway) {
      _notice(DragOutNoticeKind.pausedMidway, promise, destinationPath);
      throw const DragOutPromiseException(
        DragOutPromiseFailure.paused,
        _pausedMidwayMessage,
      );
    }
    if (settled == null || settled.state == TransferTaskState.cancelled) {
      throw const DragOutPromiseException(
        DragOutPromiseFailure.cancelled,
        'the download was cancelled',
      );
    }
    throw DragOutPromiseException(
      DragOutPromiseFailure.failed,
      settled.error ?? settled.state.name,
    );
  }

  /// The English diagnostic a promise stopped by a pause hands the
  /// native completion (the user-facing report is the Alert).
  static const _pausedMidwayMessage = 'the download was paused';

  /// Calls [onPaused] when [taskId] is paused on its own (its Transfers
  /// row's Pause), which the queue announces as the task's `paused`
  /// event. A paused task parks until a resume, so a promise waiting on
  /// it gives up instead. Null without a queue to listen to.
  static StreamSubscription<TransferQueueEvent>? _onTaskPaused(
    AppTransferQueue? queue,
    String taskId,
    void Function() onPaused,
  ) => queue?.events.listen((event) {
    if (event is TransferQueueTaskEvent &&
        event.taskId == taskId &&
        event.state == TransferTaskState.paused) {
      onPaused();
    }
  });

  void _reportProgress(
    _Session session,
    _Promise promise,
    int transferred,
    int? total, {
    bool force = false,
  }) {
    if (_disposed) return;
    final now = _clock();
    final last = promise.lastProgressAt;
    if (!force && last != null && now.difference(last) < progressInterval) {
      return;
    }
    promise.lastProgressAt = now;
    _backend.reportProgress(
      sessionId: session.id,
      promiseId: promise.id,
      completedBytes: transferred,
      totalBytes: total,
    );
  }

  void _notice(
    DragOutNoticeKind kind,
    _Promise promise,
    String destinationPath,
  ) {
    _notices.add(
      DragOutNotice(
        id: (++_sequence).toString(),
        kind: kind,
        itemName: promise.name,
        destinationDir: p.dirname(destinationPath),
      ),
    );
    while (_notices.length > _maxNotices) {
      _notices.removeAt(0);
    }
    if (!_disposed) notifyListeners();
  }

  /// Drops ended sessions past [sessionRetention] (and the oldest idle
  /// ones beyond the cap); a session with a promise in flight stays.
  void _prune() {
    final now = _clock();
    _sessions.removeWhere((_, session) {
      final endedAt = session.endedAt;
      return endedAt != null &&
          now.difference(endedAt) > sessionRetention &&
          !session.busy;
    });
    while (_sessions.length > _maxSessions) {
      final idle = _sessions.values
          .where((session) => !session.busy && !session.running)
          .firstOrNull;
      if (idle == null) break;
      _sessions.remove(idle.id);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _backend.delegate = null;
    super.dispose();
  }
}

/// `desktop_drop` 0.7.1's promise staging root on macOS:
/// `FileManager.default.temporaryDirectory/Drops` (its
/// `uniqueDropDestination`), which for Poltergeist's unsandboxed build
/// is `$TMPDIR/Drops`, the same root `Directory.systemTemp` reads.
String desktopDropStagingDirectory() =>
    p.join(Directory.systemTemp.path, 'Drops');

final class _Session {
  _Session({
    required this.id,
    required this.payload,
    required this.items,
    required this.promises,
  });

  final String id;
  final PaneEntryDrag payload;
  final List<DragOutItem> items;
  final Map<String, _Promise> promises;

  /// Started and not yet reported ended.
  bool running = false;
  DateTime? endedAt;

  /// When one of this session's promises was called into the
  /// `desktop_drop` staging folder (the echo's signature).
  DateTime? stagingEchoAt;
  bool echoClaimed = false;

  late final Set<String> localPaths = {
    for (final item in items)
      if (item is LocalDragOutItem) p.normalize(item.path),
  };

  bool get busy => promises.values.any((promise) => promise.inFlight);
}

final class _Promise {
  _Promise({
    required this.id,
    required this.serverId,
    required this.remotePath,
    required this.name,
    required this.isDirectory,
    this.size,
  });

  final String id;
  final String serverId;
  final String remotePath;
  final String name;
  final bool isDirectory;
  final int? size;

  bool inFlight = false;
  bool cancelled = false;
  void Function()? cancel;
  DateTime? lastProgressAt;
}
