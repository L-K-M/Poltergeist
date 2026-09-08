import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/prompts/keyboard_interactive_dialog.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

const _data = KeyboardInteractivePromptData(
  name: 'Duo Security',
  instruction: 'Enter the code from your authenticator',
  prompts: ['Passcode', 'Second factor'],
);

class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  List<String>? result;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) {
              final result = this.result;
              return result == null
                  ? FilledButton(
                      onPressed: () async {
                        this.result = await showKeyboardInteractiveDialog(
                          context,
                          _data,
                        );
                        if (mounted) setState(() {});
                      },
                      child: const Text('open'),
                    )
                  : Text('result:${result.join('|')}');
            },
          ),
        ),
      ),
    );
  }
}

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(const _Harness());
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders name, instruction, and one field per prompt', (
    tester,
  ) async {
    await _open(tester);

    expect(find.text('Duo Security'), findsOneWidget);
    expect(find.text('Enter the code from your authenticator'), findsOneWidget);
    expect(find.text('Passcode'), findsOneWidget);
    expect(find.text('Second factor'), findsOneWidget);
    expect(find.text('Submit'), findsOneWidget);
  });

  testWidgets('falls back to a localized title when the name is empty', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                await showKeyboardInteractiveDialog(
                  context,
                  const KeyboardInteractivePromptData(
                    name: '',
                    instruction: '',
                    prompts: ['Code'],
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Authentication'), findsOneWidget);
  });

  testWidgets('answers one value per prompt, in order', (tester) async {
    await _open(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Passcode'),
      '123456',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Second factor'),
      'push',
    );
    await tester.tap(find.text('Submit'));
    await tester.pumpAndSettle();

    expect(find.text('result:123456|push'), findsOneWidget);
  });

  testWidgets('Enter in the final prompt submits every answer', (tester) async {
    await _open(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Passcode'),
      '123456',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Second factor'),
      'push',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('result:123456|push'), findsOneWidget);
  });

  testWidgets('Enter advances from a non-final prompt', (tester) async {
    await _open(tester);

    final passcode = find.widgetWithText(TextField, 'Passcode');
    final secondFactor = find.widgetWithText(TextField, 'Second factor');
    expect(
      tester.widget<TextField>(passcode).textInputAction,
      TextInputAction.next,
    );
    expect(
      tester.widget<TextField>(secondFactor).textInputAction,
      TextInputAction.done,
    );

    await tester.enterText(passcode, '123456');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();

    expect(
      find.descendant(
        of: secondFactor,
        matching: find.byWidgetPredicate(
          (widget) => widget is EditableText && widget.focusNode.hasFocus,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a repeated submit cannot pop the route below the dialog', (
    tester,
  ) async {
    await _open(tester);
    final submit = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Submit'),
    );

    submit.onPressed!();
    submit.onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('result:|'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel answers with an empty list (fails the auth step)', (
    tester,
  ) async {
    await _open(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Passcode'),
      '123456',
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('result:'), findsOneWidget);
  });

  testWidgets('answers are obscured until revealed, per field', (tester) async {
    await _open(tester);

    TextField fieldOf(String label) =>
        tester.widget<TextField>(find.widgetWithText(TextField, label));

    expect(fieldOf('Passcode').obscureText, isTrue);
    expect(fieldOf('Second factor').obscureText, isTrue);
    expect(find.byTooltip('Show answer'), findsNWidgets(2));

    await tester.tap(find.byTooltip('Show answer').first);
    await tester.pump();

    expect(fieldOf('Passcode').obscureText, isFalse);
    expect(fieldOf('Second factor').obscureText, isTrue);
    expect(find.byTooltip('Hide answer'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide answer'));
    await tester.pump();
    expect(fieldOf('Passcode').obscureText, isTrue);
  });

  testWidgets('field controllers dispose only after the route exit animation — '
      'the ported use-after-dispose regression', (tester) async {
    await _open(tester);

    // Focus a field so its IME connection is live — the exact state under
    // which Séance's early dispose threw (the port's doc comment records
    // `clearComposing()` firing on focus loss).
    await tester.enterText(find.widgetWithText(TextField, 'Passcode'), '1');
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    // Pump the full reverse transition: dispose must happen after it.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));

    // No exceptions escaped the frame — the test fails loudly otherwise.
    expect(tester.takeException(), isNull);
  });

  testWidgets('the first field autofocuses for immediate typing', (
    tester,
  ) async {
    await _open(tester);

    final passcode = find.widgetWithText(TextField, 'Passcode');
    final focusedEditor = find.descendant(
      of: passcode,
      matching: find.byWidgetPredicate(
        (widget) => widget is EditableText && widget.focusNode.hasFocus,
      ),
    );
    expect(passcode, findsOneWidget);
    expect(
      focusedEditor,
      findsOneWidget,
      reason: 'the first prompt field must own keyboard focus',
    );
    expect(tester.testTextInput.hasAnyClients, isTrue);

    // Text enters through the active IME without clicking the field.
    tester.testTextInput.enterText('a');
    await tester.pump();
    expect(tester.widget<EditableText>(focusedEditor).controller.text, 'a');
  });
}
