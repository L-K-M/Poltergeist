/// Increment when the cross-isolate message contract changes.
const engineProtocolVersion = 1;

/// Plain-data events keep sockets and callbacks on the engine isolate.
sealed class EngineEvent {
  final int protocolVersion;

  const EngineEvent() : protocolVersion = engineProtocolVersion;
}

/// Item counters and task rollups travel together; the UI cannot derive totals
/// from the subset of items retained by progress coalescing.
final class TransferProgressEvent extends EngineEvent {
  final String taskId;
  final String itemId;
  final int transferred;
  final int? total;
  final int taskTransferredBytes;
  final int? taskTotalBytes;

  const TransferProgressEvent({
    required this.taskId,
    required this.itemId,
    required this.transferred,
    required this.total,
    required this.taskTransferredBytes,
    required this.taskTotalBytes,
  });
}

/// One flush window across all tasks, so task count cannot multiply port traffic.
final class TransferProgressBatchEvent extends EngineEvent {
  final List<TransferProgressEvent> items;

  TransferProgressBatchEvent(Iterable<TransferProgressEvent> items)
    : items = List.unmodifiable(items);
}
