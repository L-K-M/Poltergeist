import 'dart:async';

import 'package:poltergeist_app/services/drag_out_producer.dart';
import 'package:poltergeist_app/services/os_drag_out.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// A scripted [DragOutBackend]: records every `startDrag` request and
/// progress report, answers [nextResult], and exposes the delegate so a
/// test plays the native side's callbacks.
class FakeDragOutBackend implements DragOutBackend {
  FakeDragOutBackend({this.support = DragOutSupport.localFiles});

  @override
  DragOutSupport support;

  DragOutBackendDelegate? attached;

  @override
  set delegate(DragOutBackendDelegate? delegate) => attached = delegate;

  final requests = <DragOutRequest>[];
  final progress =
      <({String promiseId, int completedBytes, int? totalBytes})>[];

  /// The answer the next `startDrag` gets.
  DragOutStartResult nextResult = const DragOutStarted();

  /// When set, `startDrag` parks until it completes.
  Completer<void>? startGate;

  @override
  Future<DragOutStartResult> startDrag(DragOutRequest request) async {
    requests.add(request);
    await startGate?.future;
    return nextResult;
  }

  @override
  void reportProgress({
    required String sessionId,
    required String promiseId,
    required int completedBytes,
    int? totalBytes,
  }) {
    progress.add((
      promiseId: promiseId,
      completedBytes: completedBytes,
      totalBytes: totalBytes,
    ));
  }
}

/// One scripted produce the fake producer started.
class FakeDragOutProduce {
  FakeDragOutProduce({
    required this.taskId,
    required this.serverId,
    required this.remotePath,
    required this.destinationPath,
    required this.expectedSize,
    required this.onProgress,
  });

  final String taskId;
  final String serverId;
  final String remotePath;
  final String destinationPath;
  final int? expectedSize;
  final RemoteTransferProgress? onProgress;
  final result = Completer<RemoteFileEntry>();

  void complete() => result.complete(
    RemoteFileEntry(
      path: destinationPath,
      name: destinationPath.split('/').last,
      type: RemoteFileType.file,
      size: expectedSize,
    ),
  );

  void fail(RemoteFileErrorKind kind, String message) => result.completeError(
    RemoteFileException(kind: kind, operation: 'produce', message: message),
  );
}

/// A scripted [DragOutProducer]: each produce is a [FakeDragOutProduce]
/// the test completes or fails; [cancel] fails it as cancelled.
class FakeDragOutProducer implements DragOutProducer {
  final produces = <FakeDragOutProduce>[];
  final cancelled = <String>[];

  @override
  PreviewProduceTicket produceFile({
    required String serverId,
    required String remotePath,
    required String destinationPath,
    int? expectedSize,
    RemoteTransferProgress? onProgress,
  }) {
    final produce = FakeDragOutProduce(
      taskId: 'produce-${produces.length + 1}',
      serverId: serverId,
      remotePath: remotePath,
      destinationPath: destinationPath,
      expectedSize: expectedSize,
      onProgress: onProgress,
    );
    produces.add(produce);
    return PreviewProduceTicket(
      taskId: produce.taskId,
      result: produce.result.future,
    );
  }

  @override
  void cancel(String taskId) {
    cancelled.add(taskId);
    for (final produce in produces) {
      if (produce.taskId == taskId && !produce.result.isCompleted) {
        produce.fail(RemoteFileErrorKind.cancelled, 'cancelled');
      }
    }
  }
}
