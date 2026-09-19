import 'dart:async';
import 'dart:ui';

import 'package:poltergeist_app/services/desktop_window_lifecycle.dart';

/// Scripted adapters for [DesktopWindowLifecycle] tests: every native call
/// records into [FakeWindowAdapter.events] and block/fail switches let a
/// test hold or break any stage. `emitClose` drives the intercepted
/// window-close callback the way `window_manager` delivers it.
final class FakeWindowAdapter implements DesktopWindowAdapter {
  int ensureInitializedCalls = 0;
  bool failEnsureInitialized = false;
  bool blockEnsureInitialized = false;
  bool failShow = false;
  bool failDestroy = false;
  bool failSetMinimumSize = false;
  bool blockReadyToShow = false;
  bool blockGetBounds = false;
  bool preventClose = false;
  bool callbacksRegistered = false;
  bool destroyed = false;
  Rect bounds = const Rect.fromLTWH(80, 60, 1180, 760);
  Size? minimumSize;
  final minimumSizes = <Size>[];
  final callsAfterDestroy = <String>[];
  WindowShowOptions? readyOptions;
  final events = <String>[];
  final ensureInitializedStarted = Completer<void>();
  final readyToShowStarted = Completer<void>();
  final getBoundsStarted = Completer<void>();
  Completer<void>? _readyToShowRelease;
  Completer<void>? _ensureInitializedRelease;
  Completer<void>? _getBoundsRelease;
  void Function()? _onMove;
  void Function()? _onResize;
  void Function()? _onClose;

  @override
  Future<void> ensureInitialized() async {
    ensureInitializedCalls++;
    if (!ensureInitializedStarted.isCompleted) {
      ensureInitializedStarted.complete();
    }
    if (blockEnsureInitialized) {
      _ensureInitializedRelease ??= Completer<void>();
      await _ensureInitializedRelease!.future;
    }
    if (failEnsureInitialized) throw StateError('initialization failed');
  }

  @override
  Future<Rect> getBounds() async {
    _recordCall('getBounds');
    if (!getBoundsStarted.isCompleted) getBoundsStarted.complete();
    if (blockGetBounds) {
      _getBoundsRelease ??= Completer<void>();
      await _getBoundsRelease!.future;
    }
    return bounds;
  }

  @override
  Future<void> setBounds(Rect value) async {
    _recordCall('setBounds');
    bounds = value;
    events.add('bounds');
  }

  @override
  Future<void> setMinimumSize(Size value) async {
    _recordCall('setMinimumSize');
    if (failSetMinimumSize) throw StateError('minimum size failed');
    minimumSize = value;
    minimumSizes.add(value);
  }

  @override
  Future<void> enableCloseInterception() async {
    _recordCall('enableCloseInterception');
    preventClose = true;
  }

  @override
  Future<void> waitUntilReadyToShow(WindowShowOptions options) async {
    _recordCall('waitUntilReadyToShow');
    readyOptions = options;
    events.add('ready');
    if (!readyToShowStarted.isCompleted) readyToShowStarted.complete();
    if (!blockReadyToShow) return;

    _readyToShowRelease ??= Completer<void>();
    await _readyToShowRelease!.future;
  }

  @override
  Future<void> show() async {
    _recordCall('show');
    if (failShow) throw StateError('show failed');
    events.add('show');
  }

  @override
  Future<void> focus() async {
    _recordCall('focus');
    events.add('focus');
  }

  @override
  Future<void> destroy() async {
    _recordCall('destroy');
    if (failDestroy) throw StateError('destroy failed');
    events.add('destroy');
    destroyed = true;
  }

  @override
  void registerCallbacks({
    required void Function() onMove,
    required void Function() onResize,
    required void Function() onClose,
  }) {
    _recordCall('registerCallbacks');
    callbacksRegistered = true;
    _onMove = onMove;
    _onResize = onResize;
    _onClose = onClose;
  }

  @override
  void unregisterCallbacks() {
    callbacksRegistered = false;
    _onMove = null;
    _onResize = null;
    _onClose = null;
  }

  void emitMove() => _onMove?.call();
  void emitResize() => _onResize?.call();
  void emitClose() => _onClose?.call();

  // Releases are one-shot and idempotent: the gate drops its completer
  // and clears the block flag, so a second release is a no-op and the
  // gate can never re-park on a stale completer.
  void releaseReadyToShow() {
    final release = _readyToShowRelease;
    _readyToShowRelease = null;
    blockReadyToShow = false;
    if (release != null && !release.isCompleted) release.complete();
  }

  void releaseEnsureInitialized() {
    final release = _ensureInitializedRelease;
    _ensureInitializedRelease = null;
    blockEnsureInitialized = false;
    if (release != null && !release.isCompleted) release.complete();
  }

  void releaseGetBounds() {
    final release = _getBoundsRelease;
    _getBoundsRelease = null;
    blockGetBounds = false;
    if (release != null && !release.isCompleted) release.complete();
  }

  void _recordCall(String call) {
    if (destroyed) callsAfterDestroy.add(call);
  }
}

final class FakeDisplayAdapter implements DisplayAdapter {
  @override
  Future<Rect> primaryWorkArea() async => const Rect.fromLTWH(0, 0, 1920, 1040);

  @override
  Future<List<Rect>> workAreas() async => [
    const Rect.fromLTWH(0, 0, 1920, 1040),
  ];
}

final class FakeMacTitlebarAdapter implements MacTitlebarAdapter {
  int initializeCalls = 0;

  @override
  Future<void> initialize() async => initializeCalls++;
}

final class FakeDebounceScheduler {
  int cancelCount = 0;
  Duration? lastDelay;
  Future<void> Function()? _callback;
  final _activeCallbacks = <Future<void> Function()>{};

  void Function() schedule(Duration delay, Future<void> Function() callback) {
    lastDelay = delay;
    _callback = callback;
    _activeCallbacks.add(callback);
    return () {
      if (!_activeCallbacks.remove(callback)) return;

      cancelCount++;
      if (identical(_callback, callback)) _callback = null;
    };
  }

  Future<void> fire() async {
    final pending = _activeCallbacks.toList(growable: false);
    _activeCallbacks.clear();
    _callback = null;

    for (final callback in pending) {
      await callback();
    }
  }
}
