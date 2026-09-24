import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/ui/menus/app_menu_host.dart';

/// The live registry the mounted shell rendered last (D21): read from
/// the menu host, which every shell build feeds the whole list. D32's
/// header renders only curated commands, so tests address commands by
/// id through here rather than by a toolbar button that may not exist.
List<RegisteredCommand> shellCommands(WidgetTester tester) =>
    tester.widget<AppMenuHost>(find.byType(AppMenuHost)).commands;

/// The registered command [id], or a failed expectation naming it.
RegisteredCommand shellCommand(WidgetTester tester, String id) {
  final match = shellCommands(tester).where((c) => c.id == id);
  expect(match, isNotEmpty, reason: 'command $id is not registered');
  return match.first;
}

bool shellCommandRegistered(WidgetTester tester, String id) =>
    shellCommands(tester).any((c) => c.id == id);

bool shellCommandEnabled(WidgetTester tester, String id) =>
    shellCommand(tester, id).enabled();

/// Runs [id] through the shell's own runner — the path the menus, the
/// chord layer, and the header's buttons take (enablement and the
/// one-session guard included) — then pumps.
Future<void> runShellCommand(
  WidgetTester tester,
  String id, {
  bool settle = true,
}) async {
  final host = tester.widget<AppMenuHost>(find.byType(AppMenuHost));
  final command = shellCommand(tester, id);
  unawaited(host.onRun(command));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}
