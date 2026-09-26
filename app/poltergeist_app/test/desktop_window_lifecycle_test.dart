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
import 'support/fake_window_adapters.dart';

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

  test('windowReady resolves only once waitUntilReadyToShow has', () async {
    // Windows: window_manager creates the taskbar list that its
    // setProgressBar dereferences inside waitUntilReadyToShow, so the
    // Dock/taskbar reporter waits on this signal.
    final window = FakeWindowAdapter()..blockReadyToShow = true;
    final lifecycle = _lifecycle(window: window);
    var ready = false;
    unawaited(lifecycle.windowReady.then((_) => ready = true));

    await lifecycle.prepare();
    final showing = lifecycle.show();
    await window.readyToShowStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);

    window.releaseReadyToShow();
    await showing;
    expect(ready, isTrue);
  });

  test('windowReady never resolves when prepare failed', () async {
    final window = FakeWindowAdapter()..failEnsureInitialized = true;
    final lifecycle = _lifecycle(window: window);
    var ready = false;
    unawaited(lifecycle.windowReady.then((_) => ready = true));

    await expectLater(lifecycle.prepare(), throwsA(isA<StateError>()));
    await lifecycle.show();
    await Future<void>.delayed(Duration.zero);

    expect(window.events, isNot(contains('ready')));
    expect(ready, isFalse);
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

  test('close waits for in-flight prepare before destroying', () async {
    final window = FakeWindowAdapter()..blockEnsureInitialized = true;
    final lifecycle = _lifecycle(window: window);

    final preparing = lifecycle.prepare();
    await window.ensureInitializedStarted.future;
    final closing = lifecycle.close();
    await Future<void>.delayed(Duration.zero);

    final closeStartedDuringPrepare = window.getBoundsStarted.isCompleted;
    final destroyedDuringPrepare = window.events.contains('destroy');

    window.releaseEnsureInitialized();
    await Future.wait([preparing, closing]);

    expect(closeStartedDuringPrepare, isFalse);
    expect(destroyedDuringPrepare, isFalse);
    expect(window.callbacksRegistered, isFalse);
    expect(window.events.last, 'destroy');
    expect(window.callsAfterDestroy, isEmpty);
  });

  test('close tears down after in-flight prepare fails', () async {
    final window = FakeWindowAdapter()
      ..blockEnsureInitialized = true
      ..failEnsureInitialized = true;
    final lifecycle = _lifecycle(window: window);

    final preparing = lifecycle.prepare();
    final prepareFailure = expectLater(preparing, throwsA(isA<StateError>()));
    await window.ensureInitializedStarted.future;
    final closing = lifecycle.close();
    await Future<void>.delayed(Duration.zero);

    final closeStartedDuringPrepare = window.getBoundsStarted.isCompleted;
    final destroyedDuringPrepare = window.events.contains('destroy');

    window.releaseEnsureInitialized();
    await prepareFailure;
    await closing;

    expect(closeStartedDuringPrepare, isFalse);
    expect(destroyedDuringPrepare, isFalse);
    expect(window.callbacksRegistered, isFalse);
    expect(window.events.last, 'destroy');
    expect(window.callsAfterDestroy, isEmpty);
  });

  test('prepare stays idle after close has started', () async {
    final window = FakeWindowAdapter();
    final lifecycle = _lifecycle(window: window);

    await lifecycle.close();
    await lifecycle.prepare();

    expect(window.ensureInitializedCalls, 0);
    expect(window.callbacksRegistered, isFalse);
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
    const saveDelay = Duration(milliseconds: 37);
    final window = FakeWindowAdapter();
    final debounce = FakeDebounceScheduler();
    final lifecycle = _lifecycle(
      window: window,
      debounce: debounce,
      saveDelay: saveDelay,
    );

    await lifecycle.prepare();
    window.emitMove();
    window.emitResize();

    expect(debounce.cancelCount, 1);
    expect(debounce.lastDelay, saveDelay);
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

    await lifecycle.show();

    expect(window.events, containsAllInOrder(['ready', 'show', 'focus']));

    window.failDestroy = false;
    await lifecycle.close();

    expect(window.events.last, 'destroy');
  });

  test('close stays idempotent after window destruction succeeds', () async {
    final window = FakeWindowAdapter();
    final lifecycle = _lifecycle(window: window);

    await lifecycle.prepare();
    await lifecycle.close();
    await lifecycle.close();

    expect(window.events.where((event) => event == 'destroy'), hasLength(1));
    expect(window.callsAfterDestroy, isEmpty);
  });

  test('a vetoed close keeps the window up and re-runs on retry', () async {
    final window = FakeWindowAdapter();
    var allowClose = false;
    var guardCalls = 0;
    final lifecycle = _lifecycle(
      window: window,
      confirmClose: () async {
        guardCalls++;
        return allowClose;
      },
    );

    await lifecycle.prepare();
    final vetoed = await lifecycle.close();

    expect(vetoed, isFalse);
    expect(window.events, isNot(contains('destroy')));
    expect(window.callbacksRegistered, isTrue);
    // A veto leaves the lifecycle live: show must not be gated by a
    // stale closing flag.
    await lifecycle.show();
    expect(window.events, containsAllInOrder(['ready', 'show', 'focus']));

    allowClose = true;
    final closed = await lifecycle.close();

    expect(closed, isTrue);
    expect(guardCalls, 2);
    expect(window.events.last, 'destroy');
  });

  test('a guard error fails the close and leaves the window up', () async {
    final window = FakeWindowAdapter();
    final errors = <Object>[];
    final lifecycle = _lifecycle(
      window: window,
      confirmClose: () async => throw StateError('guard failed'),
      onError: (error, _) => errors.add(error),
    );

    await lifecycle.prepare();
    await expectLater(lifecycle.close(), throwsA(isA<StateError>()));

    expect(window.events, isNot(contains('destroy')));
    expect(window.callbacksRegistered, isTrue);

    // The callback route surfaces the same failure through onError.
    window.emitClose();
    await pumpEventQueue();

    expect(errors, contains(isA<StateError>()));
  });
  test('another window taking the close skips the whole quit path (00 D39)',
      () async {
    final window = FakeWindowAdapter();
    var guardCalls = 0;
    var instead = true;
    final lifecycle = _lifecycle(
      window: window,
      confirmClose: () async {
        guardCalls++;
        return true;
      },
      closeInstead: () async => instead,
    );

    await lifecycle.prepare();
    expect(await lifecycle.close(), isFalse);

    expect(guardCalls, 0);
    expect(window.events, isNot(contains('destroy')));
    expect(window.callbacksRegistered, isTrue);

    // The last window's close is a quit again, guard first.
    instead = false;
    expect(await lifecycle.close(), isTrue);
    expect(guardCalls, 1);
    expect(window.events.last, 'destroy');
  });

  test('saveBounds writes the current bounds for a quit that skips the '
      'close path', () async {
    final window = FakeWindowAdapter();
    final lifecycle = _lifecycle(window: window);

    await lifecycle.saveBounds();
    expect(await jsonValue(_settingsFile, 'window.width'), isNull);

    await lifecycle.prepare();
    await lifecycle.saveBounds();

    expect(await jsonValue(_settingsFile, 'window.width'), 1180);
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
  Future<bool> Function()? confirmClose,
  Future<bool> Function()? closeInstead,
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
    confirmClose: confirmClose,
    closeInstead: closeInstead,
    onError: onError,
  );
}

Future<double?> jsonValue(File file, String key) async {
  if (!await file.exists()) return null;

  final contents = await file.readAsString();
  final value = (jsonDecode(contents) as Map<String, dynamic>)[key];
  return (value as num?)?.toDouble();
}
