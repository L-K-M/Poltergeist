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

void main() {
  test('completes commands from batch sentinels without a prompt', () async {
    final session = await _startSession();

    await session.initialize();
    final wall = Stopwatch()..start();
    final elapsed = await session.run('get source target');
    wall.stop();
    await session.close();

    expect(elapsed, isA<Duration>());
    expect(
      wall.elapsed - elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 10)),
    );
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
}

Future<BatchCommandSession> _startSession() async {
  final process = await Process.start('/bin/sh', ['-c', _fakeBatchProcess]);
  return BatchCommandSession(process);
}
