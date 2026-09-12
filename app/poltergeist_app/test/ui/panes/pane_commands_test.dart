import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';

void main() {
  RegisteredCommand command(
    String id, {
    List<ShortcutActivator> Function(TargetPlatform)? activators,
    bool enabled = true,
    void Function()? onRun,
  }) {
    return RegisteredCommand(
      id: id,
      scope: CommandScope.app,
      label: (l10n) => id,
      activators: activators,
      enabled: () => enabled,
      run: (_) async => onRun?.call(),
    );
  }

  final activator = SingleActivator(LogicalKeyboardKey.keyR, control: true);

  testWidgets('a disabled command still consumes its chord', (tester) async {
    var outerSawKey = false;
    var ran = false;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // The observer sits OUTSIDE the command layer: a disabled
        // command's chord must not fall through to farther scopes
        // (nearer scopes win by Flutter's focus precedence regardless).
        // CallbackShortcuts pairs the intent with its own action, so the
        // detector actually fires if the chord escapes the command layer
        // — a bare Shortcuts mapping could never invoke it.
        home: CallbackShortcuts(
          bindings: {activator: () => outerSawKey = true},
          child: CommandChordScope(
            commands: [
              command(
                'x',
                activators: (_) => [activator],
                enabled: false,
                onRun: () => ran = true,
              ),
            ],
            child: const Scaffold(
              body: Focus(autofocus: true, child: SizedBox.expand()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    // The command layer owns the chord even when the command is
    // disabled: outer scopes never see it, and the command never runs.
    expect(outerSawKey, isFalse);
    expect(ran, isFalse);
  });

  testWidgets('an enabled command\'s chord runs it', (tester) async {
    var ran = false;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CommandChordScope(
          commands: [
            command(
              'x',
              activators: (_) => [activator],
              onRun: () => ran = true,
            ),
          ],
          child: const Scaffold(
            body: Focus(autofocus: true, child: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(ran, isTrue);
  });

  testWidgets('duplicate activators fail the registration assert', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CommandChordScope(
          commands: [
            command('a', activators: (_) => [activator]),
            command('b', activators: (_) => [activator]),
          ],
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );

    // The registration assert trips in debug builds; release keeps the
    // documented later-command-wins behavior.
    expect(tester.takeException(), isA<AssertionError>());
  });
}
