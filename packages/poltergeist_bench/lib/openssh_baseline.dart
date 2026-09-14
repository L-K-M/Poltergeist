import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';

const baselineCommandTimeout = Duration(hours: 1);
const baselineInitializationTimeout = Duration(minutes: 1);
const _baselineShutdownGracePeriod = Duration(seconds: 10);
const _baselineForcedShutdownGracePeriod = Duration(seconds: 5);
const _sentinelPrefix = 'POLTERGEIST_M0_SFTP_SENTINEL';

class BatchCommandTimeoutException extends TimeoutException {
  final String command;
  final String stdout;
  final String stderr;

  BatchCommandTimeoutException({
    required this.command,
    required Duration timeout,
    required this.stdout,
    required this.stderr,
  }) : super('OpenSSH batch command timed out: $command', timeout);

  @override
  String toString() =>
      '${super.toString()}; stdout=${jsonEncode(stdout)}; '
      'stderr=${jsonEncode(stderr)}';
}

class OpenSshBaseline {
  final BatchCommandSession _session;

  const OpenSshBaseline._(this._session);

  static Future<OpenSshBaseline> connect({
    required BenchEndpoint endpoint,
    required String identityFile,
    Duration initializationTimeout = baselineInitializationTimeout,
  }) async {
    final process = await Process.start('sftp', [
      '-q',
      '-b',
      '-',
      '-P',
      '${endpoint.port}',
      '-i',
      identityFile,
      '-o',
      'BatchMode=yes',
      '-o',
      'IdentitiesOnly=yes',
      '-o',
      'StrictHostKeyChecking=no',
      '-o',
      'UserKnownHostsFile=/dev/null',
      '${endpoint.username}@${endpoint.host}',
    ]);
    final session = BatchCommandSession(process);
    try {
      await session.initialize(timeout: initializationTimeout);
      return OpenSshBaseline._(session);
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  Future<Duration> download(
    String remotePath,
    String localPath, {
    Duration timeout = baselineCommandTimeout,
  }) => _session.run(
    'get ${_batchPath(remotePath)} ${_batchPath(localPath)}',
    timeout: timeout,
  );

  Future<Duration> upload(
    String localPath,
    String remotePath, {
    Duration timeout = baselineCommandTimeout,
  }) => _session.run(
    'put ${_batchPath(localPath)} ${_batchPath(remotePath)}',
    timeout: timeout,
  );

  Future<void> remove(
    String remotePath, {
    Duration timeout = baselineCommandTimeout,
  }) async {
    await _session.run('rm ${_batchPath(remotePath)}', timeout: timeout);
  }

  Future<void> close() => _session.close();
}

/// Drives a persistent non-interactive process with local-command sentinels.
class BatchCommandSession {
  final Process _process;
  final Duration _shutdownGracePeriod;
  final Duration _forcedShutdownGracePeriod;
  final StringBuffer _stdout = StringBuffer();
  final StringBuffer _stderr = StringBuffer();
  Completer<Duration>? _sentinelWaiter;
  String? _expectedSentinel;
  Stopwatch? _sentinelStopwatch;
  Duration? _commandElapsed;
  int _sentinelMatches = 0;
  int _scanOffset = 0;
  int _sentinelSequence = 0;
  int? _exitCode;

  factory BatchCommandSession(
    Process process, {
    Duration shutdownGracePeriod = _baselineShutdownGracePeriod,
    Duration forcedShutdownGracePeriod = _baselineForcedShutdownGracePeriod,
  }) => BatchCommandSession._(
    process,
    shutdownGracePeriod,
    forcedShutdownGracePeriod,
  );

  BatchCommandSession._(
    this._process,
    this._shutdownGracePeriod,
    this._forcedShutdownGracePeriod,
  ) {
    _process.stdout.transform(utf8.decoder).listen(_onStdout);
    _process.stderr.transform(utf8.decoder).listen(_stderr.write);
    unawaited(_process.exitCode.then(_onExit));
  }

  Future<void> initialize({
    Duration timeout = baselineInitializationTimeout,
  }) async {
    await _sendSentinel(timeout: timeout);
  }

  Future<Duration> run(
    String command, {
    Duration timeout = baselineCommandTimeout,
  }) => _sendSentinel(command: command, timeout: timeout);

  Future<void> close() async {
    final knownExitCode = _exitCode;
    if (knownExitCode != null) {
      _throwForExit(knownExitCode);
      return;
    }

    _process.stdin.writeln('bye');
    await _process.stdin.flush();
    await _process.stdin.close();

    final gracefulExit = await _waitForExit(_shutdownGracePeriod);
    if (gracefulExit != null) {
      _throwForExit(gracefulExit);
      return;
    }

    // Shutdown is untimed evidence cleanup; stop a wedged SSH transport.
    _process.kill();
    final terminatedExit = await _waitForExit(_forcedShutdownGracePeriod);
    if (terminatedExit != null) return;

    _process.kill(ProcessSignal.sigkill);
    await _process.exitCode.timeout(_forcedShutdownGracePeriod);
  }

  Future<int?> _waitForExit(Duration timeout) async {
    try {
      return await _process.exitCode.timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  Future<Duration> _sendSentinel({
    String? command,
    Duration timeout = baselineCommandTimeout,
  }) async {
    final exitCode = _exitCode;
    if (exitCode != null) _throwForExit(exitCode);
    if (_sentinelWaiter != null) {
      throw StateError('OpenSSH batch commands must run sequentially.');
    }

    final sentinel = '${_sentinelPrefix}_${_sentinelSequence++}';
    final waiter = Completer<Duration>();
    _expectedSentinel = sentinel;
    _sentinelWaiter = waiter;
    _sentinelStopwatch = Stopwatch()..start();
    _commandElapsed = null;
    _sentinelMatches = 0;

    try {
      if (command != null) _process.stdin.writeln(command);
      _process.stdin.writeln('!echo $sentinel');
      await _process.stdin.flush();
      return await waiter.future.timeout(
        timeout,
        onTimeout: () => throw BatchCommandTimeoutException(
          command: command ?? 'initialize',
          timeout: timeout,
          stdout: _stdout.toString(),
          stderr: _stderr.toString(),
        ),
      );
    } finally {
      if (identical(_sentinelWaiter, waiter)) {
        _sentinelWaiter = null;
        _expectedSentinel = null;
        _sentinelStopwatch = null;
        _commandElapsed = null;
        _sentinelMatches = 0;
      }
    }
  }

  void _onStdout(String chunk) {
    _stdout.write(chunk);
    final sentinel = _expectedSentinel;
    final waiter = _sentinelWaiter;
    if (sentinel == null || waiter == null) return;

    final output = _stdout.toString();
    while (true) {
      final match = output.indexOf(sentinel, _scanOffset);
      if (match < 0) {
        final nextOffset = output.length - sentinel.length + 1;
        if (nextOffset > _scanOffset) _scanOffset = nextOffset;
        return;
      }

      _scanOffset = match + sentinel.length;
      _sentinelMatches++;
      if (_sentinelMatches == 1) {
        _commandElapsed = _sentinelStopwatch!.elapsed;
        continue;
      }

      // Batch sftp first echoes the command, then emits the shell result.
      waiter.complete(_commandElapsed!);
      return;
    }
  }

  void _onExit(int exitCode) {
    _exitCode = exitCode;
    final waiter = _sentinelWaiter;
    if (waiter == null || waiter.isCompleted) return;

    waiter.completeError(_exitException(exitCode));
  }

  void _throwForExit(int exitCode) {
    if (exitCode == 0) return;

    throw _exitException(exitCode);
  }

  ProcessException _exitException(int exitCode) =>
      ProcessException('sftp', const [], _stderr.toString(), exitCode);
}

String _batchPath(String path) {
  if (path.contains('\n') || path.contains('\r')) {
    throw ArgumentError.value(path, 'path', 'SFTP paths cannot contain lines.');
  }

  final escaped = path.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}
