import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_m0_bench/openssh_baseline.dart';
import 'package:test/test.dart';

const _fakeBatchProcess = r'''
while IFS= read -r line; do
  case "$line" in
    "!echo "*)
      printf 'sftp> %s\n' "$line"
      sleep 0.02
      printf '%s\n' "${line#!echo }"
      ;;
    fail) printf 'fixture failure\n' >&2; exit 7 ;;
    bye) exit 0 ;;
  esac
done
''';

const _gatedBatchProcess = r'''
sentinel_count=0
while IFS= read -r line; do
  case "$line" in
    "!echo "*)
      printf 'sftp> %s\n' "$line"
      if [ "$sentinel_count" -gt 0 ]; then
        IFS= read -r release
      fi
      printf '%s\n' "${line#!echo }"
      sentinel_count=$((sentinel_count + 1))
      ;;
    bye) exit 0 ;;
  esac
done
''';

const _stuckBatchProcess = r'''
while IFS= read -r line; do
  case "$line" in
    "!echo "*)
      printf 'sftp> %s\n' "$line"
      printf '%s\n' "${line#!echo }"
      ;;
    bye) exec sleep 600 ;;
  esac
done
''';
const _silentBatchProcess = r'''
while IFS= read -r line; do
  case "$line" in
    bye) exit 0 ;;
  esac
done
''';
void main() {
  test('bounds initialization before any transfer starts', () async {
    final process = await Process.start('/bin/sh', ['-c', _silentBatchProcess]);
    final session = BatchCommandSession(
      process,
      shutdownGracePeriod: Duration.zero,
    );

    await expectLater(
      session.initialize(timeout: Duration.zero),
      throwsA(isA<TimeoutException>()),
    );
    await session.close();
  });

  test('completes commands from batch sentinels without a prompt', () async {
    final delegate = await Process.start('/bin/sh', ['-c', _gatedBatchProcess]);
    final process = _BroadcastProcess(delegate);
    final session = BatchCommandSession(process);

    await session.initialize();
    final echoedSentinel = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.startsWith('sftp> !echo '));
    var completed = false;
    final command = session.run(
      'get source target',
      timeout: const Duration(seconds: 1),
    );
    unawaited(command.then((_) => completed = true));

    // The echoed sentinel cannot complete before its shell result arrives.
    await echoedSentinel;
    await Future<void>.value();
    expect(completed, isFalse);

    process.stdin.writeln('release');
    await process.stdin.flush();
    final elapsed = await command;
    await session.close();

    expect(elapsed, isA<Duration>());
  });

  test('accepts a per-command transfer timeout', () async {
    final session = await _startSession(shutdownGracePeriod: Duration.zero);
    await session.initialize();

    await expectLater(
      session.run('get source target', timeout: Duration.zero),
      throwsA(
        isA<BatchCommandTimeoutException>().having(
          (error) => error.command,
          'command',
          'get source target',
        ),
      ),
    );
    await session.close();
  });

  test('surfaces a batch process exit before its sentinel', () async {
    final session = await _startSession();
    await session.initialize();

    await expectLater(
      session.run('fail'),
      throwsA(
        isA<ProcessException>().having(
          (error) => error.errorCode,
          'exit code',
          7,
        ),
      ),
    );
  });

  test('terminates a batch process when graceful close stalls', () async {
    final process = await Process.start('/bin/sh', ['-c', _stuckBatchProcess]);
    final session = BatchCommandSession(
      process,
      shutdownGracePeriod: Duration.zero,
    );

    await session.initialize();

    await expectLater(session.close(), completes);
  });
}

Future<BatchCommandSession> _startSession({
  Duration? shutdownGracePeriod,
}) async {
  final process = await Process.start('/bin/sh', ['-c', _fakeBatchProcess]);
  return BatchCommandSession(
    process,
    shutdownGracePeriod: shutdownGracePeriod ?? const Duration(seconds: 10),
  );
}

class _BroadcastProcess implements Process {
  final Process _delegate;
  late final Stream<List<int>> _stdout = _delegate.stdout.asBroadcastStream();

  _BroadcastProcess(this._delegate);

  @override
  Future<int> get exitCode => _delegate.exitCode;

  @override
  int get pid => _delegate.pid;

  @override
  Stream<List<int>> get stderr => _delegate.stderr;

  @override
  IOSink get stdin => _delegate.stdin;

  @override
  Stream<List<int>> get stdout => _stdout;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _delegate.kill(signal);
}
