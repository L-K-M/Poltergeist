import 'dart:io';

/// Runs Linux fixture tools with a deadline covering their child processes.
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

  // Kill the entire group, including children that ignore TERM after bash exits.
  final seconds = timeout.inMicroseconds / Duration.microsecondsPerSecond;
  return Process.run(
    'timeout',
    ['--signal=KILL', '${seconds}s', executable, ...arguments],
    environment: environment,
    workingDirectory: workingDirectory,
  );
}
