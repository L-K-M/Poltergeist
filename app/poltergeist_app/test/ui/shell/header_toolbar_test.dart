import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/shortcut_format.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/shell/header_toolbar.dart';

/// D32's header (10 §4) rendered straight from a command list: it is a
/// curated rendering of the registry — only commands with a toolbar
/// placement appear — with shortcut tooltips, badges, and the overflow
/// order as the window narrows.
void main() {
  final runs = <String>[];

  setUp(runs.clear);

  RegisteredCommand command(
    String id, {
    CommandToolbarPlacement? placement,
    bool enabled = true,
    List<ShortcutActivator> Function(TargetPlatform)? activators,
  }) => RegisteredCommand(
    id: id,
    scope: CommandScope.app,
    label: (l10n) => 'Label $id',
    icon: Icons.star_outline,
    enabled: () => enabled,
    activators: activators,
    toolbarPlacement: placement,
    run: (_) async {},
  );

  final commands = [
    command(
      'lead',
      placement: const CommandToolbarPlacement(
        slot: ToolbarSlot.leading,
        order: 10,
      ),
    ),
    command(
      'action',
      placement: const CommandToolbarPlacement(
        slot: ToolbarSlot.actions,
        order: 10,
      ),
    ),
    command(
      'primary',
      placement: const CommandToolbarPlacement(
        slot: ToolbarSlot.primary,
        order: 10,
        labelled: true,
      ),
      activators: (_) => const [
        SingleActivator(LogicalKeyboardKey.keyK, control: true),
      ],
    ),
    command(
      'status',
      enabled: false,
      placement: const CommandToolbarPlacement(
        slot: ToolbarSlot.status,
        order: 10,
      ),
    ),
    // Registered but uncurated: menus and chords only.
    command('menuOnly'),
  ];

  Future<void> pumpHeader(
    WidgetTester tester, {
    double width = 1200,
    Map<String, int> badges = const {},
  }) async {
    tester.view.physicalSize = Size(width, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPoltergeistTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: HeaderToolbar(
              commands: commands,
              onRun: (command) async => runs.add(command.id),
              title: const Text('Title'),
              badges: badges,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder button(String id) => find.byKey(ValueKey('command.$id'));

  testWidgets('renders only the curated commands, in slot order', (
    tester,
  ) async {
    await pumpHeader(tester);
    for (final id in ['lead', 'action', 'primary', 'status']) {
      expect(button(id), findsOneWidget, reason: id);
    }
    expect(button('menuOnly'), findsNothing);

    double x(String id) => tester.getCenter(button(id)).dx;
    expect(x('lead'), lessThan(tester.getCenter(find.text('Title')).dx));
    expect(x('action'), lessThan(x('primary')));
    expect(x('primary'), lessThan(x('status')));
  });

  testWidgets('buttons run through onRun; a disabled one is inert', (
    tester,
  ) async {
    await pumpHeader(tester);
    await tester.tap(button('action'));
    await tester.tap(button('status'));
    await tester.pump();
    expect(runs, ['action']);
    expect(tester.widget<InkWell>(button('status')).onTap, isNull);
  });

  testWidgets('primary buttons carry their label; narrow windows shed it '
      'first, then fold the actions into »', (tester) async {
    await pumpHeader(tester);
    expect(find.text('Label primary'), findsOneWidget);
    expect(find.byKey(const ValueKey('toolbar.overflow')), findsNothing);

    await pumpHeader(tester, width: 760);
    expect(find.text('Label primary'), findsNothing);
    expect(button('action'), findsOneWidget);

    await pumpHeader(tester, width: 600);
    expect(button('action'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('toolbar.overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toolbar.overflow.action')));
    await tester.pumpAndSettle();
    expect(runs, ['action']);
  });

  testWidgets('assistive tech can press a button, never a disabled one', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpHeader(tester);
      final node = tester.getSemantics(button('action'));
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester.semantics.tap(find.semantics.byLabel('Label action'));
      await tester.pump();
      expect(runs, ['action']);

      final disabled = tester.getSemantics(button('status'));
      expect(
        disabled.getSemanticsData().hasAction(SemanticsAction.tap),
        isFalse,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a badge shows its count, capped at 99+', (tester) async {
    await pumpHeader(tester, badges: {'status': 3});
    expect(
      find.descendant(of: button('status'), matching: find.text('3')),
      findsOneWidget,
    );
    await pumpHeader(tester, badges: {'status': 120});
    expect(
      find.descendant(of: button('status'), matching: find.text('99+')),
      findsOneWidget,
    );
  });

  test('the tooltip names the first shortcut after the label', () {
    final l10n = AppLocalizationsEn();
    final primary = commands.singleWhere((c) => c.id == 'primary');
    final chord = formatShortcutActivator(
      const SingleActivator(LogicalKeyboardKey.keyK, control: true),
      TargetPlatform.linux,
    )!;
    expect(
      commandTooltip(primary, l10n, TargetPlatform.linux),
      'Label primary  $chord',
    );
    final lead = commands.singleWhere((c) => c.id == 'lead');
    expect(commandTooltip(lead, l10n, TargetPlatform.linux), 'Label lead');
  });
}
