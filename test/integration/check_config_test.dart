import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'check_config.dart';

const _m0TimeoutMinutes = 360;
const _m0BenchmarkJobName = 'm0_bench';
const _m0AggregateJobName = 'm0_bench_aggregate';
const _m0ShardNames = ['standard', 'rtt100-1gb-upload'];
const _m0ArtifactPrefix = 'm0-bench-results';
const _m0ResultsPath = 'tool/bench/bench-results.json';
const _m0CommandLogVariable = 'POLTERGEIST_M0_COMMAND_LOG';
const _m0ProfileScriptVariable = 'POLTERGEIST_M0_PROFILE_SCRIPT';
const _m0BenchCommandVariable = 'POLTERGEIST_M0_BENCH_COMMAND';
const _measuredRttMs = 101;
const _benchFailureExitCode = 23;
const _usageExitCode = 2;
const _modernAlpineImage =
    'alpine:20260805@sha256:'
    '020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000';
const _modernOpenSshVersion = '10.5_p1-r1';
const _modernOpenSshPackages = [
  'openssh-client-common',
  'openssh-server-pam',
  'openssh-sftp-server',
];

void main() {
  test('accepts loopback long-form publishing', () {
    final errors = findExposureErrors({
      'services': {
        'safe': {
          'ports': [
            {'host_ip': '127.0.0.1', 'published': '2201', 'target': 22},
          ],
        },
      },
    });

    expect(errors, isEmpty);
  });

  test('rejects a resolved short-form mapping without host IP', () {
    final errors = findExposureErrors({
      'services': {
        'unsafe': {
          'ports': [
            {'published': '2201', 'target': 22},
          ],
        },
      },
    });

    expect(errors.single, contains('all interfaces'));
  });

  test('rejects a non-loopback long-form mapping', () {
    final errors = findExposureErrors({
      'services': {
        'unsafe': {
          'ports': [
            {'host_ip': '0.0.0.0', 'published': '2201', 'target': 22},
          ],
        },
      },
    });

    expect(errors.single, contains('0.0.0.0'));
  });

  test('rejects host networking without published ports', () {
    final errors = findExposureErrors({
      'services': {
        'unsafe': {'network_mode': 'host'},
      },
    });

    expect(errors.single, contains('host networking'));
  });

  test('audits the OpenSSH 10 post-quantum default', () {
    final config = File(
      'test/integration/sshd-common/config/sshd_config.chacha',
    ).readAsStringSync();

    expect(config, contains('mlkem768x25519-sha256'));
    expect(config, isNot(contains('sntrup761x25519-sha512')));
  });

  test('pins the current modern OpenSSH fixture', () {
    final dockerfile = File(
      'test/integration/sshd-modern/Dockerfile',
    ).readAsStringSync();

    expect(dockerfile.split('\n').first, 'FROM $_modernAlpineImage');
    for (final package in _modernOpenSshPackages) {
      expect(dockerfile, contains('$package=$_modernOpenSshVersion'));
    }
  });

  test('pins matching legacy OpenSSH client and server packages', () {
    final dockerfile = File(
      'test/integration/sshd-legacy/Dockerfile',
    ).readAsStringSync();

    expect(dockerfile, contains(r'ARG OPENSSH_VERSION='));
    expect(dockerfile, contains(r'openssh-client=${OPENSSH_VERSION}'));
    expect(dockerfile, contains(r'openssh-server=${OPENSSH_VERSION}'));
  });

  test('pulls the frozen legacy image by digest', () {
    final compose =
        loadYaml(File('test/integration/docker-compose.yml').readAsStringSync())
            as YamlMap;
    final services = compose['services'] as YamlMap;
    final legacy = services['sshd-legacy'] as YamlMap;

    expect(
      legacy['image'],
      matches(
        RegExp(r'^ghcr\.io/l-k-m/poltergeist-sshd-legacy@sha256:[a-f0-9]{64}$'),
      ),
    );
    expect(legacy.containsKey('build'), isFalse);
  });

  test('shards M0 measurements without shortening their budget', () {
    final workflow =
        loadYaml(File('.github/workflows/ci.yml').readAsStringSync())
            as YamlMap;
    final jobs = workflow['jobs'] as YamlMap;
    final benchmark = jobs[_m0BenchmarkJobName] as YamlMap;
    final strategy = benchmark['strategy'] as YamlMap;
    final matrix = strategy['matrix'] as YamlMap;

    expect(strategy['fail-fast'], isFalse);
    expect((matrix['shard'] as YamlList).toList(), _m0ShardNames);
    expect(benchmark['timeout-minutes'], _m0TimeoutMinutes);

    final steps = (benchmark['steps'] as YamlList).cast<YamlMap>();
    final measurement = _stepNamed(steps, 'Run fixture and measurements');
    expect(
      measurement['run'],
      contains(
        r'test/integration/run.sh --lifecycle-only -- '
        r'tool/bench/run.sh "${{ matrix.shard }}"',
      ),
    );

    final uploads = _expectRetriedArtifactUpload(
      steps,
      firstStepId: 'upload_shard',
      expectedCondition: 'always()',
    );
    for (final upload in uploads) {
      final options = upload['with'] as YamlMap;
      expect(options['name'], '$_m0ArtifactPrefix-\${{ matrix.shard }}');
      expect(options['path'], _m0ResultsPath);
      expect(options['if-no-files-found'], 'error');
      expect(options['overwrite'], isTrue);
    }
  });

  test('aggregates both M0 shards into one canonical artifact', () {
    final workflow =
        loadYaml(File('.github/workflows/ci.yml').readAsStringSync())
            as YamlMap;
    final jobs = workflow['jobs'] as YamlMap;
    final aggregate = jobs[_m0AggregateJobName] as YamlMap;

    expect(aggregate['needs'], _m0BenchmarkJobName);
    expect('${aggregate['if']}', contains('always()'));
    expect('${aggregate['if']}', contains("'m0-bench'"));

    final steps = (aggregate['steps'] as YamlList).cast<YamlMap>();
    for (final shard in _m0ShardNames) {
      final download = _stepNamed(steps, 'Download $shard measurements');
      final options = download['with'] as YamlMap;
      expect(download['uses'], 'actions/download-artifact@v4');
      expect(options['name'], '$_m0ArtifactPrefix-$shard');
      expect(options['path'], 'tool/bench/shards/$shard');
    }

    final aggregation = _stepNamed(steps, 'Aggregate M0 measurements');
    final command = '${aggregation['run']}'.replaceAll(RegExp(r'\s+'), ' ');
    expect(aggregation['working-directory'], 'tool/bench');
    expect(
      command,
      contains(
        'dart run bin/aggregate.dart '
        '--standard shards/standard/bench-results.json '
        '--slow shards/rtt100-1gb-upload/bench-results.json '
        '--output bench-results.json',
      ),
    );

    final uploads = _expectRetriedArtifactUpload(
      steps,
      firstStepId: 'upload_evidence',
      expectedCondition: null,
    );
    for (final upload in uploads) {
      final options = upload['with'] as YamlMap;
      expect(options['name'], _m0ArtifactPrefix);
      expect(options['path'], _m0ResultsPath);
      expect(options['overwrite'], isTrue);
    }
  });

  test('routes every M0 shard through measured network profiles', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-m0-runner-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final commandLog = File('${directory.path}/commands.log');
    final profileScript = File('${directory.path}/profile.sh');
    final benchCommand = File('${directory.path}/bench.sh');
    await _writeExecutable(profileScript, _fakeProfileScript);
    await _writeExecutable(benchCommand, _fakeBenchCommand);

    for (final entry in _expectedShardCommands.entries) {
      await commandLog.writeAsString('');
      final result = await Process.run(
        'tool/bench/run.sh',
        [entry.key],
        environment: {
          _m0CommandLogVariable: commandLog.path,
          _m0ProfileScriptVariable: profileScript.path,
          _m0BenchCommandVariable: benchCommand.path,
        },
      );

      expect(result.exitCode, 0, reason: '${entry.key}: ${result.stderr}');
      expect(await commandLog.readAsLines(), entry.value);
    }
  });

  test('clears the RTT profile after a benchmark failure', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-m0-failure-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final commandLog = File('${directory.path}/commands.log');
    final profileScript = File('${directory.path}/profile.sh');
    final benchCommand = File('${directory.path}/bench.sh');
    await _writeExecutable(profileScript, _fakeProfileScript);
    await _writeExecutable(benchCommand, _fakeFailingBenchCommand);

    final result = await Process.run(
      'tool/bench/run.sh',
      ['rtt100-1gb-upload'],
      environment: {
        _m0CommandLogVariable: commandLog.path,
        _m0ProfileScriptVariable: profileScript.path,
        _m0BenchCommandVariable: benchCommand.path,
      },
    );

    expect(result.exitCode, _benchFailureExitCode);
    expect(await commandLog.readAsLines(), [
      'profile lan',
      'profile rtt100',
      'profile measure-rtt-ms',
      'bench throughput --link rtt100 '
          '--throughput-slice=only-1gb-upload --reset '
          '--rtt-ms $_measuredRttMs',
      'profile lan',
    ]);
  });

  test('rejects an unknown M0 shard', () async {
    final result = await Process.run('tool/bench/run.sh', ['unknown']);

    expect(result.exitCode, _usageExitCode);
    expect('${result.stderr}', contains('usage: run.sh'));
  });
}

const _expectedShardCommands = {
  'full': [
    'profile lan',
    'bench throughput --link lan --reset',
    'profile lan',
    'bench pipeline',
    'bench algorithms',
    'profile lan',
    'profile rtt100',
    'profile measure-rtt-ms',
    'bench throughput --link rtt100 --rtt-ms $_measuredRttMs',
    'profile lan',
    'profile lan',
    'profile rtt100',
    'profile measure-rtt-ms',
    'bench pipeline --link rtt100 --rtt-ms $_measuredRttMs',
    'profile lan',
    'profile lan',
    'bench isolate',
  ],
  'standard': [
    'profile lan',
    'bench throughput --link lan --reset',
    'profile lan',
    'bench pipeline',
    'bench algorithms',
    'profile lan',
    'profile rtt100',
    'profile measure-rtt-ms',
    'bench throughput --link rtt100 '
        '--throughput-slice=without-1gb-upload --rtt-ms $_measuredRttMs',
    'profile lan',
    'profile lan',
    'profile rtt100',
    'profile measure-rtt-ms',
    'bench pipeline --link rtt100 --rtt-ms $_measuredRttMs',
    'profile lan',
    'profile lan',
    'bench isolate',
  ],
  'rtt100-1gb-upload': [
    'profile lan',
    'profile rtt100',
    'profile measure-rtt-ms',
    'bench throughput --link rtt100 '
        '--throughput-slice=only-1gb-upload --reset '
        '--rtt-ms $_measuredRttMs',
    'profile lan',
  ],
};

const _fakeProfileScript =
    '''#!/bin/sh
set -eu
printf 'profile %s\\n' "\$*" >> "\$$_m0CommandLogVariable"
if [ "\${1:-}" = 'measure-rtt-ms' ]; then
  printf '$_measuredRttMs\\n'
fi
''';

const _fakeBenchCommand =
    '''#!/bin/sh
set -eu
printf 'bench %s\\n' "\$*" >> "\$$_m0CommandLogVariable"
''';

const _fakeFailingBenchCommand =
    '''#!/bin/sh
set -eu
printf 'bench %s\\n' "\$*" >> "\$$_m0CommandLogVariable"
exit $_benchFailureExitCode
''';

YamlMap _stepNamed(Iterable<YamlMap> steps, String name) =>
    steps.singleWhere((step) => step['name'] == name);

List<YamlMap> _expectRetriedArtifactUpload(
  Iterable<YamlMap> steps, {
  required String firstStepId,
  required String? expectedCondition,
}) {
  final uploads = steps
      .where((step) => step['uses'] == 'actions/upload-artifact@v4')
      .toList();
  expect(uploads, hasLength(2));

  final first = uploads.first;
  expect(first['id'], firstStepId);
  expect(first['continue-on-error'], isTrue);
  if (expectedCondition != null) expect(first['if'], expectedCondition);

  final retry = uploads.last;
  expect(retry['if'], "always() && steps.$firstStepId.outcome == 'failure'");
  expect(retry.containsKey('continue-on-error'), isFalse);
  return uploads;
}

Future<void> _writeExecutable(File file, String contents) async {
  await file.writeAsString(contents);
  final chmod = await Process.run('chmod', ['700', file.path]);
  if (chmod.exitCode != 0) {
    throw StateError('chmod failed: ${chmod.stderr}');
  }
}
