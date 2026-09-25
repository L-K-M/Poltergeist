import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'app_transfer_queue.dart';

/// The fixed caps a user can pick, 1 up to one short of the app-wide
/// total: a cap of [maxGlobalInFlightTransfers] or more never binds, so
/// Automatic already means it.
final List<int> transferConcurrencyChoices = List.unmodifiable([
  for (var files = 1; files < maxGlobalInFlightTransfers; files++) files,
]);

/// The per-server transfer caps (00 D37) and their one owner: the default
/// the Activity panel's popover sets, the overrides the server editor
/// sets, both persisted device-locally, and the queue they bound.
///
/// Every change reaches the bound queue at once, so a raised cap starts
/// waiting files straight away, and [queue]'s setter applies the current
/// caps, so a queue bound late starts under them rather than uncapped.
final class TransferLimitsController extends ChangeNotifier {
  TransferLimitsController({
    ServerTransferLimits initial = ServerTransferLimits.none,
    this.persistDefault,
    this.persistOverride,
    this.onError,
  }) : _limits = initial;

  /// Writes the default. Best-effort, like the bandwidth limits: the
  /// choice applies before the write lands, and a failed write reports
  /// through [onError].
  final Future<void> Function(TransferConcurrency value)? persistDefault;

  /// Writes one server's own choice (null clears it) and answers with
  /// every override now stored, which becomes the state in force.
  final Future<Map<String, TransferConcurrency>> Function(
    String serverId,
    TransferConcurrency? value,
  )?
  persistOverride;

  final void Function(Object error, StackTrace stack)? onError;

  ServerTransferLimits _limits;
  AppTransferQueue? _queue;

  ServerTransferLimits get limits => _limits;

  /// The cap every server takes unless it chose its own.
  TransferConcurrency get perServer => _limits.perServer;

  /// [serverId]'s own choice, or null when it follows [perServer].
  TransferConcurrency? overrideFor(String serverId) =>
      _limits.overrides[serverId];

  AppTransferQueue? get queue => _queue;

  set queue(AppTransferQueue? next) {
    _queue = next;
    next?.serverTransferLimits = _limits;
  }

  /// The popover's choice: in force at once, then persisted.
  void setPerServer(TransferConcurrency value) {
    if (value == _limits.perServer) return;
    _apply(
      ServerTransferLimits(perServer: value, overrides: _limits.overrides),
    );
    final persist = persistDefault;
    if (persist == null) return;
    unawaited(
      Future.sync(() => persist(value)).catchError((Object error, stack) {
        onError?.call(error, stack);
      }),
    );
  }

  /// The server editor's choice: persisted first, so a Save that could
  /// not store it fails where the user can see it (the future throws)
  /// instead of applying a cap the next launch would not have.
  Future<void> setOverride(String serverId, TransferConcurrency? value) async {
    final persist = persistOverride;
    final Map<String, TransferConcurrency> overrides;
    if (persist == null) {
      overrides = {..._limits.overrides};
      if (value == null) {
        overrides.remove(serverId);
      } else {
        overrides[serverId] = value;
      }
    } else {
      overrides = await persist(serverId, value);
    }
    _apply(
      ServerTransferLimits(
        perServer: _limits.perServer,
        overrides: Map.unmodifiable(overrides),
      ),
    );
  }

  void _apply(ServerTransferLimits next) {
    _limits = next;
    _queue?.serverTransferLimits = next;
    notifyListeners();
  }
}
