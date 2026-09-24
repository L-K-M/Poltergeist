// The Sync Files sheet (D32 §7): the options drive the plan sentence
// live, Both Ways hides behind ⋯, remote-only availability is honest,
// and each verb hands the configured pair back to the shell.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/rsync_endpoints.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/sync/sync_setup_sheet.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../support/sync_harness.dart';

/// The sheet's recorded outcome — `closed` flips once it pops.
final class _Outcome {
  bool closed = false;
  SyncSheetResult? result;
}

Future<_Outcome> _pumpSheet(
  WidgetTester tester, {
  SyncSheetMode mode = SyncSheetMode.adHoc,
  SyncPair? initial,
  bool Function(SyncEndpoint endpoint)? endpointAvailable,
  Future<bool> Function(SyncPair pair)? onSaveFavorite,
  RsyncEndpointResolver? rsyncEndpoints,
  Size size = const Size(1200, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final outcome = _Outcome();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildPoltergeistTheme(Brightness.dark),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                outcome.result = await showSyncSetupSheet(
                  context,
                  mode: mode,
                  initial:
                      initial ??
                      (mode == SyncSheetMode.newSaved
                          ? null
                          : testSyncPair(
                              left: '/Users/me/site',
                              right: '/Volumes/Backup/site-copy',
                            )),
                  endpointAvailable: endpointAvailable ?? (_) => true,
                  onSaveFavorite: onSaveFavorite,
                  rsyncEndpoints: rsyncEndpoints,
                );
                outcome.closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return outcome;
}

String _plan(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('sync.sheet.plan')))
    .textSpan!
    .toPlainText();

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

const _remoteRight = RemoteEndpoint(
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: '127.0.0.1',
      port: 2222,
      username: 'demo',
      authMethod: AuthMethod.password,
    ),
  ),
  path: '/var/www/site',
);

void main() {
  testWidgets('renders the tiles and the default plan sentence', (
    tester,
  ) async {
    await _pumpSheet(tester);
    expect(find.text('Sync Files'), findsOneWidget);
    expect(find.text('This computer'), findsNWidgets(2));
    expect(find.text('…/Volumes/Backup/site-copy'), findsNothing);
    expect(find.text('/Volumes/Backup/site-copy'), findsOneWidget);
    expect(find.text('Here’s the plan:'), findsOneWidget);
    expect(
      _plan(tester),
      startsWith(
        'Your local folder “site-copy” will be updated from your local '
        'folder “site”.',
      ),
    );
    expect(_plan(tester), endsWith('No files will be deleted.'));
    // The engine cannot follow symlinks or filter by age — neither is
    // offered (D32 §7's hidden rows).
    expect(find.textContaining('symbolic'), findsNothing);
    expect(find.textContaining('days'), findsNothing);
  });

  testWidgets('the direction toggle swaps source and destination', (
    tester,
  ) async {
    final outcome = await _pumpSheet(tester);
    await _tapKey(tester, 'sync.sheet.direction');
    expect(
      _plan(tester),
      startsWith(
        'Your local folder “site” will be updated from your local folder '
        '“site-copy”.',
      ),
    );
    await _tapKey(tester, 'sync.sheet.simulate');
    expect(outcome.result!.action, SyncSheetAction.simulate);
    expect(outcome.result!.pair.rules.direction, SyncDirection.rightToLeft);
  });

  testWidgets('the compare dropdown rewrites the replacement clause', (
    tester,
  ) async {
    await _pumpSheet(tester);
    await _tapKey(tester, 'sync.sheet.compare');
    await tester.tap(find.text('File Size').last);
    await tester.pumpAndSettle();
    expect(
      _plan(tester),
      contains('Files that differ in size will be replaced'),
    );
    expect(find.text('Modification dates aren’t compared'), findsOneWidget);

    await _tapKey(tester, 'sync.sheet.compare');
    await tester.tap(find.text('Checksum').last);
    await tester.pumpAndSettle();
    expect(_plan(tester), contains('compared by checksum'));
  });

  testWidgets('the delete checkbox turns on Mirror with a red clause', (
    tester,
  ) async {
    final outcome = await _pumpSheet(tester);
    expect(find.byKey(const ValueKey('sync.sheet.plan.warning')), findsNothing);
    await _tapKey(tester, 'sync.sheet.deleteOrphans');
    expect(
      _plan(tester),
      contains(
        'Files in “site-copy” that aren’t in “site” will be deleted '
        '(moved to .poltergeist-trash).',
      ),
    );
    expect(_plan(tester), isNot(contains('No files will be deleted.')));
    expect(
      find.byKey(const ValueKey('sync.sheet.plan.warning')),
      findsOneWidget,
    );

    await _tapKey(tester, 'sync.sheet.deletePermanent');
    expect(_plan(tester), contains('will be deleted permanently.'));

    await _tapKey(tester, 'sync.sheet.synchronize');
    expect(outcome.result!.action, SyncSheetAction.synchronize);
    expect(outcome.result!.pair.rules.deletions, DeletionPolicy.permanent);
  });

  testWidgets('Both Ways lives in the ⋯ menu and disables deletions', (
    tester,
  ) async {
    final outcome = await _pumpSheet(tester);
    await _tapKey(tester, 'sync.sheet.deleteOrphans');
    await _tapKey(tester, 'sync.sheet.more');
    await _tapKey(tester, 'sync.sheet.more.bothWays');

    expect(_plan(tester), contains('will each receive the files'));
    expect(_plan(tester), endsWith('No files will be deleted.'));
    expect(find.text('Not available when syncing both ways'), findsOneWidget);
    final checkbox = tester.widget<Checkbox>(
      find.byKey(const ValueKey('sync.sheet.deleteOrphans')),
    );
    expect(checkbox.value, isFalse);
    expect(checkbox.onChanged, isNull);

    // The toggle returns to one-way; it can never select Both Ways.
    await _tapKey(tester, 'sync.sheet.direction');
    expect(_plan(tester), startsWith('Your local folder “site-copy” will be'));

    await _tapKey(tester, 'sync.sheet.more');
    await _tapKey(tester, 'sync.sheet.more.bothWays');
    await _tapKey(tester, 'sync.sheet.simulate');
    final rules = outcome.result!.pair.rules;
    expect(rules.direction, SyncDirection.bidirectional);
    expect(rules.deletions, DeletionPolicy.none);
  });

  testWidgets('hidden files and skip rules feed the sentence and result', (
    tester,
  ) async {
    final outcome = await _pumpSheet(tester);
    await _tapKey(tester, 'sync.sheet.includeHidden');
    expect(_plan(tester), contains('Hidden files are left out.'));

    // Checking "Skip items" with no rules opens the editor.
    await _tapKey(tester, 'sync.sheet.skipRules');
    expect(find.text('Skip Rules'), findsOneWidget);
    // The engine's built-in patterns are listed read-only.
    expect(find.text('.DS_Store'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('sync.rules.field')),
      '*.log\nbuild/\n',
    );
    await _tapKey(tester, 'sync.rules.done');
    expect(find.text('2 rules'), findsOneWidget);
    expect(_plan(tester), contains('Items matching 2 rules are left out.'));

    // Unchecking keeps the rules for a re-check but runs without them.
    await _tapKey(tester, 'sync.sheet.skipRules');
    expect(_plan(tester), isNot(contains('rules are left out')));
    await _tapKey(tester, 'sync.sheet.skipRules');
    await _tapKey(tester, 'sync.sheet.simulate');
    final rules = outcome.result!.pair.rules;
    expect(rules.includeHidden, isFalse);
    expect(rules.excludeGlobs, ['*.log', 'build/']);
  });

  testWidgets('Time Offset sets the tolerance and the 1-hour shift', (
    tester,
  ) async {
    final outcome = await _pumpSheet(
      tester,
      initial: testSyncPair(
        left: '/a/site',
        right: '/b/site-copy',
        rules: const SyncRuleSet(acceptedTimeShifts: [7200]),
      ),
    );
    expect(
      find.text(
        'Modification date tolerance: 2 seconds, plus 1 custom time shift',
      ),
      findsOneWidget,
    );
    await _tapKey(tester, 'sync.sheet.timeOffset');
    await tester.enterText(
      find.byKey(const ValueKey('sync.timeOffset.tolerance')),
      '5',
    );
    await _tapKey(tester, 'sync.timeOffset.hourShift');
    await _tapKey(tester, 'sync.timeOffset.done');
    expect(
      find.text(
        'Modification date tolerance: 5 seconds, ignoring exact 1-hour '
        'differences, plus 1 custom time shift',
      ),
      findsOneWidget,
    );
    await _tapKey(tester, 'sync.sheet.simulate');
    final rules = outcome.result!.pair.rules;
    expect(rules.mtimeToleranceSecs, 5);
    // The 7200 shift the dialog does not own survives.
    expect(rules.acceptedTimeShifts, [3600, 7200]);
  });

  testWidgets('an unavailable remote side keeps the verbs disabled', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      initial: SyncPair(
        id: 'p',
        name: 'site ⇄ site',
        left: const LocalEndpoint('/Users/me/site'),
        right: _remoteRight,
        rules: const SyncRuleSet(),
      ),
      endpointAvailable: (endpoint) => endpoint is LocalEndpoint,
      rsyncEndpoints: resolveRsyncEndpoints,
    );
    expect(find.text('demo@127.0.0.1:2222'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sync.sheet.unavailable')),
      findsOneWidget,
    );
    FilledButton synchronize() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('sync.sheet.synchronize')),
    );
    expect(synchronize().onPressed, isNull);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('sync.sheet.simulate')),
          )
          .onPressed,
      isNull,
    );
    // The rsync export still works — it needs no engine verbs.
    await _tapKey(tester, 'sync.sheet.more');
    final rsync = tester.widget<PopupMenuItem<Object?>>(
      find.byKey(const ValueKey('sync.sheet.more.rsync')),
    );
    expect(rsync.enabled, isTrue);
  });

  testWidgets('Save as Favorite asks for a name and persists', (tester) async {
    final saved = <SyncPair>[];
    await _pumpSheet(
      tester,
      onSaveFavorite: (pair) async {
        saved.add(pair);
        return true;
      },
    );
    await _tapKey(tester, 'sync.sheet.more');
    await _tapKey(tester, 'sync.sheet.more.saveFavorite');
    await tester.enterText(
      find.byKey(const ValueKey('sync.favoriteName.field')),
      'Site backup',
    );
    await _tapKey(tester, 'sync.favoriteName.save');
    expect(saved.single.name, 'Site backup');
    expect(saved.single.id, 'pair-1');
    // The sheet stays open for the run.
    expect(find.byKey(const ValueKey('sync.sheet')), findsOneWidget);
  });

  testWidgets('new saved sync needs a name, then Save hands it back', (
    tester,
  ) async {
    final outcome = await _pumpSheet(
      tester,
      mode: SyncSheetMode.newSaved,
      initial: testSyncPair(name: '', left: '/a/site', right: '/b/copy'),
    );
    expect(find.text('New Saved Sync'), findsOneWidget);
    OutlinedButton save() => tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('sync.sheet.save')),
    );
    expect(save().onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('sync.sheet.name')),
      'Nightly',
    );
    await tester.pump();
    await _tapKey(tester, 'sync.sheet.save');
    expect(outcome.result!.action, SyncSheetAction.save);
    expect(outcome.result!.pair.name, 'Nightly');
  });

  testWidgets('a new saved sync without panes asks for folders', (
    tester,
  ) async {
    await _pumpSheet(tester, mode: SyncSheetMode.newSaved);
    expect(find.text('Choose Folders…'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('sync.sheet.plan')), findsNothing);
    await tester.tap(find.text('Choose Folders…').first);
    await tester.pumpAndSettle();
    // The full pair editor collects the endpoints.
    expect(find.text('Sync pair'), findsOneWidget);
  });

  testWidgets('a reopened favorite names itself under the title', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      mode: SyncSheetMode.saved,
      initial: testSyncPair(name: 'Nightly site backup'),
    );
    expect(find.text('Sync Files'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sync.sheet.favoriteName')),
      findsOneWidget,
    );
    expect(find.text('Nightly site backup'), findsOneWidget);
  });

  testWidgets('Enter is the default button: Synchronize', (tester) async {
    final outcome = await _pumpSheet(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(outcome.result!.action, SyncSheetAction.synchronize);
  });

  testWidgets('Cancel closes without a result', (tester) async {
    final outcome = await _pumpSheet(tester);
    await _tapKey(tester, 'sync.sheet.cancel');
    expect(outcome.closed, isTrue);
    expect(outcome.result, isNull);
  });

  testWidgets('below 600 px the sheet is a full-screen dialog', (tester) async {
    await _pumpSheet(tester, size: const Size(420, 860));
    final dialog = tester.widget<Dialog>(
      find.byKey(const ValueKey('sync.sheet')),
    );
    expect(dialog.insetPadding, EdgeInsets.zero);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('Sync Files'), findsOneWidget);
  });
}
