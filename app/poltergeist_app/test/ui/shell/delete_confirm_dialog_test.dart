import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/shell/delete_confirm_dialog.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

DeleteConfirmation _confirmation({
  List<String> roots = const ['/srv/a.txt'],
  DeleteDisposition disposition = DeleteDisposition.permanent,
  bool quantified = true,
  bool remoteTrashOptIn = false,
  bool trashUnavailable = false,
  int? totalItems,
  int? totalBytes,
  int flagged = 0,
}) => DeleteConfirmation(
  source: const ServerFsLocation('srv'),
  rootPaths: roots,
  names: [for (final r in roots.take(3)) r.split('/').last],
  effectiveDisposition: disposition,
  quantified: quantified,
  remoteTrashOptIn: remoteTrashOptIn,
  trashUnavailable: trashUnavailable,
  totalItems: totalItems ?? roots.length,
  totalBytes: totalBytes ?? 1200,
  flaggedCount: flagged,
);

Future<DeleteDecision?> _open(
  WidgetTester tester,
  DeleteConfirmation confirmation,
) async {
  DeleteDecision? decision;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            decision = await showDeleteConfirmDialog(
              context,
              locationLabel: 'prod-web',
              prepare: (_) async => confirmation,
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return decision;
}

void main() {
  for (final confirm in [false, true]) {
    testWidgets('repeated ${confirm ? 'Confirm' : 'Cancel'} keeps the page '
        'beneath the dialog', (tester) async {
      final harness = await _DialogHarness.open(tester);
      harness.preparation.complete(_confirmation());
      await tester.pumpAndSettle();
      final callback = confirm
          ? tester
                .widget<FilledButton>(
                  find.byKey(const ValueKey('delete.confirm')),
                )
                .onPressed!
          : tester
                .widget<TextButton>(find.byKey(const ValueKey('delete.cancel')))
                .onPressed!;
      callback();
      callback();
      await tester.pumpAndSettle();
      expect(find.text('underlying page'), findsOneWidget);
      expect(
        await harness.decision,
        confirm ? isA<DeleteConfirmed>() : isA<DeleteCancelled>(),
      );
    });
  }

  testWidgets('late cancelled preparation cannot pop the underlying page', (
    tester,
  ) async {
    final harness = await _DialogHarness.open(tester);
    await tester.tap(find.byKey(const ValueKey('delete.cancel')));
    harness.preparation.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('underlying page'), findsOneWidget);
    expect(await harness.decision, isA<DeleteCancelled>());
  });

  testWidgets('covered dialog actions cannot answer a newer route', (
    tester,
  ) async {
    final harness = await _DialogHarness.open(tester);
    harness.preparation.complete(_confirmation());
    await tester.pumpAndSettle();
    final cancel = tester
        .widget<TextButton>(find.byKey(const ValueKey('delete.cancel')))
        .onPressed!;
    final confirm = tester
        .widget<FilledButton>(find.byKey(const ValueKey('delete.confirm')))
        .onPressed!;
    final newer = showDialog<void>(
      context: harness.navigator.currentContext!,
      builder: (_) => const AlertDialog(title: Text('newer dialog')),
    );
    await tester.pumpAndSettle();
    cancel();
    confirm();
    await tester.pumpAndSettle();
    expect(find.text('newer dialog'), findsOneWidget);
    expect(harness.cancellation.isCancelled, isFalse);
    harness.navigator.currentState!.pop();
    await newer;
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete.cancel')));
    await tester.pumpAndSettle();
    expect(await harness.decision, isA<DeleteCancelled>());
    expect(find.text('underlying page'), findsOneWidget);
  });

  testWidgets('obsolete preparation removes only its covered route', (
    tester,
  ) async {
    final harness = await _DialogHarness.open(tester);
    final newer = showDialog<void>(
      context: harness.navigator.currentContext!,
      builder: (_) => const AlertDialog(title: Text('newer dialog')),
    );
    await tester.pump(const Duration(milliseconds: 250));
    harness.preparation.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('newer dialog'), findsOneWidget);
    expect(await harness.decision, isA<DeleteCancelled>());
    harness.navigator.currentState!.pop();
    await newer;
    await tester.pumpAndSettle();
    expect(find.text('underlying page'), findsOneWidget);
    expect(find.byKey(const ValueKey('delete.dialog')), findsNothing);
  });

  testWidgets('Back cancels preparation before the exit animation ends', (
    tester,
  ) async {
    final harness = await _DialogHarness.open(tester);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(harness.cancellation.isCancelled, isTrue);
    harness.preparation.complete(null);
    await tester.pumpAndSettle();
    expect(await harness.decision, isA<DeleteCancelled>());
    expect(find.text('underlying page'), findsOneWidget);
  });

  testWidgets('repeated dismiss after a preparation error keeps the page', (
    tester,
  ) async {
    final harness = await _DialogHarness.open(tester);
    harness.preparation.completeError(StateError('counting failed'));
    await tester.pump();
    expect(find.textContaining('counting failed'), findsOneWidget);
    final cancel = tester
        .widget<TextButton>(find.byKey(const ValueKey('delete.cancel')))
        .onPressed!;
    cancel();
    cancel();
    await tester.pumpAndSettle();
    expect(find.text('underlying page'), findsOneWidget);
    expect(await harness.decision, isA<DeleteCancelled>());
  });

  testWidgets('disposing the navigator cancels pending preparation', (
    tester,
  ) async {
    final harness = await _DialogHarness.open(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(harness.cancellation.isCancelled, isTrue);
    harness.preparation.completeError(StateError('late failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a remote permanent delete names the items and the server', (
    tester,
  ) async {
    await _open(tester, _confirmation(roots: ['/srv/a.txt', '/srv/b.txt']));
    expect(find.text('Delete “a.txt”, “b.txt” from prod-web?'), findsOneWidget);
    expect(find.text('This cannot be undone.'), findsOneWidget);
    // Permanent: Cancel, not the destructive verb, holds the default.
    final cancel = tester.widget<TextButton>(
      find.byKey(const ValueKey('delete.cancel')),
    );
    expect(cancel.autofocus, isTrue);
  });

  testWidgets('more than three roots use the count and size', (tester) async {
    await _open(
      tester,
      _confirmation(
        roots: ['/srv/a', '/srv/b', '/srv/c', '/srv/d'],
        totalItems: 12,
        totalBytes: 1400000000,
      ),
    );
    expect(find.textContaining('Delete 12 items ('), findsOneWidget);
    expect(find.textContaining('from prod-web?'), findsOneWidget);
  });

  testWidgets('a walk that gave up falls back without counts and still '
      'discloses flagged names', (tester) async {
    await _open(tester, _confirmation(quantified: false, flagged: 1));
    expect(find.text('Delete the selected items from prod-web?'), findsOneWidget);
    expect(
      find.text('May include items with undecodable names.'),
      findsOneWidget,
    );
  });

  testWidgets('the server trash opt-in pre-checks and switches to move '
      'wording; unchecking reverts to permanent', (tester) async {
    await _open(
      tester,
      _confirmation(
        disposition: DeleteDisposition.trash,
        remoteTrashOptIn: true,
      ),
    );
    expect(
      find.text('Move “a.txt” to .poltergeist-trash/ on prod-web?'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('delete.serverTrash')));
    await tester.pumpAndSettle();
    expect(find.text('Delete “a.txt” from prod-web?'), findsOneWidget);
  });

  testWidgets('after a permanent gesture, checking the server trash box '
      'confirms a move to the trash', (tester) async {
    DeleteDecision? decision;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              decision = await showDeleteConfirmDialog(
                context,
                locationLabel: 'prod-web',
                prepare: (_) async => _confirmation(remoteTrashOptIn: true),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Delete “a.txt” from prod-web?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete.serverTrash')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete.confirm')));
    await tester.pumpAndSettle();
    expect(
      (decision! as DeleteConfirmed).disposition,
      DeleteDisposition.trash,
    );
  });

  testWidgets('confirming reports whether the final wording was permanent', (
    tester,
  ) async {
    DeleteDecision? decision;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              decision = await showDeleteConfirmDialog(
                context,
                locationLabel: 'prod-web',
                prepare: (_) async => _confirmation(),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete.confirm')));
    await tester.pumpAndSettle();
    expect(decision, isA<DeleteConfirmed>());
    expect(
      (decision! as DeleteConfirmed).disposition,
      DeleteDisposition.permanent,
    );
  });

  testWidgets('trash unavailable carries D15 notice', (tester) async {
    await _open(tester, _confirmation(trashUnavailable: true));
    expect(find.byKey(const ValueKey('delete.trashUnavailable')), findsOneWidget);
    // One item reads in the singular.
    expect(
      find.text(
        "The Trash isn't available here, so this item will be deleted "
        'permanently.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the trash notice counts several items', (tester) async {
    await _open(
      tester,
      _confirmation(
        roots: const ['/srv/a.txt', '/srv/b.txt'],
        trashUnavailable: true,
      ),
    );
    expect(
      find.text(
        "The Trash isn't available here, so these items will be deleted "
        'permanently.',
      ),
      findsOneWidget,
    );
  });
}

/// A real route beneath the dialog makes an accidental second pop visible.
class _DialogHarness {
  final navigator = GlobalKey<NavigatorState>();
  final preparation = Completer<DeleteConfirmation?>();
  late final RemoteTransferCancellation cancellation;
  late final Future<DeleteDecision> decision;

  static Future<_DialogHarness> open(WidgetTester tester) async {
    final harness = _DialogHarness();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: harness.navigator,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: Text('root page')),
      ),
    );
    unawaited(
      harness.navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('underlying page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    harness.decision = showDeleteConfirmDialog(
      harness.navigator.currentContext!,
      locationLabel: 'prod-web',
      prepare: (cancellation) {
        harness.cancellation = cancellation;
        return harness.preparation.future;
      },
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    return harness;
  }
}
