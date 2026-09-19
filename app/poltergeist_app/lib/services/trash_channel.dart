import 'dart:async';
import 'dart:isolate';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// The UI-isolate end of the D15 `poltergeist/trash` channel (03 §7.1).
///
/// A `MethodChannel` only answers on an isolate that owns a binary
/// messenger — the engine isolate has none — so the channel is served
/// here: this server owns one [ReceivePort] whose [requests] SendPort
/// rides [EngineConfig.trashRequests] into the engine, where
/// `trashChannelInvokerFor` turns it back into a `TrashChannelInvoker`
/// for the macOS/Windows channel backends. Each request is a
/// [TrashInvokeRequest] answered exactly once on its reply port.
///
/// Bound only on the platforms whose backend rides the channel
/// (macOS `FileManager.trashItem`, Windows `IFileOperation`): Linux's
/// `gio trash` spawn runs inside the engine isolate and needs no relay,
/// and every other platform's backend is unwired regardless — it
/// reports `TrashErrorKind.unsupportedPlatform`/`unavailable` through
/// the same honest fallback a null server produces.
final class TrashChannelServer {
  TrashChannelServer._(this._requests, this._channel, this._onError) {
    _subscription = _requests.listen(_serve);
  }

  /// Binds the channel server on macOS/Windows; returns null elsewhere
  /// (the feature-detection: no port means no invoker means the backend
  /// reports unavailable — never a silent permanent delete).
  static TrashChannelServer? bind({
    String? operatingSystem,
    MethodChannel? channel,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) => switch (operatingSystem ?? Platform.operatingSystem) {
    'macos' || 'windows' => TrashChannelServer._(
      ReceivePort(),
      channel ?? const MethodChannel(trashChannelName),
      onError,
    ),
    _ => null,
  };

  final ReceivePort _requests;
  final MethodChannel _channel;
  final void Function(Object error, StackTrace stackTrace)? _onError;
  late final StreamSubscription<Object?> _subscription;

  /// The port [EngineConfig.trashRequests] carries into the engine.
  SendPort get requests => _requests.sendPort;

  void _serve(Object? message) {
    if (message is! TrashInvokeRequest) {
      // A foreign message on this private port is a wiring bug — report
      // it rather than dropping it silently; there is no reply port to
      // answer on, so nothing else can be done.
      _report(StateError('unexpected trash channel message: $message'));
      return;
    }
    unawaited(_invoke(message));
  }

  Future<void> _invoke(TrashInvokeRequest request) async {
    try {
      // A missing native handler surfaces as MissingPluginException here
      // and travels back as a failure reply — the invoker rethrows it and
      // ChannelTrashBackend maps it to TrashErrorKind.failed.
      final result = await _channel.invokeMethod<Object?>(
        request.method,
        request.arguments,
      );
      request.replyTo.send(TrashInvokeReply.result(result));
    } on Object catch (error, stackTrace) {
      try {
        request.replyTo.send(TrashInvokeReply.failure('$error'));
      } on Object catch (sendError) {
        _report(sendError);
      }
      // A channel failure is an expected trash outcome (the backend types
      // it), not an app fault — only the reply-send itself reports above.
      if (error is! PlatformException && error is! MissingPluginException) {
        _report(error, stackTrace);
      }
    }
  }

  void _report(Object error, [StackTrace? stackTrace]) {
    _onError?.call(error, stackTrace ?? StackTrace.current);
  }

  /// Stops serving — engine-side invocations in flight then hit their
  /// invoke timeout rather than a reply. Called from session shutdown.
  Future<void> close() async {
    await _subscription.cancel();
    _requests.close();
  }
}
