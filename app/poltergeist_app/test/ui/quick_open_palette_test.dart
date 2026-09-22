import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/recent_locations.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/ui/quick_open/quick_open_palette.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final _now = DateTime.utc(2026, 10, 1);

Bookmark _remoteFavorite(String id) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: 'fav-$id',
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: '$id.example.com',
      port: 22,
      username: 'deploy',
      authMethod: AuthMethod.agent,
    ),
  ),
  remotePath: '/srv/$id',
  sortKey: 'mm',
  createdAt: _now,
  updatedAt: _now,
);

Bookmark _localFavorite(String id) => Bookmark(
  id: id,
  kind: BookmarkKind.localFolder,
  label: 'fav-$id',
  localPath: '/local/$id',
  sortKey: 'mm',
  createdAt: _now,
  updatedAt: _now,
);

RegisteredCommand _command(
  String id, {
  bool Function()? enabled,
  String? disabledReason,
  CommandScope scope = CommandScope.app,
  List<ShortcutActivator> Function(TargetPlatform)? activators,
  CommandMenuPlacement? menuPlacement,
  void Function()? onRun,
}) => RegisteredCommand(
  id: id,
  scope: scope,
  label: (l10n) => 'Label $id',
  enabled: enabled ?? () => true,
  disabledReason: disabledReason == null
      ? null
      : (l10n) => 'because $disabledReason',
  activators: activators,
  menuPlacement: menuPlacement,
  run: (_) async => onRun?.call(),
);

void main() {
  Future<void> pumpPalette(
    WidgetTester tester, {
    List<RegisteredCommand> commands = const [],
    List<Bookmark> favorites = const [],
    List<RecentLocation> recents = const [],
    void Function(RegisteredCommand)? onCommand,
    void Function(Bookmark, QuickOpenAction)? onFavorite,
    void Function(RecentLocation, QuickOpenAction)? onRecent,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        // Pin the platform: chord formatting spells Ctrl+… on Linux and
        // ⌃… on macOS — the assertions must not depend on the host.
        theme: ThemeData(platform: TargetPlatform.linux),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showQuickOpenPalette(
                context,
                commands: commands,
                favorites: favorites,
                recents: recents,
                resolveRecentBookmark: (_) => null,
                onCommand: onCommand ?? (_) {},
                onFavorite: onFavorite ?? (_, _) {},
                onRecent: onRecent ?? (_, _) {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('renders all three sections', (tester) async {
    await pumpPalette(
      tester,
      commands: [_command('app.alpha')],
      favorites: [_remoteFavorite('one')],
      recents: [const RecentLocation.local(label: 'one', path: '/tmp/one')],
    );

    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l10n.quickOpenSectionCommands), findsOneWidget);
    expect(find.text(l10n.quickOpenSectionFavorites), findsOneWidget);
    expect(find.text(l10n.quickOpenSectionRecents), findsOneWidget);
    expect(find.text('Label app.alpha'), findsOneWidget);
    expect(find.text('fav-one'), findsOneWidget);
    expect(find.text('one'), findsOneWidget);
  });

  testWidgets('enabled commands rank ahead of disabled ones', (tester) async {
    await pumpPalette(
      tester,
      commands: [
        _command('app.disabled', enabled: () => false, disabledReason: 'x'),
        _command('app.enabled'),
      ],
    );

    final enabled = tester.getTopLeft(find.text('Label app.enabled'));
    final disabled = tester.getTopLeft(find.text('Label app.disabled'));
    expect(enabled.dy, lessThan(disabled.dy));
  });

  testWidgets('a disabled command row shows its reason', (tester) async {
    await pumpPalette(
      tester,
      commands: [
        _command(
          'app.disabled',
          enabled: () => false,
          disabledReason: 'nothing to do',
        ),
      ],
    );
    expect(find.text('because nothing to do'), findsOneWidget);
  });

  testWidgets('command rows show their shortcut', (tester) async {
    await pumpPalette(
      tester,
      commands: [
        _command(
          'app.chord',
          activators: (_) => const [
            SingleActivator(LogicalKeyboardKey.keyQ, control: true),
          ],
        ),
      ],
    );
    expect(find.text('Ctrl+Q'), findsOneWidget);
  });

  testWidgets('Enter accepts the highlighted command', (tester) async {
    final ran = <String>[];
    await pumpPalette(
      tester,
      commands: [_command('app.go')],
      onCommand: (command) => ran.add(command.id),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(ran, ['app.go']);
    // The palette closed on accept.
    expect(find.byKey(const ValueKey('quickOpen.field')), findsNothing);
  });

  testWidgets('Escape closes the palette', (tester) async {
    await pumpPalette(tester, commands: [_command('app.alpha')]);
    expect(find.byKey(const ValueKey('quickOpen.field')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quickOpen.field')), findsNothing);
  });

  testWidgets('an app-scoped chord inside the palette runs and closes', (
    tester,
  ) async {
    final ran = <String>[];
    await pumpPalette(
      tester,
      commands: [
        _command(
          'app.chord',
          activators: (_) => const [
            SingleActivator(LogicalKeyboardKey.keyQ, control: true),
          ],
        ),
      ],
      onCommand: (command) => ran.add(command.id),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(ran, ['app.chord']);
    expect(find.byKey(const ValueKey('quickOpen.field')), findsNothing);
  });

  testWidgets('a pane-scoped chord inside the palette stays suspended', (
    tester,
  ) async {
    final ran = <String>[];
    await pumpPalette(
      tester,
      commands: [
        _command(
          'pane.delete',
          scope: CommandScope.pane,
          activators: (_) => const [
            SingleActivator(LogicalKeyboardKey.keyW, control: true),
          ],
        ),
      ],
      onCommand: (command) => ran.add(command.id),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(ran, isEmpty);
    expect(find.byKey(const ValueKey('quickOpen.field')), findsOneWidget);
  });

  testWidgets('a disabled app-scoped chord stays open, no dispatch', (
    tester,
  ) async {
    final ran = <String>[];
    await pumpPalette(
      tester,
      commands: [
        _command(
          'app.locked',
          enabled: () => false,
          disabledReason: 'x',
          activators: (_) => const [
            SingleActivator(LogicalKeyboardKey.keyE, control: true),
          ],
        ),
      ],
      onCommand: (command) => ran.add(command.id),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(ran, isEmpty);
    expect(find.byKey(const ValueKey('quickOpen.field')), findsOneWidget);
  });

  testWidgets('Ctrl+Enter on a favorite accepts as newTab', (tester) async {
    final accepted = <(Bookmark, QuickOpenAction)>[];
    await pumpPalette(
      tester,
      favorites: [_localFavorite('here')],
      onFavorite: (bookmark, action) => accepted.add((bookmark, action)),
    );

    // The first highlight lands on the favorite row (no commands).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(accepted.single.$2, QuickOpenAction.newTab);
    expect(accepted.single.$1.id, 'here');
  });

  testWidgets('Alt+Enter on a recent accepts as otherPane', (tester) async {
    final accepted = <(RecentLocation, QuickOpenAction)>[];
    await pumpPalette(
      tester,
      recents: [const RecentLocation.local(label: 'one', path: '/tmp/one')],
      onRecent: (recent, action) => accepted.add((recent, action)),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();

    expect(accepted.single.$2, QuickOpenAction.otherPane);
    expect(accepted.single.$1.path, '/tmp/one');
  });

  testWidgets('typing filters rows by label', (tester) async {
    await pumpPalette(
      tester,
      commands: [_command('app.copy'), _command('app.delete')],
    );
    await tester.enterText(
      find.byKey(const ValueKey('quickOpen.field')),
      'copy',
    );
    await tester.pumpAndSettle();
    expect(find.text('Label app.copy'), findsOneWidget);
    expect(find.text('Label app.delete'), findsNothing);
  });

  testWidgets('a remote recent with no resolvable bookmark is disabled', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await pumpPalette(
      tester,
      recents: [
        const RecentLocation.remote(
          label: 'gone',
          path: '/srv/web',
          serverId: 'gone',
          remoteBookmark: null,
        ),
      ],
    );
    expect(find.text(l10n.quickOpenRecentUnavailable), findsOneWidget);
  });
}
