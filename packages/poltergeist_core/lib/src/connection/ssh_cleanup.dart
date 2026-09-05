// Reuse the pinned cleanup primitive without exposing it through our barrel.
// ignore: implementation_imports
import 'package:seance_core/src/ssh/sequential_cleanup.dart';

// Match the pinned SSH session's per-action grace period.
const _closeTimeout = Duration(seconds: 5);

/// A dead peer must not strand pool teardown or replace an operation's error.
/// The pinned helper also observes errors arriving after the timeout.
Future<void> closeSshResource(Future<void> Function() close) =>
    runSequentialCleanup(
      [close],
      actionTimeout: _closeTimeout,
      failureMode: CleanupFailureMode.ignore,
    );
