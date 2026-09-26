import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/session_state.dart';
import 'package:poltergeist_app/services/workspace_windows/window_host.dart';
import 'package:poltergeist_app/services/workspace_windows/workspace_windows.dart';

/// A runner host that records what Dart asks of it and hands out view ids
/// the way the engines do: the main window is 0, extra windows count up.
final class FakeWindowHost implements WindowHost {
  bool available = true;
  int nextViewId = 1;
  Object? createError;

  final calls = <String>[];
  WindowHostListener? currentListener;
  final fullScreen = <int, bool>{};

  @override
  set listener(WindowHostListener? listener) => currentListener = listener;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<int> create() async {
    final error = createError;
    if (error != null) throw error;
    final viewId = nextViewId++;
    calls.add('create $viewId');
    return viewId;
  }

  @override
  Future<void> destroy(int viewId) async => calls.add('destroy $viewId');

  @override
  Future<void> activate(int viewId) async => calls.add('activate $viewId');

  @override
  Future<void> hide(int viewId) async => calls.add('hide $viewId');

  @override
  Future<bool> isFullScreen(int viewId) async => fullScreen[viewId] ?? false;

  @override
  Future<void> setFullScreen(int viewId, {required bool fullScreen}) async {
    calls.add('fullScreen $viewId $fullScreen');
    this.fullScreen[viewId] = fullScreen;
  }
}

const _session = SessionState(
  activePaneId: sessionLeftPaneId,
  secondPaneHidden: false,
  panes: [
    SessionPaneState(
      paneId: sessionLeftPaneId,
      activeTab: -1,
      nextTabOrdinal: 1,
      tabs: [],
    ),
    SessionPaneState(
      paneId: sessionRightPaneId,
      activeTab: -1,
      nextTabOrdinal: 1,
      tabs: [],
    ),
  ],
);

void main() {
  late FakeWindowHost host;
  late int quits;
  late List<Object> errors;
  late WorkspaceWindows windows;

  setUp(() {
    host = FakeWindowHost();
    quits = 0;
    errors = [];
    windows = WorkspaceWindows(
      host: host,
      quitApplication: () async => quits++,
      afterFrame: () async {},
      platform: TargetPlatform.linux,
      onError: (error, _) => errors.add(error),
    );
  });

  tearDown(() => windows.dispose());

  test('start records the main window, open and active', () async {
    await windows.start(session: _session);

    expect(windows.windows, hasLength(1));
    final main = windows.windows.single;
    expect(main.isMain, isTrue);
    expect(main.viewId, mainWindowViewId);
    expect(main.isLaunchWindow, isTrue);
    expect(main.restoredSession, same(_session));
    expect(main.fullScreen, isNull);
    expect(windows.activeWindow, same(main));
    expect(windows.canOpenWindows, isTrue);
    expect(host.currentListener, same(windows));
  });

  test('a runner without the host keeps the app at one window', () async {
    host.available = false;
    await windows.start();

    await windows.openWindow();

    expect(windows.canOpenWindows, isFalse);
    expect(windows.windows, hasLength(1));
    expect(host.calls, isEmpty);
  });

  test('New Window opens an extra window, which becomes active', () async {
    await windows.start();
    var notified = 0;
    windows.addListener(() => notified++);

    await windows.openWindow();

    expect(host.calls, ['create 1']);
    expect(windows.windows, hasLength(2));
    final extra = windows.windows.last;
    expect(extra.kind, WorkspaceWindowKind.extra);
    expect(extra.viewId, 1);
    expect(extra.isLaunchWindow, isFalse);
    expect(extra.restoredSession, isNull);
    expect(extra.fullScreen, isNotNull);
    expect(windows.activeWindow, same(extra));
    expect(extra.isActive, isTrue);
    expect(windows.windows.first.isActive, isFalse);
    expect(notified, greaterThan(0));
  });

  test('a window the runner could not create is reported, not added', () async {
    await windows.start();
    host.createError = const WindowHostException('no');

    await windows.openWindow();

    expect(windows.windows, hasLength(1));
    expect(errors, [isA<WindowHostException>()]);
  });

  test('closing an extra window destroys it once its frame has gone and '
      'activates the one worked in before', () async {
    final frame = Completer<void>();
    windows.dispose();
    windows = WorkspaceWindows(
      host: host,
      quitApplication: () async => quits++,
      afterFrame: () => frame.future,
      platform: TargetPlatform.linux,
    );
    await windows.start();
    await windows.openWindow();
    final extra = windows.windows.last;

    final closing = windows.closeWindow(extra);
    await pumpEventQueue();

    // Out of the list at once, so the root drops its subtree this frame;
    // the view goes only after that frame.
    expect(windows.windows, hasLength(1));
    expect(host.calls, isNot(contains('destroy 1')));

    frame.complete();
    await closing;

    expect(host.calls, containsAllInOrder(['destroy 1', 'activate 0']));
    expect(windows.activeWindow!.isMain, isTrue);
    expect(quits, 0);
  });

  test('closing the last open window quits instead', () async {
    await windows.start();

    await windows.closeWindow(windows.windows.single);

    expect(quits, 1);
    expect(windows.windows, hasLength(1));
    expect(host.calls, isEmpty);
  });

  test('the close button on the main window hides it while another window '
      'is open, and leaves the quit to the caller otherwise', () async {
    await windows.start();
    expect(await windows.closeMainWindowInstead(), isFalse);
    expect(host.calls, isEmpty);

    await windows.openWindow();
    expect(await windows.closeMainWindowInstead(), isTrue);

    expect(host.calls, containsAllInOrder(['hide 0', 'activate 1']));
    expect(windows.windowForView(mainWindowViewId), isNull);
    expect(windows.windows.single.viewId, 1);
    expect(quits, 0);
  });

  test("the main window's close button decides after a close already under "
      'way, so the last window leaves the quit to the caller', () async {
    final frame = Completer<void>();
    final registry = WorkspaceWindows(
      host: host,
      quitApplication: () async => quits++,
      afterFrame: () => frame.future,
      platform: TargetPlatform.linux,
    );
    addTearDown(registry.dispose);
    await registry.start();
    await registry.openWindow();

    final closingExtra = registry.closeWindow(registry.windows.last);
    final closedInstead = registry.closeMainWindowInstead();
    frame.complete();
    await closingExtra;

    // By its turn the main window is the only one open: the caller's
    // quit path takes it, and the registry does not quit a second time.
    expect(await closedInstead, isFalse);
    expect(quits, 0);
    expect(registry.windows.single.isMain, isTrue);
  });

  test('a close interrupted by disposal leaves the runner alone', () async {
    final frame = Completer<void>();
    final registry = WorkspaceWindows(
      host: host,
      quitApplication: () async => quits++,
      afterFrame: () => frame.future,
      platform: TargetPlatform.linux,
    );
    await registry.start();
    await registry.openWindow();
    host.calls.clear();

    final closing = registry.closeWindow(registry.windows.last);
    await pumpEventQueue();
    registry.dispose();
    frame.complete();
    await closing;

    expect(host.calls, isEmpty);
  });

  test('New Window shows a hidden main window again, fresh, before asking '
      'the runner for another', () async {
    await windows.start(session: _session);
    final launched = windows.windows.single;
    await windows.openWindow();
    await windows.closeWindow(launched);
    host.calls.clear();

    await windows.openWindow();

    expect(host.calls, ['activate 0']);
    final main = windows.windowForView(mainWindowViewId)!;
    expect(main, isNot(same(launched)));
    expect(main.serial, isNot(launched.serial));
    expect(main.isLaunchWindow, isFalse);
    expect(main.restoredSession, isNull);
    expect(windows.activeWindow, same(main));
    // Opening order: the extra window came first this time.
    expect(windows.windows.map((window) => window.viewId), [1, 0]);
  });

  test('opens are serialized, so two quick New Windows cannot both reuse '
      'the hidden main window', () async {
    await windows.start();
    await windows.openWindow();
    await windows.closeWindow(windows.windowForView(mainWindowViewId)!);
    host.calls.clear();

    await Future.wait([windows.openWindow(), windows.openWindow()]);

    expect(host.calls, ['activate 0', 'create 2']);
    expect(windows.windows, hasLength(3));
  });

  test(
    "the runner's reports move the active window and close windows",
    () async {
      await windows.start();
      await windows.openWindow();
      final main = windows.windowForView(mainWindowViewId)!;

      windows.onWindowActivated(mainWindowViewId);
      expect(windows.activeWindow, same(main));

      windows.onWindowActivated(42);
      expect(windows.activeWindow, same(main));

      windows.onWindowCloseRequested(1);
      await pumpEventQueue();
      expect(host.calls, contains('destroy 1'));
      expect(windows.windows, [main]);
    },
  );

  test('restoring opens each saved window with its session', () async {
    await windows.start();

    await windows.restoreWindows([_session, _session]);

    expect(windows.windows, hasLength(3));
    expect(
      windows.windows.skip(1).map((window) => window.restoredSession),
      everyElement(same(_session)),
    );
    expect(windows.activeWindow, same(windows.windows.last));
  });

  test("an extra window's full screen goes to the runner", () async {
    await windows.start();
    await windows.openWindow();
    final fullScreen = windows.windows.last.fullScreen!;

    expect(fullScreen.supported, isTrue);
    await fullScreen.toggle();
    expect(fullScreen.isFullScreen, isTrue);
    await fullScreen.toggle();

    expect(
      host.calls,
      containsAllInOrder(['fullScreen 1 true', 'fullScreen 1 false']),
    );
  });

  testWidgets('the app-wide keys answer for the active window', (tester) async {
    // Built inside the test's fake-async zone: the one setUp built chains
    // its operations on a future of the real zone, whose callbacks a
    // widget test never runs.
    windows.dispose();
    windows = WorkspaceWindows(
      host: host,
      quitApplication: () async => quits++,
      afterFrame: () async {},
      platform: TargetPlatform.linux,
    );
    await windows.start();
    await windows.openWindow();
    final main = windows.windowForView(mainWindowViewId)!;
    final extra = windows.windows.last;
    Widget navigator(WorkspaceWindow window) => SizedBox(
      width: 100,
      height: 100,
      child: ScaffoldMessenger(
        key: window.scaffoldMessengerKey,
        child: Navigator(
          key: window.navigatorKey,
          onGenerateRoute: (_) =>
              MaterialPageRoute<void>(builder: (_) => const SizedBox()),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: Row(children: [navigator(main), navigator(extra)])),
    );

    expect(
      windows.navigatorKey.currentState,
      same(extra.navigatorKey.currentState),
    );
    expect(
      windows.scaffoldMessengerKey.currentState,
      same(extra.scaffoldMessengerKey.currentState),
    );

    windows.onWindowActivated(mainWindowViewId);

    expect(
      windows.navigatorKey.currentState,
      same(main.navigatorKey.currentState),
    );
    expect(windows.navigatorKey.currentContext, isNotNull);
  });
}
