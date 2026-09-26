import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/window_drop_in.dart';
import 'package:poltergeist_app/services/workspace_windows/window_host.dart';
import 'package:poltergeist_app/services/workspace_windows/window_titlebar.dart';

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
      contains(RegExp(r'PoltergeistFlutterViewController\(\s*engine: engine,')),
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
      RegExp(r'FlutterDesktopEngineProcessExternalWindowMessage\(\s*engine_'),
    );
    expect(close, isNonNegative);
    expect(lifecycle, greaterThan(close));
  });

  test('Linux takes the extra windows down with the main window, before '
      'its finalize', () {
    final linux = runners['linux']!;
    final destroyCallback = linux.indexOf('void main_window_destroy_cb(');
    final hostFree = linux.indexOf('void host_free(');
    expect(destroyCallback, isNonNegative);
    expect(
      linux.substring(destroyCallback, hostFree),
      contains('gtk_widget_destroy('),
    );
    // host_free runs from the main window's finalize, where destroying
    // other toplevels would re-enter GTK.
    final hostFreeBody = linux.substring(
      hostFree,
      linux.indexOf('\n}\n', hostFree),
    );
    expect(hostFreeBody, isNot(contains('gtk_widget_destroy(')));
    expect(
      linux,
      contains(
        RegExp(
          r'g_signal_connect\(main_window, "destroy",\s*G_CALLBACK\(main_window_destroy_cb\)',
        ),
      ),
    );
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

  group("an extra window has the main window's integrations", () {
    final dropIn = {
      'linux': _read('linux/runner/drop_in_channel.cc'),
      'macos': _read('macos/Runner/DropInView.swift'),
      'windows': _read('windows/runner/drop_in.cpp'),
    };

    test('every runner reports drops on the channel Dart decodes', () {
      expect(runners['macos'], contains('"${windowDropInChannel.name}"'));
      expect(dropIn['linux'], contains('"${windowDropInChannel.name}"'));
      expect(runners['windows'], contains('"${windowDropInChannel.name}"'));
      for (final MapEntry(key: platform, value: source) in dropIn.entries) {
        for (final method in WindowDropInMethod.values) {
          expect(source, contains('"${method.name}"'), reason: '$platform $method');
        }
        for (final key in WindowDropInKey.values) {
          expect(source, contains('"${key.name}"'), reason: '$platform $key');
        }
      }
    });

    test('drops from other apps are taken as copies only (00 D14)', () {
      expect(dropIn['linux'], contains('GDK_ACTION_COPY'));
      expect(dropIn['linux'], isNot(contains('GDK_ACTION_MOVE')));
      expect(dropIn['windows'], contains('*effect &= DROPEFFECT_COPY;'));
      expect(dropIn['windows'], isNot(contains('DROPEFFECT_MOVE')));
      expect(dropIn['macos'], contains('return .copy'));
      expect(dropIn['macos'], isNot(contains('.move')));
    });

    test('each runner gives every extra view a drop target and its drags '
        'out', () {
      expect(
        runners['linux'],
        contains('drag_out_channel_add_view(view);\n  drop_in_channel_add_view(view);'),
      );
      expect(runners['windows'], contains('ViewDropTarget::Register('));
      // Revoked before the view goes, which RevokeDragDrop needs.
      final windows = runners['windows']!;
      expect(
        windows.indexOf('drop_target_->Revoke();'),
        lessThan(windows.indexOf('FlutterDesktopViewControllerDestroy(')),
      );
      expect(
        _read('windows/runner/flutter_window.cpp'),
        contains('drag_out_->SetViewResolver('),
      );
      expect(runners['macos'], contains('controller.view.addSubview(DropInView('));
      expect(runners['macos'], contains('dragOut?.controllerForView = '));
      expect(
        _read('macos/Runner/DragOutChannel.swift'),
        contains('let viewId = (args["viewId"] as? NSNumber)?.int64Value ?? 0'),
      );
      expect(
        _read('linux/runner/drag_out_channel.cc'),
        contains('view_for(self, view_id_at(args))'),
      );
    });

    test('the new sources are compiled in', () {
      expect(
        _read('linux/runner/CMakeLists.txt'),
        contains('"drop_in_channel.cc"'),
      );
      expect(_read('windows/runner/CMakeLists.txt'), contains('"drop_in.cpp"'));
      final project = _read('macos/Runner.xcodeproj/project.pbxproj');
      expect(project, contains('QuickLookHost.swift in Sources'));
      expect(project, contains('DropInView.swift in Sources'));
    });

    test('macOS serves the titlebar channel for extra windows', () {
      final macos = runners['macos']!;
      expect(macos, contains('"${windowTitlebarChannel.name}"'));
      for (final method in WindowTitlebarMethod.values) {
        expect(macos, contains('case "${method.name}":'), reason: '$method');
      }
      for (final event in WindowTitlebarEvent.values) {
        expect(macos, contains('"${event.name}"'), reason: '$event');
      }
      for (final key in WindowTitlebarKey.values) {
        expect(macos, contains('"${key.name}"'), reason: '$key');
      }
      // The main window's titlebar geometry: full-size content under an
      // empty unified toolbar.
      expect(macos, contains('.fullSizeContentView'));
      expect(macos, contains('toolbarStyle = .unified'));
      expect(macos, contains('titlebarAppearsTransparent = true'));
    });

    test('every macOS workspace window hands the Quick Look panel to the '
        'one host', () {
      final host = _read('macos/Runner/QuickLookHost.swift');
      for (final method in [
        'isAvailable',
        'isVisible',
        'showPreview',
        'updatePreview',
        'hidePreview',
      ]) {
        expect(host, contains('"$method"'), reason: method);
      }
      expect(host, contains('invokeMethod("closed", arguments: ["viewId":'));
      for (final window in [
        _read('macos/Runner/MainFlutterWindow.swift'),
        runners['macos']!,
      ]) {
        expect(window, contains('quickLook?.acceptsControl(panel)'));
        expect(window, contains('quickLook?.beginControl(panel)'));
        expect(window, contains('quickLook?.endControl(panel)'));
      }
    });

    test("macOS routes each view's semantics to its own window", () {
      final controller = _read(
        'macos/Runner/PoltergeistFlutterViewController.m',
      );
      expect(controller, contains('- (void)updateSemantics:(const void*)update {'));
      // A late view has no bridge until told semantics are on.
      expect(
        controller.indexOf('[target notifySemanticsEnabledChanged];'),
        lessThan(controller.indexOf('[target updateSemantics:update];')),
      );
      expect(controller, contains('offsetof(PoltergeistSemanticsUpdate, view_id)'));
    });
  });
}
