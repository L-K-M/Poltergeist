import 'dart:io';

import 'package:test/test.dart';

const _profileScript = 'test/integration/sshd-common/netem-profile.sh';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('poltergeist-netem-test-');
    await _writeExecutable('${sandbox.path}/tc', _fakeTc);
    await _writeExecutable('${sandbox.path}/ip', _fakeIp);
  });

  tearDown(() => sandbox.delete(recursive: true));

  test('LAN reset rejects a stale netem qdisc', () async {
    final result = await _runProfile(sandbox, {
      'FAKE_ETH0_QDISC': 'qdisc netem 1: root delay 50ms',
    });

    expect(result.exitCode, isNonZero);
    expect(result.stderr, contains('stale qdisc'));
  });

  test('LAN reset tolerates absent qdiscs and links', () async {
    final result = await _runProfile(sandbox, {
      'FAKE_ETH0_QDISC': 'qdisc noqueue 0: root refcnt 2',
    });

    expect(result.exitCode, 0);
  });

  test('LAN reset rejects a stale ingress redirect', () async {
    final result = await _runProfile(sandbox, {
      'FAKE_ETH0_QDISC': 'qdisc noqueue 0: root refcnt 2',
      'FAKE_IFB_PRESENT': '1',
    });

    expect(result.exitCode, isNonZero);
    expect(result.stderr, contains('stale ingress'));
  });
}

Future<ProcessResult> _runProfile(
  Directory sandbox,
  Map<String, String> overrides,
) => Process.run(
  '/bin/sh',
  [_profileScript, 'lan'],
  environment: {
    ...Platform.environment,
    'PATH': '${sandbox.path}:/usr/bin:/bin',
    ...overrides,
  },
);

Future<void> _writeExecutable(String path, String contents) async {
  await File(path).writeAsString(contents);
  final result = await Process.run('chmod', ['700', path]);
  if (result.exitCode != 0) throw StateError('chmod failed: ${result.stderr}');
}

const _fakeTc = r'''#!/bin/sh
if [ "$*" = 'qdisc show dev eth0' ]; then
  printf '%s\n' "${FAKE_ETH0_QDISC:-}"
  exit 0
fi
exit 1
''';

const _fakeIp = r'''#!/bin/sh
if [ "$*" = 'link show dev ifb0' ] && [ "${FAKE_IFB_PRESENT:-0}" = '1' ]; then
  exit 0
fi
exit 1
''';
