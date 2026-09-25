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

  // The production header's shape on Linux/Windows (10 §4): the sidebar
  // toggle, back / forward, three actions, labelled Sync and Connect,
  // the activity and inspector buttons, the filter field, and ☰.
  CommandToolbarPlacement at(
    ToolbarSlot slot,
    int order, {
    int group = 0,
    bool labelled = false,
  }) => CommandToolbarPlacement(
    slot: slot,
    order: order,
    group: group,
    labelled: labelled,
  );
  final production = [
    command('sidebar', placement: at(ToolbarSlot.leading, 10)),
    command('back', placement: at(ToolbarSlot.leading, 20, group: 1)),
    command('forward', placement: at(ToolbarSlot.leading, 21, group: 1)),
    command('newFolder', placement: at(ToolbarSlot.actions, 10)),
    command('trash', placement: at(ToolbarSlot.actions, 20)),
    command('copy', placement: at(ToolbarSlot.actions, 30)),
    command('sync', placement: at(ToolbarSlot.primary, 10, labelled: true)),
    command(
      'connect',
      placement: at(ToolbarSlot.primary, 20, labelled: true),
    ),
    command('activity', placement: at(ToolbarSlot.status, 10, group: 1)),
    command('inspector', placement: at(ToolbarSlot.status, 20, group: 1)),
  ];

  /// The narrowest the header gets: the pane floor (two 260 px panes and
  /// their splitter) the sidebar leaves beside it when inline.
  const headerFloor = 527.0;

  Future<void> pumpHeader(
    WidgetTester tester, {
    double width = 1200,
    Map<String, ToolbarBadge> badges = const {},
    List<RegisteredCommand>? shown,
    bool chrome = false,
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
              commands: shown ?? commands,
              onRun: (command) async => runs.add(command.id),
              title: const Text('Title'),
              badges: badges,
              filterField: chrome ? const SizedBox(height: 28) : null,
              // AppMainMenuButton's shape: a compact 18 px IconButton.
              menuButton: chrome
                  ? IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: () {},
                      icon: const Icon(Icons.menu),
                    )
                  : null,
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

  testWidgets('narrowing sheds the primary labels, then folds the actions, '
      'then the primary buttons, into »', (tester) async {
    // 0: labelled, 1: icon-only, 2: actions in », 3: Sync/Connect too.
    var stage = 0;
    for (var width = 1200.0; width >= headerFloor; width -= 7) {
      await pumpHeader(tester, width: width, shown: production, chrome: true);
      final labelled = find.text('Label sync').evaluate().isNotEmpty;
      final actionsInline = button('newFolder').evaluate().isNotEmpty;
      final primaryInline = button('sync').evaluate().isNotEmpty;
      final now = labelled
          ? 0
          : actionsInline
          ? 1
          : primaryInline
          ? 2
          : 3;
      expect(primaryInline || !actionsInline, isTrue, reason: '$width');
      expect(now, greaterThanOrEqualTo(stage), reason: '$width px');
      stage = now;
    }
    expect(stage, 3, reason: 'the floor sheds everything it can');

    // Whatever folded still runs from the » menu.
    await tester.tap(find.byKey(const ValueKey('toolbar.overflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toolbar.overflow.sync')));
    await tester.pumpAndSettle();
    expect(runs, ['sync']);
  });

  testWidgets('down to the header floor the title keeps its room and '
      'nothing overflows', (tester) async {
    for (var width = 1200.0; width >= headerFloor; width -= 7) {
      await pumpHeader(tester, width: width, shown: production, chrome: true);
      expect(tester.takeException(), isNull, reason: '$width px');
      expect(
        tester.getSize(find.text('Title')).width,
        greaterThanOrEqualTo(96),
        reason: '$width px',
      );
    }
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
    await pumpHeader(
      tester,
      badges: {'status': const ToolbarBadge(count: 3, announcement: '')},
    );
    expect(
      find.descendant(of: button('status'), matching: find.text('3')),
      findsOneWidget,
    );
    await pumpHeader(
      tester,
      badges: {'status': const ToolbarBadge(count: 120, announcement: '')},
    );
    expect(
      find.descendant(of: button('status'), matching: find.text('99+')),
      findsOneWidget,
    );
  });

  testWidgets('a badge is announced in words; no badge, no value', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await pumpHeader(
        tester,
        badges: {
          'status': const ToolbarBadge(count: 3, announcement: '3 alerts'),
          'lead': const ToolbarBadge(count: 0, announcement: 'none'),
        },
      );
      String valueOf(String id) =>
          tester.getSemantics(button(id)).getSemanticsData().value;
      expect(valueOf('status'), '3 alerts');
      expect(valueOf('lead'), isEmpty);
    } finally {
      semantics.dispose();
    }
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
