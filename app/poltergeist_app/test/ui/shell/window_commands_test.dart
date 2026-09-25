import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/workspace_windows/workspace_windows.dart';
import 'package:poltergeist_app/ui/shell/window_commands.dart';

import '../../services/workspace_windows_test.dart' show FakeWindowHost;

class _NoContext extends Fake implements BuildContext {}

void main() {
  late FakeWindowHost host;
  late WorkspaceWindows windows;
  late int quits;

  setUp(() async {
    host = FakeWindowHost();
    quits = 0;
    windows = WorkspaceWindows(
      host: host,
      quitApplication: () async => quits++,
      afterFrame: () async {},
      platform: TargetPlatform.linux,
    );
    await windows.start();
  });

  tearDown(() => windows.dispose());

  RegisteredCommand command(String id) => buildWindowCommands(
    window: windows.windows.single,
  ).singleWhere((command) => command.id == id);

  test('New Window and Close Window sit in File around the tab verbs', () {
    final l10n = AppLocalizationsEn();
    final newWindow = command(kWindowNewCommandId);
    final closeWindow = command(kWindowCloseCommandId);

    expect(newWindow.label(l10n), 'New Window');
    expect(closeWindow.label(l10n), 'Close Window');
    expect(newWindow.scope, CommandScope.app);
    expect(newWindow.menuPlacement!.menu, AppMenuId.file);
    // Ahead of New Tab (10); after Close Tab (30), in its group (5).
    expect(newWindow.menuPlacement!.order, lessThan(10));
    expect(closeWindow.menuPlacement!.group, 5);
    expect(closeWindow.menuPlacement!.order, greaterThan(30));
  });

  test('⌘N and ⇧⌘W on macOS, Ctrl+N and Ctrl+Shift+W elsewhere', () {
    final newWindow = command(kWindowNewCommandId).activators!;
    final closeWindow = command(kWindowCloseCommandId).activators!;

    expect(newWindow(TargetPlatform.macOS), const [
      SingleActivator(LogicalKeyboardKey.keyN, meta: true),
    ]);
    expect(newWindow(TargetPlatform.linux), const [
      SingleActivator(LogicalKeyboardKey.keyN, control: true),
    ]);
    expect(closeWindow(TargetPlatform.macOS), const [
      SingleActivator(LogicalKeyboardKey.keyW, meta: true, shift: true),
    ]);
    expect(closeWindow(TargetPlatform.windows), const [
      SingleActivator(LogicalKeyboardKey.keyW, control: true, shift: true),
    ]);
  });

  test('New Window opens one; Close Window on the last one quits', () async {
    await command(kWindowNewCommandId).run(_NoContext());
    expect(host.calls, ['create 1']);

    final extra = windows.windows.last;
    await buildWindowCommands(window: extra)
        .singleWhere((command) => command.id == kWindowCloseCommandId)
        .run(_NoContext());
    expect(host.calls, contains('destroy 1'));

    await command(kWindowCloseCommandId).run(_NoContext());
    expect(quits, 1);
  });
}
