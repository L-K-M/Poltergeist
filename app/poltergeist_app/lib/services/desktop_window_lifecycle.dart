import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:macos_window_utils/macos_window_utils.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'app_preferences.dart';
import 'window_geometry.dart';

const _initialWindowSize = Size(1180, 760);
const _minimumContentSize = Size(720, 480);
const _defaultGeometrySaveDelay = Duration(milliseconds: 250);

void Function() _scheduleWithTimer(
  Duration delay,
  Future<void> Function() callback,
) {
  final timer = Timer(delay, () => callback().ignore());
  return timer.cancel;
}

enum DesktopPlatform { other, linux, macos, windows }

enum WindowPlacement { centered, restored }

DesktopPlatform _currentPlatform() {
  if (Platform.isMacOS) return DesktopPlatform.macos;
  if (Platform.isWindows) return DesktopPlatform.windows;
  if (Platform.isLinux) return DesktopPlatform.linux;
  return DesktopPlatform.other;
}

final class WindowShowOptions {
  const WindowShowOptions({
    required this.size,
    required this.placement,
    required this.minimumSize,
  });

  final Size size;
  final WindowPlacement placement;
  final Size minimumSize;
}

abstract interface class DesktopWindowAdapter {
  Future<void> ensureInitialized();

  Future<void> waitUntilReadyToShow(WindowShowOptions options);

  Future<void> setBounds(Rect bounds);

  Future<void> setMinimumSize(Size size);

  Future<void> show();

  Future<void> focus();

  Future<void> enableCloseInterception();

  Future<Rect> getBounds();

  Future<void> destroy();

  void registerCallbacks({
    required void Function() onMove,
    required void Function() onResize,
    required void Function() onClose,
  });

  void unregisterCallbacks();
}

abstract interface class DisplayAdapter {
  Future<Rect> primaryWorkArea();

  Future<List<Rect>> workAreas();
}

abstract interface class MacTitlebarAdapter {
  Future<void> initialize();
}

final class DesktopWindowLifecycle {
  DesktopWindowLifecycle(
    this._preferences, {
    DesktopWindowAdapter? window,
    DisplayAdapter? displays,
    MacTitlebarAdapter? titlebar,
    DesktopPlatform? platform,
    Duration geometrySaveDelay = _defaultGeometrySaveDelay,
    void Function() Function(Duration, Future<void> Function())?
    scheduleDebounce,
    void Function(Object, StackTrace)? onError,
  }) : _window = window ?? _WindowManagerAdapter(),
       _displays = displays ?? _ScreenRetrieverAdapter(),
       _titlebar = titlebar ?? _MacTitlebarAdapter(),
       _platform = platform ?? _currentPlatform(),
       // Keep lifecycle timing private; callers configure it by named option.
       // ignore: prefer_initializing_formals
       _geometrySaveDelay = geometrySaveDelay,
       _scheduleDebounce = scheduleDebounce ?? _scheduleWithTimer,
       // Keep the callback private while allowing test-only error injection.
       // ignore: prefer_initializing_formals
       _onError = onError;

  final AppPreferences _preferences;
  final DesktopWindowAdapter _window;
  final DisplayAdapter _displays;
  final MacTitlebarAdapter _titlebar;
  final DesktopPlatform _platform;
  final Duration _geometrySaveDelay;
  final void Function() Function(Duration, Future<void> Function())
  _scheduleDebounce;
  final void Function(Object, StackTrace)? _onError;

  Rect? _restoredBounds;
  void Function()? _cancelScheduledSave;
  Future<void> _windowTail = Future.value();
  Future<void>? _prepareFuture;
  Future<void>? _closeFuture;
  Size? _calibratedContentSize;
  var _prepared = false;
  var _closing = false;
  var _calibrationRevision = 0;

  Future<void> prepare() {
    if (_platform == DesktopPlatform.other || _prepared || _closing) {
      return Future.value();
    }

    return _prepareFuture ??= _prepare().whenComplete(() {
      _prepareFuture = null;
    });
  }

  Future<void> _prepare() async {
    try {
      await _window.ensureInitialized();
      if (_closing) return;

      if (_platform == DesktopPlatform.macos) {
        await _titlebar.initialize();
        if (_closing) return;
      }

      final primaryWorkArea = await _displays.primaryWorkArea();
      if (_closing) return;

      final workAreas = await _displays.workAreas();
      if (_closing) return;

      final storedBounds = await _preferences.loadWindowBounds();
      if (_closing) return;

      if (storedBounds != null) {
        _restoredBounds = clampWindowBounds(
          bounds: storedBounds,
          workAreas: workAreas,
          fallbackWorkArea: primaryWorkArea,
        );
      }

      _window.registerCallbacks(
        onMove: _onWindowMove,
        onResize: _onWindowResize,
        onClose: _onWindowClose,
      );
      await _window.enableCloseInterception();
      if (_closing) return;

      _prepared = true;
    } catch (_) {
      _window.unregisterCallbacks();
      rethrow;
    }
  }

  Future<void> show() async {
    if (!_prepared || _closing) return;

    await _enqueueWindowOperation(() async {
      if (_closing) return;

      await _window.waitUntilReadyToShow(
        WindowShowOptions(
          size: _restoredBounds?.size ?? _initialWindowSize,
          placement: _restoredBounds == null
              ? WindowPlacement.centered
              : WindowPlacement.restored,
          minimumSize: _minimumContentSize,
        ),
      );
      if (_closing) return;

      if (_restoredBounds case final bounds?) await _window.setBounds(bounds);
      if (_closing) return;

      await _window.show();
      if (_closing) return;

      await _window.focus();
    });
  }

  Future<void> calibrateMinimumSize(Size contentSize) async {
    if (!_prepared ||
        _closing ||
        contentSize == _calibratedContentSize ||
        !_isFinitePositive(contentSize)) {
      return;
    }

    final revision = ++_calibrationRevision;
    await _enqueueWindowOperation(() async {
      if (!_isCurrentCalibration(revision)) return;

      try {
        final outerBounds = await _window.getBounds();
        if (!_isCurrentCalibration(revision)) return;

        final frameSize = Size(
          (outerBounds.width - contentSize.width).clamp(0, double.infinity),
          (outerBounds.height - contentSize.height).clamp(0, double.infinity),
        );
        final minimumSize = Size(
          _minimumContentSize.width + frameSize.width,
          _minimumContentSize.height + frameSize.height,
        );

        await _window.setMinimumSize(minimumSize);
        if (!_isCurrentCalibration(revision)) return;

        if (outerBounds.width >= minimumSize.width &&
            outerBounds.height >= minimumSize.height) {
          _calibratedContentSize = contentSize;
          return;
        }

        await _window.setBounds(
          Rect.fromLTWH(
            outerBounds.left,
            outerBounds.top,
            outerBounds.width < minimumSize.width
                ? minimumSize.width
                : outerBounds.width,
            outerBounds.height < minimumSize.height
                ? minimumSize.height
                : outerBounds.height,
          ),
        );
        if (_isCurrentCalibration(revision)) {
          _calibratedContentSize = contentSize;
        }
      } catch (error, stack) {
        _report(error, stack);
      }
    });
  }

  Future<void> close() {
    final activeClose = _closeFuture;
    if (activeClose != null) return activeClose;

    _closing = true;
    _calibrationRevision++;
    _cancelScheduledSave?.call();
    _cancelScheduledSave = null;
    final closeFuture = _runClose();
    _closeFuture = closeFuture;
    return closeFuture;
  }

  Future<void> _runClose() async {
    try {
      await _enqueueWindowOperation(_close);
    } catch (_) {
      _closeFuture = null;
      rethrow;
    }
  }

  void _onWindowMove() => _scheduleSave();

  void _onWindowResize() => _scheduleSave();

  void _onWindowClose() {
    unawaited(_closeFromCallback());
  }

  Future<void> _closeFromCallback() async {
    try {
      await close();
    } catch (error, stack) {
      _report(error, stack);
    }
  }

  void _scheduleSave() {
    if (_closing) return;

    _cancelScheduledSave?.call();
    _cancelScheduledSave = _scheduleDebounce(_geometrySaveDelay, () {
      _cancelScheduledSave = null;
      return _enqueueWindowOperation(() async {
        if (_closing) return;
        await _saveCurrentBounds();
      });
    });
  }

  Future<void> _saveCurrentBounds() async {
    late final Rect bounds;
    try {
      bounds = await _window.getBounds();
    } catch (error, stack) {
      _report(error, stack);
      return;
    }

    try {
      await _preferences.saveWindowBounds(bounds);
    } catch (error, stack) {
      _report(error, stack);
    }
  }

  Future<void> _close() async {
    await _saveCurrentBounds();

    await _window.destroy();
    _window.unregisterCallbacks();
  }

  Future<void> _enqueueWindowOperation(Future<void> Function() operation) {
    // Native window APIs are stateful and must never overlap.
    final result = _windowTail.then((_) => operation());
    _windowTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  bool _isCurrentCalibration(int revision) {
    return !_closing && revision == _calibrationRevision;
  }

  void _report(Object error, StackTrace stack) {
    try {
      _onError?.call(error, stack);
    } catch (_) {
      // Error reporting must not create an unhandled callback failure.
    }
  }

  bool _isFinitePositive(Size size) {
    return size.width.isFinite &&
        size.height.isFinite &&
        size.width > 0 &&
        size.height > 0;
  }
}

final class _WindowManagerAdapter
    with WindowListener
    implements DesktopWindowAdapter {
  _WindowManagerAdapter();

  void Function()? _onMove;
  void Function()? _onResize;
  void Function()? _onClose;

  @override
  Future<void> ensureInitialized() => windowManager.ensureInitialized();

  @override
  Future<void> waitUntilReadyToShow(WindowShowOptions options) {
    return windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: options.size,
        center: options.placement == WindowPlacement.centered,
        minimumSize: options.minimumSize,
      ),
    );
  }

  @override
  Future<void> setBounds(Rect bounds) => windowManager.setBounds(bounds);

  @override
  Future<void> setMinimumSize(Size size) => windowManager.setMinimumSize(size);

  @override
  Future<void> show() => windowManager.show();

  @override
  Future<void> focus() => windowManager.focus();

  @override
  Future<void> enableCloseInterception() => windowManager.setPreventClose(true);

  @override
  Future<Rect> getBounds() => windowManager.getBounds();

  @override
  Future<void> destroy() => windowManager.destroy();

  @override
  void registerCallbacks({
    required void Function() onMove,
    required void Function() onResize,
    required void Function() onClose,
  }) {
    _onMove = onMove;
    _onResize = onResize;
    _onClose = onClose;
    windowManager.addListener(this);
  }

  @override
  void unregisterCallbacks() {
    windowManager.removeListener(this);
    _onMove = null;
    _onResize = null;
    _onClose = null;
  }

  @override
  void onWindowMove() => _onMove?.call();

  @override
  void onWindowResize() => _onResize?.call();

  @override
  void onWindowClose() => _onClose?.call();
}

final class _ScreenRetrieverAdapter implements DisplayAdapter {
  const _ScreenRetrieverAdapter();

  @override
  Future<Rect> primaryWorkArea() async =>
      _workArea(await screenRetriever.getPrimaryDisplay());

  @override
  Future<List<Rect>> workAreas() async =>
      (await screenRetriever.getAllDisplays()).map(_workArea).toList();

  static Rect _workArea(Display display) {
    return (display.visiblePosition ?? Offset.zero) &
        (display.visibleSize ?? display.size);
  }
}

final class _MacTitlebarAdapter implements MacTitlebarAdapter {
  const _MacTitlebarAdapter();

  @override
  Future<void> initialize() async {
    await WindowManipulator.initialize();
    await WindowManipulator.enableFullSizeContentView();
    await WindowManipulator.makeTitlebarTransparent();
    await WindowManipulator.hideTitle();
  }
}
