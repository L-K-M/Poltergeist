import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/workspace_windows/window_host.dart';

String _read(String path) => File(path).readAsStringSync();

/// The workspace windows' runner contract (00 D39). The Linux host is
/// exercised for real under Xvfb (docs/STATUS.md); the macOS and Windows
/// hosts only compile in CI. These checks keep each runner serving the
/// protocol the Dart side speaks, and keep the load-bearing choices from
/// drifting: every window is a view on the app's one engine, never a second
/// engine, and an extra window never feeds the main window's plugins.
void main() {
  final runners = {
    'linux': _read('linux/runner/workspace_windows.cc'),
    'macos': _read('macos/Runner/WorkspaceWindows.swift'),
    'windows': _read('windows/runner/workspace_windows.cpp'),
  };

  test('every runner serves the channel with every method and event', () {
    for (final MapEntry(key: platform, value: source) in runners.entries) {
      expect(
        source,
        contains('"${workspaceWindowsChannel.name}"'),
        reason: platform,
      );
      for (final method in WindowHostMethod.values) {
        expect(
          source,
          contains('"${method.name}"'),
          reason: '$platform $method',
        );
      }
      for (final event in WindowHostEvent.values) {
        expect(source, contains('"${event.name}"'), reason: '$platform $event');
      }
      for (final key in [WindowHostKey.viewId, WindowHostKey.fullScreen]) {
        expect(source, contains('"${key.name}"'), reason: '$platform $key');
      }
    }
    // Only the Windows runner needs the engine id: its C++ wrapper keeps
    // the main window's engine handle to itself.
    expect(runners['windows'], contains('"${WindowHostKey.engineId.name}"'));
  });

  test('the main window is the implicit view in every runner', () {
    expect(mainWindowViewId, 0);
    expect(runners['linux'], contains('kMainViewId = 0;'));
    expect(runners['macos'], contains('mainViewId: Int64 = 0'));
    expect(runners['windows'], contains('kMainViewId = 0;'));
  });

  test('extra windows are views on the app engine, not engines of their '
      'own', () {
    final linux = runners['linux']!;
    expect(linux, contains('fl_view_new_for_engine(host->engine)'));
    expect(linux, isNot(contains('fl_view_new(')));
    expect(linux, isNot(contains('fl_dart_project_new')));

    final macos = runners['macos']!;
    expect(
      macos,
      contains('PoltergeistFlutterViewController(\n      engine: engine,'),
    );
    expect(macos, contains('PoltergeistEnableMultiView(engine)'));
    expect(macos, isNot(contains('FlutterDartProject')));

    final windows = runners['windows']!;
    expect(windows, contains('FlutterDesktopEngineCreateViewController('));
    expect(windows, isNot(contains('FlutterDesktopEngineCreate(')));
    expect(windows, isNot(contains('DartProject')));
  });

  test('macOS reaches multi-view through the flag, guarded', () {
    final helper = _read('macos/Runner/PoltergeistMultiView.m');
    // Not -enableMultiView, whose live NSAssert fires once the implicit
    // view exists.
    expect(helper, isNot(contains('[engine enableMultiView]')));
    expect(helper, contains('@try'));
    expect(helper, contains('setValue:@YES forKey:@"multiViewEnabled"'));
    expect(
      _read('macos/Runner/Runner-Bridging-Header.h'),
      contains('#import "PoltergeistMultiView.h"'),
    );
  });

  test("Windows keeps extra windows' messages from the plugins", () {
    final windows = runners['windows']!;
    // window_manager's top-level proc takes whatever it is handed as the
    // main window's: a close, a minimize, full screen.
    expect(windows, isNot(contains('HandleTopLevelWindowProc')));
    expect(
      windows,
      contains('FlutterDesktopEngineProcessExternalWindowMessage('),
    );
    // The close goes to Dart before the engine's lifecycle could read the
    // last visible window's close as a quit.
    final close = windows.indexOf('case WM_CLOSE:');
    final lifecycle = windows.indexOf(
      'FlutterDesktopEngineProcessExternalWindowMessage(\n            engine_',
    );
    expect(close, isNonNegative);
    expect(lifecycle, greaterThan(close));
  });

  test('every host is compiled in and installed with the main window', () {
    expect(
      _read('linux/runner/CMakeLists.txt'),
      contains('"workspace_windows.cc"'),
    );
    expect(
      _read('linux/runner/my_application.cc'),
      contains(
        'workspace_windows_install(GTK_APPLICATION(application), window, view);',
      ),
    );
    expect(
      _read('windows/runner/CMakeLists.txt'),
      contains('"workspace_windows.cpp"'),
    );
    expect(
      _read('windows/runner/flutter_window.cpp'),
      contains('std::make_unique<WorkspaceWindowsHost>('),
    );
    final project = _read('macos/Runner.xcodeproj/project.pbxproj');
    expect(project, contains('WorkspaceWindows.swift in Sources'));
    expect(project, contains('PoltergeistMultiView.m in Sources'));
    expect(
      _read('macos/Runner/MainFlutterWindow.swift'),
      contains('workspaceWindows = WorkspaceWindowsHost('),
    );
  });
}
