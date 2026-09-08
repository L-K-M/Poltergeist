import 'dart:io';

/// Bounds a Linux command's process group until that command exits.
///
/// Callers must wait for their children, as service-control.sh does. Detached
/// descendants and children outliving the command are outside this deadline.
///
/// Dart reports SIGKILL as -9 (shells use 137); the outer harness owns Docker
/// cleanup when the command exceeds its deadline.
Future<ProcessResult> runFixtureProcess(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  Map<String, String>? environment,
  String? workingDirectory,
}) {
  if (timeout <= Duration.zero) {
    throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
  }

  // Kill the monitored group even when a child ignores TERM.
  final seconds = timeout.inMicroseconds / Duration.microsecondsPerSecond;
  return Process.run(
    'timeout',
    ['--signal=KILL', '${seconds}s', executable, ...arguments],
    environment: environment,
    workingDirectory: workingDirectory,
  );
}
