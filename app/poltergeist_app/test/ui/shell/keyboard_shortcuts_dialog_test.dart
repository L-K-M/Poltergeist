import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/ui/shell/keyboard_shortcuts_dialog.dart';

RegisteredCommand _command(
  String id,
  String label,
  List<ShortcutActivator>? activators, {
  AppMenuId? menu,
}) => RegisteredCommand(
  id: id,
  scope: CommandScope.app,
  label: (_) => label,
  activators: activators == null ? null : (_) => activators,
  menuPlacement: menu == null
      ? null
      : CommandMenuPlacement(menu: menu, order: 10),
  run: (_) async {},
);

void main() {
  testWidgets('lists every chorded command under its menu, macOS glyphs', (
    tester,
  ) async {
    final commands = [
      _command(
        'tab.new',
        'New Tab',
        const [SingleActivator(LogicalKeyboardKey.keyT, meta: true)],
        menu: AppMenuId.file,
      ),
      _command(
        'view.refresh',
        'Refresh',
        const [SingleActivator(LogicalKeyboardKey.keyR, meta: true)],
        menu: AppMenuId.view,
      ),
      _command('app.noChord', 'No Chord', null, menu: AppMenuId.file),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showKeyboardShortcutsDialog(context, commands),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('help.shortcuts.dialog')), findsOneWidget);
    expect(find.text('New Tab'), findsOneWidget);
    expect(find.text('⌘T'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
    // A command without a chord has nothing to teach here.
    expect(find.text('No Chord'), findsNothing);
  });
}
