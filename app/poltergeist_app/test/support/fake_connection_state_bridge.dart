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
    final failure = watchFailure;
    if (failure != null) throw failure;
    // Recorded only for watches that returned a lane: a refused call is
    // never a subscription.
    watched.add(serverId);
    return _controller(serverId).stream;
  }

  @override
  Stream<RecoveryFailedEvent> get recoveryFailures => _recovery.stream;

  bool hasListener(String serverId) =>
      _controllers[serverId]?.hasListener ?? false;

  bool get recoveryHasListener => _recovery.hasListener;

  void emitStatus(String serverId, ServerStatus status) {
    _failFastIfStopped();
    _controller(serverId).add(status);
  }

  void failStatusLane(String serverId, Object error) {
    _failFastIfStopped();
    _controller(serverId).addError(error);
  }

  /// A dead engine accepts no emissions for any id — watched or not — so a
  /// post-termination emission cannot land in a silently fresh controller
  /// and pass vacuously.
  void _failFastIfStopped() {
    if (_controllersClosed) {
      throw StateError('The engine has terminated.');
    }
  }

  void emitRecovery(
    String serverId, {
    String? paneTabId,
    String message = 'Could not resolve the home directory.',
  }) {
    _failFastIfStopped();
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
    // A dead engine also fails fast on new watches (see [watchFailure]), so
    // a reload after termination cannot silently re-subscribe to a done
    // lane — matching the production client's `_closed` guard.
    watchFailure ??= StateError('The engine has terminated.');
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
