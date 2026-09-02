import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/app_preferences.dart';
import 'package:poltergeist_app/services/desktop_window_lifecycle.dart';
import 'package:poltergeist_app/services/settings_store.dart';

import 'support/controlled_settings_writer.dart';

late Directory _temporaryDirectory;
late File _settingsFile;

void main() {
  setUp(() async {
    _temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_window_lifecycle_test_',
    );
    _settingsFile = File(p.join(_temporaryDirectory.path, 'settings.json'));
  });

  tearDown(() async {
    if (await _temporaryDirectory.exists()) {
      await _temporaryDirectory.delete(recursive: true);
    }
  });

  test('prepare configures the window and macOS titlebar', () async {
    final window = FakeWindowAdapter();
    final displays = FakeDisplayAdapter();
    final titlebar = FakeMacTitlebarAdapter();
    final lifecycle = _lifecycle(
      window: window,
      displays: displays,
      titlebar: titlebar,
      platform: DesktopPlatform.macos,
    );

    await lifecycle.prepare();

    expect(window.ensureInitializedCalls, 1);
    expect(window.preventClose, isTrue);
    expect(window.callbacksRegistered, isTrue);
    expect(titlebar.initializeCalls, 1);
  });

  test('show restores clamped geometry before showing and focusing', () async {
    final window = FakeWindowAdapter();
    await _settingsFile.writeAsString(
      '{"window.left":3000.0,"window.top":2000.0,'
      '"window.width":900.0,"window.height":600.0}',
    );
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    await lifecycle.show();

    expect(window.readyOptions?.size, const Size(900, 600));
    expect(window.readyOptions?.placement, WindowPlacement.restored);
    expect(window.bounds, const Rect.fromLTWH(510, 220, 900, 600));
    expect(window.events, ['ready', 'bounds', 'show', 'focus']);
  });

  test('prepare returns platform initialization failures', () async {
    final window = FakeWindowAdapter()..failEnsureInitialized = true;
    final lifecycle = _lifecycle(window: window);

    await expectLater(lifecycle.prepare(), throwsA(isA<StateError>()));
  });

  test('concurrent prepare calls share platform initialization', () async {
    final window = FakeWindowAdapter()..blockEnsureInitialized = true;
    final lifecycle = _lifecycle(window: window);

    final first = lifecycle.prepare();
    await window.ensureInitializedStarted.future;
    final second = lifecycle.prepare();
    await Future<void>.delayed(Duration.zero);
    final initializationCalls = window.ensureInitializedCalls;

    window.releaseEnsureInitialized();
    await Future.wait([first, second]);

    expect(initializationCalls, 1);
  });

  test('prepare retries after platform initialization fails', () async {
    final window = FakeWindowAdapter()..failEnsureInitialized = true;
    final lifecycle = _lifecycle(window: window);

    await expectLater(lifecycle.prepare(), throwsA(isA<StateError>()));
    window.failEnsureInitialized = false;
    await lifecycle.prepare();

    expect(window.ensureInitializedCalls, 2);
    expect(window.callbacksRegistered, isTrue);
  });

  test('show returns window presentation failures', () async {
    final window = FakeWindowAdapter()..failShow = true;
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    await expectLater(lifecycle.show(), throwsA(isA<StateError>()));
  });

  test('calibrates outer minimum size from first-frame content size', () async {
    final window = FakeWindowAdapter()
      ..bounds = const Rect.fromLTWH(10, 20, 700, 460);
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    await lifecycle.calibrateMinimumSize(const Size(680, 420));

    expect(window.minimumSize, const Size(740, 520));
    expect(window.bounds, const Rect.fromLTWH(10, 20, 740, 520));
  });

  test('recalibrates when the settled content inset changes', () async {
    final window = FakeWindowAdapter();
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    await lifecycle.calibrateMinimumSize(const Size(1180, 760));
    await lifecycle.calibrateMinimumSize(const Size(1180, 730));

    expect(window.minimumSizes, [const Size(720, 480), const Size(720, 510)]);
  });

  test('calibration waits for presentation to settle', () async {
    final window = FakeWindowAdapter()..blockReadyToShow = true;
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    final showing = lifecycle.show();
    await window.readyToShowStarted.future;

    final calibration = lifecycle.calibrateMinimumSize(const Size(1180, 730));
    await Future<void>.delayed(Duration.zero);

    expect(window.minimumSizes, isEmpty);

    window.releaseReadyToShow();
    await showing;
    await calibration;

    expect(window.minimumSizes, [const Size(720, 510)]);
  });

  test('an in-flight calibration yields to the latest content size', () async {
    final window = FakeWindowAdapter()..blockGetBounds = true;
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    final early = lifecycle.calibrateMinimumSize(const Size(1180, 760));
    await window.getBoundsStarted.future;

    final settled = lifecycle.calibrateMinimumSize(const Size(1180, 730));
    window.releaseGetBounds();
    await Future.wait([early, settled]);

    expect(window.minimumSizes, [const Size(720, 510)]);
  });

  test('close drops queued calibration and runs after presentation', () async {
    final window = FakeWindowAdapter()..blockReadyToShow = true;
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    final showing = lifecycle.show();
    await window.readyToShowStarted.future;

    final calibration = lifecycle.calibrateMinimumSize(const Size(1180, 730));
    final closing = lifecycle.close();
    await Future<void>.delayed(Duration.zero);

    expect(window.events, isNot(contains('destroy')));

    window.releaseReadyToShow();
    await Future.wait([showing, calibration, closing]);

    expect(window.minimumSizes, isEmpty);
    expect(window.events.last, 'destroy');
    expect(window.callsAfterDestroy, isEmpty);
  });

  test('close waits for an active calibration before destroying', () async {
    final window = FakeWindowAdapter()..blockGetBounds = true;
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    final calibration = lifecycle.calibrateMinimumSize(const Size(1180, 730));
    await window.getBoundsStarted.future;

    final closing = lifecycle.close();
    await Future<void>.delayed(Duration.zero);

    expect(window.events, isNot(contains('destroy')));

    window.releaseGetBounds();
    await Future.wait([calibration, closing]);

    expect(window.minimumSizes, isEmpty);
    expect(window.events.last, 'destroy');
    expect(window.callsAfterDestroy, isEmpty);
  });

  test('calibration failures are reported without escaping', () async {
    final window = FakeWindowAdapter()..failSetMinimumSize = true;
    final errors = <Object>[];
    final lifecycle = _lifecycle(
      window: window,
      onError: (error, _) => errors.add(error),
    );

    await lifecycle.prepare();
    await lifecycle.calibrateMinimumSize(const Size(1180, 730));

    expect(errors, [isA<StateError>()]);
  });

  test('move and resize save through the debounced path', () async {
    final window = FakeWindowAdapter();
    final debounce = FakeDebounceScheduler();
    final lifecycle = _lifecycle(window: window, debounce: debounce);

    await lifecycle.prepare();
    window.emitMove();
    window.emitResize();

    expect(debounce.cancelCount, 1);
    expect(await _settingsFile.exists(), isFalse);

    await debounce.fire();

    expect(await jsonValue(_settingsFile, 'window.left'), 80.0);
    expect(await jsonValue(_settingsFile, 'window.top'), 60.0);
    expect(await jsonValue(_settingsFile, 'window.width'), 1180.0);
    expect(await jsonValue(_settingsFile, 'window.height'), 760.0);
  });

  test(
    'close cancels the timer, awaits the final save, then destroys',
    () async {
      final window = FakeWindowAdapter();
      final writer = ControlledSettingsWriter()..blockWrites = true;
      final debounce = FakeDebounceScheduler();
      final lifecycle = _lifecycle(
        window: window,
        writer: writer,
        debounce: debounce,
      );

      await lifecycle.prepare();
      window.emitMove();
      final closing = lifecycle.close();
      await writer.firstWriteStarted.future;
      expect(debounce.cancelCount, 1);
      expect(window.events, isNot(contains('destroy')));

      writer.releaseWrites();
      await closing;
      expect(window.events.last, 'destroy');
      expect(window.callbacksRegistered, isFalse);
    },
  );

  test('save failures are reported and do not escape callbacks', () async {
    final window = FakeWindowAdapter();
    final writer = ControlledSettingsWriter()..failWrites = true;
    final errors = <Object>[];
    final debounce = FakeDebounceScheduler();
    final lifecycle = _lifecycle(
      window: window,
      writer: writer,
      debounce: debounce,
      onError: (error, _) => errors.add(error),
    );

    await lifecycle.prepare();
    window.emitMove();
    await debounce.fire();

    expect(errors, hasLength(1));

    writer.failWrites = false;
    await lifecycle.close();

    expect(window.events.last, 'destroy');
  });

  test('final geometry save failure is reported once before destroy', () async {
    final window = FakeWindowAdapter();
    final writer = ControlledSettingsWriter()..failWrites = true;
    final errors = <Object>[];
    final lifecycle = _lifecycle(
      window: window,
      writer: writer,
      onError: (error, _) => errors.add(error),
    );

    await lifecycle.prepare();
    await lifecycle.close();

    expect(errors, [isA<StateError>()]);
    expect(window.events.last, 'destroy');
  });

  test(
    'close callback reports destroy failures without an unhandled error',
    () async {
      final window = FakeWindowAdapter()..failDestroy = true;
      final errors = <Object>[];
      final errorReported = Completer<void>();
      final lifecycle = _lifecycle(
        window: window,
        onError: (error, _) {
          errors.add(error);
          if (!errorReported.isCompleted) errorReported.complete();
        },
      );

      await lifecycle.prepare();
      window.emitClose();
      await errorReported.future;

      expect(errors, contains(isA<StateError>()));
    },
  );

  test('close retries after window destruction fails', () async {
    final window = FakeWindowAdapter()..failDestroy = true;
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    await expectLater(lifecycle.close(), throwsA(isA<StateError>()));

    expect(window.callbacksRegistered, isTrue);

    window.failDestroy = false;
    await lifecycle.close();

    expect(window.events.last, 'destroy');
  });
}

DesktopWindowLifecycle _lifecycle({
  required FakeWindowAdapter window,
  ControlledSettingsWriter? writer,
  FakeDisplayAdapter? displays,
  FakeMacTitlebarAdapter? titlebar,
  DesktopPlatform platform = DesktopPlatform.linux,
  Duration saveDelay = const Duration(milliseconds: 1),
  FakeDebounceScheduler? debounce,
  void Function(Object, StackTrace)? onError,
}) {
  final store = SettingsStore(
    path: _settingsFile.path,
    atomicWriter: writer?.call,
    onError: onError,
  );
  return DesktopWindowLifecycle(
    AppPreferences(store: store),
    window: window,
    displays: displays ?? FakeDisplayAdapter(),
    titlebar: titlebar ?? FakeMacTitlebarAdapter(),
    platform: platform,
    geometrySaveDelay: saveDelay,
    scheduleDebounce: debounce?.schedule,
    onError: onError,
  );
}

Future<double?> jsonValue(File file, String key) async {
  if (!await file.exists()) return null;

  final contents = await file.readAsString();
  final value = (jsonDecode(contents) as Map<String, dynamic>)[key];
  return (value as num?)?.toDouble();
}

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
  Future<void> enableCloseInterception() async => preventClose = true;

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

  void releaseReadyToShow() => _readyToShowRelease?.complete();

  void releaseEnsureInitialized() => _ensureInitializedRelease?.complete();

  void releaseGetBounds() => _getBoundsRelease?.complete();

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
  Future<void> Function()? _callback;
  final _activeCallbacks = <Future<void> Function()>{};

  void Function() schedule(Duration delay, Future<void> Function() callback) {
    _callback = callback;
    _activeCallbacks.add(callback);
    return () {
      if (!_activeCallbacks.remove(callback)) return;

      cancelCount++;
      if (identical(_callback, callback)) _callback = null;
    };
  }

  Future<void> fire() async {
    final callback = _callback;
    _callback = null;
    _activeCallbacks.remove(callback);
    if (callback != null) await callback();
  }
}
