import 'package:poltergeist_core/poltergeist_core.dart';

/// The remote-file half of OS drag-out (00 D14's amendment): one
/// produce hop per promised file, written straight into the folder the
/// OS gave. main.dart composes it next to `QueuePreviewProducer` over
/// the same queue, so the hop is a queue-visible Transfers row with
/// byte progress and a working Cancel, exempt from the queue pause like
/// every produce (03 §4.7).
abstract interface class DragOutProducer {
  /// Starts producing [remotePath] on [serverId] at [destinationPath].
  /// The ticket's result fails with a `RemoteFileException`: `conflict`
  /// when a file already sits at the destination (it is never
  /// replaced), `cancelled` after [cancel], or the queue's failure.
  PreviewProduceTicket produceFile({
    required String serverId,
    required String remotePath,
    required String destinationPath,
    int? expectedSize,
    RemoteTransferProgress? onProgress,
  });

  /// Cancels the produce task [taskId] (the Finder-side cancel).
  void cancel(String taskId);
}

/// [DragOutProducer] over the queue's produce seam: every hop is
/// [ProduceWriteMode.exclusive] (a user folder's same-named file wins)
/// and draws from [ProduceSlotPool.dragOut], so a many-file drop leaves
/// Quick Look's two slots free.
final class QueueDragOutProducer implements DragOutProducer {
  QueueDragOutProducer(this._producer);

  final PreviewProducer _producer;

  @override
  PreviewProduceTicket produceFile({
    required String serverId,
    required String remotePath,
    required String destinationPath,
    int? expectedSize,
    RemoteTransferProgress? onProgress,
  }) => _producer.start(
    PreviewProduceSpec(
      serverId: serverId,
      remotePath: remotePath,
      destinationPath: destinationPath,
      expectedSize: expectedSize,
      onProgress: onProgress,
      writeMode: ProduceWriteMode.exclusive,
      slotPool: ProduceSlotPool.dragOut,
    ),
  );

  @override
  void cancel(String taskId) => _producer.cancel(taskId);
}
