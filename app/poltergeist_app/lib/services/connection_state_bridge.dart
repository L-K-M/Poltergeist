import 'package:poltergeist_core/poltergeist_core.dart';

/// The engine facet the connection-state composition consumes: 03 §5's two
/// state lanes and nothing else. [EngineClient] supplies both; keeping the
/// seam this narrow means a controller or widget never reaches for the whole
/// client (03 §1's layering — the app talks to the engine through the port).
abstract interface class ConnectionStateBridge {
  /// One server's connection status, current value first (03 §3.2).
  ///
  /// Live-only and replay-free apart from that first value: subscribe before
  /// the state you need can change (03 §5). Completes only when the engine
  /// tears its lanes down — never per server — so `onDone` means engine death.
  Stream<ServerStatus> watchServer(String serverId);

  /// Terminal recovery failures, delivered independently of any watch and
  /// scoped to the pane binding that failed when one did (03 §3.3).
  Stream<RecoveryFailedEvent> get recoveryFailures;
}

/// Wraps a spawned [EngineClient] as the connection-state seam.
ConnectionStateBridge connectionStateBridgeOf(EngineClient client) =>
    _EngineConnectionStateBridge(client);

final class _EngineConnectionStateBridge implements ConnectionStateBridge {
  _EngineConnectionStateBridge(this._client);

  final EngineClient _client;

  @override
  Stream<ServerStatus> watchServer(String serverId) =>
      _client.watchServer(serverId);

  @override
  Stream<RecoveryFailedEvent> get recoveryFailures => _client.recoveryFailures;
}
