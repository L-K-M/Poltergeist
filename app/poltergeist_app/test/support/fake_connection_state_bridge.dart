import 'dart:async';

import 'package:poltergeist_app/services/connection_state_bridge.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// The engine's two connection-state lanes, socket-free (03 §5).
///
/// Delivery is synchronous so an emission lands before the caller's next
/// statement; the real lanes cross an isolate port, which the controller
/// suite pins separately against a spawned [EngineClient].
final class FakeConnectionStateBridge implements ConnectionStateBridge {
  final _controllers = <String, StreamController<ServerStatus>>{};
  final _recovery = StreamController<RecoveryFailedEvent>.broadcast(sync: true);

  /// Watch calls in order, so a reload's re-subscription is observable.
  final watched = <String>[];

  /// Thrown by [watchServer] instead of returning a stream — a dead engine's
  /// fail-fast contract.
  Object? watchFailure;

  bool _recoveryClosed = false;
  bool _controllersClosed = false;

  StreamController<ServerStatus> _controller(String serverId) =>
      _controllers.putIfAbsent(
        serverId,
        () => StreamController<ServerStatus>.broadcast(sync: true),
      );

  @override
  Stream<ServerStatus> watchServer(String serverId) {
    watched.add(serverId);
    final failure = watchFailure;
    if (failure != null) throw failure;
    return _controller(serverId).stream;
  }

  @override
  Stream<RecoveryFailedEvent> get recoveryFailures => _recovery.stream;

  bool hasListener(String serverId) =>
      _controllers[serverId]?.hasListener ?? false;

  bool get recoveryHasListener => _recovery.hasListener;

  void emitStatus(String serverId, ServerStatus status) =>
      _controller(serverId).add(status);

  void failStatusLane(String serverId, Object error) =>
      _controller(serverId).addError(error);

  void emitRecovery(
    String serverId, {
    String? paneTabId,
    String message = 'Could not resolve the home directory.',
  }) {
    _recovery.add(
      RecoveryFailedEvent(
        serverId: serverId,
        paneTabId: paneTabId,
        error: EngineError(
          kind: RemoteFileErrorKind.permissionDenied,
          operation: 'canonicalize',
          message: message,
        ),
      ),
    );
  }

  /// The engine died: every lane closes, as `EngineClient._terminate` does.
  Future<void> stopEngine() async {
    if (!_controllersClosed) {
      _controllersClosed = true;
      for (final controller in _controllers.values) {
        await controller.close();
      }
    }
    if (!_recoveryClosed) {
      _recoveryClosed = true;
      await _recovery.close();
    }
  }

  Future<void> close() => stopEngine();
}
