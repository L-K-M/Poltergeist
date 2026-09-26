import 'dart:ui' show FlutterView, Scene, SemanticsUpdate;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/workspace_windows/window_host.dart';
import 'package:poltergeist_app/services/workspace_windows/workspace_window_scope.dart';
import 'package:poltergeist_app/services/workspace_windows/workspace_windows.dart';
import 'package:poltergeist_app/ui/menus/app_menu_host.dart';
import 'package:poltergeist_app/ui/workspace_windows_root.dart';

import '../services/workspace_windows_test.dart' show FakeWindowHost;

/// A second view for the test binding, the way Flutter's own multi-view
/// tests make one: the test view's metrics under another id, rendering
/// nowhere.
final class _FakeView extends TestFlutterView {
  _FakeView(TestFlutterView view, {required this.viewId})
    : super(
        view: view,
        platformDispatcher: view.platformDispatcher,
        display: view.display,
      );

  @override
  final int viewId;

  @override
  void render(Scene scene, {Size? size}) {}

  @override
  void updateSemantics(SemanticsUpdate update) {}
}

/// Records what the root's PlatformMenuBar pushes (the default delegate
/// asserts the real platform for provided items).
class _RecordingMenuDelegate extends PlatformMenuDelegate {
  List<PlatformMenuItem> menus = const [];

  @override
  void clearMenus() => menus = const [];

  @override
  void setMenus(List<PlatformMenuItem> topLevelMenus) => menus = topLevelMenus;

  @override
  bool debugLockDelegate(BuildContext context) => true;

  @override
  bool debugUnlockDelegate(BuildContext context) => true;
}

RegisteredCommand _command(String id) => RegisteredCommand(
  id: id,
  scope: CommandScope.app,
  label: (_) => id,
  run: (_) async {},
  menuPlacement: const CommandMenuPlacement(menu: AppMenuId.file, order: 1),
);

List<String> _fileItems(List<PlatformMenuItem> menus) => [
  for (final menu in menus.whereType<PlatformMenu>())
    if (menu.label == 'File')
      for (final member in menu.menus)
        for (final item
            in member is PlatformMenuItemGroup ? member.members : [member])
          item.label,
];

void main() {
  late FakeWindowHost host;
  late WorkspaceWindows windows;
  late Map<int, FlutterView> views;
  late Map<int, FlutterView> seenViews;

  /// Built inside each test's fake-async zone (see workspace_windows_test).
  Future<void> startWindows(WidgetTester tester) async {
    host = FakeWindowHost();
    windows = WorkspaceWindows(
      host: host,
      quitApplication: () async {},
      afterFrame: () async {},
      platform: TargetPlatform.linux,
    );
    addTearDown(windows.dispose);
    views = {mainWindowViewId: tester.view};
    seenViews = {};
    await windows.start();
  }

  Widget root({Widget Function(WorkspaceWindow window)? content}) =>
      WorkspaceWindowsRoot(
        windows: windows,
        viewFor: (viewId) => views[viewId],
        buildWindow: (window) => MaterialApp(
          theme: ThemeData(platform: defaultTargetPlatform),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              seenViews[window.viewId] = View.of(context);
              final scope = WorkspaceWindowScope.maybeOf(context)!;
              return content?.call(window) ??
                  Text(
                    'window ${window.viewId} '
                    '${scope.active ? 'active' : 'inactive'}',
                  );
            },
          ),
        ),
      );

  testWidgets('renders one view per open window that has one', (tester) async {
    await startWindows(tester);
    await windows.openWindow();
    await tester.pumpWidget(root(), wrapWithView: false);

    // The extra window's view has not arrived yet: nothing renders it.
    expect(find.text('window 0 inactive'), findsOneWidget);
    expect(find.textContaining('window 1'), findsNothing);

    views[1] = _FakeView(tester.view, viewId: 1);
    tester.binding.handleMetricsChanged();
    await tester.pump();

    expect(find.text('window 1 active'), findsOneWidget);

    windows.onWindowActivated(mainWindowViewId);
    await tester.pump();

    expect(find.text('window 0 active'), findsOneWidget);
    expect(find.text('window 1 inactive'), findsOneWidget);
    expect(seenViews[1], same(views[1]));
  });

  testWidgets("macOS: the menu bar shows the active window's menus", (
    tester,
  ) async {
    final delegate = _RecordingMenuDelegate();
    final original = WidgetsBinding.instance.platformMenuDelegate;
    WidgetsBinding.instance.platformMenuDelegate = delegate;
    addTearDown(() {
      WidgetsBinding.instance.platformMenuDelegate = original;
    });
    await startWindows(tester);
    await windows.openWindow();
    views[1] = _FakeView(tester.view, viewId: 1);

    await tester.pumpWidget(
      root(
        content: (window) => AppMenuHost(
          commands: [_command('run ${window.viewId}')],
          onRun: (_) async {},
          child: Text('window ${window.viewId}'),
        ),
      ),
      wrapWithView: false,
    );
    await tester.pump();

    // One bar, the root's: a window's own would fight over the native one.
    expect(find.byType(PlatformMenuBar), findsOneWidget);
    expect(_fileItems(delegate.menus), ['run 1']);

    windows.onWindowActivated(mainWindowViewId);
    await tester.pump();
    await tester.pump();

    expect(_fileItems(delegate.menus), ['run 0']);

    // Every window renders into its own view, semantics included: the
    // runner routes each view's tree to its own window.
    expect(seenViews[1], same(views[1]));
    expect(seenViews[mainWindowViewId], same(tester.view));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
