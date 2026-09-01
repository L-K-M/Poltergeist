import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';

const baselineCommandTimeout = Duration(minutes: 30);
const _sentinelPrefix = 'POLTERGEIST_M0_SFTP_SENTINEL';

class OpenSshBaseline {
  final BatchCommandSession _session;

  const OpenSshBaseline._(this._session);

  static Future<OpenSshBaseline> connect({
    required BenchEndpoint endpoint,
    required String identityFile,
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
    await session.initialize();
    return OpenSshBaseline._(session);
  }

  Future<Duration> download(String remotePath) =>
      _session.run('get $remotePath /dev/null');

  Future<Duration> upload(String localPath, String remotePath) =>
      _session.run('put $localPath $remotePath');

  Future<void> remove(String remotePath) async {
    await _session.run('rm $remotePath');
  }

  Future<void> close() => _session.close();
}

/// Drives a persistent non-interactive process with local-command sentinels.
class BatchCommandSession {
  final Process _process;
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

  BatchCommandSession(this._process) {
    _process.stdout.transform(utf8.decoder).listen(_onStdout);
    _process.stderr.transform(utf8.decoder).listen(_stderr.write);
    unawaited(_process.exitCode.then(_onExit));
  }

  Future<void> initialize() async {
    await _sendSentinel();
  }

  Future<Duration> run(String command) => _sendSentinel(command: command);

  Future<void> close() async {
    final knownExitCode = _exitCode;
    if (knownExitCode != null) {
      _throwForExit(knownExitCode);
      return;
    }

    _process.stdin.writeln('bye');
    await _process.stdin.flush();
    await _process.stdin.close();

    final exitCode = await _process.exitCode.timeout(baselineCommandTimeout);
    _throwForExit(exitCode);
  }

  Future<Duration> _sendSentinel({String? command}) async {
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
      return await waiter.future.timeout(baselineCommandTimeout);
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
