import '../connection/pool_policy.dart';

/// How many of the queue's files may move to or from one server at once
/// (00 D37). [files] is null for [TransferConcurrency.automatic]: no
/// per-server cap, so only the process-wide [maxGlobalInFlightTransfers]
/// bounds the server — the behavior before D37.
final class TransferConcurrency {
  const TransferConcurrency.automatic() : files = null;

  /// A cap of [files] at once. A value at or above
  /// [maxGlobalInFlightTransfers] is legal and simply never binds.
  const TransferConcurrency.fixed(int this.files)
    : assert(files >= 1, 'a fixed cap must allow at least one file');

  final int? files;

  bool get isAutomatic => files == null;

  @override
  bool operator ==(Object other) =>
      other is TransferConcurrency && other.files == files;

  @override
  int get hashCode => files.hashCode;

  @override
  String toString() => isAutomatic
      ? 'TransferConcurrency.automatic()'
      : 'TransferConcurrency.fixed($files)';
}

/// The per-server caps the transfer queue dispatches under (00 D37): one
/// default every server gets, and the servers that chose their own.
///
/// A server with no entry in [overrides] takes [perServer]; an entry
/// wins even when it is [TransferConcurrency.automatic], so one fast
/// server can opt out of a default cap the rest keep.
final class ServerTransferLimits {
  const ServerTransferLimits({
    this.perServer = const TransferConcurrency.automatic(),
    this.overrides = const {},
  });

  /// No cap anywhere — the queue's behavior before D37.
  static const none = ServerTransferLimits();

  final TransferConcurrency perServer;
  final Map<String, TransferConcurrency> overrides;

  /// The cap in force for [serverId], null when it has none.
  int? filesFor(String serverId) => (overrides[serverId] ?? perServer).files;
}
