import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/app_preferences.dart';
import 'package:poltergeist_app/services/desktop_window_lifecycle.dart';
import 'package:poltergeist_app/services/quit_guard.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';
import '../support/fake_window_adapters.dart';

/// The 07 §3.5 close-interception chain, exercised end to end: the real
/// [DesktopWindowLifecycle] receives the close callback, consults
/// [QuitGuard] (which shows 02 §10's quit dialog over the app-facing
/// [AppTransferQueue] seam), and only reaches `destroy` after the
/// journal flush resolves.
///
/// The close path performs real settings IO, so the interactions run
/// inside `tester.runAsync` — real futures cannot resolve inside the
/// fake-async zone.
void main() {
  late Directory temporaryDirectory;
  late SettingsStore settingsStore;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'poltergeist_quit_guard_test_',
    );
    settingsStore = SettingsStore(
      path: p.join(temporaryDirectory.path, 'settings.json'),
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  Future<_Harness> pumpApp(
    WidgetTester tester, {
    Duration flushTimeout = const Duration(seconds: 2),
    bool mountQueue = true,
  }) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final harness = _Harness(
      settingsStore: settingsStore,
      flushTimeout: flushTimeout,
    );
    addTearDown(harness.queue.close);
    await tester.pumpWidget(
      PoltergeistApp(
        navigatorKey: harness.navigatorKey,
        transferQueue: mountQueue ? harness.queue : null,
        quitGuard: harness.guard,
      ),
    );
    await tester.pump();
    await tester.runAsync(() => harness.lifecycle.prepare());
    return harness;
  }

  bool isShown(Finder finder) => finder.evaluate().isNotEmpty;

  /// Inside `runAsync` everything is real-time: poll on a real clock so
  /// the close chain's IO hops are not hostage to a fixed delay. A
  /// missing condition falls through after a bounded wait and the
  /// expectations below report what actually happened.
  Future<void> waitFor(WidgetTester tester, bool Function() met) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!met() && DateTime.now().isBefore(deadline)) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await tester.pump();
  }

  Future<void> waitForQuitDialog(WidgetTester tester) =>
      waitFor(tester, () => isShown(find.byKey(const ValueKey('quit.dialog'))));

  Future<void> waitForFlushWarning(WidgetTester tester) => waitFor(
    tester,
    () => isShown(find.byKey(const ValueKey('quitFlush.dialog'))),
  );

  Future<void> waitForDestroy(
    WidgetTester tester,
    FakeWindowAdapter window,
  ) => waitFor(tester, () => window.events.contains('destroy'));

  Future<void> waitForDialogDismissed(WidgetTester tester) => waitFor(
    tester,
    () => !isShown(find.byKey(const ValueKey('quit.dialog'))) &&
        !isShown(find.byKey(const ValueKey('quitFlush.dialog'))),
  );

  testWidgets('close with active tasks warns and does not destroy', (
    tester,
  ) async {
    final h = await pumpApp(tester);
    h.queue.addTask(
      state: TransferTaskState.running,
      totalBytes: 2 * 1000 * 1000,
      transferredBytes: 800 * 1000,
    );
    h.queue.addTask(state: TransferTaskState.queued);

    await tester.runAsync(() async {
      h.window.emitClose();
      await waitForQuitDialog(tester);

      expect(find.byKey(const ValueKey('quit.dialog')), findsOneWidget);
      expect(find.textContaining('2 transfers are running'), findsOneWidget);
      expect(
        find.textContaining('1.2 MB remaining so far'),
        findsOneWidget,
      );
      expect(h.window.events, isNot(contains('destroy')));
      expect(h.window.callbacksRegistered, isTrue);

      // Leave the close cleanly vetoed for teardown.
      await tester.tap(find.byKey(const ValueKey('quit.keepTransferring')));
      await waitForDialogDismissed(tester);
    });
  });

  testWidgets(
    'unknown-total tasks never subtract from the remaining floor',
    (tester) async {
      final h = await pumpApp(tester);
      // Still scanning: 900 MB moved with no discovered total. Its
      // progress must not cancel the known task's 100 MB remaining.
      h.queue.addTask(
        state: TransferTaskState.running,
        scanComplete: false,
        transferredBytes: 900 * 1000 * 1000,
      );
      h.queue.addTask(
        state: TransferTaskState.running,
        totalBytes: 200 * 1000 * 1000,
        transferredBytes: 100 * 1000 * 1000,
      );

      await tester.runAsync(() async {
        h.window.emitClose();
        await waitForQuitDialog(tester);

        expect(find.byKey(const ValueKey('quit.dialog')), findsOneWidget);
        expect(
          find.textContaining('100 MB remaining so far'),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const ValueKey('quit.keepTransferring')),
        );
        await waitForDialogDismissed(tester);
      });
    },
  );

  testWidgets('Keep Transferring vetoes the close; a retry re-asks', (
    tester,
  ) async {
    final h = await pumpApp(tester);
    h.queue.addTask(state: TransferTaskState.running);

    await tester.runAsync(() async {
      h.window.emitClose();
      await waitForQuitDialog(tester);
      expect(find.byKey(const ValueKey('quit.dialog')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('quit.keepTransferring')));
      await waitForDialogDismissed(tester);

      expect(find.byKey(const ValueKey('quit.dialog')), findsNothing);
      expect(h.window.events, isNot(contains('destroy')));
      expect(h.queue.flushJournalCalls, 0);
      expect(h.queue.pauseTaskCalls, isEmpty);

      // The veto unwinds the close state — a second close re-runs the
      // guard instead of riding the stale in-flight result.
      h.window.emitClose();
      await waitForQuitDialog(tester);
      expect(find.byKey(const ValueKey('quit.dialog')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('quit.keepTransferring')));
      await waitForDialogDismissed(tester);
      expect(h.window.events, isNot(contains('destroy')));
    });
  });

  testWidgets('dismissing the dialog vetoes the close', (tester) async {
    final h = await pumpApp(tester);
    h.queue.addTask(state: TransferTaskState.running);

    await tester.runAsync(() async {
      h.window.emitClose();
      await waitForQuitDialog(tester);
      expect(find.byKey(const ValueKey('quit.dialog')), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await waitForDialogDismissed(tester);

      expect(find.byKey(const ValueKey('quit.dialog')), findsNothing);
      expect(h.window.events, isNot(contains('destroy')));
      expect(h.queue.flushJournalCalls, 0);
    });
  });

  testWidgets(
    'Pause and Quit pauses live tasks, flushes the journal, then destroys',
    (tester) async {
      final h = await pumpApp(tester);
      final running = h.queue.addTask(state: TransferTaskState.running);
      final queued = h.queue.addTask(state: TransferTaskState.queued);
      h.queue.addTask(state: TransferTaskState.completed);

      await tester.runAsync(() async {
        final closing = h.lifecycle.close();
        await waitForQuitDialog(tester);
        expect(find.byKey(const ValueKey('quit.dialog')), findsOneWidget);
        expect(h.window.events, isNot(contains('destroy')));

        await tester.tap(find.byKey(const ValueKey('quit.pauseAndQuit')));
        await waitForDestroy(tester, h.window);

        expect(h.queue.pauseTaskCalls, [running.id, queued.id]);
        expect(h.queue.flushJournalCalls, 1);
        expect(h.window.events.last, 'destroy');
        expect(await closing, isTrue);
      });
    },
  );

  testWidgets('destroy waits for the journal flush to resolve', (
    tester,
  ) async {
    final h = await pumpApp(tester);
    h.queue.addTask(state: TransferTaskState.running);
    h.queue.blockFlushJournal = true;

    await tester.runAsync(() async {
      final closing = h.lifecycle.close();
      await waitForQuitDialog(tester);
      await tester.tap(find.byKey(const ValueKey('quit.pauseAndQuit')));
      await waitFor(tester, () => h.queue.flushJournalCalls > 0);

      // The answer landed but the flush is still in flight: the window
      // must not destroy ahead of the journal.
      expect(h.queue.flushJournalCalls, 1);
      expect(h.window.events, isNot(contains('destroy')));

      h.queue.releaseFlushJournal();
      await waitForDestroy(tester, h.window);

      expect(await closing, isTrue);
      expect(h.window.events.last, 'destroy');
    });
  });

  testWidgets('Cancel Transfers and Quit cancels tasks, flushes, destroys', (
    tester,
  ) async {
    final h = await pumpApp(tester);
    final running = h.queue.addTask(state: TransferTaskState.running);
    final paused = h.queue.addTask(state: TransferTaskState.paused);

    await tester.runAsync(() async {
      final closing = h.lifecycle.close();
      await waitForQuitDialog(tester);
      await tester.tap(find.byKey(const ValueKey('quit.cancelTransfers')));
      await waitForDestroy(tester, h.window);

      expect(
        h.queue.cancelTaskCalls,
        containsAll([running.id, paused.id]),
      );
      expect(h.queue.pauseTaskCalls, isEmpty);
      expect(h.queue.flushJournalCalls, 1);
      expect(h.window.events.last, 'destroy');
      expect(await closing, isTrue);
    });
  });

  testWidgets('no active tasks flushes the journal and closes silently', (
    tester,
  ) async {
    final h = await pumpApp(tester);
    h.queue.addTask(state: TransferTaskState.completed);
    h.queue.addTask(state: TransferTaskState.failed);

    final closed = await tester.runAsync(() => h.lifecycle.close());

    expect(closed, isTrue);
    expect(find.byKey(const ValueKey('quit.dialog')), findsNothing);
    expect(h.queue.flushJournalCalls, 1);
    expect(h.window.events.last, 'destroy');
  });

  testWidgets('no queue seam closes without touching a journal', (
    tester,
  ) async {
    final h = await pumpApp(tester, mountQueue: false);

    final closed = await tester.runAsync(() => h.lifecycle.close());

    expect(closed, isTrue);
    expect(find.byKey(const ValueKey('quit.dialog')), findsNothing);
    expect(h.queue.flushJournalCalls, 0);
    expect(h.window.events.last, 'destroy');
  });

  testWidgets('a paused-only queue still warns on close', (tester) async {
    final h = await pumpApp(tester);
    h.queue.addTask(state: TransferTaskState.paused);

    await tester.runAsync(() async {
      h.window.emitClose();
      await waitForQuitDialog(tester);

      expect(find.byKey(const ValueKey('quit.dialog')), findsOneWidget);
      expect(find.textContaining('1 transfer is running'), findsOneWidget);
      expect(h.window.events, isNot(contains('destroy')));

      // The in-flight close from emitClose is the one being answered —
      // close() joins it rather than starting a second one.
      final closing = h.lifecycle.close();
      await tester.tap(find.byKey(const ValueKey('quit.pauseAndQuit')));
      await waitForDestroy(tester, h.window);

      // Paused tasks are already persisted as paused — the quit verb
      // does not re-pause them; the flush alone covers their journal
      // records.
      expect(h.queue.pauseTaskCalls, isEmpty);
      expect(h.queue.flushJournalCalls, 1);
      expect(await closing, isTrue);
      expect(h.window.events.last, 'destroy');
    });
  });

  testWidgets('a flush timeout warns, keeps the window open, and reports', (
    tester,
  ) async {
    final h = await pumpApp(
      tester,
      flushTimeout: const Duration(milliseconds: 40),
    );
    h.queue.blockFlushJournal = true;

    await tester.runAsync(() async {
      final closing = h.lifecycle.close();
      // Real timers inside runAsync — the flush timeout fires on the
      // real clock, then the warning builds.
      await waitForFlushWarning(tester);

      expect(
        find.byKey(const ValueKey('quitFlush.dialog')),
        findsOneWidget,
      );
      expect(h.errors, contains(isA<TimeoutException>()));
      expect(h.window.events, isNot(contains('destroy')));

      await tester.tap(find.byKey(const ValueKey('quitFlush.dismiss')));
      await waitForDialogDismissed(tester);

      expect(await closing, isFalse);
      expect(h.window.events, isNot(contains('destroy')));
      expect(h.window.callbacksRegistered, isTrue);

      // The window survived; a retry with a healthy journal closes.
      h.queue.blockFlushJournal = false;
      final retried = await h.lifecycle.close();
      expect(retried, isTrue);
      expect(h.queue.flushJournalCalls, 2);
      expect(h.window.events.last, 'destroy');
    });
  });

  testWidgets('a failed flush warns and keeps the window open', (
    tester,
  ) async {
    final h = await pumpApp(tester);
    h.queue.flushJournalError = StateError('disk full');

    await tester.runAsync(() async {
      final closing = h.lifecycle.close();
      await waitForFlushWarning(tester);

      expect(
        find.byKey(const ValueKey('quitFlush.dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('disk full'), findsOneWidget);
      expect(h.errors, contains(isA<StateError>()));
      expect(h.window.events, isNot(contains('destroy')));

      await tester.tap(find.byKey(const ValueKey('quitFlush.dismiss')));
      await waitForDialogDismissed(tester);
      expect(await closing, isFalse);
      expect(h.window.events, isNot(contains('destroy')));
    });
  });

  testWidgets('a flush that keeps failing can still quit anyway', (
    tester,
  ) async {
    final h = await pumpApp(tester);
    h.queue.flushJournalError = StateError('disk full');

    await tester.runAsync(() async {
      // Quit again only retries the same failing write.
      final first = h.lifecycle.close();
      await waitForFlushWarning(tester);
      await tester.tap(find.byKey(const ValueKey('quitFlush.dismiss')));
      await waitForDialogDismissed(tester);
      expect(await first, isFalse);

      final second = h.lifecycle.close();
      await waitForFlushWarning(tester);
      await tester.tap(find.byKey(const ValueKey('quitFlush.quitAnyway')));
      await waitForDialogDismissed(tester);

      expect(await second, isTrue);
      expect(h.queue.flushJournalCalls, 2);
      expect(h.window.events.last, 'destroy');
    });
  });
}

final class _Harness {
  _Harness({
    required SettingsStore settingsStore,
    required Duration flushTimeout,
  }) {
    guard = QuitGuard(
      navigatorKey: navigatorKey,
      flushTimeout: flushTimeout,
      onError: (error, _) => errors.add(error),
    );
    lifecycle = DesktopWindowLifecycle(
      AppPreferences(store: settingsStore),
      window: window,
      displays: FakeDisplayAdapter(),
      titlebar: FakeMacTitlebarAdapter(),
      platform: DesktopPlatform.linux,
      confirmClose: guard.confirmClose,
      onError: (error, _) => errors.add(error),
    );
  }

  final navigatorKey = GlobalKey<NavigatorState>();
  final window = FakeWindowAdapter();
  final queue = FakeAppTransferQueue();
  final errors = <Object>[];
  late final QuitGuard guard;
  late final DesktopWindowLifecycle lifecycle;
}
