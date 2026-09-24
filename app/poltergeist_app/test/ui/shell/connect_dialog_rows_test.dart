import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/shell/connect_dialog.dart';

/// D32 §4's Connect popover: saved servers as one-click rows above Quick
/// Connect, recent first, keyboard-driven from the focused field, in a
/// dialog that hugs its content.
void main() {
  ConnectServerChoice choice(String id, List<String> opened) =>
      ConnectServerChoice(
        id: id,
        label: 'Server $id',
        detail: 'me@$id.example.com',
        mark: const Icon(Icons.dns_outlined, size: 16),
        open: () => opened.add(id),
      );

  group('orderConnectChoices', () {
    test('recent servers first (deduped), then alphabetical, capped', () {
      final opened = <String>[];
      final choices = [
        for (final id in ['delta', 'alpha', 'echo', 'bravo', 'golf', 'charlie',
            'foxtrot', 'hotel'])
          choice(id, opened),
      ];
      final ordered = orderConnectChoices(choices, [
        'golf',
        'gone-server',
        'bravo',
        'golf',
      ]);
      expect(ordered.map((c) => c.id), [
        'golf',
        'bravo',
        'alpha',
        'charlie',
        'delta',
        'echo',
      ]);
      expect(ordered, hasLength(connectDialogServerLimit));
    });
  });

  group('dialog', () {
    late List<String> opened;
    late List<String> connected;

    Future<void> pumpDialog(WidgetTester tester, int servers) async {
      opened = [];
      connected = [];
      tester.view.physicalSize = const Size(1180, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildPoltergeistTheme(
            Brightness.light,
            platform: TargetPlatform.linux,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const ValueKey('open'),
                  onPressed: () => showConnectDialog(
                    context,
                    servers: [
                      for (var i = 0; i < servers; i++)
                        choice('s$i', opened),
                    ],
                    onConnect: (bookmark, _) =>
                        connected.add(bookmark.server!.identity!.host),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
    }

    final dialog = find.byKey(const ValueKey('connect.dialog'));
    final field = find.byKey(const ValueKey('quickConnect.field'));

    testWidgets('hugs its content instead of filling the window', (
      tester,
    ) async {
      for (final servers in [0, 3]) {
        await pumpDialog(tester, servers);
        final size = tester.getSize(
          find.descendant(of: dialog, matching: find.byType(Material)).first,
        );
        expect(size.width, inInclusiveRange(440, 500), reason: '$servers');
        expect(size.height, lessThan(760 * 0.7), reason: '$servers');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
    });

    testWidgets('the field has focus; arrows walk the rows and Return opens '
        'the highlighted one', (tester) async {
      await pumpDialog(tester, 3);
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      expect(find.text('Server s0'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      // Focus never leaves the field while the highlight moves.
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(dialog, findsNothing);
      expect(opened, ['s1']);
    });

    testWidgets('↑ from the field lands on the last row; past the ends '
        'Return goes back to the address', (tester) async {
      await pumpDialog(tester, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      // s1 → s0 → no highlight: the typed address connects.
      await tester.enterText(field, 'me@typed.example.com');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(connected, ['typed.example.com']);
    });

    testWidgets('typing drops the highlight so Return connects the address', (
      tester,
    ) async {
      await pumpDialog(tester, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.enterText(field, 'me@other.example.com');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(connected, ['other.example.com']);
    });

    testWidgets('a click opens a row', (tester) async {
      await pumpDialog(tester, 2);
      await tester.tap(find.byKey(const ValueKey('connect.server.s1')));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(opened, ['s1']);
    });
  });
}
