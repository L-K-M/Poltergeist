// SyncPairEditorDialog regressions (D32 §7 task 4): a save must keep
// the ruleset fields the dialog does not show, and must not reset the
// pair state's case-sensitivity overrides it was never told about.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/ui/sync/sync_pair_editor.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../support/sync_harness.dart';

/// Mounts a launcher that opens the editor and records what it pops.
Future<List<SyncPairEditorResult?>> _pumpEditor(
  WidgetTester tester, {
  SyncPair? initial,
  SyncCaseOverrides? initialCaseOverrides,
}) async {
  final results = <SyncPairEditorResult?>[];
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              results.add(
                await showDialog<SyncPairEditorResult>(
                  context: context,
                  builder: (_) => SyncPairEditorDialog(
                    initial: initial,
                    initialCaseOverrides: initialCaseOverrides,
                  ),
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
  return results;
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a save keeps acceptedTimeShifts and the symlink policy', (
    tester,
  ) async {
    final results = await _pumpEditor(
      tester,
      initial: testSyncPair(
        rules: const SyncRuleSet(
          acceptedTimeShifts: [3600],
          symlinks: SymlinkPolicy.copyAsLink,
          excludeGlobs: ['*.log'],
          trashPathRight: '/srv/trash',
        ),
      ),
    );
    await _save(tester);

    final rules = results.single!.pair.rules;
    // Before the fix `_result()` rebuilt the set from scratch and both
    // fields silently reverted to their defaults.
    expect(rules.acceptedTimeShifts, [3600]);
    expect(rules.symlinks, SymlinkPolicy.copyAsLink);
    expect(rules.excludeGlobs, ['*.log']);
    expect(rules.trashPathRight, '/srv/trash');
    expect(rules.trashPathLeft, isNull);
  });

  testWidgets('seeded case overrides show and survive an untouched save', (
    tester,
  ) async {
    final results = await _pumpEditor(
      tester,
      initial: testSyncPair(),
      initialCaseOverrides: const SyncCaseOverrides(left: true, right: false),
    );
    // The Options section holds the case fields.
    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    expect(find.text('Case-sensitive'), findsOneWidget);
    expect(find.text('Case-insensitive'), findsOneWidget);

    await _save(tester);
    // Untouched fields over unchanged endpoints leave the stored pair
    // state authoritative — the old dialog returned auto/auto here and
    // the session's rescan cleared both overrides.
    expect(results.single!.caseOverrides, isNull);
  });

  testWidgets('an unseeded editor never resets overrides on save', (
    tester,
  ) async {
    final results = await _pumpEditor(tester, initial: testSyncPair());
    await _save(tester);
    expect(results.single!.caseOverrides, isNull);
  });

  testWidgets('a changed case field returns both sides', (tester) async {
    final results = await _pumpEditor(
      tester,
      initial: testSyncPair(),
      initialCaseOverrides: const SyncCaseOverrides(left: true),
    );
    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Case-sensitive'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Case-insensitive').last);
    await tester.pumpAndSettle();
    await _save(tester);

    final overrides = results.single!.caseOverrides!;
    expect(overrides.left, isFalse);
    expect(overrides.right, isNull);
  });
}
