import 'dart:async' show unawaited;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';

import 'checkout_session.dart';
import 'engine_session.dart';
import 'quit_guard.dart';
import 'recent_locations.dart';
import 'session_persistence.dart';

/// The exit hook's flush budget: long enough for a real disk write,
/// short enough that a wedged one cannot stall the exit decision.
const _exitFlushTimeout = Duration(seconds: 2);

/// The app's one lifecycle listener over its app-wide models: the engine
/// session, the session document, the quit guard, the managed checkouts,
/// and Quick Open's recents. Null when there is nothing to listen for.
///
/// Exactly one may exist per app. With several windows the framework asks
/// every listener whether the app may exit, one after another, so a
/// listener per window would ask the quit guard once per window and show
/// its dialog again after the first answer (00 D38).
///
/// Engine lifetime follows the app's: `detached` is the last state a
/// desktop process sees (the window is gone), so the session shuts the
/// engine down there — best-effort orderly teardown before process exit.
/// `onExitRequested` covers the window-close path where `detached` may
/// never be delivered to Dart before the process is torn down; both routes
/// land on the same idempotent shutdown.
AppLifecycleListener? attachAppSessionLifecycle({
  EngineSession? session,
  SessionPersistence? persistence,
  QuitGuard? quitGuard,
  CheckoutSession? checkouts,
  RecentLocationsStore? recentLocations,
  List<Future<void> Function()> exitFlushes = const [],
}) {
  if (session == null &&
      persistence == null &&
      quitGuard == null &&
      checkouts == null) {
    return null;
  }
  return AppLifecycleListener(
    onStateChange: (state) {
      session?.forwardLifecycle(state);
      // 06 §3.3's reconcile-on-resume: every foreground transition
      // rehashes the managed checkouts and repairs degraded
      // snapshots — the designed fallback when a watcher missed
      // events while the app sat backgrounded.
      if (state == AppLifecycleState.resumed && checkouts != null) {
        unawaited(
          checkouts.reconcileOnResume().catchError((
            Object error,
            StackTrace stackTrace,
          ) {
            FlutterError.reportError(
              FlutterErrorDetails(exception: error, stack: stackTrace),
            );
          }),
        );
      }
    },
    // The framework awaits this future before exiting — the only exit
    // hook with a wait semantic, so the pending mirror writes flush
    // before the process is allowed to die. The session's shutdown
    // itself is triggered fire-and-forget (idempotent), keeping the
    // exit decision independent of teardown-path futures.
    onExitRequested: () async {
      // The quit guard rides this path too: a platform quit (⌘Q, OS
      // termination) never reaches the window's close callback, so
      // without this the journal could exit unflushed and un-warned.
      // A veto cancels the exit — the same answer the intercepted
      // close gets, sharing one in-flight decision.
      if (quitGuard != null && !await quitGuard.confirmClose()) {
        return AppExitResponse.cancel;
      }
      // Flush what is already queued before stopping the engine: the
      // tails snapshot at call time, so writes racing the shutdown
      // trigger still land first. The session document (02 §3's
      // app-quit safe point) flushes in the same bounded wait. Both
      // are best-effort — the framework awaits this future, so
      // neither a failed nor a wedged flush may block the exit.
      try {
        await Future.wait<void>([
          if (session != null) session.flushWrites(),
          if (persistence != null) persistence.flush(),
          // 02 §8.4's recents share the safe point: a debounced write
          // still pending at quit must land before the window dies.
          if (recentLocations != null) recentLocations.flush(),
          for (final flush in exitFlushes) flush(),
        ]).timeout(_exitFlushTimeout);
      } on Object catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(exception: error, stack: stackTrace),
        );
      }
      session?.forwardLifecycle(AppLifecycleState.detached);
      return AppExitResponse.exit;
    },
  );
}
